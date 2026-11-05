#!/usr/bin/env python3
"""Generate the PD_CPU OFF-state corruption model from the elaborated netlist.

Every state element (flip-flop, latch, memory word) below the power-domain
boundary module is listed by elaborating the RTL with Yosys (``proc`` only, so
names are the RTL names) and walking the instance tree. The generated include
file provides, for use inside a testbench module:

  task pd_cpu_corrupt_state();   // overwrite all PD_CPU state with CORRUPT values
  task pd_cpu_force_outputs();   // drive all PD_CPU outputs to CORRUPT values
  task pd_cpu_release_outputs();
  localparam int PD_CPU_STATE_BITS / PD_CPU_STATE_ELEMS

The testbench defines the macros
  `PD_CPU_PATH                  hierarchical path of the domain instance
  `PD_CPU_CORRUPT(lhs, width)   statement corrupting lhs (X or random), NBA
  `PD_CPU_CORRUPT_BLK(lhs, w)   same, blocking (for clocked-block temporaries)
  `PD_CPU_FORCE(lhs, width)     statement forcing an output
so the same model works for 4-state (X) and 2-state (random) simulators.

Usage: gen_corrupt_model.py <yosys_json> <top_module> <out.svh>
"""
import json
import re
import sys

STATE_CELLS = {
    "$dff", "$adff", "$sdff", "$dffe", "$adffe", "$sdffe", "$sdffce", "$aldff",
    "$aldffe", "$dffsr", "$dffsre", "$dlatch", "$adlatch", "$dlatchsr", "$ff",
}


def sv_name(name: str) -> str:
    """Yosys public name -> SystemVerilog hierarchical path component(s)."""
    # Yosys names the scope of an unnamed 'else if' generate block twice
    # (genblkN.genblkN); IEEE 1800 gives the whole if-else-if chain one scope.
    name = re.sub(r"(genblk\d+)\.\1\.", r"\1.", name)
    return name


_src_cache = {}


def blocking_names(mod):
    """Names assigned with a blocking '=' somewhere in the module's source.

    Such variables (clocked-block temporaries) must be overwritten with a
    blocking assignment too: Verilator rejects mixing '=' and '<=' on one
    variable. All other state is corrupted with a non-blocking assignment.
    """
    text = module_text(mod)
    return set(re.findall(r"\b([A-Za-z_]\w*)\s*(?:\[[^\]]*\]\s*)?=(?!=)", text))


def module_text(mod):
    src = mod.get("attributes", {}).get("src", "")
    m = re.match(r"(.*):(\d+)\.\d+-(\d+)\.\d+$", src)
    if not m:
        return ""
    fname, first, last = m.group(1), int(m.group(2)), int(m.group(3))
    if fname not in _src_cache:
        try:
            _src_cache[fname] = open(fname).read().splitlines()
        except OSError:
            _src_cache[fname] = []
    return "\n".join(_src_cache[fname][first - 1:last])


def wire_names(mod):
    """Names declared as nets ('wire'): aliases of state, never written."""
    names = set()
    for decl in re.findall(r"\bwire\b([^;]*);", module_text(mod)):
        decl = re.sub(r"\[[^\]]*\]", " ", decl.split("=")[0])
        names.update(re.findall(r"[A-Za-z_]\w*", decl))
    return names


def collect(modules, mod_name, path, out):
    mod = modules[mod_name]
    netnames = mod["netnames"]
    blk = blocking_names(mod)
    wires = wire_names(mod)
    ports = set(mod.get("ports", {}))
    # A flop output bit can carry several names (e.g. "x_q" and the port "x_o"
    # driven by "assign x_o = x_q", or a debug "wire d = x"). Prefer the
    # variable, because a continuously-assigned net cannot be written.
    bit2net = {}
    for n, nv in sorted(netnames.items(),
                        key=lambda kv: (kv[0] in wires, kv[0] in ports, len(kv[0]), kv[0])):
        if n.startswith("$") or nv.get("hide_name"):
            continue
        for idx, b in enumerate(nv["bits"]):
            if isinstance(b, int):
                bit2net.setdefault(b, (n, idx))

    regs = {}
    for cell in mod["cells"].values():
        if cell["type"] not in STATE_CELLS:
            continue
        for b in cell["connections"].get("Q", []):
            if isinstance(b, int) and b in bit2net:
                n, _ = bit2net[b]
                regs[n] = len(netnames[n]["bits"])
    for n, width in sorted(regs.items()):
        kind = "blk" if n in blk else "reg"
        out.append((kind, f"{path}.{sv_name(n)}", width))

    for mname, mem in sorted(mod.get("memories", {}).items()):
        size = int(mem["size"])
        offset = int(mem.get("start_offset", 0))
        width = int(mem["width"])
        for i in range(offset, offset + size):
            out.append(("mem", f"{path}.{sv_name(mname)}[{i}]", width))

    for cname, cell in sorted(mod["cells"].items()):
        if cell["type"] in modules and not cname.startswith("$"):
            collect(modules, cell["type"], f"{path}.{sv_name(cname)}", out)


def main() -> int:
    src, top, dst = sys.argv[1], sys.argv[2], sys.argv[3]
    modules = json.load(open(src))["modules"]
    elems = []
    collect(modules, top, "`PD_CPU_PATH", elems)

    outputs = []
    for pname, port in modules[top]["ports"].items():
        if port["direction"] == "output":
            outputs.append((pname, len(port["bits"])))

    bits = sum(w for _, _, w in elems)
    lines = [
        "// Generated by scripts/gen_corrupt_model.py - do not edit.",
        f"// Power domain top: {top}",
        f"// State elements: {len(elems)} ({bits} bits), outputs: {len(outputs)}",
        f"localparam int PD_CPU_STATE_ELEMS = {len(elems)};",
        f"localparam int PD_CPU_STATE_BITS  = {bits};",
        "",
        "task automatic pd_cpu_corrupt_state();",
    ]
    for kind, p, w in elems:
        macro = "PD_CPU_CORRUPT_BLK" if kind == "blk" else "PD_CPU_CORRUPT"
        lines.append(f"  `{macro}({p}, {w})")
    lines += ["endtask", "", "task automatic pd_cpu_force_outputs();"]
    for p, w in outputs:
        lines.append(f"  `PD_CPU_FORCE(`PD_CPU_PATH.{p}, {w})")
    lines += ["endtask", "", "task automatic pd_cpu_release_outputs();"]
    for p, _ in outputs:
        lines.append(f"  release `PD_CPU_PATH.{p};")
    lines += ["endtask", ""]
    open(dst, "w").write("\n".join(lines))
    print(f"{dst}: {len(elems)} state elements, {bits} bits, {len(outputs)} outputs")
    return 0


if __name__ == "__main__":
    sys.exit(main())

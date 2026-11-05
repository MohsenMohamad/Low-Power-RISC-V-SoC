#!/usr/bin/env python3
"""Scripted, self-checking UART monitor sessions.

A session spec is a text file:
    > <command sent to the monitor>
    < <regex that must match a line of that command's response>
    ! <regex that must NOT match any line of that command's response>
    # comment
Lines before the first '>' apply to the boot output (before the first
prompt).

  monitor_check.py gen   <spec> <uart_in>   write the RX byte stream
  monitor_check.py check <spec> <uart_log>  verify the captured TX log;
                                            prints PASS/FAIL, exit 0/1
"""
import re
import sys

PROMPT = "mon> "


def parse(spec_path):
    steps = [{"cmd": None, "want": [], "deny": []}]
    for raw in open(spec_path):
        line = raw.rstrip("\n")
        if not line.strip() or line.startswith("#"):
            continue
        tag, body = line[:1], line[2:] if len(line) > 1 else ""
        if tag == ">":
            steps.append({"cmd": body, "want": [], "deny": []})
        elif tag == "<":
            steps[-1]["want"].append(body)
        elif tag == "!":
            steps[-1]["deny"].append(body)
        else:
            sys.exit("bad spec line: %r" % line)
    return steps


def gen(spec_path, out_path):
    with open(out_path, "w") as f:
        for st in parse(spec_path)[1:]:
            f.write(st["cmd"] + "\n")


def check(spec_path, log_path):
    steps = parse(spec_path)
    log = open(log_path, errors="replace").read().replace("\r", "")
    chunks = log.split(PROMPT)
    # chunk 0: boot output; chunk i: echo of command i + its response
    ok = True
    for i, st in enumerate(steps):
        name = "boot" if st["cmd"] is None else st["cmd"]
        if i >= len(chunks):
            print("FAIL [%s]: no output (session ended early)" % name)
            ok = False
            continue
        text = chunks[i]
        lines = text.split("\n")
        if st["cmd"] is not None:
            if lines[0].strip() != st["cmd"].strip():
                print("FAIL [%s]: echo mismatch: %r" % (name, lines[0]))
                ok = False
            lines = lines[1:]
        for pat in st["want"]:
            if not any(re.search(pat, l) for l in lines):
                print("FAIL [%s]: missing /%s/" % (name, pat))
                ok = False
        for pat in st["deny"]:
            hit = [l for l in lines if re.search(pat, l)]
            if hit:
                print("FAIL [%s]: unexpected /%s/: %r" % (name, pat, hit[0]))
                ok = False
    n = len(steps) - 1
    print("monitor session %s: %d commands, %s" % (spec_path, n, "PASS" if ok else "FAIL"))
    return ok


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("gen", "check"):
        sys.exit(__doc__)
    if sys.argv[1] == "gen":
        gen(sys.argv[2], sys.argv[3])
    else:
        sys.exit(0 if check(sys.argv[2], sys.argv[3]) else 1)


if __name__ == "__main__":
    main()

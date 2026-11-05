#!/usr/bin/env bash
# Single toolchain setup script (doc/SPEC.md "Toolchain"). Installs, or with
# --check only verifies, the exact tool versions used by `make test`. CI runs
# the same script (.github/workflows/ci.yml).
#
#   scripts/setup_toolchain.sh            install everything (Ubuntu 24.04, root or sudo)
#   scripts/setup_toolchain.sh --check    verify installed versions, exit 1 on any mismatch
#   scripts/setup_toolchain.sh --env      print the PATH/environment lines to use
#
# Pinned versions (the only versions `make test` results are reported for):
#   RISC-V GCC        13.2.0   Ubuntu 24.04 gcc-riscv64-unknown-elf 13.2.0-11ubuntu1+12
#   RISC-V binutils   2.42     Ubuntu 24.04 binutils-riscv64-unknown-elf 2.42-1ubuntu1+6
#                     (riscv-arch-test 3.9.1 is known to fail with GCC 14: compressed
#                     padding in the test macros; GCC 14 is rejected by --check)
#   Verilator         v5.054   built from source (VERILATOR_PREFIX)
#   Spike             riscv-isa-sim f90d5af53f50b0feec7a7cbcb4411e1e0410c465, built as libriscv
#   Icarus Verilog    12.0     Ubuntu 24.04 iverilog 12.0-2build2
#   Yosys             0.33     Ubuntu 24.04 yosys 0.33-5build2
#   SymbiYosys        tag yosys-0.33 (85dd50b92a3acf170954a06f20f49e2162ce5273)
#   Z3                5.3.3    PyPI z3-solver==5.3.3.0 (yosys-smtbmc and Verilator randomize();
#                     Ubuntu's 4.8.12 hangs in yosys-smtbmc)
#   sv2v              v0.0.13  release binary (SystemVerilog -> Verilog for Yosys 0.33 / Icarus)
#   riscv-arch-test   3.9.1    git submodule third_party/riscv-arch-test (eb66181)
#   Python            3.10 or newer
set -euo pipefail

GCC_VER=13.2.0
BINUTILS_VER=2.42
APT_GCC=13.2.0-11ubuntu1+12
APT_BINUTILS=2.42-1ubuntu1+6
APT_IVERILOG=12.0-2build2
APT_YOSYS=0.33-5build2
VERILATOR_TAG=v5.054
SPIKE_REV=f90d5af53f50b0feec7a7cbcb4411e1e0410c465
SBY_TAG=yosys-0.33
SBY_REV=85dd50b92a3acf170954a06f20f49e2162ce5273
Z3_PIP=5.3.3.0
SV2V_TAG=v0.0.13
ARCH_TEST_REV=eb66181dd27ff7847e2c3a010705b13490b0bf75

VERILATOR_PREFIX=${VERILATOR_PREFIX:-/opt/verilator-${VERILATOR_TAG#v}}
SPIKE_PREFIX=${SPIKE_PREFIX:-/opt/spike}
TOOLS_BIN=${TOOLS_BIN:-/usr/local/bin}
SRC=${SRC:-/opt/src}
JOBS=${JOBS:-$(nproc)}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

sudo_() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

env_lines() {
  echo "export PATH=$VERILATOR_PREFIX/bin:$SPIKE_PREFIX/bin:$TOOLS_BIN:\$PATH"
  echo "export SPIKE_PREFIX=$SPIKE_PREFIX"
}

# ------------------------------------------------------------------ check
check() {
  local bad=0
  export PATH="$VERILATOR_PREFIX/bin:$SPIKE_PREFIX/bin:$TOOLS_BIN:$PATH"
  ok()   { printf '  %-16s %-28s ok\n' "$1" "$2"; }
  fail() { printf '  %-16s %-28s MISMATCH: %s\n' "$1" "$2" "$3"; bad=1; }
  ver()  { "$@" 2>/dev/null | head -1 || true; }

  v=$(ver riscv64-unknown-elf-gcc -dumpfullversion)
  [ "$v" = "$GCC_VER" ] && ok riscv-gcc "$v" || fail riscv-gcc "${v:-absent}" "need $GCC_VER (GCC 14 breaks riscv-arch-test)"
  v=$(ver riscv64-unknown-elf-as --version | grep -o ' [0-9]\+\.[0-9]\+' | head -1 | tr -d ' ')
  [ "$v" = "$BINUTILS_VER" ] && ok riscv-binutils "$v" || fail riscv-binutils "${v:-absent}" "need $BINUTILS_VER"
  v=$(ver verilator --version | awk '{print $2}')
  [ "v$v" = "$VERILATOR_TAG" ] && ok verilator "$v" || fail verilator "${v:-absent}" "need $VERILATOR_TAG"
  if [ -f "$SPIKE_PREFIX/.rev" ] && [ "$(cat "$SPIKE_PREFIX/.rev")" = "$SPIKE_REV" ] && [ -x "$SPIKE_PREFIX/bin/spike" ]; then
    ok spike "${SPIKE_REV:0:12}"
  else
    fail spike "$(cat "$SPIKE_PREFIX/.rev" 2>/dev/null || echo absent)" "need $SPIKE_REV in $SPIKE_PREFIX"
  fi
  v=$(ver iverilog -V | awk '{print $4}')
  [ "$v" = "12.0" ] && ok iverilog "$v" || fail iverilog "${v:-absent}" "need 12.0"
  v=$(ver yosys -V | awk '{print $2}')
  [ "$v" = "0.33" ] && ok yosys "$v" || fail yosys "${v:-absent}" "need 0.33"
  if command -v sby >/dev/null && [ "$(cat "$TOOLS_BIN/.sby_rev" 2>/dev/null)" = "$SBY_REV" ]; then
    ok symbiyosys "$SBY_TAG"
  else
    fail symbiyosys "$(cat "$TOOLS_BIN/.sby_rev" 2>/dev/null || echo absent)" "need $SBY_TAG ($SBY_REV)"
  fi
  v=$(ver z3 --version | awk '{print $3}')
  [ "$v" = "${Z3_PIP%.0}" ] && ok z3 "$v ($(command -v z3))" || fail z3 "${v:-absent}" "need ${Z3_PIP%.0} first on PATH"
  v=$(ver sv2v --version | awk '{print $2}')
  [ "$v" = "$SV2V_TAG" ] && ok sv2v "$v" || fail sv2v "${v:-absent}" "need $SV2V_TAG"
  v=$(git -C "$ROOT/third_party/riscv-arch-test" rev-parse HEAD 2>/dev/null || true)
  [ "$v" = "$ARCH_TEST_REV" ] && ok riscv-arch-test "3.9.1" || fail riscv-arch-test "${v:-absent}" "git submodule update --init"
  v=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' && ok python3 "$v" || fail python3 "$v" "need >= 3.10"
  if [ $bad = 0 ]; then echo "TOOLCHAIN: all pinned versions present"; else echo "TOOLCHAIN: FAIL"; fi
  return $bad
}

# ------------------------------------------------------------------ install
install() {
  sudo_ apt-get update
  sudo_ env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential git python3 python3-pip autoconf bison flex help2man libfl-dev ccache curl unzip \
    device-tree-compiler libboost-regex-dev libboost-system-dev \
    "gcc-riscv64-unknown-elf=$APT_GCC" "binutils-riscv64-unknown-elf=$APT_BINUTILS" \
    "iverilog=$APT_IVERILOG" "yosys=$APT_YOSYS"
  sudo_ mkdir -p "$SRC" "$TOOLS_BIN"

  # Z3 (PyPI build; first on PATH via TOOLS_BIN)
  sudo_ python3 -m pip install --break-system-packages --prefix /usr/local "z3-solver==$Z3_PIP" \
    || sudo_ python3 -m pip install --prefix /usr/local "z3-solver==$Z3_PIP"

  # Verilator
  if ! "$VERILATOR_PREFIX/bin/verilator" --version 2>/dev/null | grep -q " ${VERILATOR_TAG#v} "; then
    sudo_ rm -rf "$SRC/verilator-$VERILATOR_TAG"
    sudo_ git clone --depth 1 --branch "$VERILATOR_TAG" https://github.com/verilator/verilator.git "$SRC/verilator-$VERILATOR_TAG"
    (cd "$SRC/verilator-$VERILATOR_TAG" && sudo_ autoconf && sudo_ ./configure --prefix="$VERILATOR_PREFIX" \
       && sudo_ make -j"$JOBS" && sudo_ make install)
  fi

  # Spike (libriscv for the co-simulation bridge)
  if [ "$(cat "$SPIKE_PREFIX/.rev" 2>/dev/null)" != "$SPIKE_REV" ]; then
    sudo_ rm -rf "$SRC/riscv-isa-sim"
    sudo_ git clone https://github.com/riscv-software-src/riscv-isa-sim.git "$SRC/riscv-isa-sim"
    (cd "$SRC/riscv-isa-sim" && sudo_ git checkout "$SPIKE_REV" && sudo_ git submodule update --init --depth 1 \
       && sudo_ mkdir -p build && cd build && sudo_ ../configure --prefix="$SPIKE_PREFIX" \
       && sudo_ make -j"$JOBS" && sudo_ make install)
    echo "$SPIKE_REV" | sudo_ tee "$SPIKE_PREFIX/.rev" >/dev/null
  fi

  # SymbiYosys
  if [ "$(cat "$TOOLS_BIN/.sby_rev" 2>/dev/null)" != "$SBY_REV" ]; then
    sudo_ rm -rf "$SRC/sby"
    sudo_ git clone https://github.com/YosysHQ/sby.git "$SRC/sby"
    (cd "$SRC/sby" && sudo_ git checkout "$SBY_REV" && sudo_ make install PREFIX="$(dirname "$TOOLS_BIN")")
    echo "$SBY_REV" | sudo_ tee "$TOOLS_BIN/.sby_rev" >/dev/null
  fi

  # sv2v
  if ! sv2v --version 2>/dev/null | grep -q "$SV2V_TAG"; then
    tmp=$(mktemp -d)
    curl -sSL -o "$tmp/sv2v.zip" "https://github.com/zachjs/sv2v/releases/download/$SV2V_TAG/sv2v-Linux.zip"
    (cd "$tmp" && unzip -q sv2v.zip)
    sudo_ install -m 755 "$tmp/sv2v-Linux/sv2v" "$TOOLS_BIN/sv2v"
    rm -rf "$tmp"
  fi

  # riscv-arch-test
  git -C "$ROOT" submodule update --init --depth 1 third_party/riscv-arch-test

  check
  echo "Add to the environment:"
  env_lines
}

case "${1:-}" in
  --check) check ;;
  --env)   env_lines ;;
  "")      install ;;
  *)       echo "usage: $0 [--check|--env]"; exit 2 ;;
esac

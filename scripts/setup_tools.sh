#!/usr/bin/env bash
# Install / build the verification tool chain (Ubuntu 24.04).
#   * RISC-V GCC (riscv64-unknown-elf), z3 (SMT solver for SV randomize())
#   * Verilator >= 5.036 (built from source; tested with v5.052)
#   * Spike (riscv-isa-sim, built from source, installed to $SPIKE_PREFIX)
# riscv-arch-test 3.9.1 is a git submodule: git submodule update --init
set -euo pipefail

VERILATOR_TAG=${VERILATOR_TAG:-v5.052}
VERILATOR_PREFIX=${VERILATOR_PREFIX:-/opt/verilator}
SPIKE_PREFIX=${SPIKE_PREFIX:-/opt/spike}
SPIKE_REV=${SPIKE_REV:-f90d5af53f50b0feec7a7cbcb4411e1e0410c465}   # version verified against
SRC=${SRC:-/opt/src}
JOBS=${JOBS:-$(nproc)}

sudo_() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

sudo_ apt-get update
sudo_ env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential git python3 autoconf bison flex help2man libfl-dev ccache \
  device-tree-compiler gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf z3

mkdir -p "$SRC"

if ! "$VERILATOR_PREFIX/bin/verilator" --version 2>/dev/null | grep -q "${VERILATOR_TAG#v}"; then
  rm -rf "$SRC/verilator"
  git clone --depth 1 --branch "$VERILATOR_TAG" https://github.com/verilator/verilator.git "$SRC/verilator"
  (cd "$SRC/verilator" && autoconf && ./configure --prefix="$VERILATOR_PREFIX" && make -j"$JOBS" && sudo_ make install)
fi

if [ ! -x "$SPIKE_PREFIX/bin/spike" ]; then
  rm -rf "$SRC/riscv-isa-sim"
  git clone https://github.com/riscv-software-src/riscv-isa-sim.git "$SRC/riscv-isa-sim"
  (cd "$SRC/riscv-isa-sim" && git checkout "$SPIKE_REV" && git submodule update --init --depth 1 && mkdir -p build && cd build \
     && ../configure --prefix="$SPIKE_PREFIX" && make -j"$JOBS" && sudo_ make install)
fi

echo "Tools ready. Example:"
echo "  export PATH=$VERILATOR_PREFIX/bin:\$PATH"
echo "  make test SPIKE_PREFIX=$SPIKE_PREFIX"

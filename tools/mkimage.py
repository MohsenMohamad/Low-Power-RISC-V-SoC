#!/usr/bin/env python3
"""Turn raw firmware binaries into loadable images.

  mkimage.py app <in.bin> <out.bin> <out.hex> --mem-base A --load-addr B
      Patch the CRC-32 into the application image header (see
      fw/include/handoff.h), check the header fields and write a word-wide
      $readmemh file for the RAM model (addresses relative to --mem-base).

  mkimage.py rom <in.bin> <out.hex> --size N
      Check the size and write a $readmemh file for the ROM model.
"""
import argparse
import struct
import sys
import zlib

IMAGE_MAGIC = 0x5041504C
HDR_FMT = "<8I"
HDR_SIZE = struct.calcsize(HDR_FMT)


def write_hex(path, data, word_offset):
    if len(data) % 4:
        data += b"\0" * (4 - len(data) % 4)
    with open(path, "w") as f:
        f.write("@%x\n" % word_offset)
        for i in range(0, len(data), 4):
            f.write("%08x\n" % struct.unpack_from("<I", data, i)[0])


def cmd_app(a):
    data = bytearray(open(a.input, "rb").read())
    if len(data) < HDR_SIZE:
        sys.exit("image too small")
    magic, ver, load, size, entry, _crc, _r0, _r1 = struct.unpack_from(HDR_FMT, data, 0)
    if magic != IMAGE_MAGIC:
        sys.exit("bad image magic 0x%08x" % magic)
    if load != a.load_addr:
        sys.exit("load address 0x%08x != 0x%08x" % (load, a.load_addr))
    if len(data) < size <= len(data) + 16:
        data += b"\0" * (size - len(data))      # alignment padding at the end
    if size != len(data):
        sys.exit("header size %d != binary size %d" % (size, len(data)))
    if not (load <= entry < load + size):
        sys.exit("entry 0x%08x outside image" % entry)
    crc = zlib.crc32(bytes(data[HDR_SIZE:])) & 0xFFFFFFFF
    struct.pack_into("<I", data, 20, crc)
    open(a.output, "wb").write(data)
    write_hex(a.hex, bytes(data), (load - a.mem_base) // 4)
    print("app image: %d bytes, entry 0x%08x, crc 0x%08x" % (size, entry, crc))


def cmd_rom(a):
    data = open(a.input, "rb").read()
    if len(data) > a.size:
        sys.exit("ROM image %d bytes exceeds %d" % (len(data), a.size))
    write_hex(a.output, data, 0)
    print("rom image: %d of %d bytes used" % (len(data), a.size))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    pa = sub.add_parser("app")
    pa.add_argument("input")
    pa.add_argument("output")
    pa.add_argument("hex")
    pa.add_argument("--mem-base", type=lambda s: int(s, 0), required=True)
    pa.add_argument("--load-addr", type=lambda s: int(s, 0), required=True)
    pr = sub.add_parser("rom")
    pr.add_argument("input")
    pr.add_argument("output")
    pr.add_argument("--size", type=lambda s: int(s, 0), required=True)
    a = p.parse_args()
    cmd_app(a) if a.cmd == "app" else cmd_rom(a)


if __name__ == "__main__":
    main()

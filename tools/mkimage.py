#!/usr/bin/env python3
"""Turn raw firmware binaries into loadable images.

  mkimage.py app <in.bin> <out.bin> <out.hex> --mem-base A --load-addr B
      Check every image header field against doc/BOOT_ABI.md (exactly the
      rules the boot ROM applies, so an image the ROM would reject is a build
      error), patch the CRC-32 and write a word-wide $readmemh file for the RAM
      model (addresses relative to --mem-base).

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


IMAGE_VERSION = 1
RAM_SIZE = 0x20000          # doc/SPEC.md; the image may not run past the RAM
APP_OFFSET = 0x1000         # doc/BOOT_ABI.md: image at RAM_BASE + 0x1000


def check_header(magic, ver, load, size, entry, rsvd0, rsvd1, length, load_addr, mem_base):
    """Return a list of rule violations (doc/BOOT_ABI.md "Application image")."""
    errs = []
    if magic != IMAGE_MAGIC:
        errs.append("bad image magic 0x%08x" % magic)
    if ver != IMAGE_VERSION:
        errs.append("header version %d != %d" % (ver, IMAGE_VERSION))
    if load != load_addr:
        errs.append("load address 0x%08x != 0x%08x" % (load, load_addr))
    if load != mem_base + APP_OFFSET:
        errs.append("load address 0x%08x is not RAM base + 0x%x" % (load, APP_OFFSET))
    if size != length:
        errs.append("header size %d != binary size %d" % (size, length))
    if size % 4:
        errs.append("image size %d is not a multiple of 4" % size)
    if size < HDR_SIZE or size > RAM_SIZE - APP_OFFSET:
        errs.append("image size %d outside [%d, %d]" % (size, HDR_SIZE, RAM_SIZE - APP_OFFSET))
    if not (load + HDR_SIZE <= entry < load + size):
        errs.append("entry 0x%08x outside the image body" % entry)
    if entry % 4:
        errs.append("entry 0x%08x is not 4-byte aligned" % entry)
    if rsvd0 or rsvd1:
        errs.append("reserved header words are not 0")
    return errs


def cmd_app(a):
    data = bytearray(open(a.input, "rb").read())
    if len(data) < HDR_SIZE:
        sys.exit("image too small")
    magic, ver, load, size, entry, _crc, r0, r1 = struct.unpack_from(HDR_FMT, data, 0)
    if len(data) < size <= len(data) + 16:
        data += b"\0" * (size - len(data))      # alignment padding at the end
    errs = check_header(magic, ver, load, size, entry, r0, r1, len(data), a.load_addr, a.mem_base)
    if errs:
        sys.exit("mkimage: invalid image %s: %s" % (a.input, "; ".join(errs)))
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

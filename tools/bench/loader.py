"""Firmware loading through the monitor, with checksum verification.

The image (tools/mkimage.py format: 32-byte header "LPAP", load address,
size, entry, CRC-32 of the bytes after the header) is checked on the host,
written with 'poke', read back with 'peek <addr> <n>' and its CRC-32
compared with the host CRC. The boot ROM checks the header CRC again when
it boots the image after 'reset'.
"""
import binascii
import struct

HDR_FMT = "<8I"
IMAGE_MAGIC = 0x5041504C


class LoadError(Exception):
    pass


def read_image(path):
    data = open(path, "rb").read()
    if len(data) < 32 or len(data) % 4:
        raise LoadError("%s: not a word-aligned image" % path)
    magic, ver, load, size, entry, crc, _r0, _r1 = struct.unpack_from(HDR_FMT, data, 0)
    if magic != IMAGE_MAGIC:
        raise LoadError("%s: bad magic 0x%08x" % (path, magic))
    if size != len(data):
        raise LoadError("%s: header size %d != file size %d" % (path, size, len(data)))
    if binascii.crc32(data[32:]) & 0xFFFFFFFF != crc:
        raise LoadError("%s: header CRC does not match the image" % path)
    return {"data": data, "load": load, "entry": entry, "crc": crc, "size": size}


def load(mon, path, chunk=64, progress=None):
    """Write the image with poke and verify it by read-back. Returns the image dict."""
    img = read_image(path)
    data, base = img["data"], img["load"]
    words = struct.unpack("<%dI" % (len(data) // 4), data)
    for i, w in enumerate(words):
        mon.poke(base + 4 * i, w)
        if progress and i % 256 == 0:
            progress("  load %d/%d words" % (i, len(words)))
    # read back
    back = []
    for i in range(0, len(words), chunk):
        n = min(chunk, len(words) - i)
        v = mon.peek(base + 4 * i, n)
        back += v if isinstance(v, list) else [v]
    rb = struct.pack("<%dI" % len(back), *back)
    host_crc = binascii.crc32(data) & 0xFFFFFFFF
    tgt_crc = binascii.crc32(rb) & 0xFFFFFFFF
    if host_crc != tgt_crc:
        bad = next(i for i in range(len(words)) if words[i] != back[i])
        raise LoadError("read-back CRC 0x%08x != 0x%08x (first bad word at 0x%08x)" % (tgt_crc, host_crc, base + 4 * bad))
    img["verified_crc"] = tgt_crc
    return img

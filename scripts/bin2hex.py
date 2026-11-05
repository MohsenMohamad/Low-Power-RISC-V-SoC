#!/usr/bin/env python3
"""Convert a flat little-endian binary into a $readmemh word file."""
import sys


def main() -> int:
    src, dst, words = sys.argv[1], sys.argv[2], int(sys.argv[3])
    data = open(src, "rb").read()
    if len(data) > 4 * words:
        print(f"error: image is {len(data)} bytes, ROM holds {4 * words}", file=sys.stderr)
        return 1
    data += b"\x00" * (-len(data) % 4)
    with open(dst, "w") as f:
        for i in range(0, len(data), 4):
            f.write(f"{int.from_bytes(data[i:i + 4], 'little'):08x}\n")
    print(f"{dst}: {len(data)} bytes ({len(data) * 100 // (4 * words)}% of ROM)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

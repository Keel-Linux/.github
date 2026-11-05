#!/usr/bin/python3 -I
"""Write a binary PPM (P6, maxval 255) as a PNG, with the standard library only.

usage: ppm2png.py IN.ppm OUT.png

QEMU's screendump writes a P6 file. keel-commission sends this script to
the PVE host (python3 - IN OUT) and converts each screen there, so the
host needs no other package and only the smaller PNG crosses the link.

Exit 0 on success, 2 for a usage error or a file that is no P6 PPM.
"""

import struct
import sys
import zlib


def header(data):
    """The width, height and offset of the pixels of a P6 PPM"""
    fields, pos = [], 2
    if data[:2] != b"P6":
        raise ValueError("not a P6 PPM")
    while len(fields) < 3:
        while pos < len(data) and data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos)
            continue
        start = pos
        while pos < len(data) and data[pos:pos + 1].isdigit():
            pos += 1
        if start == pos:
            raise ValueError("a bad PPM header")
        fields.append(int(data[start:pos]))
    width, height, maxval = fields
    if maxval != 255:
        raise ValueError("maxval %d is not 255" % maxval)
    pos += 1
    if len(data) - pos < width * height * 3:
        raise ValueError("the PPM is short")
    return width, height, pos


def chunk(kind, body):
    crc = zlib.crc32(kind + body) & 0xFFFFFFFF
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", crc)


def png(data):
    width, height, pos = header(data)
    stride = width * 3
    rows = b"".join(b"\x00" + data[pos + y * stride:pos + (y + 1) * stride]
                    for y in range(height))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b""))


def main(argv):
    if len(argv) != 3:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    try:
        with open(argv[1], "rb") as handle:
            out = png(handle.read())
    except (OSError, ValueError) as error:
        print("ppm2png: %s: %s" % (argv[1], error), file=sys.stderr)
        return 2
    with open(argv[2], "wb") as handle:
        handle.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

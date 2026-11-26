#!/usr/bin/python3 -I
"""The text of a VM screen, read from the picture that QEMU gives
(qm monitor screendump), with no agent in the guest.

usage: screentext.py PPM           print the text of the screen in PPM
       screentext.py --png PNG     the same for a PNG of ppm2png.py
       screentext.py --font        exit 0 when the console font loads

The Linux console of the VM (the framebuffer of --vga std) draws each
character in a cell of 8 x 16 pixels, with one foreground colour and one
background colour. A cell is made a bitmap: the colour of fewer pixels is
"on" (for a tie, the colour of the top left pixel is "off"). The glyphs
of the console font give the character of each known bitmap, as /dev/vcs1
gives it: the code of the glyph as a Latin-1 character. A cell of one
colour is a blank.

The font is read when the command runs, never kept in this repository:
- KC_CONSOLE_FONT, when set: a PSF file (PSF 1 or 2, gzip or not), glyph
  N for code N, as the console holds it;
- else the console font of the host itself, from /dev/tty1 (or /dev/tty0)
  with the KDFONTOP ioctl, as `setfont -O` reads it. A PVE host loads no
  console font, so its console has the built-in VGA 8x16 font of Linux,
  the font of the VM console (BR1 test PVE host, 2026-11-26: the same
  bytes as lib/fonts/font_8x16.c). The VGA16 fonts of console-setup are
  not the same ("f", "v" and quotes differ): do not use them.
A font that is not 8 x 16, or no font, is exit 3 with what to do. The underline cursor of the
console inverts the 2 bottom rows of its cell: a bitmap that is not known
is tried again with those rows inverted.

A cell that is not known is written as U+FFFD. Each row of cells is one
line, with the trailing blanks removed. A picture whose size is not a
multiple of the cell, or in which more than a quarter of the cells that
are not blank are not known (a graphic boot menu, a BIOS text mode screen),
is not read: exit 1. Exit 2 for a usage error, 3 for no font.

Standard library only: keel-commission runs this on the PVE host.
"""

import ctypes
import fcntl
import gzip
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ppm2png  # noqa: E402

CELL_W = 8
CELL_H = 16
CURSOR_ROWS = 2
UNKNOWN = "�"
# the most cells, as a part of the cells that are not blank, that may be
# unknown on a screen that is read
MAX_UNKNOWN = 0.25
TTYS = ("/dev/tty1", "/dev/tty0")
KDFONTOP = 0x4B72
KD_FONT_OP_GET = 1
# the most that KD_FONT_OP_GET gives: 512 glyphs of 32 rows of 32 pixels
MAX_GLYPHS, MAX_SIZE = 512, 32
PSF1_MAGIC = b"\x36\x04"
PSF2_MAGIC = b"\x72\xb5\x4a\x86"
FONT_HELP = ("set KC_CONSOLE_FONT on the PVE host to a PSF of the Linux VGA"
             " 8x16 font (lib/fonts/font_8x16.c), or run as root on a host"
             " whose console has no other font loaded")


class FontError(Exception):
    """No 8 x 16 console font"""


class _FontOp(ctypes.Structure):
    # struct console_font_op of linux/kd.h
    _fields_ = [("op", ctypes.c_uint), ("flags", ctypes.c_uint),
                ("width", ctypes.c_uint), ("height", ctypes.c_uint),
                ("charcount", ctypes.c_uint), ("data", ctypes.c_void_p)]


def console_glyphs(tty):
    """(width, height, [glyph rows]) of the font of the console TTY"""
    data = ctypes.create_string_buffer(MAX_GLYPHS * MAX_SIZE * 4)
    op = _FontOp(KD_FONT_OP_GET, 0, MAX_SIZE, MAX_SIZE, MAX_GLYPHS,
                 ctypes.addressof(data))
    fd = os.open(tty, os.O_RDONLY | os.O_NOCTTY)
    try:
        fcntl.ioctl(fd, KDFONTOP, op)
    finally:
        os.close(fd)
    # GET keeps 32 rows a glyph, one byte a row for a width of 8
    return op.width, op.height, [data.raw[i * MAX_SIZE:i * MAX_SIZE + op.height]
                                 for i in range(op.charcount)]


def psf_glyphs(path):
    """(width, height, [glyph rows]) of a PSF 1 or PSF 2 file"""
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    if data[:2] == PSF1_MAGIC:
        mode, height = data[2], data[3]
        count, offset, size, width = 512 if mode & 1 else 256, 4, height, 8
    elif data[:4] == PSF2_MAGIC:
        offset, _, count, size, height, width = struct.unpack(
            "<IIIIII", data[8:32])
    else:
        raise FontError("%s is no PSF file" % path)
    if len(data) < offset + count * size:
        raise FontError("%s is short" % path)
    return width, height, [data[offset + i * size:offset + (i + 1) * size]
                           for i in range(count)]


def canonical(bits):
    """BITS with the colour of fewer pixels on (for a tie, the top left
    pixel off), as bitmap() makes a cell"""
    on = sum(bin(b).count("1") for b in bits)
    total = CELL_W * CELL_H
    if on * 2 > total or (on * 2 == total and bits[0] & 0x80):
        bits = bytes(b ^ 0xFF for b in bits)
    return bits


def load_font():
    """{bitmap: character} of the console font; raises FontError"""
    path = os.environ.get("KC_CONSOLE_FONT")
    if path:
        try:
            width, height, glyphs = psf_glyphs(path)
        except OSError as error:
            raise FontError("KC_CONSOLE_FONT: %s" % error) from error
    else:
        errors = []
        for tty in TTYS:
            try:
                width, height, glyphs = console_glyphs(tty)
                break
            except OSError as error:
                errors.append("%s: %s" % (tty, error.strerror))
        else:
            raise FontError("no console font (%s): %s"
                            % ("; ".join(errors), FONT_HELP))
    if (width, height) != (CELL_W, CELL_H):
        raise FontError("the console font is %dx%d, not %dx%d: %s"
                        % (width, height, CELL_W, CELL_H, FONT_HELP))
    table = {}
    # printable ASCII first: of a glyph and its inverse, ASCII is kept
    order = list(range(0x20, 0x7F)) + [code for code in range(256)
                                       if not 0x20 <= code < 0x7F]
    for code in order:
        if code < len(glyphs):
            bits = canonical(glyphs[code])
            if any(bits):
                table.setdefault(bits, chr(code))
    return table


def pixels_ppm(data):
    """(width, height, rows of RGB bytes) of a P6 PPM"""
    width, height, pos = ppm2png.header(data)
    stride = width * 3
    return width, height, [data[pos + y * stride:pos + (y + 1) * stride]
                           for y in range(height)]


def pixels_png(data):
    """(width, height, rows of RGB bytes) of a PNG as ppm2png.py writes it:
    8-bit RGB, filter 0 on each row"""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, width, height = 8, b"", 0, 0
    while pos + 8 <= len(data):
        size, = struct.unpack(">I", data[pos:pos + 4])
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + size]
        if kind == b"IHDR":
            width, height, depth, colour = struct.unpack(">IIBB", body[:10])
            if (depth, colour) != (8, 2):
                raise ValueError("not an 8-bit RGB PNG")
        elif kind == b"IDAT":
            idat += body
        pos += 12 + size
    raw = zlib.decompress(idat)
    stride = width * 3 + 1
    rows = []
    for y in range(height):
        if raw[y * stride] != 0:
            raise ValueError("a PNG row filter that is not 0")
        rows.append(raw[y * stride + 1:(y + 1) * stride])
    return width, height, rows


def bitmap(rows, cx, cy):
    """The bitmap of the cell at column CX and row CY, None for a cell of
    one colour, b"" for a cell of more than two colours"""
    x0, width = cx * CELL_W * 3, CELL_W * 3
    parts = [rows[cy * CELL_H + y][x0:x0 + width] for y in range(CELL_H)]
    first = parts[0][:3]
    if all(part == first * CELL_W for part in parts):
        return None
    counts = {}
    pixels = [[part[x * 3:x * 3 + 3] for x in range(CELL_W)] for part in parts]
    for row in pixels:
        for colour in row:
            counts[colour] = counts.get(colour, 0) + 1
    if len(counts) != 2:
        return b""
    (one, n_one), (two, n_two) = counts.items()
    off = one if n_one > n_two else two
    if n_one == n_two:
        off = first
    return bytes(sum(0x80 >> x for x in range(CELL_W) if row[x] != off)
                 for row in pixels)


def under_cursor(bits):
    """BITS with the rows of the underline cursor inverted, made canonical
    again (the colour of fewer pixels on)"""
    keep = CELL_H - CURSOR_ROWS
    return canonical(bits[:keep] + bytes(b ^ 0xFF for b in bits[keep:]))


def character(bits, font):
    if bits is None:
        return " "
    if bits in font:
        return font[bits]
    if not bits:
        return UNKNOWN
    bits = under_cursor(bits)
    if not any(bits):
        # the cursor on a blank
        return " "
    return font.get(bits, UNKNOWN)


def text(width, height, rows, font):
    """The lines of the screen; raises Unreadable"""
    if width % CELL_W or height % CELL_H or not width or not height:
        raise Unreadable("%dx%d is no grid of %dx%d cells"
                         % (width, height, CELL_W, CELL_H))
    lines, marked, unknown = [], 0, 0
    for cy in range(height // CELL_H):
        line = ""
        for cx in range(width // CELL_W):
            bits = bitmap(rows, cx, cy)
            char = character(bits, font)
            marked += bits is not None
            unknown += char == UNKNOWN
            line += char
        lines.append(line.rstrip())
    if marked and unknown > marked * MAX_UNKNOWN:
        raise Unreadable("%d of %d cells are no known character"
                         % (unknown, marked))
    return lines


def main(argv):
    args = argv[1:]
    if args == ["--font"]:
        args = []
    png = args[:1] == ["--png"]
    if png:
        args = args[1:]
    if len(args) != 1 and argv[1:] != ["--font"]:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    try:
        font = load_font()
    except FontError as error:
        print("screentext: %s" % error, file=sys.stderr)
        return 3
    if not args:
        return 0
    try:
        with open(args[0], "rb") as handle:
            data = handle.read()
        picture = (pixels_png if png else pixels_ppm)(data)
        lines = text(*picture, font)
    except (OSError, ValueError, zlib.error, Unreadable) as error:
        print("screentext: %s: %s" % (args[0], error), file=sys.stderr)
        return 1
    sys.stdout.write("".join(line + "\n" for line in lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

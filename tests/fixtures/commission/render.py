#!/usr/bin/python3 -I
"""render.py TEXT PPM: draw the lines of the file TEXT as a console screen
of 80 x 25 cells of 8 x 16 pixels, with the glyphs of the PSF file
KC_CONSOLE_FONT, light grey on blue, as qm monitor screendump gives it.
U+FFFD is a cell of three colours, which is no glyph.
render.py --graphic PPM: a picture that is no console text (a boot menu).
render.py --font PSF: write a PSF 1 font of 256 glyphs of 8 x 16 for the
tests: glyph N has N in its first row and one pixel in its second row, so
every glyph is a different bitmap. It is no real font: the tests of real
screens read the font of a console.
A test helper: not shipped."""

import os
import sys

COLS, ROWS, CW, CH = 80, 25, 8, 16
FG, BG = b"\xaa\xaa\xaa", b"\x00\x00\xaa"
ODD = b"\xff\x55\x55"
NO_GLYPH = "�"


def write_font(path):
    glyphs = b"".join(bytes([code, 0x01]) + bytes(CH - 2) for code in range(256))
    with open(path, "wb") as f:
        f.write(b"\x36\x04\x00" + bytes([CH]) + glyphs)


def glyphs():
    with open(os.environ["KC_CONSOLE_FONT"], "rb") as f:
        data = f.read()
    return {chr(code): data[4 + code * CH:4 + (code + 1) * CH]
            for code in range(256)}


def screen(lines, table):
    blank = bytes(CH)
    rows = []
    for cy in range(ROWS):
        line = (lines[cy] if cy < len(lines) else "")[:COLS].ljust(COLS)
        cells = [table.get(c, blank) if c != " " else blank for c in line]
        for y in range(CH):
            rows.append(b"".join(
                b"".join(ODD if c == NO_GLYPH and x == y % CW
                         else FG if cell[y] & (0x80 >> x) else BG
                         for x in range(CW))
                for c, cell in zip(line, cells)))
    return rows


def graphic():
    return [bytes((x * 7 + y * 3) % 256 for x in range(640 * 3))
            for y in range(480)]


def main(argv):
    if argv[1] == "--font":
        write_font(argv[2])
        return
    if argv[1] == "--graphic":
        rows, out = graphic(), argv[2]
    else:
        with open(argv[1], encoding="utf-8") as f:
            lines = f.read().split("\n")
        rows, out = screen(lines, glyphs()), argv[2]
    width = len(rows[0]) // 3
    with open(out, "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (width, len(rows)) + b"".join(rows))


if __name__ == "__main__":
    main(sys.argv)

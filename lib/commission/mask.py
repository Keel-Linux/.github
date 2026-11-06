#!/usr/bin/python3 -I
"""Mask the invites of a cloud pass in every file under a directory.

usage: mask.py DIR < INVITES

INVITES has one invite per line. Each is replaced by "<invite N>", and so
is each longest piece of it of PIECE bytes or more: an input box narrower
than the invite shows windows of it that slide while it is typed.
"""

import os
import re
import sys

PIECE = 12


def masked(run, invite, mark):
    """run with each longest piece of invite of PIECE bytes or more marked"""
    grams = {invite[i:i + PIECE] for i in range(len(invite) - PIECE + 1)}
    if not any(run[i:i + PIECE] in grams for i in range(len(run) - PIECE + 1)):
        return run
    out, i = b"", 0
    while i < len(run):
        end = next((j for j in range(len(run), i + PIECE - 1, -1) if run[i:j] in invite), 0)
        out, i = (out + mark, end) if end else (out + run[i:i + 1], i + 1)
    return out


def main(directory, invites):
    """Mask each invite in each file under directory"""
    for top, _, names in os.walk(directory):
        for name in names:
            path = os.path.join(top, name)
            with open(path, "rb") as handle:
                text = old = handle.read()
            for n, invite in enumerate(invites, 1):
                mark = b"<invite %d>" % n
                text = re.sub(rb"[A-Za-z0-9_.~+/=:-]{%d,}" % PIECE,
                              lambda m: masked(m.group(0), invite, mark), text)
            if text != old:
                with open(path, "wb") as handle:
                    handle.write(text)


if __name__ == "__main__":
    main(sys.argv[1], [line.rstrip("\n").encode() for line in sys.stdin if line.strip()])

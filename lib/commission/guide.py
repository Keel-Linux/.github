#!/usr/bin/python3 -I
"""Write the guide of a commissioning run (decision 0076): OUT/guide.md.

usage: guide.py OUT

Each pass of the run has a section with a table: one column for each node
(one column only for a pass of one machine), and one row for each screen
in the order the node showed it: the screenshot (or the text frame of a
container's console, or a web page) and, under it, what the operator typed
or chose. The rows come from the screens.tsv of each machine, which
keel-commission writes with the answers already masked: a secret is named
("the root secret"), never given.

    OUT/PASS/screens.tsv          a pass of one machine
    OUT/PASS/NODE/screens.tsv     a pass of several nodes, NODE/meta beside

A screens.tsv line is "NN<TAB>LABEL<TAB>FILE<TAB>ANSWER", FILE relative to
the folder of the screens.tsv.
"""

import os
import sys


def read_rows(folder):
    rows = []
    with open(os.path.join(folder, "screens.tsv"), encoding="utf-8") as handle:
        for line in handle:
            fields = (line.rstrip("\n").split("\t") + ["", "", "", ""])[:4]
            rows.append(fields)
    return rows


def read_meta(folder):
    meta = {}
    try:
        with open(os.path.join(folder, "meta"), encoding="utf-8") as handle:
            for line in handle:
                key, _, value = line.rstrip("\n").partition("\t")
                meta[key] = value
    except OSError:
        pass
    return meta


def cell(out, folder, row):
    _, label, path, answer = row
    link = os.path.relpath(os.path.join(folder, path), out).replace(" ", "%20")
    if path.endswith(".png"):
        shown = "![%s](%s)" % (label, link)
    else:
        shown = "[%s](%s)" % (label, link)
    if answer:
        shown += "<br>typed: `%s`" % answer.replace("|", "\\|").replace("`", "'")
    return shown


def columns(out, name):
    """The (title, folder) of each machine of the pass NAME"""
    base = os.path.join(out, name)
    if os.path.exists(os.path.join(base, "screens.tsv")):
        return [(name, base)]
    found = []
    for node in sorted(os.listdir(base)):
        folder = os.path.join(base, node)
        if os.path.exists(os.path.join(folder, "screens.tsv")):
            meta = read_meta(folder)
            title = node
            if meta.get("role"):
                title = "%s, %s (%s)" % (node, meta["role"], meta.get("site", ""))
            found.append((int(meta.get("vmid", 0) or 0), title, folder))
    return [(title, folder) for _, title, folder in sorted(found)]


def section(out, name):
    cols = columns(out, name)
    if not cols:
        return []
    tables = [read_rows(folder) for _, folder in cols]
    lines = ["## %s" % name, "",
             "| Step | " + " | ".join(title for title, _ in cols) + " |",
             "|---|" + "---|" * len(cols)]
    for i in range(max(len(t) for t in tables)):
        cells = [cell(out, folder, rows[i]) if i < len(rows) else ""
                 for (_, folder), rows in zip(cols, tables)]
        lines.append("| %d | %s |" % (i + 1, " | ".join(cells)))
    return lines + [""]


def main(argv):
    if len(argv) != 2 or not os.path.isdir(argv[1]):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    out = argv[1]
    lines = ["# Commissioning guide", "",
             "Each column is one machine; each row is one screen, in the order "
             "the machine showed it, with what the operator typed or chose. "
             "A secret is named, never shown.", ""]
    for name in sorted(os.listdir(out)):
        if os.path.isdir(os.path.join(out, name)):
            lines += section(out, name)
    with open(os.path.join(out, "guide.md"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

"""The published images of an application page (decision 0077), for pages.py.

The image list is the output of sha256sum over the published files: one
line "SHA256  FILE" for each template and ISO. A page names the template
and the ISO of its own application from this list, and every pass it
shows must have run exactly that file with exactly that sha256. A node of
another application (own no in its meta, such as the Core witness of a
cloud advanced pass) must run an image of the list, but never stands in
for the image of the page.
"""

import os
import re

from pagehtml import Refused

LINE = re.compile(r"([0-9a-f]{64}) [ *]([^/\s]+)")
FILE = r"debian-[0-9]+-%s_([0-9][0-9.]*-[0-9]+)_amd64\.(tar\.zst|iso)"


def read(path):
    """{file name: sha256} of the image list at PATH"""
    found = {}
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError as error:
        raise Refused("%s: %s" % (path, error.strerror)) from error
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        match = LINE.fullmatch(line.strip())
        if not match:
            raise Refused("%s line %d: not SHA256  FILE" % (os.path.basename(path), number))
        found[match.group(2)] = match.group(1)
    return found


def own(images, repo, release):
    """{"template": (file, sha256), "iso": (file, sha256) or None} of REPO
    in IMAGES; refused unless the list names one template of REPO and the
    version in its name is RELEASE, the head of the changelog"""
    pattern = re.compile(FILE % re.escape(repo))
    kinds = {"template": [], "iso": []}
    for name in sorted(images):
        match = pattern.fullmatch(name)
        if match:
            kinds["template" if match.group(2) == "tar.zst" else "iso"].append((name, match.group(1)))
    if not kinds["template"]:
        raise Refused("the image list names no template of %s" % repo)
    result = {}
    for kind, found in kinds.items():
        if len(found) > 1:
            raise Refused("the image list names %d %ss of %s" % (len(found), kind, repo))
        if not found:
            result[kind] = None
            continue
        name, version = found[0]
        if version != release:
            raise Refused("the image list names %s %s, but the changelog of the repository says %s"
                          % (repo, version, release))
        result[kind] = (name, images[name])
    return result


def ran(meta, key):
    """(file name, sha256) that a meta file says the pass or node ran"""
    value = meta.get(key, "")
    return os.path.basename(value.partition(":")[2] or value), meta.get("sha256", "")


def same(where, got, want):
    """Refused unless GOT, the (file, sha256) a run names, is WANT"""
    if got[0] != want[0]:
        raise Refused("%s: ran %s, not %s" % (where, got[0] or "no file", want[0]))
    if got[1] != want[1]:
        raise Refused("%s: ran %s with sha256 %s, the list names %s..."
                      % (where, got[0], got[1][:16] + "..." if got[1] else "none", want[1][:16]))


def other(where, got, images, page):
    """Refused unless a node of another application ran an image of the list"""
    if got[1] == page[1]:
        raise Refused("%s: own no, but it ran the image of the page" % where)
    if images.get(got[0]) != got[1]:
        raise Refused("%s: ran %s with sha256 %s..., which the list does not name"
                      % (where, got[0], got[1][:16]))


def where(folder, parts=2):
    """The last PARTS parts of FOLDER, to name a run or a file in a message"""
    return "/".join(os.path.normpath(folder).split(os.sep)[-parts:])


def check(passes, images, page):
    """Refused unless every pass and node of PASSES ran the image of PAGE,
    {"template": ..., "iso": ...} as own() gives it"""
    for one in passes:
        if one["mode"] == "simple":
            kind = "iso" if one["name"] == "vm-iso" else "template"
            want = page[kind]
            if want is None:
                raise Refused("%s: the image list names no %s of the application" % (where(one["folder"]), kind))
            same(where(one["folder"]), ran(one["meta"], kind), want)
            continue
        same(where(one["folder"]), (page["template"][0], one["meta"].get("sha256", "")), page["template"])
        for node in one["nodes"]:
            got = ran(node["meta"], "image")
            if node["meta"].get("own", "yes") == "no":
                other(where(node["folder"]), got, images, page["template"])
            else:
                same(where(node["folder"]), got, page["template"])

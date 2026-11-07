#!/usr/bin/python3 -I
"""Make the page of an application from its commissioning (decision 0077).

usage: pages.py build APP OUT --repo DIR --mode MODE=DIR... [--invites FILE]
       pages.py check OUT [--invites FILE]

build writes OUT/index.html and OUT/img/: the page that keellinux.org/apps/APP/
serves from the "pages" branch of the appliance repository. It reads:

    lib/commission/apps.yaml   the name and the version of the application
    --repo DIR                 a checkout of the appliance repository: its
                               changelog (the Keel release), README.rst (what
                               the application is) and the manifest of
                               packages/*/manifest.yaml when there is one
    --mode simple=DIR          a run of single machines: DIR/SITE/PASS/ with
                               meta, record.tsv and screens.tsv (lxc-* and
                               vm-iso), as keel-commission writes them
    --mode cloud_simple=DIR    a pass of several nodes: DIR/meta and
    --mode cloud_advanced=DIR  DIR/NODE/ for each node

Every pass and every check of a node must have passed: a page never shows
an image that did not pass. The page holds the text frames of a
container's screens, and these hold the invite of the mesh when the run did
not mask it. So the text is masked again with the invites of --invites, one
for each line, as mask.py does, and then every text file of OUT is checked:
build and check stop with status 1 when a "keelN:" token, a piece of an
invite of 12 characters or more, or a run of 12 characters or more that
has an upper case letter, a lower case letter and a digit (a piece of a
token or of a password) is in it. A picture cannot be masked, so a picture
of an invite or a join screen stops the build.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import mask  # noqa: E402  (beside this file)
import pagehtml  # noqa: E402
import yaml  # noqa: E402

MODES = ("simple", "cloud_simple", "cloud_advanced")
INVITE = re.compile(r"keel[0-9]+a?:[A-Za-z0-9_-]{4,}")
RUN = re.compile(r"[A-Za-z0-9_-]{12,}")
# a WireGuard public key, as keel mesh status prints it: public, but a
# random run of letters and digits like a secret, so it is not shown
WGKEY = re.compile(r"[A-Za-z0-9+/]{43}=")
STARS = re.compile(r"\*{4,}")
PICTURE_NEVER = re.compile(r"invite|join")


Refused = pagehtml.Refused


def read_tsv(path, fields):
    """The lines of a tab separated file, each padded to FIELDS fields"""
    rows = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                rows.append((line.rstrip("\n").split("\t") + [""] * fields)[:fields])
    return rows


def read_meta(folder):
    """The meta file of a pass or a node, as a dict"""
    path = os.path.join(folder, "meta")
    if not os.path.isfile(path):
        return {}
    return {key: value for key, value in read_tsv(path, 2)}


def checks(folder):
    """The checks of FOLDER/record.tsv, refused when one did not pass"""
    path = os.path.join(folder, "record.tsv")
    if not os.path.isfile(path):
        raise Refused("%s: no record.tsv" % folder)
    records = read_tsv(path, 3)
    failed = [check for status, check, _ in records if status != "pass"]
    if failed:
        raise Refused("%s: %d check(s) did not pass, the first %s" % (folder, len(failed), failed[0]))
    if not records:
        raise Refused("%s: record.tsv has no check" % folder)
    return records


def machine(folder, name):
    """One machine of a pass: its meta, checks and screens"""
    records = checks(folder)
    screens = os.path.join(folder, "screens.tsv")
    rows = read_tsv(screens, 4) if os.path.isfile(screens) else []
    return {"name": name, "folder": folder, "meta": read_meta(folder),
            "records": records, "rows": rows}


def passed(folder):
    """The meta of a pass folder, refused when it did not pass"""
    meta = read_meta(folder)
    if meta.get("result") != "pass":
        raise Refused("%s: the result is %r, not pass" % (folder, meta.get("result", "missing")))
    return meta


def simple_passes(run):
    """The passes of single machines under RUN/SITE/PASS, in order"""
    found = []
    for site in sorted(os.listdir(run)):
        for name in sorted(os.listdir(os.path.join(run, site)) if os.path.isdir(os.path.join(run, site)) else []):
            folder = os.path.join(run, site, name)
            if os.path.isfile(os.path.join(folder, "meta")):
                meta = passed(folder)
                one = machine(folder, name)
                found.append({"mode": "simple", "name": name, "site": meta.get("site", site),
                              "meta": meta, "nodes": [one]})
    if not found:
        raise Refused("%s: no pass of a single machine (SITE/PASS/meta)" % run)
    return found


def cloud_pass(mode, folder):
    """The pass of several nodes in FOLDER, its nodes in the order of their vmid"""
    if not os.path.isfile(os.path.join(folder, "meta")) and os.path.isdir(os.path.join(folder, mode)):
        folder = os.path.join(folder, mode)
    meta = passed(folder)
    nodes = []
    for name in sorted(os.listdir(folder)):
        sub = os.path.join(folder, name)
        if os.path.isfile(os.path.join(sub, "record.tsv")) and os.path.isfile(os.path.join(sub, "meta")):
            nodes.append(machine(sub, name))
    if not nodes:
        raise Refused("%s: a pass of %s with no node" % (folder, mode))
    nodes.sort(key=lambda node: int(node["meta"].get("vmid", 0) or 0))
    return {"mode": mode, "name": mode, "site": meta.get("site", ""), "meta": meta, "nodes": nodes,
            "cross": checks(folder)}


def image(passes, kind):
    """(file name, sha256) of the image that every pass of KIND ran, None
    when no pass is of that kind; refused when two passes ran different ones"""
    seen = set()
    for one in passes:
        if one["mode"] == "simple" and (one["name"] == "vm-iso") == (kind == "iso"):
            value = one["meta"].get(kind, "")
            seen.add((os.path.basename(value.partition(":")[2] or value), one["meta"].get("sha256", "")))
    if len(seen) > 1:
        raise Refused("the passes ran %d different %s images: %s" % (len(seen), kind, sorted(seen)))
    if not seen:
        return None
    name, sha256 = seen.pop()
    if not name or not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise Refused("a pass of the %s names no image or no sha256" % kind)
    return name, sha256


def release(repo):
    """The Keel release of the appliance, from the head of its changelog:
    "keel-odoo-19.0 (16)" is 19.0-16"""
    with open(os.path.join(repo, "changelog"), encoding="utf-8") as handle:
        head = handle.readline()
    found = re.match(r"^(\S+) \(([^)]+)\)", head)
    if not found:
        raise Refused("%s/changelog: the first line names no version" % repo)
    base = re.search(r"-([0-9]+\.[0-9]+)$", found.group(1))
    return "%s-%s" % (base.group(1), found.group(2)) if base else found.group(2)


def about(repo):
    """The first paragraph of README.rst, without its reStructuredText marks"""
    try:
        with open(os.path.join(repo, "README.rst"), encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return ""
    para, started = [], False
    for index, line in enumerate(lines):
        rule = index + 1 < len(lines) and re.fullmatch(r"[=\-~]{3,}", lines[index + 1] or "-")
        if re.fullmatch(r"[=\-~]{3,}", line) or rule:
            continue
        if line.strip():
            started = True
            para.append(line.strip())
        elif started:
            break
    text = " ".join(para)
    text = re.sub(r"`([^`<]+?)\s*(?:<[^>]*>)?`_+", r"\1", text)
    text = re.sub(r"``([^`]+)``", r"\1", text)
    return re.sub(r"::$", ".", text).replace("::", ":")


def manifest(repo):
    """The appliance manifest of the repository, {} when it has none"""
    packages = os.path.join(repo, "packages")
    for name in sorted(os.listdir(packages)) if os.path.isdir(packages) else []:
        path = os.path.join(packages, name, "manifest.yaml")
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as handle:
                return yaml.safe_load(handle) or {}
    return {}


def app_entry(apps_file, app, repo):
    """The entry of APP in apps.yaml, its version checked in the repository"""
    with open(apps_file, encoding="utf-8") as handle:
        apps = (yaml.safe_load(handle) or {}).get("apps", {})
    if app not in apps:
        raise Refused("%s: no application %r" % (apps_file, app))
    entry = apps[app]
    proof = os.path.join(repo, entry["file"])
    try:
        with open(proof, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        raise Refused("%s: %s" % (proof, error.strerror)) from error
    if entry["match"] not in text:
        raise Refused("%s does not say %r: is %r still the version?" % (proof, entry["match"], entry["version"]))
    return entry


def commit(repo):
    """The commit of the repository checkout, "" when it is not one"""
    try:
        return subprocess.run(["git", "-C", repo, "rev-parse", "--short=12", "HEAD"], check=True,
                              capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def masked(text, invites):
    """TEXT with each invite and each piece of it of mask.PIECE bytes or
    more replaced, as mask.py does to a file, and the WireGuard keys out"""
    data = text.encode("utf-8")
    for number, invite in enumerate((one.encode("utf-8") for one in invites), 1):
        mark = b"<invite %d>" % number
        data = re.sub(rb"[A-Za-z0-9_.~+/=:-]{%d,}" % mask.PIECE,
                      lambda found, invite=invite, mark=mark: mask.masked(found.group(0), invite, mark), data)
    data = mask.BESIDE.sub(rb"\1", data)
    text = WGKEY.sub("<public key>", data.decode("utf-8", "replace"))
    # a password box shows one star for each character: not its length
    return STARS.sub("********", text)


def leaks(text, invites=()):
    """What in TEXT may be an invite or a secret, as short descriptions"""
    found = ["a token %s..." % hit.group(0)[:9] for hit in INVITE.finditer(text)]
    for invite in invites:
        for i in range(len(invite) - mask.PIECE + 1):
            if invite[i:i + mask.PIECE] in text:
                found.append("a piece of an invite")
                break
    for hit in RUN.finditer(text):
        run = hit.group(0)
        if re.search(r"[A-Z]", run) and re.search(r"[a-z]", run) and re.search(r"[0-9]", run):
            found.append("a run like a token, %s..." % run[:4])
    return found


def check(out, invites=()):
    """Refused when a text file under OUT holds what leaks() finds"""
    for top, dirs, names in os.walk(out):
        dirs[:] = [name for name in dirs if name != ".git"]
        for name in names:
            if name.endswith(".png"):
                continue
            path = os.path.join(top, name)
            with open(path, encoding="utf-8", errors="replace") as handle:
                found = leaks(handle.read(), invites)
            if found:
                raise Refused("%s: %s" % (path, "; ".join(sorted(set(found)))))


def frame(path, invites):
    """The text of a container's screen, masked and cut into lines"""
    with open(path, encoding="utf-8", errors="replace") as handle:
        return pagehtml.frame_lines(masked(handle.read(), invites))


def collect(args):
    """The passes of the modes given on the command line"""
    passes = []
    for given in args.mode:
        mode, _, folder = given.partition("=")
        if mode not in MODES or not folder:
            raise Refused("--mode %r: MODE=DIR, MODE one of %s" % (given, ", ".join(MODES)))
        if not os.path.isdir(folder):
            raise Refused("--mode %s: %s is not a folder" % (mode, folder))
        passes.extend(simple_passes(folder) if mode == "simple" else [cloud_pass(mode, folder)])
    return passes


def replace(out, made):
    """OUT holds what MADE holds, and the .git of a pages branch worktree"""
    os.makedirs(out, exist_ok=True)
    for name in os.listdir(out):
        path = os.path.join(out, name)
        if name == ".git":
            continue
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path)
        else:
            os.remove(path)
    for name in os.listdir(made):
        shutil.move(os.path.join(made, name), os.path.join(out, name))


def build(args):
    """Write the page of args.app to args.out. The page is made and checked
    in a folder of its own first, so a refused page changes nothing in OUT."""
    invites = read_invites(args.invites)
    entry = app_entry(args.apps, args.app, args.repo)
    passes = collect(args)
    found = manifest(args.repo)
    page = {"app": args.app, "entry": entry, "release": release(args.repo), "about": about(args.repo),
            "manifest": found, "commit": commit(args.repo), "passes": passes,
            "template": image(passes, "template"), "iso": image(passes, "iso")}
    parent = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(parent, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".pages-", dir=parent) as made:
        html = pagehtml.render(page, lambda path: frame(path, invites), made, PICTURE_NEVER)
        with open(os.path.join(made, "index.html"), "w", encoding="utf-8") as handle:
            handle.write(html)
        check(made, invites)
        replace(args.out, made)


def read_invites(path):
    """The invites of FILE, one for each line"""
    if not path:
        return []
    with open(path, encoding="utf-8") as handle:
        return [line.strip() for line in handle if line.strip()]


def main(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(prog="pages.py", description="the page of an application (0077)")
    sub = parser.add_subparsers(dest="command", required=True)
    one = sub.add_parser("build")
    one.add_argument("app")
    one.add_argument("out")
    one.add_argument("--repo", required=True)
    one.add_argument("--mode", action="append", required=True)
    one.add_argument("--apps", default=os.path.join(here, "apps.yaml"))
    one.add_argument("--invites")
    two = sub.add_parser("check")
    two.add_argument("out")
    two.add_argument("--invites")
    args = parser.parse_args(argv)
    try:
        if args.command == "build":
            build(args)
        else:
            check(args.out, read_invites(args.invites))
    except Refused as error:
        print("pages.py: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

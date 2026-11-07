"""The HTML of an application page (decision 0077), for pages.py.

render() takes the page that pages.py read, copies the pictures it shows
to OUT/img/ and returns index.html. Every text is escaped, and every link
is relative, so the page works from a file and under /apps/NAME/.
"""

import html
import os
import re
import shutil

TITLES = {"simple": "Simple: one node",
          "cloud_simple": "Cloud simple: two nodes, failover by hand",
          "cloud_advanced": "Cloud advanced: two data nodes and a witness"}
PASSES = {"lxc-interactive": "the LXC template, answered on the console",
          "lxc-preseed": "the LXC template, described before the boot",
          "vm-iso": "the ISO in a virtual machine"}


class Refused(Exception):
    """A page that must not be written, and why"""


def esc(text):
    return html.escape(str(text), quote=True)


def frame_lines(text):
    """The lines of a console frame: the line drawing of the dialog boxes
    (q, x, l, k, m, j, t and u in the terminal's graphic set) taken out"""
    text = re.sub(r"[lmtk]?q{3,}[kjux]?", "\n", text)
    text = re.sub(r"\s*x(\s+x)+\s*", "\n", text)
    text = re.sub(r"(?:(?<=\s)x(?=\s))|(?:^x\s)|(?:\sx$)", "\n", text, flags=re.M)
    text = re.sub(r"\s*>=+ ", "\n", text)
    lines = []
    for line in (part.strip() for part in text.split("\n")):
        if line and line not in ("qq", "x") and (not lines or lines[-1] != line):
            lines.append(line)
    return lines


class Pictures:
    """Copies the pictures of the page to OUT/img/, once each"""

    def __init__(self, out, never):
        self.out, self.never, self.done = out, never, {}

    def link(self, source, key, label):
        if self.never.search(label):
            raise Refused("%s: a picture of the %s screen can hold an invite, and a picture"
                          " cannot be masked" % (source, label))
        if source not in self.done:
            relative = os.path.join("img", key, os.path.basename(source))
            os.makedirs(os.path.dirname(os.path.join(self.out, relative)), exist_ok=True)
            shutil.copyfile(source, os.path.join(self.out, relative))
            self.done[source] = relative
        return self.done[source]


def cell(node, row, key, pictures, frame):
    """The HTML of one screen: the picture or the text, and what was typed"""
    _, label, path, answer = row
    source = os.path.join(node["folder"], path)
    title = label.replace("web-", "web: ").replace("_", " ")
    parts = ['<div class="screen"><p class="label">%s</p>' % esc(title)]
    if path.endswith(".png"):
        link = pictures.link(source, key, label)
        parts.append('<a href="%s"><img loading="lazy" src="%s" alt="%s"></a>' % (esc(link), esc(link), esc(title)))
    elif os.path.isfile(source):
        lines = frame(source)
        parts.append('<details><summary>the screen, as text</summary><pre>%s</pre></details>'
                     % esc("\n".join(lines[-40:])))
    if answer:
        parts.append('<p class="typed">typed: <code>%s</code></p>' % esc(answer))
    parts.append("</div>")
    return "".join(parts)


def node_title(node, one):
    meta = node["meta"]
    if one["mode"] == "simple":
        return "%s (%s)" % (PASSES.get(one["name"], one["name"]), one["site"])
    return "%s, %s" % (meta.get("role", node["name"]).capitalize(), meta.get("site", "").upper())


def guide(one, pictures, frame):
    """The table of a pass: one column for each node, one row for each screen"""
    key = one["mode"] if one["mode"] != "simple" else "%s-%s" % (one["site"], one["name"])
    columns = one["nodes"]
    if len(columns) == 1:
        node = columns[0]
        steps = "".join('<li><span class="step">%d</span>%s</li>' % (
            step + 1, cell(node, row, "%s/%s" % (key, node["name"]), pictures, frame))
            for step, row in enumerate(node["rows"]))
        return '<h4>%s</h4><ol class="steps">%s</ol>' % (esc(node_title(node, one)), steps)
    depth = max(len(node["rows"]) for node in columns)
    head = "".join("<th>%s</th>" % esc(node_title(node, one)) for node in columns)
    body = []
    for step in range(depth):
        cells = []
        for node in columns:
            row = node["rows"][step] if step < len(node["rows"]) else None
            cells.append("<td>%s</td>" % (cell(node, row, "%s/%s" % (key, node["name"]), pictures, frame)
                                          if row else "&#8212;"))
        body.append('<tr><th scope="row">%d</th>%s</tr>' % (step + 1, "".join(cells)))
    return ('<div class="guide cols-%d"><table><thead><tr><th>Step</th>%s</tr></thead><tbody>%s'
            "</tbody></table></div>" % (len(columns), head, "".join(body)))


def shown(passes, mode):
    """The passes of MODE the page shows as guides: for simple, the template
    on the console and the ISO of the first site; for a cloud mode, its pass"""
    found = [one for one in passes if one["mode"] == mode]
    if mode != "simple" or not found:
        return found
    first = found[0]["site"]
    return [one for one in found if one["site"] == first and one["name"] in ("lxc-interactive", "vm-iso")]


def records(passes):
    """Every check of every node of PASSES, in order"""
    for one in passes:
        for node in one["nodes"]:
            yield from node["records"]


def first_boot(passes, found):
    """The questions, the passwords, the services and the ports"""
    asked, services, urls = {}, [], []
    for _, check, text in records(passes):
        if check.startswith("keel-init.asked.") and text not in asked.values():
            asked.setdefault(check[len("keel-init.asked."):], text)
        elif check.startswith("service.") and check[8:] not in services:
            services.append(check[8:])
        elif check.startswith("url.") and check[4:] not in urls:
            urls.append(check[4:])
    items = "".join("<li>%s%s</li>" % (esc(text), ' <span class="tag">password</span>' if "password" in key else "")
                    for key, text in asked.items())
    parts = ["<h2>The first boot</h2><p>The questions of the first boot, of all the modes and roles. A node asks"
             " only those of its mode and role (the guides below show each one):</p><ul>%s</ul>" % items]
    parts.append("<p>No password is copied between nodes: only the invite lines (decision 0076).</p>")
    if found.get("processes"):
        rows = "".join("<tr><td>%s</td><td>%s</td><td>%s</td></tr>" % (
            esc(proc["name"]), esc(", ".join("%s/%s" % (one["port"], one.get("protocol", "tcp"))
                                             for one in proc.get("listen", []))),
            esc(", ".join(one.get("expose", "") for one in proc.get("listen", []))))
            for proc in found["processes"])
        parts.append("<h3>Services and ports</h3><table><thead><tr><th>Service</th><th>Port</th>"
                     "<th>Open to</th></tr></thead><tbody>%s</tbody></table>" % rows)
    else:
        parts.append("<h3>Services</h3><p>%s</p>" % esc(", ".join(services)))
        parts.append("<h3>Addresses the commissioning checked</h3><ul>%s</ul>" % "".join("<li><code>%s</code></li>" % esc(url) for url in urls))
    return "".join(parts)


def gallery(passes, pictures):
    """The web pages of the first container pass on the console"""
    for one in passes:
        if one["mode"] == "simple" and one["name"] == "lxc-interactive":
            node = one["nodes"][0]
            shots = [row for row in node["rows"] if row[2].endswith(".png") and row[1].startswith("web-")]
            figures = "".join('<figure><a href="%s"><img loading="lazy" src="%s" alt="%s"></a>'
                              "<figcaption>%s<br><span>%s</span></figcaption></figure>" % (
                                  esc(link), esc(link), esc(row[1]), esc(row[1][4:].replace("-", " ")),
                                  esc(row[3]))
                              for row in shots
                              for link in [pictures.link(os.path.join(node["folder"], row[2]),
                                                         "%s-%s/%s" % (one["site"], one["name"], node["name"]),
                                                         row[1])])
            return '<h2>Screenshots</h2><div class="gallery">%s</div>' % figures
    return ""


def results(passes):
    """The commissioning result of each pass"""
    rows = []
    for one in passes:
        count = sum(len(node["records"]) for node in one["nodes"]) + len(one.get("cross", []))
        name = PASSES.get(one["name"], one["name"]) if one["mode"] == "simple" else TITLES[one["mode"]]
        where = ", ".join(("%s %s" % (node["meta"].get("role", ""), node["meta"].get("site", one["site"]))).strip()
                          for node in one["nodes"])
        rows.append("<tr><td>%s</td><td>%s</td><td>%s</td><td>%d of %d</td><td><code>%s</code></td></tr>" % (
            esc(name), esc(where),
            esc(one["meta"].get("date", "")), count, count, esc(one["meta"].get("contract", "")[:16])))
    return ("<h2>Commissioning</h2><p>Every pass below passed every check (decision 0075). A page never"
            " shows an image that did not pass.</p><table><thead><tr><th>Pass</th><th>Nodes</th><th>Date</th>"
            "<th>Checks passed</th><th>Contract</th></tr></thead><tbody>%s</tbody></table>" % "".join(rows))


def install(page):
    parts = ["<h2>Install</h2>"]
    if page["template"]:
        parts.append("<h3>LXC template, for Proxmox VE</h3><p><code>%s</code></p><p class=\"sha\">sha256 "
                     "<code>%s</code></p><p>Make a container from the template. At the first login on the console,"
                     " run <code>keel-init</code> and choose the installation mode.</p>" % (
                         esc(page["template"][0]), esc(page["template"][1])))
    if page["iso"]:
        parts.append("<h3>ISO, for a virtual or a real machine</h3><p><code>%s</code></p><p class=\"sha\">sha256 "
                     "<code>%s</code></p><p>Boot the ISO and install. The first boot of the installed system asks"
                     " the same questions as the template.</p>" % (esc(page["iso"][0]), esc(page["iso"][1])))
    return "".join(parts)


def modes(page, pictures, frame):
    parts = ["<h2>Installation modes</h2><p>Each column is one machine. Each row is one screen, in the order"
             " the machine showed it, with what the operator typed or chose. A secret is named, never shown.</p>"]
    offered = page["manifest"].get("modes") or [mode for mode in TITLES if any(
        one["mode"] == mode for one in page["passes"])]
    for mode in offered:
        parts.append('<h3 id="%s">%s</h3>' % (esc(mode), esc(TITLES.get(mode, mode))))
        guides = shown(page["passes"], mode)
        if not guides:
            parts.append("<p>No passing commissioning run of this mode yet.</p>")
        for one in guides:
            parts.append(guide(one, pictures, frame))
    return "".join(parts)


def render(page, frame, out, never):
    """index.html of PAGE; the pictures go to OUT/img/"""
    pictures = Pictures(out, never)
    entry = page["entry"]
    image = page["template"] or page["iso"]
    body = [
        '<header><a href="../../appliances.html">Keel Linux applications</a></header><main>',
        '<p class="kicker">%s</p><h1>%s</h1>' % (esc(entry["name"]), esc(entry["version"])),
        '<p class="release">Keel release <strong>%s</strong>%s</p>' % (
            esc(page["release"]), " &#183; image <code>%s</code>" % esc(image[0]) if image else ""),
        "<p>%s</p>" % esc(page["about"]) if page["about"] else "",
        install(page), first_boot(page["passes"], page["manifest"]), gallery(page["passes"], pictures),
        modes(page, pictures, frame), results(page["passes"]),
        "</main><footer><p>Made from %s%s and its commissioning records.</p></footer>" % (
            esc(entry["repo"]), " at %s" % esc(page["commit"]) if page["commit"] else ""),
    ]
    return ("<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            "<title>%s</title><style>%s</style></head><body>%s</body></html>\n" % (
                esc("%s %s" % (entry["name"], entry["version"])), STYLE, "".join(body)))


STYLE = """
:root{--bg:#fbfbf9;--fg:#1d2327;--muted:#5b6670;--line:#d9dde1;--card:#fff;--accent:#0b5cad;--code:#f1f3f5}
@media (prefers-color-scheme:dark){:root{--bg:#14171a;--fg:#e6e8ea;--muted:#9aa4ad;--line:#2e353b;
--card:#1b1f23;--accent:#6cb0ff;--code:#23292e}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);
font:16px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif}
header{padding:12px 16px;border-bottom:1px solid var(--line)}a{color:var(--accent)}
main{max-width:1180px;margin:0 auto;padding:16px}
.kicker{margin:24px 0 0;color:var(--muted);font-weight:600;letter-spacing:.02em}
h1{font-size:clamp(2.2rem,6vw,3.6rem);line-height:1.1;margin:4px 0 8px}
.release{color:var(--muted);margin:0 0 24px}h2{margin-top:40px;border-top:1px solid var(--line);padding-top:24px}
code{background:var(--code);padding:1px 5px;border-radius:4px;font-size:.9em;overflow-wrap:anywhere}
.sha code{font-size:.8em}.tag{font-size:.75em;border:1px solid var(--line);border-radius:10px;padding:0 6px;
color:var(--muted)}
table{border-collapse:collapse;width:100%}th,td{border:1px solid var(--line);padding:8px;vertical-align:top;
text-align:left}thead th{background:var(--card);position:sticky;top:0}
.guide{overflow-x:auto;margin:12px 0 24px}.guide td{background:var(--card);min-width:260px}
.steps{list-style:none;padding:0;display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));
gap:12px}.steps li{background:var(--card);border:1px solid var(--line);padding:8px}.step{float:right;
color:var(--muted);font-weight:600}h4{margin:16px 0 4px}.screen img{width:100%;height:auto;border:1px solid var(--line);display:block}
.screen .label{margin:0 0 6px;font-weight:600}.typed{margin:6px 0 0;color:var(--muted)}
pre{white-space:pre-wrap;font-size:12px;line-height:1.35;max-height:320px;overflow:auto;background:var(--code);
padding:8px;margin:6px 0 0}
.gallery{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:16px}
figure{margin:0;background:var(--card);border:1px solid var(--line);padding:8px}figure img{width:100%;
height:auto;display:block}figcaption{font-weight:600;margin-top:6px}figcaption span{font-weight:400;
color:var(--muted);font-size:.9em}
footer{border-top:1px solid var(--line);color:var(--muted);padding:16px;text-align:center;font-size:.9em}
"""

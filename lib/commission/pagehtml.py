"""The HTML of an application page (decision 0077), for pages.py.

render() takes the page that pages.py read, copies the pictures it shows
to OUT/img/ and returns index.html. Every text is escaped. A link to a
picture is relative, so the page works from a file and under /apps/NAME/,
and a link to the site is absolute (pagesite.py).
"""

import html
import os
import re
import shutil

import pagesite

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
                                          if row else ""))
        body.append('<tr><th scope="row">%d</th>%s</tr>' % (step + 1, "".join(cells)))
    return ('<div class="mode-guide cols-%d"><table><thead><tr><th>Step</th>%s</tr></thead><tbody>%s'
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
        rows.append("<tr><td>%s</td><td>%s</td><td>%s</td><td>%d of %d</td></tr>" % (
            esc(name), esc(where), esc(one["meta"].get("date", "")), count, count))
    return ('<h2 id="commissioning">Commissioning</h2><p>%s</p><p>Every pass below passed every check'
            " (decision 0075). A page never shows an image that did not pass.</p><table><thead><tr><th>Pass</th>"
            "<th>Nodes</th><th>Date</th><th>Checks passed</th></tr></thead><tbody>%s</tbody></table>"
            % (esc(summary(passes)), "".join(rows)))


def summary(passes):
    """One sentence: how many passes, on which sites, from which day to which day"""
    sites = sorted({node["meta"].get("site", one["site"]) for one in passes for node in one["nodes"]} - {""})
    days = sorted(one["meta"].get("date", "")[:10] for one in passes if one["meta"].get("date"))
    checked = sum(sum(len(node["records"]) for node in one["nodes"]) + len(one.get("cross", [])) for one in passes)
    when = days[0] if days and days[0] == days[-1] else "%s to %s" % (days[0], days[-1]) if days else "no date"
    return "%d passes on the sites %s, %s: %d checks, all passed." % (
        len(passes), ", ".join(site.upper() for site in sites), when, checked)


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
    title = "%s %s" % (entry["name"], entry["version"])
    made = "This page is made from %s%s and from its commissioning records." % (
        entry["repo"], " at %s" % page["commit"] if page["commit"] else "")
    body = [
        pagesite.header(), '<main id="main" class="app"><div class="wrap">',
        '<p class="crumbs"><a href="%s/appliances.html">Appliances</a> / %s</p>' % (pagesite.SITE, esc(entry["name"])),
        '<span class="eyebrow">%s</span><h1>%s</h1>' % (esc(entry["name"]), esc(entry["version"])),
        '<p class="release">Keel release <strong>%s</strong>%s</p>' % (
            esc(page["release"]), " &#183; image <code>%s</code>" % esc(image[0]) if image else ""),
        '<p class="lead">%s</p>' % esc(page["about"]) if page["about"] else "",
        pagesite.install(entry["repo"], page), first_boot(page["passes"], page["manifest"]),
        gallery(page["passes"], pictures), modes(page, pictures, frame), results(page["passes"]),
        "</div></main>", pagesite.footer(made),
    ]
    return ("<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            "<title>%s, Keel Linux</title><meta name=\"description\" content=\"%s\">"
            "<meta name=\"color-scheme\" content=\"light dark\">"
            "<link rel=\"icon\" type=\"image/svg+xml\" href=\"%s/assets/keel-mark.svg\">"
            "<link rel=\"stylesheet\" href=\"%s/style.css\"><style>%s</style></head><body>%s</body></html>\n" % (
                esc(title), esc("%s: how to install it, the guide of each installation mode, and its"
                                " commissioning result." % title), pagesite.SITE, pagesite.SITE,
                pagesite.STYLE, "".join(body)))

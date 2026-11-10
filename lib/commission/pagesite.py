"""The parts of an application page (decision 0077) that are the site's, for
pagehtml.py: the header, the footer, the stylesheet and the install steps.

The page is served at https://keellinux.org/apps/NAME/ from the "pages"
branch of the appliance repository, not from the site repository. So every
link to the site is absolute, and the page uses the site's stylesheet by
its absolute address. The few classes of its own (the guides, the screens,
the gallery) use the colour tokens of that stylesheet.
"""

import html

SITE = "https://keellinux.org"
MIRROR = "https://mirror.keellinux.org/images/"
KEYRING = "https://archive.keellinux.org/keel-images-keyring.asc"
# the fingerprint that sqv prints for a good signature by the images key,
# as appliances.html of the site gives it
IMAGES_FINGERPRINT = "E71DB9C3CA6AC18075395CC3ED3A709C4F3E2F3C"
NAV = (("appliances.html", "Appliances"), ("architecture.html", "Architecture"),
       ("security.html", "Security"), ("cloud.html", "Cloud &amp; replication"),
       ("roadmap.html", "Roadmap"), ("guidelines.html", "Guidelines"))


def esc(text):
    return html.escape(str(text), quote=True)


def header():
    """The header of the site, with Appliances as the current section"""
    items = "".join('<li><a href="%s/%s"%s>%s</a></li>' % (
        SITE, page, ' aria-current="page"' if page == "appliances.html" else "", name) for page, name in NAV)
    return ('<a class="skip" href="#main">Skip to content</a><header class="site-header"><div class="wrap">'
            '<a class="brand" href="%s/" aria-label="Keel Linux, home"><img src="%s/assets/keel-mark.svg"'
            ' alt="" width="32" height="32"><span>Keel Linux</span></a><nav class="site-nav" id="site-nav"'
            ' aria-label="Main"><ul>%s</ul></nav></div></header>' % (SITE, SITE, items))


def footer(made):
    """The footer of the site, with MADE: what the page was made from"""
    items = "".join('<li><a href="%s/%s">%s</a></li>' % (SITE, page, name) for page, name in NAV)
    return ('<footer class="site-footer"><div class="wrap"><div class="footer-grid"><div>'
            '<a class="brand" href="%s/"><img src="%s/assets/keel-mark.svg" alt="" width="32" height="32">'
            "<span>Keel Linux</span></a><p>%s</p></div><nav aria-label=\"Site\"><h2>Site</h2><ul>%s</ul></nav>"
            '<nav aria-label="Source"><h2>Source</h2><ul><li><a href="https://git.pop.coop/Keel-Linux">'
            "git.pop.coop, the source</a></li></ul></nav></div><p class=\"legal\">Keel Linux is compatible with"
            " TurnKey Linux appliances. TurnKey Linux is a trademark of its owners. Keel Linux is an independent"
            " project.</p></div></footer>" % (SITE, SITE, esc(made), items))


def check_steps(name):
    """The commands that download NAME with its signature and check both"""
    return ("curl -fLO %s%s -O %s%s.sha512 -O %s%s.sha512.asc\ncurl -fLO %s\n"
            "sqv --keyring keel-images-keyring.asc %s.sha512.asc %s.sha512\nsha512sum -c %s.sha512"
            % (MIRROR, name, MIRROR, name, MIRROR, name, KEYRING, name, name, name))


def template(repo, image):
    """The install steps of the LXC template IMAGE, (file name, sha256)"""
    name, sha256 = image
    return ("<h3>LXC template, for Proxmox VE</h3><p><code>%s</code></p><p class=\"sha\">sha256 <code>%s</code></p>"
            "<h4>With the Keel index</h4><p>keel-pve gets the signed index of the Keel templates and checks"
            " the template against it. The Templates dialog of the Proxmox web interface does not show Keel"
            " templates. Install keel-pve from the Keel archive, suite <code>trixie-testing</code>, as its"
            ' <a href="https://git.pop.coop/Keel-Linux/keel-pve">README</a> says. Then run these commands on'
            " the Proxmox node:</p><pre class=\"code\">keel-pve update\nkeel-pve download local %s</pre>"
            "<h4>With the file</h4><ol><li>Download the template, its <code>.sha512</code> and its"
            " <code>.sha512.asc</code>.</li><li>Check the signature. Then check the digest.</li>"
            "<li>Copy the template to <code>/var/lib/vz/template/cache/</code> on the Proxmox node.</li>"
            "</ol><pre class=\"code\">%s\ncp %s /var/lib/vz/template/cache/</pre>"
            "<p>If <code>sqv</code> prints <code>%s</code>, the signature is good. It also prints \"Missing key\""
            " for the main key of the project. This is expected.</p>"
            "<h4>Make the container</h4><pre class=\"code\">pct create 200 local:vztmpl/%s --hostname %s"
            " \\\n  --unprivileged 1 --features nesting=1 \\\n  --net0 name=eth0,bridge=vmbr0,ip6=auto</pre>"
            "<p>Start the container and log in on its console as root. The first boot asks its questions"
            " there.</p>" % (esc(name), esc(sha256), esc(repo), esc(check_steps(name)), esc(name), IMAGES_FINGERPRINT,
                             esc(name), esc(repo.replace("keel-", ""))))


def iso(image):
    """The install steps of the ISO IMAGE, (file name, sha256)"""
    name, sha256 = image
    return ("<h3>ISO, for a virtual or a real machine</h3><p><code>%s</code></p><p class=\"sha\">sha256"
            " <code>%s</code></p><pre class=\"code\">%s</pre><p>Boot the machine from the ISO and install."
            " The first boot of the installed system asks the same questions as the template.</p>"
            % (esc(name), esc(sha256), esc(check_steps(name))))


def install(repo, page):
    """The install section of PAGE: the template and the ISO it names"""
    parts = ['<h2 id="install">Install</h2>']
    if page["template"]:
        parts.append(template(repo, page["template"]))
    if page["iso"]:
        parts.append(iso(page["iso"]))
    return "".join(parts)


STYLE = """
.app main{padding-bottom:48px}.app .wrap>h2{margin-top:48px;border-top:1px solid var(--line);padding-top:24px}
.app .release{color:var(--muted);margin:0 0 24px}.app .sha code{font-size:.8em;overflow-wrap:anywhere}
.app .tag{font-size:.75em;border:1px solid var(--line);border-radius:10px;padding:0 6px;color:var(--muted)}
.app table{border-collapse:collapse;width:100%}.app th,.app td{border:1px solid var(--line);padding:8px;
vertical-align:top;text-align:left}.app thead th{background:var(--surface-2)}
.mode-guide{overflow-x:auto;margin:12px 0 24px}.mode-guide td{background:var(--surface);min-width:260px}
.steps{list-style:none;padding:0;display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:12px}
.steps li{background:var(--surface);border:1px solid var(--line);border-radius:var(--radius-sm);padding:8px}
.step{float:right;color:var(--muted);font-weight:600}.screen img{width:100%;height:auto;
border:1px solid var(--line);display:block}.screen .label{margin:0 0 6px;font-weight:600}
.typed{margin:6px 0 0;color:var(--muted)}.screen pre{white-space:pre-wrap;font:12px/1.35 var(--mono);
max-height:320px;overflow:auto;background:var(--code-bg);padding:8px;margin:6px 0 0}
.gallery{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:16px}
.gallery figure{margin:0;background:var(--surface);border:1px solid var(--line);border-radius:var(--radius-sm);
padding:8px}.gallery img{width:100%;height:auto;display:block}.gallery figcaption{font-weight:600;margin-top:6px}
.gallery figcaption span{font-weight:400;color:var(--muted);font-size:.9em}
"""

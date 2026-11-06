"""The parts of the commissioning contract that drive screens (decisions 0075
and 0076): the VM from the ISO, the web screenshots, and the nodes of the
cloud modes. contract.py reads them with the rest of the contract.

The lines they add to `contract.py tsv`, fields separated by a tab:

    vm         KEY  VALUE                 memory (MiB), cores, disk (GiB)
    installer  ID  PROMPT  KEYS  FLAGS    a screen of the ISO installer
    shot       NAME  SCHEME  PORT  PATH  AFTER  USER_FIELD  USER  PASS_FIELD
               SECRET  SUBMIT  WAIT  TEXT a web screenshot; TEXT, when not
                                          empty, must be on the last page
    nshot      NODE  NAME ...             a web screenshot of that node only:
                                          a node with nshot lines takes them
                                          in place of the shot lines
    node       NAME  SITE  KIND  IMAGE  MODE  ROLE  CONTRACT
                                          CONTRACT the absolute path of the
                                          contract of the node's appliance,
                                          "-" for this one
    answer     NODE  ID  PROMPT  KEYS     a screen of that node only
    capture    WHAT  REGEX  GROUP         invite or vip, read on a screen;
                                          GROUP 1 when REGEX has a group
    wait       PROMPT                     a screen that waits for another node:
                                          no key while it is up
    cross      ID  AT  RUN  MATCH  COUNT  SECRET
                                          a check across the nodes ("-"
                                          for an empty field)

KEYS is what the operator types: letters, digits and @._+-:/=~ as they are,
and the names in braces for the other keys, for example "n", "{ret}" or
"{down}{down}{ret}". {secret:NAME} types the value of a secret, {invite:N}
the Nth invite line read on the screen of the first node, and {vip} the VIP
read there. Only the runner resolves them, and only when it types them.
"""

import re

NAME = re.compile(r"^[a-z][a-z0-9_]*$")
CONTRACT = re.compile(r"^[A-Za-z0-9_./-]+\.ya?ml$")
NODE = re.compile(r"^[a-z][a-z0-9-]*$")
PROMPT = re.compile(r"^[A-Za-z0-9 ._:()/'-]+$")
PATH = re.compile(r"^/[^\s\t'\"\\]*$")
SELECTOR = re.compile(r"^[^\t\n'\"\\]+$")
SAFE = re.compile(r"^[^\t\n]+$")
VOLID = re.compile(r"^[A-Za-z0-9._-]+:[A-Za-z0-9._/-]+$")
SITE = re.compile(r"^[a-z][a-z0-9]*$")

# the key names of `qm sendkey` (QEMU's), and the terminal bytes of each,
# as a Tcl string body for the expect script of a container's console
KEYS = {
    "ret": ("ret", "\\r"), "tab": ("tab", "\\t"), "esc": ("esc", "\\033"),
    "spc": ("spc", " "), "bksp": ("backspace", "\\x7f"),
    "up": ("up", "\\033\\[A"), "down": ("down", "\\033\\[B"),
    "right": ("right", "\\033\\[C"), "left": ("left", "\\033\\[D"),
}
CHARS = {".": "dot", "-": "minus", "_": "shift-minus", "@": "shift-2",
         "+": "shift-equal", ":": "shift-semicolon", "/": "slash",
         "=": "equal", "~": "shift-grave_accent", " ": "spc"}
TOKEN = re.compile(r"\{([a-z]+)(?::([A-Za-z0-9_]+))?\}|([A-Za-z0-9@._+:/=~ -])")

# the screens of tkl-installer, read on its tty1 on BR1, 2026-11-05: Guided
# LVM, no separate /boot, the scheme, the erase, the install, the reboot,
# and the medium out (the runner ejects the ISO there, as an operator does)
INSTALLER = [
    {"id": "partitioning", "prompt": "Choose a partitioning scheme", "keys": "{ret}"},
    {"id": "separate_boot", "prompt": "Create a separate /boot partition", "keys": "n"},
    {"id": "scheme", "prompt": "Proceed with this partition scheme", "keys": "{ret}"},
    {"id": "erase", "prompt": "This will ERASE ALL DATA", "keys": "{ret}"},
    {"id": "begin", "prompt": "Begin installation", "keys": "y"},
    {"id": "reboot", "prompt": "reboot into the newly installed system", "keys": "y"},
    {"id": "medium", "prompt": "REMOVE the live installation medium",
     "keys": "{ret}{ret}", "eject": True, "last": True},
]
VM = {"memory": 2048, "cores": 2, "disk": 16}
MODES = {"simple", "cloud_simple", "cloud_advanced"}
ROLES = {"primary", "replica", "witness"}
KINDS = {"lxc", "vm"}
# what each cloud mode is made of (0076): one primary, the replicas, and in
# cloud advanced one witness
SHAPE = {"cloud_simple": {"primary": 1, "replica": 1, "witness": 0},
         "cloud_advanced": {"primary": 1, "replica": 1, "witness": 1}}


def keys_valid(keys, secrets, captures):
    """None when KEYS is typeable, else what is wrong with it"""
    if not isinstance(keys, str) or not keys:
        return "keys is empty or not a string"
    pos = 0
    for match in TOKEN.finditer(keys):
        if match.start() != pos:
            break
        pos = match.end()
        name, arg = match.group(1), match.group(2)
        if name is None:
            continue
        if name == "secret" and arg not in secrets:
            return "{secret:%s} is not a declared secret" % arg
        if name == "invite" and ("invite" not in captures or not (arg or "").isdigit()):
            return "{invite:%s} needs capture.invite and a number" % arg
        if name == "vip" and "vip" not in captures:
            return "{vip} needs capture.vip"
        if name not in KEYS and name not in ("secret", "invite", "vip"):
            return "{%s} is not a key name" % name
    if pos != len(keys):
        return "%r has characters no key types" % keys[pos:pos + 10]
    return None


def resolve(keys, values):
    """KEYS as tokens: ("key", NAME) or ("text", TEXT), values filled in"""
    out, pos = [], 0
    for match in TOKEN.finditer(keys):
        if match.start() != pos:
            break
        pos = match.end()
        name, arg, char = match.groups()
        if char is not None:
            out.append(("text", char))
        elif name in KEYS:
            out.append(("key", name))
        else:
            ref = name + (":" + arg if arg else "")
            if ref not in values:
                raise KeyError(ref)
            out.append(("text", values[ref]))
    if pos != len(keys):
        raise ValueError("%r has characters no key types" % keys[pos:pos + 10])
    return out


def as_qm(tokens):
    """The `sendkey` lines of qm monitor for the tokens"""
    lines = []
    for kind, value in tokens:
        if kind == "key":
            lines.append("sendkey " + KEYS[value][0])
            continue
        for char in value:
            if char.isupper():
                lines.append("sendkey shift-" + char.lower())
            elif char.isalnum():
                lines.append("sendkey " + char)
            elif char in CHARS:
                lines.append("sendkey " + CHARS[char])
            else:
                raise ValueError("no key types %r" % char)
    return "".join(line + "\n" for line in lines)


def as_tcl(tokens):
    """The tokens as the body of a Tcl string for expect's send"""
    out = []
    for kind, value in tokens:
        if kind == "key":
            out.append(KEYS[value][1])
        else:
            out.append(re.sub(r'([\\\[\]$"{}])', r"\\\1", value))
    return "".join(out)


def as_mask(keys):
    """KEYS as the guide shows them: the secrets and invites named, not given"""
    def name(match):
        word, arg, char = match.groups()
        if char is not None:
            return char
        if word == "secret":
            return "(the %s secret)" % arg
        if word == "invite":
            return "(invite %s of the first node)" % arg
        if word == "vip":
            return "(the VIP)"
        return "<%s>" % word
    return TOKEN.sub(name, keys)


BOX = "│┃║|"


def capture(regex, text):
    """Every match of REGEX in the screen TEXT, a match that the screen
    wrapped at the edge of its box joined with the start of the next line.
    A REGEX with a group gives its first group: "VIP: (fd[0-9a-f:]+)" gives
    the address, not the label."""
    pattern = re.compile(regex)
    lines, tight = [], []
    for raw in text.splitlines():
        body = raw.rstrip()
        if body[-1:] and body[-1] in BOX:
            body = body[:-1]
        # only a line whose text touches the edge of its box was wrapped
        tight.append(bool(body) and not body[-1].isspace())
        lines.append(body.strip().strip(BOX).strip())
    found = []
    for i, line in enumerate(lines):
        for match in pattern.finditer(line):
            value, j = match.group(0), i
            # a match that runs to the edge of its line goes on in the next
            while (tight[j] and line.endswith(value) and j + 1 < len(lines)
                   and lines[j + 1]):
                more = pattern.match(value + lines[j + 1].split()[0])
                if not more or len(more.group(0)) <= len(value):
                    break
                value, j = more.group(0), j + 1
                line = lines[j]
            if pattern.groups:
                value = pattern.match(value).group(1)
            if value and value not in found:
                found.append(value)
    return found


def check_vm(doc, secrets, errors):
    vm = doc.get("vm", {})
    if not isinstance(vm, dict):
        errors.append("vm is not a mapping")
        return []
    rows = []
    for key, default in VM.items():
        value = vm.get(key, default)
        if not isinstance(value, int) or value < 1:
            errors.append("vm.%s %r is not a positive number" % (key, value))
        rows.append(["vm", key, str(value)])
    screens = vm.get("installer", INSTALLER)
    if not isinstance(screens, list) or not screens:
        errors.append("vm.installer is not a list of screens")
        return rows
    ids = set()
    for item in screens:
        if not isinstance(item, dict):
            errors.append("an installer screen is not a mapping")
            continue
        sid, prompt = str(item.get("id", "")), str(item.get("prompt", ""))
        if not NAME.match(sid) or sid in ids:
            errors.append("installer screen id %r is not a new lower case name" % sid)
        ids.add(sid)
        if not PROMPT.match(prompt):
            errors.append("installer screen %s: prompt %r is not usable" % (sid, prompt))
        bad = keys_valid(item.get("keys"), secrets, set())
        if bad:
            errors.append("installer screen %s: %s" % (sid, bad))
        flags = ",".join(f for f in ("eject", "last") if item.get(f) is True)
        rows.append(["installer", sid, prompt, str(item.get("keys")), flags or "-"])
    if not any(item.get("last") is True for item in screens if isinstance(item, dict)):
        errors.append("vm.installer has no screen with last: true")
    return rows


def check_shots(doc, secrets, errors):
    return [["shot"] + row for row in shot_rows(doc.get("screenshots", []), secrets,
                                                 errors, "screenshots")]


def shot_rows(items, secrets, errors, where):
    """The fields of each screenshot of the list ITEMS (WHERE names it)"""
    rows, names = [], set()
    if not isinstance(items, list):
        errors.append("%s is not a list" % where)
        return rows
    for item in items:
        if not isinstance(item, dict):
            errors.append("a screenshot is not a mapping")
            continue
        name = str(item.get("name", ""))
        if not NODE.match(name) or name in names:
            errors.append("screenshot name %r is not a new lower case name" % name)
        names.add(name)
        scheme = item.get("scheme", "https")
        if scheme not in ("http", "https"):
            errors.append("screenshot %s: scheme %r is not http or https" % (name, scheme))
        port = item.get("port", 443 if scheme == "https" else 80)
        if not isinstance(port, int) or not 0 < port < 65536:
            errors.append("screenshot %s: port %r is not a port" % (name, port))
        path, after = str(item.get("url", "")), str(item.get("after", ""))
        for key, value in (("url", path), ("after", after)):
            if (value or key == "url") and not PATH.match(value):
                errors.append("screenshot %s: %s %r is not a path from /" % (name, key, value))
        login = item.get("login", {})
        fields = ["", "", "", "", ""]
        if not isinstance(login, dict):
            errors.append("screenshot %s: login is not a mapping" % name)
        elif login:
            fields = [str(login.get(k, "")) for k in
                      ("user_field", "user", "password_field", "secret", "submit")]
            for key, value in zip(("user_field", "user", "password_field", "submit"),
                                  fields[:3] + fields[4:]):
                if not SELECTOR.match(value):
                    errors.append("screenshot %s: login.%s %r is missing or not usable"
                                  % (name, key, value))
            if fields[3] not in secrets:
                errors.append("screenshot %s: login.secret %r is not a declared secret"
                              % (name, fields[3]))
        # wait: more seconds for a page that keeps loading after its load
        # event (the dashboard of Webmin, BR1 2026-11-05)
        wait = item.get("wait", 0)
        if not isinstance(wait, int) or not 0 <= wait <= 120:
            errors.append("screenshot %s: wait %r is not 0 to 120 seconds" % (name, wait))
        # text: words the last page must show, the notice of a replica for
        # example (BR2, 2026-11-06): a page can answer 200 and still be the
        # wrong one
        text = item.get("text", "")
        if not isinstance(text, str) or not PROMPT.match(text or "x"):
            errors.append("screenshot %s: text %r is not usable" % (name, text))
        rows.append([name, str(scheme), str(port), path, after] + fields
                    + [str(wait), str(text)])
    return rows


def check_cloud(doc, secrets, errors):
    cloud = doc.get("cloud", {})
    if not isinstance(cloud, dict):
        errors.append("cloud is not a mapping")
        return [], set()
    rows, captures = [], set()
    patterns = cloud.get("capture", {})
    if not isinstance(patterns, dict):
        errors.append("cloud.capture is not a mapping")
        patterns = {}
    for what, regex in patterns.items():
        if what not in ("invite", "vip"):
            errors.append("cloud.capture.%s is not invite or vip" % what)
            continue
        try:
            group = min(re.compile(str(regex)).groups, 1)
        except re.error as error:
            errors.append("cloud.capture.%s: %s" % (what, error))
            continue
        if not SAFE.match(str(regex)):
            errors.append("cloud.capture.%s has a tab or a newline" % what)
            continue
        captures.add(what)
        # GROUP: the part of the match that is the value, for expect
        rows.append(["capture", what, str(regex), str(group)])
    waits = cloud.get("waits", [])
    if not isinstance(waits, list):
        errors.append("cloud.waits is not a list")
        waits = []
    for prompt in waits:
        if not PROMPT.match(str(prompt)):
            errors.append("cloud.waits: %r is not a prompt" % (prompt,))
            continue
        rows.append(["wait", str(prompt)])
    checks = cloud.get("checks", [])
    if not isinstance(checks, list):
        errors.append("cloud.checks is not a list")
        checks = []
    for item in checks:
        if not isinstance(item, dict):
            errors.append("a cloud check is not a mapping")
            continue
        cid, run = str(item.get("id", "")), str(item.get("run", ""))
        if not re.match(r"^[a-z][a-z0-9_.-]*$", cid):
            errors.append("cloud check id %r is not usable" % cid)
        if not SAFE.match(run):
            errors.append("cloud check %s: run is empty or has a tab or a newline" % cid)
        on, match = str(item.get("at", "")), str(item.get("match", ""))
        if not (on in ROLES or on == "all" or NODE.match(on)):
            errors.append("cloud check %s: at %r is not a role, a node or all" % (cid, on))
        if match:
            try:
                re.compile(match)
            except re.error as error:
                errors.append("cloud check %s: match: %s" % (cid, error))
        count = item.get("count", "")
        if count != "" and (not isinstance(count, int) or count < 0):
            errors.append("cloud check %s: count %r is not a number" % (cid, count))
        secret = str(item.get("secret", ""))
        if secret and secret not in secrets:
            errors.append("cloud check %s: secret %r is not declared" % (cid, secret))
        if "\t" in match:
            errors.append("cloud check %s: match has a tab" % cid)
        # "-" for an empty field: bash's read joins two tabs into one
        rows.append(["cross", cid, on, run, match or "-", str(count) or "-", secret or "-"])
    return rows, captures


def check_node(item, secrets, captures, errors):
    name = str(item.get("name", ""))
    if not NODE.match(name):
        errors.append("node name %r is not a lower case name" % name)
    site, kind = str(item.get("site", "")), item.get("kind", "lxc")
    mode, role = item.get("mode"), item.get("role", "primary")
    image = str(item.get("image", ""))
    if not SITE.match(site):
        errors.append("node %s: site %r is not a site name" % (name, site))
    if kind not in KINDS:
        errors.append("node %s: kind %r is not lxc or vm" % (name, kind))
    if mode not in MODES:
        errors.append("node %s: mode %r is not one of %s" % (name, mode, ", ".join(sorted(MODES))))
    if role not in ROLES:
        errors.append("node %s: role %r is not one of %s" % (name, role, ", ".join(sorted(ROLES))))
    if image and not VOLID.match(image):
        errors.append("node %s: image %r is not a volume id" % (name, image))
    # contract: the contract of another appliance, for a node of it in this
    # set (the Keel Core witness): its questions, proofs, checks and
    # screenshots replace this one's on that node
    other = item.get("contract", "")
    if not isinstance(other, str) or (other and not CONTRACT.match(other)):
        errors.append("node %s: contract %r is not a file name" % (name, other))
        other = ""
    rows = [["node", name, site, str(kind), image or "-", str(mode), str(role), other or "-"]]
    answers = item.get("answers")
    answers = [] if answers is None else answers
    if not isinstance(answers, list):
        errors.append("node %s: answers is not a list" % name)
        answers = []
    for answer in answers:
        if not isinstance(answer, dict):
            errors.append("node %s: an answer is not a mapping" % name)
            continue
        aid, prompt = str(answer.get("id", "")), str(answer.get("prompt", ""))
        if not NAME.match(aid):
            errors.append("node %s: answer id %r is not a lower case name" % (name, aid))
        if not PROMPT.match(prompt):
            errors.append("node %s: answer %s: prompt %r is not usable" % (name, aid, prompt))
        bad = keys_valid(answer.get("keys"), secrets, captures)
        if bad:
            errors.append("node %s: answer %s: %s" % (name, aid, bad))
        rows.append(["answer", name, aid, prompt, str(answer.get("keys"))])
    if "screenshots" in item:
        rows += [["nshot", name] + row for row in shot_rows(
            item["screenshots"], secrets, errors, "node %s: screenshots" % name)]
    return rows, name, mode, role


def check_nodes(doc, secrets, captures, errors):
    items = doc.get("nodes", [])
    if not isinstance(items, list):
        errors.append("nodes is not a list")
        return []
    rows, names, shapes = [], set(), {}
    for item in items:
        if not isinstance(item, dict):
            errors.append("a node is not a mapping")
            continue
        more, name, mode, role = check_node(item, secrets, captures, errors)
        if name in names:
            errors.append("node %s is declared twice" % name)
        names.add(name)
        shapes.setdefault(mode, {}).setdefault(role, 0)
        shapes[mode][role] += 1
        rows += more
    for mode, want in SHAPE.items():
        if mode in shapes and any(shapes[mode].get(r, 0) != n for r, n in want.items()):
            errors.append("the %s nodes are not %s" % (mode, ", ".join(
                "%d %s" % (n, r) for r, n in want.items() if n)))
    return rows


def rows(doc, secrets, errors):
    out = check_vm(doc, secrets, errors) + check_shots(doc, secrets, errors)
    cloud, captures = check_cloud(doc, secrets, errors)
    return out + check_nodes(doc, secrets, captures, errors) + cloud

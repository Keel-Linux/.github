#!/usr/bin/python3 -I
"""Read and check the commissioning contract of an appliance (decision 0075).

usage: contract.py tsv FILE           print the contract as tab separated lines
       contract.py instance FILE DIR  write the instance description and its
                                      secret files under DIR, as the machine
                                      has them: DIR/etc/keel/instance.yaml and
                                      DIR/etc/keel/secrets/KEY
       contract.py keys qm|tcl        the KEYS on stdin as `sendkey` lines of
                                      qm monitor, or as a Tcl string body
       contract.py mask               the KEYS on stdin as the guide shows them
       contract.py capture REGEX      the matches of REGEX in the screen on stdin

The instance names a secret as "secret:NAME", and NAME's value is the
environment variable KC_SECRET_NAME. Under secrets, which the first boot
reads from files only (backend file of libinithooks/declarative.py), KEY:
secret:NAME becomes KEY: {file: /etc/keel/secrets/KEY}, and that file holds
the value, mode 0600. Anywhere else the value is written in place.

Exit 0 on success, 2 when the contract is not valid (the reasons go to
stderr, one per line), 3 when a secret of the instance is not in the
environment.

The lines of `tsv`, one record per line, fields separated by a tab:

    appliance  NAME
    secret     NAME
    question   ID  HOOK  PROMPT  ANSWER  TYPE
    proof      SECRET  KIND  ARG1  ARG2  ARG3
    service    NAME
    url        URL  STATUS
    forbid     KIND  NAME

and the lines of screens.py: vm, installer, shot, node, answer, capture and
cross. bin/keel-commission reads them; it never parses YAML itself.

`keys` takes the values of {secret:NAME} from KC_SECRET_NAME, of {invite:N}
from KC_INVITE_N and of {vip} from KC_VIP, and exits 3 when one is not set.
"""

import os
import re
import sys

import yaml

# -I leaves the directory of this script out of the path: screens.py is
# found by its own path, next to this file
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import screens  # noqa: E402

NAME = re.compile(r"^[a-z][a-z0-9_]*$")
APPLIANCE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
HOOK = re.compile(r"^[0-9]{2}[A-Za-z0-9._-]+$")
PROMPT = re.compile(r"^[A-Za-z0-9 ._:()/'-]+$")
LITERAL = re.compile(r"^[A-Za-z0-9@._+-]+$")
SERVICE = re.compile(r"^[A-Za-z0-9@._-]+$")
URL = re.compile(r"^https?://[^\s\t'\"\\]+$")
SAFE = re.compile(r"^[^\t\n]+$")
PROOFS = {
    # kind: (required args, optional args)
    "shadow": (["user"], []),
    "mysql": (["user"], ["host"]),
    "pgsql": (["user"], ["host", "database"]),
    "command": (["run"], []),
}
FORBIDDEN = {"mysql-database", "pgsql-database", "hook", "path"}


def fail(errors):
    for error in errors:
        print("contract: " + error, file=sys.stderr)
    sys.exit(2)


def load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            doc = yaml.safe_load(handle)
    except (OSError, yaml.YAMLError) as error:
        fail(["cannot read %s: %s" % (path, error)])
    if not isinstance(doc, dict):
        fail(["%s is not a mapping" % path])
    return doc


def as_list(doc, key, errors):
    value = doc.get(key)
    if value is None:
        return []
    if not isinstance(value, list):
        errors.append("%s is not a list" % key)
        return []
    return value


def check_secrets(doc, errors):
    secrets = as_list(doc, "secrets", errors)
    for name in secrets:
        if not isinstance(name, str) or not NAME.match(name):
            errors.append("secret %r is not a lower case name" % (name,))
    if "root" not in secrets:
        errors.append("secrets does not declare root")
    return [s for s in secrets if isinstance(s, str)]


def check_answer(qid, answer, secrets, errors):
    if not isinstance(answer, str):
        errors.append("question %s: answer is not a string" % qid)
    elif answer.startswith("secret:"):
        if answer[7:] not in secrets:
            errors.append("question %s: %s is not declared" % (qid, answer))
    elif not LITERAL.match(answer):
        errors.append("question %s: answer %r has characters a "
                      "terminal answer cannot carry" % (qid, answer))


def check_questions(doc, secrets, errors):
    rows, ids, asked = [], set(), set()
    for item in as_list(doc, "questions", errors):
        if not isinstance(item, dict):
            errors.append("a question is not a mapping")
            continue
        qid = str(item.get("id", ""))
        if not NAME.match(qid):
            errors.append("question id %r is not a lower case name" % qid)
        if qid in ids:
            errors.append("question %s is declared twice" % qid)
        ids.add(qid)
        hook = str(item.get("hook", ""))
        if not HOOK.match(hook):
            errors.append("question %s: hook %r is not a hook name" % (qid, hook))
        prompt = str(item.get("prompt", ""))
        if not PROMPT.match(prompt):
            errors.append("question %s: prompt %r is empty or has "
                          "characters other than letters, digits and "
                          "._:()/'- " % (qid, prompt))
        answer = item.get("answer")
        # input: the answer is typed into an emptied field, then Enter;
        # choice: the answer is keys (screens.py), a menu or a yes/no box
        kind = item.get("type", "input")
        if kind == "choice":
            bad = screens.keys_valid(answer, [], set())
            if bad:
                errors.append("question %s: %s" % (qid, bad))
        elif kind == "input":
            check_answer(qid, answer, secrets, errors)
        else:
            errors.append("question %s: type %r is not input or choice" % (qid, kind))
        if isinstance(answer, str) and answer.startswith("secret:"):
            asked.add(answer[7:])
        rows.append(["question", qid, hook, prompt, str(answer), str(kind)])
    if not rows:
        errors.append("questions is empty: an appliance asks at least the "
                      "root password")
    for name in secrets:
        if name not in asked:
            errors.append("secret %s is answered by no question" % name)
    return rows


def check_proofs(doc, secrets, errors):
    rows, proved = [], set()
    for item in as_list(doc, "proofs", errors):
        if not isinstance(item, dict):
            errors.append("a proof is not a mapping")
            continue
        secret, kind = item.get("secret"), item.get("kind")
        if secret not in secrets:
            errors.append("proof of %r: not a declared secret" % (secret,))
        if kind not in PROOFS:
            errors.append("proof of %s: kind %r is not one of %s"
                          % (secret, kind, ", ".join(sorted(PROOFS))))
            continue
        required, optional = PROOFS[kind]
        args = []
        for key in required + optional:
            value = item.get(key, "")
            if key in required and not value:
                errors.append("proof of %s (%s): %s is missing"
                              % (secret, kind, key))
            if value and not SAFE.match(str(value)):
                errors.append("proof of %s (%s): %s has a tab or a newline"
                              % (secret, kind, key))
            args.append(str(value))
        proved.add(secret)
        rows.append(["proof", str(secret), kind] + args + [""] * (3 - len(args)))
    for name in secrets:
        if name not in proved:
            errors.append("secret %s has no proof" % name)
    return rows


def check_checks(doc, errors):
    rows = []
    for name in as_list(doc, "services", errors):
        if not isinstance(name, str) or not SERVICE.match(name):
            errors.append("service %r is not a unit name" % (name,))
        rows.append(["service", str(name)])
    for item in as_list(doc, "urls", errors):
        item = item if isinstance(item, dict) else {}
        url, status = item.get("url", ""), item.get("status")
        if not isinstance(url, str) or not URL.match(url):
            errors.append("url %r is not an http or https URL" % (url,))
        if not isinstance(status, int) or not 100 <= status <= 599:
            errors.append("url %s: status %r is not an HTTP status"
                          % (url, status))
        rows.append(["url", str(url), str(status)])
    for item in as_list(doc, "forbidden", errors):
        item = item if isinstance(item, dict) else {}
        kind, name = item.get("kind"), item.get("name", "")
        if kind not in FORBIDDEN:
            errors.append("forbidden kind %r is not one of %s"
                          % (kind, ", ".join(sorted(FORBIDDEN))))
        if not isinstance(name, str) or not SERVICE.match(name.replace("/", "")):
            errors.append("forbidden %s: name %r is not usable" % (kind, name))
        rows.append(["forbid", str(kind), str(name)])
    return rows


def tsv(path):
    rows, errors = contract_rows(path, nested=False)
    if errors:
        fail(errors)
    for row in rows:
        print("\t".join(row))


def contract_rows(path, nested):
    """The tsv rows of the contract at PATH and its errors. A node may name
    the contract of another appliance (the Keel Core witness of a cloud
    advanced set, decision 0076): that contract is checked too (NESTED),
    the contracts its own nodes name are not, and its secrets must be
    secrets of this one, which the runner makes once for the whole pass."""
    doc = load(path)
    errors = []
    if doc.get("contract") != 1:
        errors.append("contract: 1 is missing (the schema version)")
    appliance = str(doc.get("appliance", ""))
    if not APPLIANCE.match(appliance):
        errors.append("appliance %r is not an appliance name" % appliance)
    secrets = check_secrets(doc, errors)
    rows = [["appliance", appliance]] + [["secret", s] for s in secrets]
    rows += check_questions(doc, secrets, errors)
    rows += check_proofs(doc, secrets, errors)
    rows += check_checks(doc, errors)
    rows += screens.rows(doc, secrets, errors)
    if "instance" in doc and not isinstance(doc["instance"], dict):
        errors.append("instance is not a mapping")
    for row in rows:
        # the nodes of a contract that a node names are its own cloud
        # passes: the node takes only its questions, proofs, checks and
        # screenshots (node_tsv), so keel-core's own contract is the
        # contract of the witness
        if row[0] == "node" and row[7] != "-" and not nested:
            row[7] = node_contract(path, row[1], row[7], secrets, errors)
    return rows, errors


def node_contract(path, node, name, secrets, errors):
    """The absolute path of the contract NAME that NODE names, relative to
    the directory of PATH, checked"""
    other = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(path)), name))
    if not os.path.isfile(other):
        errors.append("node %s: contract %s is not a file" % (node, name))
        return other
    rows, more = contract_rows(other, nested=True)
    errors += ["node %s: %s: %s" % (node, name, e) for e in more]
    extra = sorted(r[1] for r in rows if r[0] == "secret" and r[1] not in secrets)
    if extra:
        errors.append("node %s: contract %s has secrets this one does not declare: %s"
                      % (node, name, ", ".join(extra)))
    return other


def render(value, missing):
    if isinstance(value, dict):
        return {k: render(v, missing) for k, v in value.items()}
    if isinstance(value, list):
        return [render(v, missing) for v in value]
    if isinstance(value, str) and value.startswith("secret:"):
        found = secret_value(value, missing)
        return value if found is None else found
    return value


SECRETS_DIR = "/etc/keel/secrets"


def secret_value(value, missing):
    """The value of "secret:NAME", or None after NAME went to MISSING"""
    name = "KC_SECRET_" + value[7:]
    if name not in os.environ:
        missing.append(value[7:])
        return None
    return os.environ[name]


def instance(path, root):
    doc = load(path)
    if not isinstance(doc.get("instance"), dict):
        fail(["instance is missing: the preseeded pass needs one"])
    missing = []
    out = render(doc["instance"], missing)
    files = {}
    declared = doc["instance"].get("secrets")
    if isinstance(declared, dict):
        for key, value in declared.items():
            if not (isinstance(value, str) and value.startswith("secret:")):
                continue
            if not NAME.match(str(key)):
                fail(["instance secrets.%s: not a lower case name" % (key,)])
            files[key] = secret_value(value, missing)
            out["secrets"][key] = {"file": "%s/%s" % (SECRETS_DIR, key)}
    if missing:
        print("contract: no value for secret " + ", ".join(missing),
              file=sys.stderr)
        sys.exit(3)
    keel = os.path.join(root, "etc", "keel")
    os.makedirs(os.path.join(keel, "secrets"), mode=0o700, exist_ok=True)
    for key, value in files.items():
        write(os.path.join(keel, "secrets", key), value)
    write(os.path.join(keel, "instance.yaml"),
          yaml.safe_dump(out, default_flow_style=False, sort_keys=False))


def write(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)


def values():
    """What {secret:NAME}, {invite:N} and {vip} stand for, from the environment"""
    found = {}
    for key, value in os.environ.items():
        if key.startswith("KC_SECRET_"):
            found["secret:" + key[10:]] = value
        elif key.startswith("KC_INVITE_"):
            found["invite:" + key[10:]] = value
    if "KC_VIP" in os.environ:
        found["vip"] = os.environ["KC_VIP"]
    return found


def keys(how):
    text = sys.stdin.read().rstrip("\n")
    try:
        tokens = screens.resolve(text, values())
        sys.stdout.write(screens.as_qm(tokens) if how == "qm" else screens.as_tcl(tokens))
    except KeyError as error:
        print("contract: no value for %s" % error.args[0], file=sys.stderr)
        sys.exit(3)
    except ValueError as error:
        print("contract: %s" % error, file=sys.stderr)
        sys.exit(2)


def main(argv):
    if argv[1:2] == ["tsv"] and len(argv) == 3:
        tsv(argv[2])
    elif argv[1:2] == ["keys"] and argv[2:] in (["qm"], ["tcl"]):
        keys(argv[2])
    elif argv[1:] == ["mask"]:
        print(screens.as_mask(sys.stdin.read().rstrip("\n")))
    elif argv[1:2] == ["capture"] and len(argv) == 3:
        for found in screens.capture(argv[2], sys.stdin.read()):
            print(found)
    elif argv[1:2] == ["instance"] and len(argv) == 4:
        instance(argv[2], argv[3])
    else:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv)

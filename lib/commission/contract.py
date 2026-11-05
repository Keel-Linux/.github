#!/usr/bin/python3 -I
"""Read and check the commissioning contract of an appliance (decision 0075).

usage: contract.py tsv FILE        print the contract as tab separated lines
       contract.py instance FILE   print the instance description, with every
                                   "secret:NAME" value replaced by the
                                   environment variable KC_SECRET_NAME

Exit 0 on success, 2 when the contract is not valid (the reasons go to
stderr, one per line), 3 when a secret of the instance is not in the
environment.

The lines of `tsv`, one record per line, fields separated by a tab:

    appliance  NAME
    secret     NAME
    question   ID  HOOK  PROMPT  ANSWER
    proof      SECRET  KIND  ARG1  ARG2  ARG3
    service    NAME
    url        URL  STATUS
    forbid     KIND  NAME

bin/keel-commission reads them; it never parses YAML itself.
"""

import os
import re
import sys

import yaml

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
        check_answer(qid, answer, secrets, errors)
        if isinstance(answer, str) and answer.startswith("secret:"):
            asked.add(answer[7:])
        rows.append(["question", qid, hook, prompt, str(answer)])
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
    if "instance" in doc and not isinstance(doc["instance"], dict):
        errors.append("instance is not a mapping")
    if errors:
        fail(errors)
    for row in rows:
        print("\t".join(row))


def render(value, missing):
    if isinstance(value, dict):
        return {k: render(v, missing) for k, v in value.items()}
    if isinstance(value, list):
        return [render(v, missing) for v in value]
    if isinstance(value, str) and value.startswith("secret:"):
        name = "KC_SECRET_" + value[7:]
        if name not in os.environ:
            missing.append(value[7:])
            return value
        return os.environ[name]
    return value


def instance(path):
    doc = load(path)
    if not isinstance(doc.get("instance"), dict):
        fail(["instance is missing: the preseeded pass needs one"])
    missing = []
    out = render(doc["instance"], missing)
    if missing:
        print("contract: no value for secret " + ", ".join(missing),
              file=sys.stderr)
        sys.exit(3)
    sys.stdout.write(yaml.safe_dump(out, default_flow_style=False,
                                    sort_keys=False))


def main(argv):
    if len(argv) != 3 or argv[1] not in ("tsv", "instance"):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        sys.exit(2)
    if argv[1] == "tsv":
        tsv(argv[2])
    else:
        instance(argv[2])


if __name__ == "__main__":
    main(sys.argv)

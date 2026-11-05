#!/usr/bin/env bats
# keel-commission (decision 0075): the contract checks, and the two LXC
# passes against a fake PVE host.
#
# KC_PVE is a fake that runs the remote command here. Its pct, pvesm and
# expect are fakes too: pct exec runs the guest script here with the paths
# of the machine moved under $GUEST and the guest's commands (systemctl,
# mysql, curl, ...) replaced by fakes that answer from files, so each case
# says what the machine is like and reads back what was recorded.

# The stand-ins are written in single quotes on purpose: they expand when
# they run.
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

KC="$BATS_TEST_DIRNAME/../bin/keel-commission"
CONTRACT_PY="$BATS_TEST_DIRNAME/../lib/commission/contract.py"
WP="$BATS_TEST_DIRNAME/fixtures/commission/wordpress.yaml"

setup() {
    TMP="$(mktemp -d)"
    FAKES="$TMP/fakes"
    GUEST="$TMP/guest"
    GBIN="$TMP/gbin"
    STATE="$TMP/state"
    OUT="$TMP/out"
    LOG="$TMP/log"
    mkdir -p "$FAKES" "$GBIN" "$STATE" "$GUEST/etc/default" "$GUEST/var/log" \
        "$GUEST/var/mail" "$GUEST/usr/lib/inithooks/firstboot.d" "$GUEST/9001/rootfs/etc"
    : > "$LOG"
    export TMP FAKES GUEST GBIN STATE OUT LOG
    export KC_PVE="$FAKES/pve" KC_POLL=1 KC_BOOT_TIMEOUT=2 KC_MAIL_WAIT=0
    export KC_CONSOLE_TIMEOUT=1 KC_CONSOLE_STEPS=3
    PATH="$FAKES:$PATH"
    export PATH

    # the PVE host: run the command string here
    cat > "$FAKES/pve" <<'EOF'
#!/bin/bash
printf 'pve %s\n' "$*" >> "$LOG"
exec bash -c "$*"
EOF

    cat > "$FAKES/pvesm" <<'EOF'
#!/bin/bash
printf 'template bytes\n' > "$TMP/template"
echo "$TMP/template"
EOF

    # pct: create/start/... by state files, exec by running the guest script
    cat > "$FAKES/pct" <<'EOF'
#!/bin/bash
printf 'pct %s\n' "$*" >> "$LOG"
case "$1" in
    status) [ -e "$STATE/exists" ] ;;
    create) [ ! -e "$STATE/create-fails" ] && touch "$STATE/exists" ;;
    start) [ ! -e "$STATE/start-fails" ] && cp "$STATE/boot-done" "$GUEST/etc/default/inithooks" 2>/dev/null; [ ! -e "$STATE/start-fails" ] ;;
    stop|destroy|unmount) rm -f "$STATE/exists"; [ "$1" != unmount ] || touch "$STATE/unmounted" ;;
    mount) [ -e "$STATE/mount-odd" ] && { echo "mounted CT $2 somewhere"; exit 0; }
           [ ! -e "$STATE/mount-fails" ] && echo "mounted CT $2 in '$GUEST/$2/rootfs'" ;;
    exec)
        sed -e "s#/etc/default/#$GUEST/etc/default/#g" -e "s#/var/#$GUEST/var/#g" \
            -e "s#/usr/lib/inithooks/#$GUEST/usr/lib/inithooks/#g" \
            | PATH="$GBIN:$PATH" bash -s ;;
esac
EOF

    # expect: keep the script, print the screen the case asked for
    cat > "$FAKES/expect" <<'EOF'
#!/bin/bash
cp "$1" "$TMP/console.exp"
cat "$STATE/screen" 2>/dev/null
EOF

    # the guest's commands
    cat > "$GBIN/systemctl" <<'EOF'
#!/bin/bash
grep -qx "${*: -1}" "$STATE/active" 2>/dev/null
EOF
    cat > "$GBIN/mysql" <<'EOF'
#!/bin/bash
case "$*" in
    *"SHOW DATABASES"*) cat "$STATE/databases" 2>/dev/null ;;
    *) [ -n "${MYSQL_PWD:-}" ] && grep -qx "$MYSQL_PWD" "$STATE/db-pass" 2>/dev/null ;;
esac
EOF
    cat > "$GBIN/psql" <<'EOF'
#!/bin/bash
case "$*" in
    *pg_database*) cat "$STATE/databases" 2>/dev/null ;;
    *) [ -n "${PGPASSWORD:-}" ] && grep -qx "$PGPASSWORD" "$STATE/db-pass" 2>/dev/null ;;
esac
EOF
    cat > "$GBIN/runuser" <<'EOF'
#!/bin/bash
shift 3
"$@"
EOF
    cat > "$GBIN/curl" <<'EOF'
#!/bin/bash
code=$(grep -F "${*: -1} " "$STATE/urls" 2>/dev/null | cut -d' ' -f2)
printf '%s' "${code:-000}"
EOF
    cat > "$GBIN/getent" <<'EOF'
#!/bin/bash
cat "$STATE/shadow" 2>/dev/null
EOF
    cat > "$GBIN/wp" <<'EOF'
#!/bin/bash
grep -qx "${*: -1}" "$STATE/app-pass" 2>/dev/null
EOF
    cat > "$GBIN/postconf" <<'EOF'
#!/bin/bash
cat "$STATE/myhostname"
EOF
    cat > "$GBIN/hostname" <<'EOF'
#!/bin/bash
[ "${1:-}" = -f ] && echo kc9001.example.invalid || echo kc9001
EOF
    chmod +x "$FAKES"/* "$GBIN"/*
    printf 'RUN_FIRSTBOOT=false\n' > "$STATE/boot-done"
    printf 'kc9001.example.invalid\n' > "$STATE/myhostname"
}

teardown() {
    rm -rf "$TMP"
}

# a contract with one secret of each proof kind
small_contract() {
    cat > "$TMP/c.yaml" <<'EOF'
contract: 1
appliance: demo
secrets: [root, db]
questions:
  - {id: root_password, hook: 30rootpass, prompt: Root Password, answer: secret:root}
  - {id: db_password, hook: 35mysqlpass, prompt: MariaDB password, answer: secret:db}
  - {id: email, hook: 85secalerts, prompt: Email, answer: admin@example.invalid}
instance:
  secrets: {root_password: secret:root, db_password: secret:db}
proofs:
  - {secret: root, kind: shadow, user: root}
  - {secret: db, kind: mysql, user: admin}
services: [nginx]
urls:
  - {url: 'https://127.0.0.1/', status: 200}
forbidden:
  - {kind: mysql-database, name: keel_check}
  - {kind: hook, name: 40lnmp-check}
  - {kind: path, name: /etc/forbidden}
EOF
}

# the machine as it should be, with the passwords of the console answers
good_machine() {
    printf 'nginx\n' > "$STATE/active"
    printf 'https://127.0.0.1/ 200\n' > "$STATE/urls"
}

# a screen where keel-init asked every question of small_contract, and the
# shadow and database passwords set to what was typed: the fake expect
# cannot type, so the case reads the answers from the script it was given.
answering_expect() {
    cat > "$FAKES/expect" <<'EOF'
#!/bin/bash
cp "$1" "$TMP/console.exp"
root=$(sed -n 's/.*KC_SEEN root_password.* 80\]\([^"]*\)\\r".*/\1/p' "$1")
db=$(sed -n 's/.*KC_SEEN db_password.* 80\]\([^"]*\)\\r".*/\1/p' "$1")
printf 'root:%s:20000:0:99999:7:::\n' "$(perl -e 'print crypt($ARGV[0], q{$6$saltsalt$})' "$root")" > "$STATE/shadow"
printf '%s\n' "$db" > "$STATE/db-pass"
cat "$STATE/screen"
EOF
    chmod +x "$FAKES/expect"
}

run_pass() {
    run "$KC" --contract "$TMP/c.yaml" --template local:vztmpl/t.tar.zst \
        --vmid 9001 --pass "$1" --site br2 --out "$OUT" "${@:2}"
}

# ---- contract ---------------------------------------------------------

@test "the wordpress contract is valid" {
    run "$KC" --check "$WP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"is a valid contract"* ]]
}

@test "a contract that is not there or not YAML is refused" {
    run "$KC" --check "$TMP/none.yaml"
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot read"* ]]
    printf 'a: [\n' > "$TMP/bad.yaml"
    run "$KC" --check "$TMP/bad.yaml"
    [ "$status" -eq 2 ]
    printf -- '- 1\n' > "$TMP/list.yaml"
    run "$KC" --check "$TMP/list.yaml"
    [ "$status" -eq 2 ]
    [[ "$output" == *"is not a mapping"* ]]
}

@test "every rule of the contract says what is wrong" {
    cat > "$TMP/c.yaml" <<'EOF'
appliance: Bad_Name
secrets: [Root, db, orphan]
questions:
  - not a mapping
  - {id: Q, hook: x, prompt: "a{b}", answer: secret:nope}
  - {id: q2, hook: 30rootpass, prompt: Ok, answer: "a b"}
  - {id: q2, hook: 30rootpass, prompt: Ok, answer: 5}
  - {id: q3, hook: 30rootpass, prompt: Ok, answer: secret:db}
proofs:
  - not a mapping
  - {secret: nope, kind: magic}
  - {secret: db, kind: mysql, host: "a\tb"}
services: ["bad unit"]
urls:
  - {url: "ftp://x", status: 99}
  - not a mapping
forbidden:
  - {kind: table, name: "a b"}
instance: [1]
EOF
    run "$KC" --check "$TMP/c.yaml"
    [ "$status" -eq 2 ]
    for want in "contract: 1 is missing" "appliance 'Bad_Name'" "secret 'Root'" \
        "does not declare root" "a question is not a mapping" "question id 'Q'" \
        "hook 'x'" "prompt 'a{b}'" "secret:nope is not declared" "cannot carry" \
        "q2 is declared twice" "answer is not a string" "secret orphan is answered by no question" \
        "a proof is not a mapping" "proof of 'nope'" "kind 'magic'" "user is missing" \
        "host has a tab" "secret orphan has no proof" "service 'bad unit'" \
        "is not an http or https URL" "is not an HTTP status" "forbidden kind 'table'" \
        "name 'a b' is not usable" "instance is not a mapping"; do
        [[ "$output" == *"$want"* ]] || { echo "missing: $want"; return 1; }
    done
}

@test "lists that are not lists, and a contract without questions" {
    printf 'contract: 1\nappliance: x\nsecrets: root\nquestions: {}\n' > "$TMP/c.yaml"
    run "$KC" --check "$TMP/c.yaml"
    [ "$status" -eq 2 ]
    [[ "$output" == *"secrets is not a list"* ]]
    [[ "$output" == *"questions is not a list"* ]]
    [[ "$output" == *"questions is empty"* ]]
}

@test "contract.py: usage, and an instance it cannot render" {
    run python3 -I "$CONTRACT_PY"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage"* ]]
    small_contract
    run python3 -I "$CONTRACT_PY" instance "$TMP/c.yaml"
    [ "$status" -eq 2 ]
    run python3 -I "$CONTRACT_PY" instance "$TMP/c.yaml" "$TMP/r"
    [ "$status" -eq 3 ]
    [[ "$output" == *"no value for secret root, db"* ]]
    [ ! -e "$TMP/r/etc/keel/instance.yaml" ]
    printf 'contract: 1\nlist: [secret:root, 1]\n' > "$TMP/n.yaml"
    run python3 -I "$CONTRACT_PY" instance "$TMP/n.yaml" "$TMP/r"
    [ "$status" -eq 2 ]
    [[ "$output" == *"instance is missing"* ]]
    printf 'instance:\n  secrets: {Root: secret:root}\n' > "$TMP/n.yaml"
    KC_SECRET_root=r run python3 -I "$CONTRACT_PY" instance "$TMP/n.yaml" "$TMP/r"
    [ "$status" -eq 2 ]
    [[ "$output" == *"secrets.Root: not a lower case name"* ]]
}

@test "contract.py: the secrets of the instance become files, the others stay in place" {
    printf 'instance:\n  keys: [secret:root, 1]\n  secrets: {root_password: secret:root, other: {generate: true}}\n' > "$TMP/n.yaml"
    KC_SECRET_root=r1 run python3 -I "$CONTRACT_PY" instance "$TMP/n.yaml" "$TMP/r"
    [ "$status" -eq 0 ]
    f="$TMP/r/etc/keel/instance.yaml"
    grep -qx -- '- r1' "$f"
    grep -q 'file: /etc/keel/secrets/root_password' "$f"
    grep -q 'generate: true' "$f"
    [ "$(cat "$TMP/r/etc/keel/secrets/root_password")" = r1 ]
    [ "$(stat -c %a "$TMP/r/etc/keel/secrets/root_password")" = 600 ]
    [ "$(stat -c %a "$f")" = 600 ]
    [ "$(stat -c %a "$TMP/r/etc/keel/secrets")" = 700 ]
    [ ! -e "$TMP/r/etc/keel/secrets/other" ]
}

# ---- arguments --------------------------------------------------------

@test "usage errors" {
    run "$KC"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage:"* ]]
    run "$KC" --bogus
    [ "$status" -eq 2 ]
    small_contract
    run "$KC" --contract "$TMP/c.yaml" --vmid 9001
    [ "$status" -eq 2 ]
    run_pass lxc-interactive --vmid x
    [ "$status" -eq 2 ]
    [[ "$output" == *"is not a container id"* ]]
    run_pass vm-iso
    [ "$status" -eq 2 ]
    [[ "$output" == *"is not lxc-interactive or lxc-preseed"* ]]
    KC_PVE="" run_pass lxc-interactive
    [ "$status" -eq 2 ]
    [[ "$output" == *"KC_PVE is not set"* ]]
}

@test "an invalid contract stops a pass before the PVE host is asked anything" {
    printf 'contract: 2\n' > "$TMP/c.yaml"
    run_pass lxc-interactive
    [ "$status" -eq 2 ]
    [ ! -s "$LOG" ]
}

@test "a container id in use is never touched" {
    small_contract
    touch "$STATE/exists"
    run_pass lxc-interactive
    [ "$status" -eq 4 ]
    ! grep -qE 'pct (create|destroy|stop)' "$LOG"
}

@test "a create or a start the PVE host refuses" {
    small_contract
    touch "$STATE/create-fails"
    run_pass lxc-interactive
    [ "$status" -eq 3 ]
    [[ "$output" == *"pct create failed"* ]]
    rm "$STATE/create-fails"
    touch "$STATE/start-fails"
    run_pass lxc-interactive
    [ "$status" -eq 3 ]
    [[ "$output" == *"pct start failed"* ]]
    rm -f "$STATE/exists"
    run_pass lxc-preseed
    [ "$status" -eq 3 ]
    rm -f "$STATE/exists" "$STATE/start-fails"
    touch "$STATE/create-fails"
    run_pass lxc-preseed
    [ "$status" -eq 3 ]
}

# ---- the interactive pass ----------------------------------------------

@test "interactive: the defects of 2026-11-05 all fail" {
    small_contract
    # no hint at login, keel-init asks only the root password, a fatal,
    # postfix keeps the build name, root has mail, keel_check is there
    printf 'KC_CONFCONSOLE\nKC_LAUNCH\nKC_SEEN root_password\nfatal [40wordpress]: cannot reach the database\nKC_DONE\n' > "$STATE/screen"
    printf 'keel-core\n' > "$STATE/myhostname"
    printf 'From www-data\nFrom www-data\n' > "$GUEST/var/mail/root"
    printf 'keel_check\n' > "$STATE/databases"
    touch "$GUEST/usr/lib/inithooks/firstboot.d/40lnmp-check"
    printf 'fatal [40wordpress]: x\n' > "$GUEST/var/log/inithooks.log"
    run_pass lxc-interactive
    [ "$status" -eq 1 ]
    for want in "fail  login.keel-init                          the login opens confconsole" "fail  keel-init.asked.db_password" \
        "pass  keel-init.asked.root_password" "fail  keel-init.no-fatal" \
        "fail  proof.root.shadow" "fail  proof.db.mysql" "fail  service.nginx" \
        "fail  url.https://127.0.0.1/" "fail  forbid.mysql-database.keel_check" \
        "fail  forbid.hook.40lnmp-check" "pass  forbid.path./etc/forbidden" \
        "fail  firstboot.no-fatal" "fail  postfix.myhostname" "fail  mail.root-empty"; do
        [[ "$output" == *"$want"* ]] || { echo "missing: $want"; return 1; }
    done
    grep -qx $'result\tfail' "$OUT/lxc-interactive/meta"
    grep -q 'pct destroy 9001' "$LOG"
}

@test "interactive: a machine that does it all passes, and no secret is written" {
    small_contract
    good_machine
    answering_expect
    printf 'KC_HINT\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_LAUNCH\nKC_DONE\n' > "$STATE/screen"
    run_pass lxc-interactive
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pass  login.keel-init                          the login says"* ]]
    [[ "$output" == *"PASS"* ]]
    grep -qx $'result\tpass' "$OUT/lxc-interactive/meta"
    grep -q $'^sha256\t[0-9a-f]\{64\}$' "$OUT/lxc-interactive/meta"
    root=$(sed -n 's/.*KC_SEEN root_password.* 80\]\([^"]*\)\\r".*/\1/p' "$TMP/console.exp")
    [ "${#root}" -eq 24 ]
    ! grep -rq "$root" "$OUT"
    grep -q 'stty_init "rows 40 columns 120"' "$TMP/console.exp"
    grep -q 'pct console 9001' "$TMP/console.exp"
    grep -q '80\]admin@example.invalid' "$TMP/console.exp"
    # the password menu gets Manual, never the Enter that takes Generate
    grep -q 'Choose how to set this password\*} $s\]} { send -- "M"' "$TMP/console.exp"
    # tty1 takes the password pct create gave, which is none of the secrets
    login=$(sed -n 's/.*-ex {Password:} { send -- "\([^"]*\)\\r".*/\1/p' "$TMP/console.exp")
    [ "${#login}" -eq 24 ]
    [ "$login" != "$root" ]
    grep -q -- "--password '$login'" "$LOG"
    ! grep -rq "$login" "$OUT"
    [[ "$output" == *"pass  console.login"* ]]
}

@test "interactive: a console that gives no root login" {
    small_contract
    good_machine
    printf 'KC_NOLOGIN\n' > "$STATE/screen"
    run_pass lxc-interactive
    [ "$status" -eq 1 ]
    [[ "$output" == *"fail  console.login                            no root login on tty1"* ]]
}

@test "interactive: a login that starts keel-init counts, a stuck console does not finish" {
    small_contract
    good_machine
    printf 'KC_SEEN root_password\nKC_STUCK\n' > "$STATE/screen"
    run_pass lxc-interactive
    [ "$status" -eq 1 ]
    [[ "$output" == *"pass  login.keel-init                          the login starts keel-init"* ]]
    [[ "$output" == *"fail  keel-init.finished                       KC_STUCK"* ]]
}

@test "interactive: a first boot that never ends" {
    small_contract
    rm "$STATE/boot-done"
    run_pass lxc-interactive --keep
    [ "$status" -eq 1 ]
    [[ "$output" == *"fail  firstboot.finished"* ]]
    ! grep -q 'pct destroy' "$LOG"
}

# ---- the preseeded pass ------------------------------------------------

@test "preseed: the description is written root only, and a deferred question fails" {
    small_contract
    good_machine
    printf 'INFO: [35mysqlpass] not asked, nobody can answer\nERR: [40wordpress] failed - exit code 1\n' > "$GUEST/var/log/inithooks.log"
    printf 'root\n' > "$STATE/shadow"
    run_pass lxc-preseed --keep
    [ "$status" -eq 1 ]
    [[ "$output" == *"fail  firstboot.no-fatal                       ERR: [40wordpress] failed"* ]]
    [[ "$output" == *"pass  instance.written"* ]]
    [[ "$output" == *"pass  preseed.answered.30rootpass"* ]]
    [[ "$output" == *"fail  preseed.answered.35mysqlpass"* ]]
    f="$GUEST/9001/rootfs/etc/keel/instance.yaml"
    [ "$(stat -c %a "$f")" = 600 ]
    grep -q 'file: /etc/keel/secrets/root_password' "$f"
    ! grep -q '[A-Za-z0-9]\{24\}' "$f"
    s="$GUEST/9001/rootfs/etc/keel/secrets"
    [ "$(stat -c %a "$s")" = 700 ]
    [ "$(stat -c %a "$s/db_password")" = 600 ]
    grep -qx '[A-Za-z0-9]\{24\}' "$s/root_password"
    [ -e "$STATE/unmounted" ]
}

@test "preseed: a description that cannot be written, and no instance in the contract" {
    small_contract
    touch "$STATE/mount-fails"
    run_pass lxc-preseed
    [ "$status" -eq 1 ]
    [[ "$output" == *"fail  instance.written"* ]]
    sed -i '/^instance:/,/^proofs:/{/^proofs:/!d}' "$TMP/c.yaml"
    rm -f "$STATE/exists"
    run_pass lxc-preseed
    [ "$status" -eq 2 ]
    [[ "$output" == *"instance is missing"* ]]
}

@test "preseed: a pgsql proof, a command proof, and no postfix" {
    cat > "$TMP/c.yaml" <<'EOF'
contract: 1
appliance: demo
secrets: [root, db, app]
questions:
  - {id: r, hook: 30rootpass, prompt: Root Password, answer: secret:root}
  - {id: d, hook: 35pgsqlpass, prompt: PostgreSQL password, answer: secret:db}
  - {id: a, hook: 40app, prompt: App password, answer: secret:app}
instance:
  secrets: {root_password: secret:root, db_password: secret:db, app_password: secret:app}
proofs:
  - {secret: root, kind: command, run: 'test -n "$SECRET"'}
  - {secret: db, kind: pgsql, user: odoo, database: odoo}
  - {secret: app, kind: command, run: 'wp user check-password admin "$SECRET"'}
forbidden:
  - {kind: pgsql-database, name: keel_check}
EOF
    rm "$GBIN/postconf"
    printf 'keel_check\n' > "$STATE/databases"
    run_pass lxc-preseed
    [ "$status" -eq 1 ]
    [[ "$output" == *"pass  proof.root.command"* ]]
    [[ "$output" == *"fail  proof.db.pgsql"* ]]
    [[ "$output" == *"fail  proof.app.command"* ]]
    [[ "$output" == *"fail  forbid.pgsql-database.keel_check"* ]]
    [[ "$output" == *"pass  postfix.myhostname                       no postfix"* ]]
}

@test "preseed: a mount path that is not the container's rootfs is never written to" {
    small_contract
    touch "$STATE/mount-odd"
    run_pass lxc-preseed
    [ "$status" -eq 1 ]
    [[ "$output" == *"fail  instance.written"* ]]
    [[ "$output" == *"not a rootfs of 9001"* ]]
    [ ! -e "$GUEST/9001/rootfs/etc/keel" ]
    [ -e "$STATE/unmounted" ]
}

@test "interactive: a login with no confconsole, no hint and no start of keel-init" {
    small_contract
    good_machine
    printf 'KC_LAUNCH\nKC_DONE\n' > "$STATE/screen"
    run_pass lxc-interactive
    [ "$status" -eq 1 ]
    [[ "$output" == *"fail  login.keel-init                          the login neither starts keel-init nor says to run it"* ]]
    [ -s "$OUT/lxc-interactive/console.txt" ]
}

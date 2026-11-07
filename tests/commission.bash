# shellcheck shell=bash
# The fake PVE host of the keel-commission tests (keel-commission.bats and
# keel-commission-vm.bats): KC_PVE runs the remote command here, and its
# pct, qm, pvesm and expect are fakes that answer from state files.

# The stand-ins are written in single quotes on purpose: they expand when
# they run. KC, CONTRACT_PY and WP are for the bats files that load this one.
# shellcheck disable=SC2016,SC2034

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
    export KC_CONSOLE_TIMEOUT=1 KC_CONSOLE_STEPS=3 KC_WEB_PROBE_PAUSE=0
    PATH="$FAKES:$PATH"
    export PATH

    # the PVE host: run the command string here
    cat > "$FAKES/pve" <<'EOF'
#!/bin/bash
printf 'pve %s\n' "$*" >> "$LOG"
# the probe of web_address: an address in STATE/reachable answers
if [[ "$*" == kc_probe=1* ]]; then
    # STATE/probe-fails: that many probes fail first, as when the PVE host
    # drops the connection
    left=$(cat "$STATE/probe-fails" 2>/dev/null || echo 0)
    if [ "$left" -gt 0 ]; then echo $((left - 1)) > "$STATE/probe-fails"; exit 255; fi
    for a in $(cat "$STATE/reachable" 2>/dev/null); do [[ "$*" == *"'$a'"* ]] && exit 0; done
    exit 1
fi
[ -e "$STATE/no-expect" ] && [ "$*" = "command -v expect" ] && exit 1
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
        # the guest paths go under $GUEST; a path that the script writes
        # into the spec ("file": ...) stays as the node sees it
        sed -e "s#/etc/default/#$GUEST/etc/default/#g" -e "s#/var/#$GUEST/var/#g" \
            -e "/\"file\": /!s#/etc/keel/#$GUEST/etc/keel/#g" \
            -e "s#/usr/lib/inithooks/#$GUEST/usr/lib/inithooks/#g" \
            | KC_FAKE_VMID="$2" PATH="$GBIN:$PATH" bash -s ;;
esac
EOF

    # expect: keep the script, print the screen the case asked for, the
    # screen of that container when the case has one
    cat > "$FAKES/expect" <<'EOF'
#!/bin/bash
id=$(sed -n 's/.*pct console \([0-9]*\).*/\1/p' "$1" | head -1)
cp "$1" "$TMP/console.exp"
cp "$1" "$TMP/console.$id.exp"
cat "$STATE/screen.$id" 2>/dev/null || cat "$STATE/screen" 2>/dev/null
EOF

    # qm: the VM. Its screens are the files $STATE/screens/NN, one after the
    # other: each qm monitor input with a sendkey goes to the next one. A
    # screen NOAGENT is one where the guest agent does not answer. After
    # the last screen the first boot has ended. guest exec runs a guest
    # script as pct exec does, and answers in JSON as qm does.
    cat > "$FAKES/qm" <<'EOF'
#!/bin/bash
printf 'qm %s\n' "$*" >> "$LOG"
cur=$(cat "$STATE/cur" 2>/dev/null || echo 1)
screen="$STATE/screens/$(printf %02d "$cur")"
json() { python3 -c 'import json,sys; print(json.dumps({"exited": 1, "exitcode": int(sys.argv[1]), "out-data": sys.stdin.read()}))' "$1"; }
case "$1" in
    status) [ -e "$STATE/vm-exists" ] ;;
    create) [ ! -e "$STATE/create-fails" ] && touch "$STATE/vm-exists" ;;
    start) [ ! -e "$STATE/start-fails" ] ;;
    stop|destroy) rm -f "$STATE/vm-exists" ;;
    set) ;;
    monitor)
        input=$(cat)
        printf '%s\n' "$input" >> "$STATE/keys"
        if grep -q '^screendump ' <<< "$input"; then
            f=$(sed -n 's/^screendump //p' <<< "$input")
            printf 'P6\n2 1\n255\nabcdef' > "$f"
        fi
        grep -q '^sendkey ' <<< "$input" && echo $((cur + 1)) > "$STATE/cur"
        true ;;
    guest)
        [ -e "$screen" ] || cp "$STATE/boot-done" "$GUEST/etc/default/inithooks"
        if [[ "$*" == *vcs1* ]]; then
            [ -e "$screen" ] || screen="$STATE/screens/last"
            # time goes on while nobody answers: the next read is the next screen
            if grep -qx NOAGENT "$screen" 2>/dev/null; then
                [ "$screen" = "$STATE/screens/last" ] || echo $((cur + 1)) > "$STATE/cur"
                echo "QEMU guest agent is not running" >&2
                exit 255
            fi
            # a progress screen (Please wait) goes on by itself after 4 reads
            if grep -q 'Please wait' "$screen"; then
                reads=$(( $(cat "$STATE/reads" 2>/dev/null || echo 0) + 1 ))
                echo "$reads" > "$STATE/reads"
                [ "$reads" -lt 4 ] || { echo $((cur + 1)) > "$STATE/cur"; rm "$STATE/reads"; }
            fi
            json 0 < "$screen"
        else
            out=$(sed -e "s#/etc/default/#$GUEST/etc/default/#g" -e "s#/var/#$GUEST/var/#g" \
                -e "s#/usr/lib/inithooks/#$GUEST/usr/lib/inithooks/#g" \
                | KC_FAKE_VMID="$3" PATH="$GBIN:$PATH" bash -s 2>/dev/null)
            rc=$?
            [ -e "$STATE/agent-hangs" ] && { printf '{"exited": 0}\n'; exit 0; }
            printf '%s' "$out" | json "$rc"
        fi ;;
esac
EOF

    # the browser of the web screenshots: one picture per shot line, and a
    # case that wants it fails with $STATE/web-fails
    cat > "$FAKES/webshot" <<'EOF'
#!/bin/bash
printf 'webshot %s proxy=%s\n' "$*" "$KC_WEB_PROXY" >> "$LOG"
n="$3"
while IFS=$'\t' read -r _ name _ _ path _ _ user _ secret _; do
    printf 'png' > "$2/web-$(printf %02d "$n")-$name.png"
    printf '%02d\tweb-%s\tweb-%02d-%s.png\topen %s\n' "$n" "$name" "$n" "$name" "$path"
    [ -z "$secret" ] || printf 'secret %s=%s\n' "$secret" "$(printenv "KC_SECRET_$secret")" >> "$STATE/web-secrets"
    n=$((n + 1))
done
[ ! -e "$STATE/web-fails" ] || { echo "no page at /wp-admin/" >&2; exit 1; }
EOF

    # the SOCKS tunnel: a port that listens, or none with $STATE/no-tunnel
    cat > "$FAKES/tunnel" <<'EOF'
#!/bin/bash
printf 'tunnel %s\n' "$*" >> "$LOG"
[ -e "$STATE/no-tunnel" ] && exit 1
port="${3##*:}"
exec python3 -c 'import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); time.sleep(30)' "$port"
EOF
    export KC_WEBSHOT="$FAKES/webshot" KC_TUNNEL="$FAKES/tunnel" KC_HOST_TMP="$TMP/host"

    # the guest's addresses, from $STATE/ip-4 and $STATE/ip-6
    cat > "$GBIN/ip" <<'EOF'
#!/bin/bash
case "$*" in
    *-4*) f="$STATE/ip-4" ;;
    *) f="$STATE/ip-6" ;;
esac
[ -e "$f" ] && printf '2: eth0    inet %s/64 scope global\n' "$(cat "$f")"
true
EOF
    # keel of the guest: the answer of the node the case wrote,
    # $STATE/keel.VMID, and exit 1 when there is none
    cat > "$GBIN/keel" <<'EOF'
#!/bin/bash
cat "$STATE/keel.$KC_FAKE_VMID" 2>/dev/null
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
id=$(sed -n 's/.*pct console \([0-9]*\).*/\1/p' "$1" | head -1)
cp "$1" "$TMP/console.exp"
cp "$1" "$TMP/console.$id.exp"
root=$(sed -n 's/.*KC_SEEN root_password.* 80\]\([^"]*\)\\r".*/\1/p' "$1")
db=$(sed -n 's/.*KC_SEEN db_password.* 80\]\([^"]*\)\\r".*/\1/p' "$1")
printf 'root:%s:20000:0:99999:7:::\n' "$(perl -e 'print crypt($ARGV[0], q{$6$saltsalt$})' "$root")" > "$STATE/shadow"
printf '%s\n' "$db" > "$STATE/db-pass"
cat "$STATE/screen.$id" 2>/dev/null || cat "$STATE/screen"
EOF
    chmod +x "$FAKES/expect"
}

run_pass() {
    run "$KC" --contract "$TMP/c.yaml" --template local:vztmpl/t.tar.zst \
        --vmid 9001 --pass "$1" --site br2 --out "$OUT" "${@:2}"
}


#!/usr/bin/env bats
# keel-commission (decisions 0075 and 0076): the VM from the ISO, the web
# screenshots, the nodes of the cloud modes and the guide, against the fake
# PVE host of commission.bash. Its qm shows the screens a case writes to
# $STATE/screens, one after the other, and answers guest exec in JSON as qm
# does, so the real qga.py and ppm2png.py run on it.

# The stand-ins are written in single quotes on purpose: they expand when
# they run.
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

load commission

LIB="$BATS_TEST_DIRNAME/../lib/commission"

# a contract with an installer of three screens, a password, an email, a
# yes/no choice and a web screenshot with a login
vm_contract() {
    cat > "$TMP/c.yaml" <<'EOF'
contract: 1
appliance: demo
secrets: [root, app]
questions:
  - {id: root_password, hook: 30rootpass, prompt: Root Password, answer: secret:root}
  - {id: app_password, hook: 40app, prompt: App password, answer: secret:app}
  - {id: email, hook: 85secalerts, prompt: System Notifications, answer: admin@example.invalid}
  - {id: updates, hook: 95secupdates, prompt: Security updates, answer: s, type: choice}
proofs:
  - {secret: root, kind: command, run: 'test -n "$SECRET"'}
  - {secret: app, kind: command, run: 'test -n "$SECRET"'}
services: [nginx]
vm:
  memory: 1024
  installer:
    - {id: scheme, prompt: Choose a partitioning scheme, keys: '{ret}'}
    - {id: begin, prompt: Begin installation, keys: y}
    - {id: medium, prompt: REMOVE the live installation medium, keys: '{ret}{ret}', eject: true, last: true}
screenshots:
  - {name: site, url: /}
  - name: admin
    url: /wp-login.php
    after: /wp-admin/
    login: {user_field: '#user_login', user: admin, password_field: '#user_pass', secret: app, submit: '#wp-submit'}
cloud:
  capture: {invite: 'keel1:[A-Z]+', vip: 'through (fd00::[0-9]+)'}
EOF
}

# screens NAME...: the screens of the VM in order; a name is a line of
# text on that screen, or NOAGENT
screens() {
    local n=0 text
    mkdir -p "$STATE/screens"
    for text in "$@"; do
        n=$((n + 1))
        if [ "$text" = NOAGENT ]; then
            echo NOAGENT > "$STATE/screens/$(printf %02d "$n")"
        else
            printf '  %s\n\n  < OK >\n' "$text" > "$STATE/screens/$(printf %02d "$n")"
        fi
    done
    printf '  confconsole: appliance services\n' > "$STATE/screens/last"
}

run_vm() {
    run "$KC" --contract "$TMP/c.yaml" --iso local:iso/demo.iso \
        --vmid 9001 --pass vm-iso --site br1 --out "$OUT" "$@"
}

# typed: what was typed on the VM, as text, one line per Enter
typed() {
    sed -n 's/^sendkey //p' "$STATE/keys" | awk '
        /^ret$/ { print line; line = ""; next }
        /^backspace$/ { next }
        /^shift-2$/ { line = line "@"; next }
        /^dot$/ { line = line "."; next }
        /^shift-[a-z]$/ { line = line toupper(substr($0, 7)); next }
        length($0) == 1 { line = line $0 }
        END { if (line != "") print line }'
}

vm_setup() {
    vm_contract
    good_machine
    printf '10.0.0.9\n' > "$STATE/ip-4"
    export KC_POLL=0 KC_BOOT_TIMEOUT=60 KC_CONSOLE_STEPS=40
}

# ---- the contract -------------------------------------------------------

@test "the wordpress contract with its screenshots and nodes is valid" {
    run python3 -I "$CONTRACT_PY" tsv "$WP"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'shot\twp-admin\thttps\t443\t/wp-login.php\t/wp-admin/\t#user_login\tadmin\t#user_pass\tapp\t#wp-submit\t0'* ]]
    [[ "$output" == *$'installer\tmedium\tREMOVE the live installation medium\t{ret}{ret}\teject,last'* ]]
    [[ "$output" == *$'node\tprimary\tbr1\tlxc\t-\tcloud_simple\tprimary'* ]]
    [[ "$output" == *$'capture\tinvite\t'* ]]
    [[ "$output" == *$'cross\tvip-holder\tall\tkeel vip status\t'* ]]
    # the contract of the vm-iso pass of BR1, 2026-11-05
    run "$KC" --check "$BATS_TEST_DIRNAME/fixtures/commission/mariadb-vm.yaml"
    [ "$status" -eq 0 ]
}

@test "every rule of the new sections says what is wrong" {
    cat > "$TMP/c.yaml" <<'EOF'
contract: 1
appliance: demo
secrets: [root]
questions:
  - {id: r, hook: 30rootpass, prompt: Root Password, answer: secret:root}
  - {id: c, hook: 30rootpass, prompt: Pick, answer: '{nope}', type: choice}
  - {id: t, hook: 30rootpass, prompt: Pick, answer: x, type: radio}
proofs:
  - {secret: root, kind: shadow, user: root}
vm:
  memory: 0
  cpu: qemu64
  installer:
    - not a mapping
    - {id: Bad, prompt: 'a{b}', keys: 'a[b'}
    - {id: two, prompt: Ok, keys: '{secret:nope}'}
screenshots:
  - not a mapping
  - {name: Bad, scheme: ftp, port: 0, url: x, after: 'y z', login: [1], wait: -1}
  - {name: two, url: /, login: {user_field: '#u', user: a, password_field: "a\tb", secret: nope}}
  - {name: two, url: /}
cloud:
  capture: {invite: '(', other: x, vip: "a\tb"}
  waits: ['a{b}']
  checks:
    - not a mapping
    - {id: Bad, at: '!', run: "", match: '(', count: -1, secret: nope}
nodes:
  - not a mapping
  - {name: Bad, site: B1, kind: box, mode: cloudy, role: king, image: 'no volid', answers: {}}
  - {name: p, site: br1, mode: cloud_simple, role: primary, answers: [1, {id: X, prompt: '', keys: '{invite:1}'}, {id: v, prompt: Ok, keys: '{vip}'}]}
  - {name: p, site: br1, mode: cloud_simple, role: primary}
EOF
    run "$KC" --check "$TMP/c.yaml"
    [ "$status" -eq 2 ]
    for want in "{nope} is not a key name" "type 'radio' is not input or choice" \
        "vm.memory 0 is not a positive number" "an installer screen is not a mapping" \
        "vm.cpu 'qemu64' is not one of host, kvm64, x86-64-v2, x86-64-v2-AES, x86-64-v3" \
        "installer screen id 'Bad'" "prompt 'a{b}' is not usable" "has characters no key types" \
        "{secret:nope} is not a declared secret" "vm.installer has no screen with last: true" \
        "a screenshot is not a mapping" "screenshot name 'Bad'" "scheme 'ftp'" "port 0 is not a port" \
        "url 'x' is not a path" "after 'y z' is not a path" "wait -1 is not 0 to 120" "login is not a mapping" \
        "login.password_field" "login.submit '' is missing" "login.secret 'nope'" "screenshot name 'two'" \
        "cloud.capture.invite: missing )" "cloud.capture.other is not invite or vip" \
        "cloud.capture.vip has a tab" "cloud.waits: 'a{b}' is not a prompt" "a cloud check is not a mapping" "cloud check id 'Bad'" \
        "run is empty" "at '!' is not a role" "match: missing )" "count -1 is not a number" \
        "secret 'nope' is not declared" "a node is not a mapping" "node name 'Bad'" "site 'B1'" \
        "kind 'box'" "mode 'cloudy'" "role 'king'" "image 'no volid'" "answers is not a list" \
        "an answer is not a mapping" "answer id 'X'" "prompt '' is not usable" \
        "{invite:1} needs capture.invite" "{vip} needs capture.vip" "node p is declared twice" \
        "the cloud_simple nodes are not 1 primary, 1 replica"; do
        [[ "$output" == *"$want"* ]] || { echo "missing: $want"; return 1; }
    done
}

@test "sections of the wrong shape are refused" {
    printf 'contract: 1\nappliance: x\nsecrets: [root]\nquestions: [{id: r, hook: 30rootpass, prompt: R, answer: "secret:root"}]\nproofs: [{secret: root, kind: shadow, user: root}]\nvm: [1]\nscreenshots: {}\ncloud: [1]\nnodes: {}\n' > "$TMP/c.yaml"
    run "$KC" --check "$TMP/c.yaml"
    [ "$status" -eq 2 ]
    for want in "vm is not a mapping" "screenshots is not a list" "cloud is not a mapping" "nodes is not a list"; do
        [[ "$output" == *"$want"* ]] || { echo "missing: $want"; return 1; }
    done
    printf 'contract: 1\nappliance: x\nsecrets: [root]\nquestions: [{id: r, hook: 30rootpass, prompt: R, answer: "secret:root"}]\nproofs: [{secret: root, kind: shadow, user: root}]\nvm: {installer: [], cpu: [host]}\ncloud: {capture: [1], checks: {}, waits: x}\n' > "$TMP/c.yaml"
    run "$KC" --check "$TMP/c.yaml"
    [ "$status" -eq 2 ]
    [[ "$output" == *"cloud.waits is not a list"* ]]
    [[ "$output" == *"vm.installer is not a list of screens"* ]]
    [[ "$output" == *"vm.cpu ['host'] is not one of"* ]]
    [[ "$output" == *"cloud.capture is not a mapping"* ]]
    [[ "$output" == *"cloud.checks is not a list"* ]]
}

@test "contract.py keys: qm key names, a Tcl body, and the guide's mask" {
    run bash -c "printf '{bksp}{secret:root}Ab.@_+-:/=~ 9{ret}{down}' | KC_SECRET_root=Xy python3 -I '$CONTRACT_PY' keys qm"
    [ "$status" -eq 0 ]
    [ "$(tr '\n' ' ' <<< "$output")" = "sendkey backspace sendkey shift-x sendkey y sendkey shift-a sendkey b sendkey dot sendkey shift-2 sendkey shift-minus sendkey shift-equal sendkey minus sendkey shift-semicolon sendkey slash sendkey equal sendkey shift-grave_accent sendkey spc sendkey 9 sendkey ret sendkey down " ]
    run bash -c "printf '{tab}{esc}{up}{left}{right}{spc}{invite:1}{vip}' | KC_INVITE_1='k\$[1]' KC_VIP=fd00::1 python3 -I '$CONTRACT_PY' keys tcl"
    [ "$output" = '\t\033\033\[A\033\[D\033\[C k\$\[1\]fd00::1' ]
    run bash -c "printf '{invite:2}' | python3 -I '$CONTRACT_PY' keys tcl"
    [ "$status" -eq 3 ]
    [[ "$output" == *"no value for invite:2"* ]]
    run bash -c "printf 'a[' | python3 -I '$CONTRACT_PY' keys qm"
    [ "$status" -eq 2 ]
    run bash -c "printf '{invite:1}' | KC_INVITE_1='a[' python3 -I '$CONTRACT_PY' keys qm"
    [ "$status" -eq 2 ]
    [[ "$output" == *"no key types '['"* ]]
    run bash -c "printf '{secret:root}{ret}{invite:2}{vip}x' | python3 -I '$CONTRACT_PY' mask"
    [ "$output" = "(the root secret)<ret>(invite 2 of the first node)(the VIP)x" ]
}

@test "contract.py capture: an invite line, also one a dialog box wrapped" {
    printf '│ Paste this line on the other node:     │\n│ keel1:AAAA-bbbb_cccc                   │\n│ VIP fd00:5::ffff:1                     │\n' > "$TMP/s1"
    run python3 -I "$CONTRACT_PY" capture 'keel1:[A-Za-z0-9_-]+' < "$TMP/s1"
    [ "$output" = "keel1:AAAA-bbbb_cccc" ]
    # 30 columns: the line runs to the box's edge and goes on below
    printf '│ keel1:AAAAAAAAAAAAAAAAAAAAAA│\n│ BBBBBB-cc                   │\n│ keel1:AAAAAAAAAAAAAAAAAAAAAA│\n│ BBBBBB-cc  and more text    │\n' > "$TMP/s2"
    run python3 -I "$CONTRACT_PY" capture 'keel1:[A-Za-z0-9_-]+' < "$TMP/s2"
    [ "$output" = "keel1:AAAAAAAAAAAAAAAAAAAAAABBBBBB-cc" ]
    run python3 -I "$CONTRACT_PY" capture 'VIP (fd[0-9a-f:]+)' < "$TMP/s1"
    # a pattern with a group gives the group: the address, not its label
    [ "$output" = "fd00:5::ffff:1" ]
    printf '│ keel1:AAAA│\n\n│ Next│\n' > "$TMP/s3"
    run python3 -I "$CONTRACT_PY" capture 'keel1:[A-Z]+' < "$TMP/s3"
    [ "$output" = "keel1:AAAA" ]
    printf 'keel1:AAAA\n!!\n' > "$TMP/s4"
    run python3 -I "$CONTRACT_PY" capture 'keel1:[A-Z]+' < "$TMP/s4"
    [ "$output" = "keel1:AAAA" ]
}

# ---- the helpers on the PVE host ------------------------------------------

@test "ppm2png: a P6 screen becomes a PNG, and anything else is refused" {
    printf 'P6\n# a comment\n2 2\n255\n\xff\x00\x00\x00\xff\x00\x00\x00\xff\xff\xff\xff' > "$TMP/s.ppm"
    run python3 -I "$LIB/ppm2png.py" "$TMP/s.ppm" "$TMP/s.png"
    [ "$status" -eq 0 ]
    [ "$(head -c 8 "$TMP/s.png" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ]
    [ "$(dd if="$TMP/s.png" bs=1 skip=12 count=12 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 494844520000000200000002 ]
    python3 -I -c 'import sys, zlib; d = open(sys.argv[1], "rb").read(); i = d.index(b"IDAT"); n = int.from_bytes(d[i-4:i], "big"); assert zlib.decompress(d[i+4:i+4+n]) == b"\x00\xff\x00\x00\x00\xff\x00\x00\x00\x00\xff\xff\xff\xff"' "$TMP/s.png"
    run python3 -I "$LIB/ppm2png.py"
    [ "$status" -eq 2 ]
    for bad in 'P3\n1 1\n255\n' 'P6\nx\n' 'P6\n1 1\n65535\n' 'P6\n2 2\n255\nabc'; do
        printf "$bad" > "$TMP/b.ppm"
        run python3 -I "$LIB/ppm2png.py" "$TMP/b.ppm" "$TMP/b.png"
        [ "$status" -eq 2 ] || { echo "accepted: $bad"; return 1; }
    done
    run python3 -I "$LIB/ppm2png.py" "$TMP/none.ppm" "$TMP/b.png"
    [ "$status" -eq 2 ]
}

@test "qga: the screen, a guest command and its status, a dead agent" {
    screens "Root Password"
    run python3 -I "$LIB/qga.py" screen 9001
    [ "$status" -eq 0 ]
    [[ "$output" == *"Root Password"* ]]
    run bash -c "printf 'echo out; echo err >&2; exit 3\n' | python3 -I '$LIB/qga.py' exec 9001"
    [ "$status" -eq 3 ]
    [[ "$output" == *out* ]]
    touch "$STATE/agent-hangs"
    run bash -c "echo true | python3 -I '$LIB/qga.py' exec 9001"
    [ "$status" -eq 124 ]
    printf 'NOAGENT\n' > "$STATE/screens/01"
    run python3 -I "$LIB/qga.py" screen 9001
    [ "$status" -eq 1 ]
    printf '#!/bin/bash\nexit 1\n' > "$FAKES/qm"
    run bash -c "echo true | python3 -I '$LIB/qga.py' exec 9001"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not answer"* ]]
    run python3 -I "$LIB/qga.py" shot 9001 "$TMP/x.png"
    [ "$status" -eq 2 ]
    run python3 -I "$LIB/qga.py"
    [ "$status" -eq 2 ]
}

@test "guide.py: one column per node, rows in order, and its usage" {
    mkdir -p "$OUT/cloud_simple/a/screens" "$OUT/cloud_simple/b" "$OUT/vm-iso" "$OUT/empty"
    printf '01\tmode\tscreens/01-mode.png\t<down><ret>\n02\troot\tscreens/02-root.txt\t(the root secret)\n' > "$OUT/cloud_simple/a/screens.tsv"
    printf 'node\ta\nsite\tbr1\nrole\tprimary\nvmid\t9002\n' > "$OUT/cloud_simple/a/meta"
    printf '01\tjoin\tscreens/01-join.png\t(invite 1 of the first node)|x\n' > "$OUT/cloud_simple/b/screens.tsv"
    printf 'node\tb\nvmid\t9001\n' > "$OUT/cloud_simple/b/meta"
    printf '01\tscheme\tscreens/01-scheme.png\t\n' > "$OUT/vm-iso/screens.tsv"
    touch "$OUT/file"
    run python3 -I "$LIB/guide.py" "$OUT"
    [ "$status" -eq 0 ]
    g="$OUT/guide.md"
    grep -qx '| Step | b | a, primary (br1) |' "$g"
    grep -qF '| 1 | ![join](cloud_simple/b/screens/01-join.png)<br>typed: `(invite 1 of the first node)\|x` | ![mode](cloud_simple/a/screens/01-mode.png)<br>typed: `<down><ret>` |' "$g"
    grep -qF '| 2 |  | [root](cloud_simple/a/screens/02-root.txt)<br>typed: `(the root secret)` |' "$g"
    grep -qx '| Step | vm-iso |' "$g"
    run python3 -I "$LIB/guide.py"
    [ "$status" -eq 2 ]
}

# ---- the VM from the ISO --------------------------------------------------

@test "vm-iso: the install and the first boot are answered, each screen is kept" {
    vm_setup
    screens NOAGENT "Choose a partitioning scheme:" "Begin installation?" \
        "Stage: Running Post-Install Commands. Please wait..." \
        "Please REMOVE the live installation medium" NOAGENT \
        "Root Password Choose how to set this password:" "Root Password Please enter new password" \
        "Root Password Confirm password" "App password" "System Notifications" \
        "Something nobody declared" "Something nobody declared" \
        "Invite: keel1:ABC through fd00::7" "Security updates"
    run_vm
    echo "$output"
    for want in "pass  installer.asked.scheme" "pass  installer.asked.medium" \
        "pass  installer.finished" "pass  firstboot.asked.root_password" \
        "pass  firstboot.asked.app_password" "pass  firstboot.asked.email" \
        "pass  firstboot.asked.updates" "pass  firstboot.finished" \
        "pass  service.nginx" "pass  proof.app.command" "pass  web.screenshots"; do
        [[ "$output" == *"$want"* ]] || { echo "missing: $want"; return 1; }
    done
    # the VM as an operator makes it, and the ISO out at the end of the install
    grep -q "qm create 9001 --name kc9001 --memory 1024 --cores 2 .*--virtio0 local-lvm:16 --ide2 'local:iso/demo.iso',media=cdrom --boot 'order=virtio0;ide2' --agent enabled=1" "$LOG"
    grep -q 'qm set 9001 --ide2 none,media=cdrom' "$LOG"
    grep -q 'qm destroy 9001 --purge 1' "$LOG"
    # Manual on the password menu, the password twice, the email, s, and
    # Enter on the screen nobody declared
    typed > "$TMP/typed"
    root=$(awk 'length == 24' "$TMP/typed" | head -1)
    [ "$(grep -cx "$root" "$TMP/typed")" -eq 2 ]
    grep -qx m "$TMP/typed"
    grep -qx admin@example.invalid "$TMP/typed"
    grep -qx s "$TMP/typed"
    [ -z "$(grep -rl "$root" "$OUT")" ]
    grep -q "secret app=" "$STATE/web-secrets"
    s="$OUT/vm-iso/screens"
    [ "$(head -c 8 "$s/02-scheme.png" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ]
    grep -q 'Choose a partitioning scheme' "$s/02-scheme.txt"
    [ -e "$s/01-installer-boot.png" ]
    ls "$s" | grep -q -- '-root_password-menu.png'
    ls "$s" | grep -q 'firstboot-screen.png'
    ls "$s" | grep -q 'firstboot-end.png'
    [ -e "$s/web-01-site.png" ]
    grep -q $'\troot_password\tscreens/[0-9]*-root_password.png\t(the root secret)<ret>$' "$OUT/vm-iso/screens.tsv"
    grep -qF 'typed: `admin@example.invalid<ret>`' "$OUT/guide.md"
    grep -qF '![web-admin](vm-iso/screens/web-02-admin.png)' "$OUT/guide.md"
    grep -qx $'iso\tlocal:iso/demo.iso' "$OUT/vm-iso/meta"
    # what the first node of a cloud mode shows, read from the screen once
    [ "$(grep -cx 'KC_INVITE keel1:ABC' "$OUT/vm-iso/console.log")" -eq 1 ]
    grep -qx 'KC_VIP fd00::7' "$OUT/vm-iso/console.log"
    # a screen that stays the same after its Enter gets Enter again, later
    [ "$(ls "$s" | grep -c 'firstboot-screen.png')" -eq 3 ]
    # the installer's progress gets a screenshot and no key
    ls "$s" | grep -q 'installer-wait.png'
    grep -q $'\tinstaller-wait\tscreens/[0-9]*-installer-wait.png\t$' "$OUT/vm-iso/screens.tsv"
    grep -q 'webshot .* proxy=socks5://127.0.0.1:' "$LOG"
}

@test "vm-iso: an agent that never answers, and a screen that never ends" {
    vm_setup
    export KC_BOOT_TIMEOUT=3
    screens NOAGENT NOAGENT
    echo NOAGENT > "$STATE/screens/last"
    run_vm --keep
    [ "$status" -eq 1 ]
    [[ "$output" == *"fail  installer.asked.scheme"* ]]
    [[ "$output" == *"fail  installer.finished                       KC_NOAGENT installer: the installer did not end"* ]]
    run grep -c 'qm destroy' "$LOG"
    [ "$output" = 0 ]
    # the same boot screen is kept once
    [ "$(ls "$OUT/vm-iso/screens" | wc -l)" -le 2 ]
    rm -rf "$STATE/screens" "$STATE/cur" "$OUT" "$GUEST/etc/default/inithooks"
    rm -f "$STATE/vm-exists"
    export KC_CONSOLE_STEPS=3 KC_BOOT_TIMEOUT=60
    screens "Choose a partitioning scheme:" "Begin installation?" \
        "Please REMOVE the live installation medium" "Root Password Please enter" \
        "Unknown 1" "Unknown 2" "Unknown 3" "Unknown 4"
    run_vm
    [ "$status" -eq 1 ]
    [[ "$output" == *"fail  firstboot.finished                       KC_STUCK firstboot"* ]]
}

@test "vm-iso: no --iso, a vmid in use, a create or a start refused" {
    vm_setup
    run "$KC" --contract "$TMP/c.yaml" --vmid 9001 --pass vm-iso --site br1 --out "$OUT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"needs --iso"* ]]
    touch "$STATE/vm-exists"
    run_vm
    [ "$status" -eq 4 ]
    rm "$STATE/vm-exists"
    touch "$STATE/create-fails"
    run_vm
    [ "$status" -eq 3 ]
    [[ "$output" == *"qm create failed"* ]]
    rm "$STATE/create-fails"
    touch "$STATE/start-fails"
    run_vm
    [ "$status" -eq 3 ]
    [[ "$output" == *"qm start failed"* ]]
}

@test "vm-iso: with no vm.cpu, qm create is the line of before and the record names kvm64" {
    vm_setup
    touch "$STATE/start-fails"
    run_vm
    [ "$status" -eq 3 ]
    grep -qxF "pve qm create 9001 --name kc9001 --memory 1024 --cores 2 --ostype l26 --scsihw virtio-scsi-single --virtio0 local-lvm:16 --ide2 'local:iso/demo.iso',media=cdrom --boot 'order=virtio0;ide2' --agent enabled=1 --vga std  " "$LOG"
    run grep -c -- '--cpu' "$LOG"
    [ "$output" = 0 ]
    grep -qx $'cpu\tkvm64' "$OUT/vm-iso/meta"
    grep -qx $'note\tvm.cpu\tthe VM has the CPU type kvm64, the default of qm create' "$OUT/vm-iso/record.tsv"
    # the fields of before keep their order, the new one comes after them
    [ "$(cut -f1 "$OUT/vm-iso/meta" | tr '\n' ' ')" = "pass site iso sha256 contract date cpu " ]
}

@test "vm-iso: the CPU type of vm.cpu goes to qm create and to the record" {
    vm_setup
    sed -i 's/^  memory: 1024$/  memory: 1024\n  cpu: x86-64-v2-AES/' "$TMP/c.yaml"
    run "$KC" --check "$TMP/c.yaml"
    [ "$status" -eq 0 ]
    touch "$STATE/start-fails"
    run_vm
    [ "$status" -eq 3 ]
    grep -qxF "pve qm create 9001 --name kc9001 --memory 1024 --cores 2 --cpu x86-64-v2-AES --ostype l26 --scsihw virtio-scsi-single --virtio0 local-lvm:16 --ide2 'local:iso/demo.iso',media=cdrom --boot 'order=virtio0;ide2' --agent enabled=1 --vga std  " "$LOG"
    grep -qx $'cpu\tx86-64-v2-AES' "$OUT/vm-iso/meta"
    grep -qx $'note\tvm.cpu\tthe VM has the CPU type x86-64-v2-AES, from vm.cpu of the contract' "$OUT/vm-iso/record.tsv"
}

@test "vm_create: a CPU type off the list never reaches qm create" {
    # contract.py refuses it first; vm.sh checks the value again, as it
    # goes into a command line on the PVE host
    # shellcheck source=../lib/commission/vm.sh
    source "$LIB/vm.sh"
    pve_retry() { echo "pve_retry $*" >> "$TMP/calls"; }
    pve() { echo "pve $*" >> "$TMP/calls"; }
    KC_VM_FIRMWARE=seabios KC_VMID=9001
    for bad in 'qemu64' 'host; reboot' 'x86-64-v2-aes' 'host --args x'; do
        KC_TSV=$(printf 'vm\tmemory\t1024\nvm\tcores\t2\nvm\tdisk\t16\nvm\tcpu\t%s\n' "$bad")
        run vm_create local:iso/x.iso
        [ "$status" -eq 1 ]
        [[ "$output" == *"vm.cpu '$bad' is not kvm64, x86-64-v2, x86-64-v2-AES, x86-64-v3 or host"* ]]
    done
    [ ! -e "$TMP/calls" ]
    for good in kvm64 x86-64-v2 x86-64-v2-AES x86-64-v3 host; do
        KC_TSV=$(printf 'vm\tcpu\t%s\n' "$good")
        run vm_cpu
        [ "$status" -eq 0 ]
        [ "$output" = "$good" ]
    done
}

@test "vm-iso: UEFI when the ISO has /EFI, or when the site says so" {
    vm_setup
    touch "$STATE/start-fails"
    printf '#!/bin/bash\necho /EFI/BOOT/BOOTX64.EFI\n' > "$FAKES/isoinfo"
    chmod +x "$FAKES/isoinfo"
    run_vm
    grep -q 'qm create 9001 .* --bios ovmf --machine q35 --efidisk0 local-lvm:1,efitype=4m' "$LOG"
    rm "$FAKES/isoinfo" "$STATE/vm-exists"
    : > "$LOG"
    KC_VM_FIRMWARE_BR1=seabios KC_VM_STORAGE_BR1=local-zfs run_vm
    run grep -c -- '--bios ovmf' "$LOG"
    [ "$output" = 0 ]
    grep -q 'virtio0 local-zfs:16' "$LOG"
}

# ---- web screenshots on a container ----------------------------------------

@test "web: the pages of the contract through a tunnel, and what fails" {
    vm_setup
    rm "$STATE/ip-4"
    small_contract
    printf 'screenshots:\n  - {name: site, url: /}\n' >> "$TMP/c.yaml"
    printf 'KC_HINT\nKC_SEEN root_password\nKC_DONE\n' > "$STATE/screen"
    run_pass lxc-interactive
    [[ "$output" == *"fail  web.screenshots                          the machine has no global address"* ]]
    printf 'fd00::5\n' > "$STATE/ip-6"
    rm -f "$STATE/exists"
    run_pass lxc-interactive
    [[ "$output" == *"pass  web.screenshots                          1 pages of fd00::5"* ]]
    grep -q 'tunnel -N -D 127.0.0.1:' "$LOG"
    grep -qx $'01\tweb-site\tscreens/web-01-site.png\topen /' "$OUT/lxc-interactive/screens.tsv"
    printf '10.0.0.5\n' > "$STATE/ip-4"
    touch "$STATE/web-fails"
    rm -f "$STATE/exists"
    run_pass lxc-interactive
    [[ "$output" == *"fail  web.screenshots                          no page at /wp-admin/"* ]]
    grep -q 'webshot fd00::5 ' "$LOG"
    # the address the PVE host reaches is taken, IPv4 here (BR2, 2026-11-06)
    printf '10.0.0.5\n' > "$STATE/reachable"
    rm -f "$STATE/exists" "$STATE/web-fails"
    run_pass lxc-interactive
    [[ "$output" == *"pass  web.screenshots                          1 pages of 10.0.0.5"* ]]
    grep -q "kc_probe=1 timeout 5 .* 'fd00::5' '443'" "$LOG"
    # a round in which no probe reaches is tried again: on BR2 every probe
    # failed once and the shots went to an address the host does not reach
    # (keel-lnpp and keel-postgresql lxc-preseed, 2026-11-06)
    printf '2\n' > "$STATE/probe-fails"
    rm -f "$STATE/exists"
    run_pass lxc-interactive
    [[ "$output" == *"pass  web.screenshots                          1 pages of 10.0.0.5"* ]]
    touch "$STATE/no-tunnel"
    rm -f "$STATE/exists"
    run_pass lxc-interactive
    [[ "$output" == *"fail  web.screenshots                          no SOCKS tunnel through the PVE host"* ]]
}

@test "lxc: the console is kept as one text frame per answered screen" {
    small_contract
    good_machine
    sed -i 's/^  - {id: email.*/  - {id: email, hook: 85secalerts, prompt: Email, answer: admin@example.invalid}\n  - {id: ok, hook: 85secalerts, prompt: Is your email correct, answer: "y", type: choice}/' "$TMP/c.yaml"
    printf 'KC_HINT\nthe root box\nKC_SEEN root_password\nthe email box\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen"
    run_pass lxc-interactive
    f="$OUT/lxc-interactive/screens"
    grep -qx 'the root box' "$f/01-root_password.txt"
    grep -qx 'the email box' "$f/02-email.txt"
    grep -qx $'01\troot_password\tscreens/01-root_password.txt\t(the root secret)' "$OUT/lxc-interactive/screens.tsv"
    grep -qx $'02\temail\tscreens/02-email.txt\tadmin@example.invalid' "$OUT/lxc-interactive/screens.tsv"
    # a choice gets its keys and nothing else once the screen is still: no
    # emptied field, no Enter
    grep -qF -- '-ex {Is your email correct} { step; set launched 1; settle; sleep 1; puts "\nKC_SEEN ok"; choose "y"; exp_continue }' "$TMP/console.exp"
}

# ---- the cloud modes -------------------------------------------------------

# two containers of cloud_simple, the replica on BR2, and the checks
cloud_contract() {
    small_contract
    cat >> "$TMP/c.yaml" <<'EOF'
cloud:
  capture:
    invite: 'keel1:[A-Za-z0-9_-]+'
    vip: 'VIP (fd00:[0-9a-f:]+)'
  waits: [Waiting for the nodes]
  checks:
    - {id: holder, at: all, run: 'keel vip status', match: holder, count: 1}
    - {id: row, at: replica, run: 'keel row "$VIP" "$SECRET"', secret: db}
    - {id: voters, at: primary, run: 'keel mesh status', match: '3 voter'}
nodes:
  - name: one
    site: br1
    mode: cloud_simple
    role: primary
    answers:
      - {id: mode, prompt: Installation mode, keys: '{down}{ret}'}
  - name: two
    site: br2
    mode: cloud_simple
    role: replica
    answers:
      - {id: join, prompt: Join a mesh, keys: '{invite:1}{ret}'}
      - {id: vip, prompt: The VIP, keys: '{vip}{ret}'}
EOF
}

run_cloud() {
    run "$KC" --contract "$TMP/c.yaml" --template local:vztmpl/t.tar.zst \
        --vmid 9001 --pass cloud_simple --site br1 --out "$OUT" "$@"
}

@test "cloud: the invite of node one is typed on node two, and the checks across them" {
    cloud_contract
    good_machine
    answering_expect
    printf '#!/bin/bash\nprintf "pve2 %%s\\n" "$*" >> "$LOG"\nexec bash -c "$*"\n' > "$FAKES/pve2"
    chmod +x "$FAKES/pve2"
    export KC_PVE_BR2="$FAKES/pve2" KC_BOOT_TIMEOUT=30
    # the bytes of a screen, as the raw console of a real node holds them:
    # grep without -a reads such a log as binary and prints no line
    printf '\033[2J\000\001\nKC_HINT\nKC_SEEN mode\nInvite a node\nKC_INVITE keel1:SECRETTOKEN\nKC_INVITE keel1:SECRETTOKEN\nKC_VIP fd00::ffff:1\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9001"
    printf 'KC_HINT\nkeel1:SECRETTOKEN pasted\nx1:SECRETTOKENx\nxel1:SECRETTOKx\nKC_SEEN join\nKC_SEEN vip\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9002"
    printf 'vip fd00::ffff:1: holder\n3 voter(s)\n' > "$STATE/keel.9001"
    printf 'vip fd00::ffff:1: follower\n' > "$STATE/keel.9002"
    run_cloud
    echo "$output"
    for want in "pass  one:keel-init.asked.mode" "pass  two:keel-init.asked.join" \
        "pass  cross.holder                             1 of 2 nodes (all)" \
        "pass  cross.row                                1 of 1 nodes (replica)" \
        "pass  cross.voters"; do
        [[ "$output" == *"$want"* ]] || { echo "missing: $want"; return 1; }
    done
    # node two got the invite and the VIP of node one's screen, as keys of
    # its answers, each screen of the node by one pattern (node_answer)
    grep '^set node_answers' "$TMP/console.9002.exp" | grep -qF '"keel1:SECRETTOKEN\r"'
    grep '^set node_answers' "$TMP/console.9002.exp" | grep -qF '"fd00::ffff:1\r"'
    grep '^set node_answers' "$TMP/console.9001.exp" | grep -qF '"\033\[B\r"'
    grep -qF -- '-ex {Installation mode} { node_answer {Installation mode}; exp_continue }' "$TMP/console.9001.exp"
    grep -qF -- '-re {keel1:[A-Za-z0-9_-]+} { puts "\nKC_INVITE $expect_out(0,string)"; answered_in $expect_out(buffer); exp_continue }' "$TMP/console.9001.exp"
    # the screen whose title a capture takes gets its answer there, once
    grep -qF 'set node_answers [list "mode"' "$TMP/console.9001.exp"
    grep -qF 'proc answered_in {text}' "$TMP/console.9001.exp"
    # a choice sends its keys, waits for the menu to draw them, then Enter
    grep -qF 'proc choose {keys}' "$TMP/console.9001.exp"
    grep -qF 'expect -timeout 5 -re {.+} { set drawn 1 }' "$TMP/console.9001.exp"
    grep -qF 'choose $keys } }' "$TMP/console.9001.exp"
    # on a screen that waits for the other node, no key and no step
    grep -qF -- '-ex {Waiting for the nodes} { set waiting 1; exp_continue }' "$TMP/console.9001.exp"
    grep -qF -- 'timeout { if {$waiting} { set waiting 0; incr waited; if {$waited > 3600} { puts "\nKC_STUCK"; exit 0 }; exp_continue }; step;' "$TMP/console.9001.exp"
    grep -qF -- '-re {VIP (fd00:[0-9a-f:]+)} { puts "\nKC_VIP $expect_out(1,string)"; answered_in $expect_out(buffer); exp_continue }' "$TMP/console.9001.exp"
    # each site's own PVE host, the vmids one after the other
    grep -q '^pve2 pct create 9002 ' "$LOG"
    grep -q '^pve pct create 9001 ' "$LOG"
    grep -q '^pve2 pct stop 9002.*pct destroy 9002' "$LOG"
    # no file of the run keeps the invite
    [ -z "$(grep -rl SECRETTOKEN "$OUT")" ]
    grep -q '<invite 1> pasted' "$OUT/cloud_simple/two/console.txt"
    # the windows of an input box narrower than the invite: pieces of it
    [ -z "$(grep -rl 'ECRETTOK' "$OUT")" ]
    grep -qx 'x<invite 1>x' "$OUT/cloud_simple/two/screens/01-join.txt"
    grep -qx $'01\tjoin\tscreens/01-join.txt\t(invite 1 of the first node)<ret>' "$OUT/cloud_simple/two/screens.tsv"
    grep -q '| Step | one, primary (br1) | two, replica (br2) |' "$OUT/guide.md"
    grep -qx $'result\tpass' "$OUT/cloud_simple/meta"
    # the release gate finds the record by the sha256 of the template the
    # nodes of this appliance boot, read on each node's own PVE host
    local sha node
    sha=$(printf 'template bytes\n' | sha256sum | cut -d' ' -f1)
    grep -qx $'sha256\t'"$sha" "$OUT/cloud_simple/meta"
    [[ "$output" == *"pass  images.same"* ]]
    for node in one two; do
        grep -qx $'sha256\t'"$sha" "$OUT/cloud_simple/$node/meta"
        grep -qx $'image\tlocal:vztmpl/t.tar.zst' "$OUT/cloud_simple/$node/meta"
        grep -qx $'own\tyes' "$OUT/cloud_simple/$node/meta"
    done
    grep -q '^pve2 sha256sum ' "$LOG"
}

@test "cloud: nodes of this appliance that boot other bytes on another site prove no one template" {
    cloud_contract
    good_machine
    answering_expect
    # one volume name, other bytes on BR2
    printf '#!/bin/bash\nprintf "template bytes %%s\\n" "${FAKE_SITE:-br1}" > "$TMP/template.${FAKE_SITE:-br1}"\necho "$TMP/template.${FAKE_SITE:-br1}"\n' > "$FAKES/pvesm"
    printf '#!/bin/bash\nprintf "pve2 %%s\\n" "$*" >> "$LOG"\nexport FAKE_SITE=br2\nexec bash -c "$*"\n' > "$FAKES/pve2"
    chmod +x "$FAKES/pve2"
    export KC_PVE_BR2="$FAKES/pve2" KC_BOOT_TIMEOUT=30
    printf 'KC_HINT\nKC_SEEN mode\nKC_INVITE keel1:SECRETTOKEN\nKC_VIP fd00::ffff:1\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9001"
    printf 'KC_HINT\nKC_SEEN join\nKC_SEEN vip\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9002"
    run_cloud
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"fail  images.same"*"do not boot one image"* ]]
    [ "$(grep -c $'^sha256\t' "$OUT/cloud_simple/meta")" = 0 ]
    grep -qx $'result\tfail' "$OUT/cloud_simple/meta"
    [ "$(sed -n 's/^sha256\t//p' "$OUT/cloud_simple/one/meta")" != "$(sed -n 's/^sha256\t//p' "$OUT/cloud_simple/two/meta")" ]
}

@test "mask.py: the pieces that a sliding input box leaves beside an invite go too" {
    # the Join a mesh box of a replica is narrower than the invite: it
    # redraws pieces of it beside the whole line, and pieces shorter than
    # PIECE stayed in screens/07-join.txt (keel-core, BR2, 2026-11-06)
    mkdir -p "$TMP/m"
    printf 'keel1:SECRETTOKENRETTOKEN\nRETTOKkeel1:SECRETTOKEN\nx keel1:SECRETTOKEN x\nx1:SECRETTOKENx\nkeel1:SECRETTOKENab\n' > "$TMP/m/screen.txt"
    printf 'keel1:SECRETTOKEN\n' | python3 -I "${CONTRACT_PY%/*}/mask.py" "$TMP/m"
    run cat "$TMP/m/screen.txt"
    [ "${lines[0]}" = '<invite 1>' ]
    [ "${lines[1]}" = '<invite 1>' ]
    [ "${lines[2]}" = 'x <invite 1> x' ]
    [ "${lines[3]}" = 'x<invite 1>x' ]
    [ "${lines[4]}" = '<invite 1>ab' ]
}

@test "webshot.py: a page whose stylesheet did not load fails, after its shot is written" {
    # The login page of a cloud advanced replica was shot with no style at
    # all, and the run counted it (wordpress, BR2, 2026-11-07). A shot now
    # fails when a stylesheet link of the page has no sheet or answered 400
    # or more, and says what the browser got; the picture stays as the
    # evidence of it.
    run python3 -I - "${CONTRACT_PY%/*}/webshot.py" "$TMP" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("webshot", sys.argv[1])
webshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(webshot)
webshot.time.sleep = lambda s: None
class Fake:
    wait = 1
    def __init__(self, bad):
        self.bad = bad
        self.shots = []
    def open(self, url):
        pass
    def wait_text(self, text):
        return True
    def evaluate(self, expression):
        if "stylesheet" in expression:
            return self.bad
        if "innerText.includes" in expression:
            return True
        return False
    def shot(self, path):
        self.shots.append(path)
    def answer(self, url):
        return "status 200, text/html, starts <!doctype html>" if url.endswith(".php") else "no answer"
    def not_css(self):
        return list(self.html)
    html = []
fields = ("site", "https", "443", "/", "", "", "", "", "", "", "0", "")
good = Fake([])
webshot.take(good, "fd00::1", sys.argv[2], 1, fields)
print("styled page: %d shot" % len(good.shots))
bad = Fake(["https://10.0.0.1/wp-admin/load-styles.php"])
try:
    webshot.take(bad, "fd00::1", sys.argv[2], 2, fields)
    print("unstyled page passed")
except OSError as e:
    print("unstyled page: %s (%d shot)" % (e, len(bad.shots)))
# Anubis's challenge as a stylesheet: Chromium keeps a sheet of 0 rules
# that it can read, as for an empty CSS file; only the type of the answer
# tells them apart (replica, BR2, 2026-11-07)
challenged = Fake([])
challenged.html = ["https://10.0.0.1/wp-admin/load-styles.php"]
try:
    webshot.take(challenged, "fd00::1", sys.argv[2], 3, fields)
    print("challenged page passed")
except OSError as e:
    print("challenged page: %s (%d shot)" % (e, len(challenged.shots)))
PY
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"styled page: 1 shot"* ]]
    # what the browser got for it is said too: the challenge of Anubis, a
    # PHP error and a 502 differ in the status, the type and the first bytes
    [[ "$output" == *"unstyled page: / has a stylesheet that did not load: https://10.0.0.1/wp-admin/load-styles.php (status 200, text/html, starts <!doctype html>) (1 shot)"* ]]
    [[ "$output" == *"challenged page: / has a stylesheet that did not load: https://10.0.0.1/wp-admin/load-styles.php (status 200, text/html, starts <!doctype html>) (1 shot)"* ]]
}

@test "webshot.py: a login whose field does not show fails, after its shot is written" {
    # The login page of Odoo 18 has its form in the page but hidden, and
    # blocks the click of its button, until a script that loads later shows
    # it. On a first view that script came late (its commit waited for the
    # standby): webshot found the field in the page, filled and clicked a
    # form that the page did not show, no login was made, and the run said
    # "the password field #password is still on the page" (odoo
    # cloud_simple, BR1 and BR2, release A3, 2026-11-10). A login is tried
    # only when the page shows the field; the picture of the page without it
    # stays as the evidence.
    run python3 -I - "${CONTRACT_PY%/*}/webshot.py" "$TMP" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("webshot", sys.argv[1])
webshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(webshot)
webshot.time.sleep = lambda s: None
os.environ["KC_SECRET_app"] = "s3cret"
class Fake:
    wait = 30
    def __init__(self, comes):
        self.comes, self.shots, self.logins = comes, [], 0
    def open(self, url):
        pass
    def wait_for(self, selector):
        return self.comes
    def evaluate(self, expression):
        return [] if "stylesheet" in expression else False
    def not_css(self):
        return []
    def shot(self, path):
        self.shots.append(os.path.basename(path))
    def login(self, *args):
        self.logins += 1
    def status(self):
        return 200
fields = ("odoo", "https", "443", "/web/login", "/odoo", "#login", "admin", "#password",
          "app", "button[type=submit]", "0", "")
shown = Fake(True)
webshot.take(shown, "fd00::1", sys.argv[2], 1, fields)
print("shown: %d login, %s" % (shown.logins, " ".join(shown.shots)))
hidden = Fake(False)
try:
    webshot.take(hidden, "fd00::1", sys.argv[2], 2, fields)
    print("hidden passed")
except OSError as e:
    print("hidden: %s (%d login, %s)" % (e, hidden.logins, " ".join(hidden.shots)))
PY
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"shown: 1 login, web-01-odoo.png web-01-odoo-after.png"* ]]
    [[ "$output" == *"hidden: the field #login did not show in 30 s, so the login was not tried (0 login, web-02-odoo.png)"* ]]
}

@test "webshot.py: the shot of a page with a text waits until the page shows it" {
    # Webmin's dashboard on a VM of BR2 came later than the page stayed
    # still: the after-login shot showed the menu only (2026-11-06). A shot
    # whose text is given is taken once the page shows that text.
    run python3 -I - "${CONTRACT_PY%/*}/webshot.py" "$TMP" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("webshot", sys.argv[1])
webshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(webshot)
clock = [0.0]
webshot.time.time = lambda: clock[0]
def sleep(s):
    clock[0] += s
webshot.time.sleep = sleep
class Fake:
    wait = 30
    def __init__(self):
        self.asked = 0
        self.shots = []
    def open(self, url):
        pass
    def wait_for(self, selector):
        return True
    def login(self, *args):
        pass
    def status(self):
        return 200
    def evaluate(self, expression):
        if "innerText.includes" in expression:
            self.asked += 1
            return self.asked >= 4
        return False
    def shot(self, path):
        self.shots.append((path, self.asked))
    def not_css(self):
        return []
os.environ["KC_SECRET_root"] = "x"
browser = Fake()
browser.wait_text = webshot.Browser.wait_text.__get__(browser)
fields = ("webmin", "https", "12321", "/", "", "#u", "root", "#p", "root", "#s", "0", "System hostname")
webshot.take(browser, "fd00::1", sys.argv[2], 1, fields)
print("asked before the after shot: %d" % browser.shots[-1][1])
PY
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"asked before the after shot: 4"* ]]
}

@test "webshot.py: a page is still until it asks for nothing more" {
    # Webmin's dashboard comes by requests after the document has loaded:
    # the after-login shot of a loaded host showed the menu and no
    # dashboard (web, BR1 lxc-preseed, and core, BR2 vm-iso, 2026-11-06)
    run python3 -I - "${CONTRACT_PY%/*}/webshot.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("webshot", sys.argv[1])
webshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(webshot)
clock = [0.0]
webshot.time.time = lambda: clock[0]
def sleep(s):
    clock[0] += s
webshot.time.sleep = sleep
browser = webshot.Browser.__new__(webshot.Browser)
browser.wait = 30
counts = iter([3, 5, 9, 12, 12, 12, 12, 12])
asked = []
def evaluate(expression):
    asked.append(expression)
    if "readyState" in expression:
        return "complete"
    return next(counts)
browser.evaluate = evaluate
browser.settle()
print("requests asked %d" % sum("resource" in a for a in asked))
print("clock %.1f" % clock[0])
PY
    echo "$output"
    [ "$status" -eq 0 ]
    # it asked until the count stayed the same twice, and no more
    [[ "$output" == *"requests asked 6"* ]]
}

@test "cloud: a node's answer replaces the question of the same id" {
    # an app contract asks the Mode screen as a question, Simple by Enter, for
    # its single node passes; the node of a cloud mode answers the same
    # screen with its hotkey. The question came first in the expect script,
    # so a cloud node chose Simple (keel-core, 2026-11-06).
    cloud_contract
    sed -i "/^questions:/a\\  - {id: mode, hook: 75keel-role, prompt: Installation mode, type: choice, answer: '{ret}'}" "$TMP/c.yaml"
    good_machine
    answering_expect
    printf '#!/bin/bash\nexec bash -c "$*"\n' > "$FAKES/pve2"
    chmod +x "$FAKES/pve2"
    export KC_PVE_BR2="$FAKES/pve2" KC_BOOT_TIMEOUT=30
    printf 'KC_HINT\nKC_SEEN mode\nKC_INVITE keel1:SECRETTOKEN\nKC_VIP fd00::ffff:1\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9001"
    printf 'KC_HINT\nKC_SEEN mode\nKC_SEEN join\nKC_SEEN vip\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9002"
    printf 'vip fd00::ffff:1: holder\n3 voter(s)\n' > "$STATE/keel.9001"
    printf 'vip fd00::ffff:1: follower\n' > "$STATE/keel.9002"
    run_cloud
    echo "$output"
    # node one answers the screen with its own keys, and only with them
    grep '^set node_answers' "$TMP/console.9001.exp" | grep -qF '"\033\[B\r"'
    grep -qF -- '-ex {Installation mode} { node_answer {Installation mode}; exp_continue }' "$TMP/console.9001.exp"
    [ "$(grep -cF -- '-ex {Installation mode}' "$TMP/console.9001.exp")" -eq 1 ]
    # node two has no answer of that id: the question stays
    grep -qF -- '-ex {Installation mode} { step; set launched 1; settle; sleep 1; puts "\nKC_SEEN mode"; choose "\r"; exp_continue }' "$TMP/console.9002.exp"
}

@test "cloud: a node with screenshots of its own takes them in place of the contract's" {
    cloud_contract
    sed -i "/keys: '{vip}{ret}'/a\\    screenshots: [{name: notice, url: /wp-login.php, text: This node is the replica}]" "$TMP/c.yaml"
    printf 'screenshots:\n  - {name: site, url: /}\n' >> "$TMP/c.yaml"
    run python3 -I "$CONTRACT_PY" tsv "$TMP/c.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'shot\tsite\thttps\t443\t/\t\t\t\t\t\t\t0\t'* ]]
    [[ "$output" == *$'nshot\ttwo\tnotice\thttps\t443\t/wp-login.php\t\t\t\t\t\t\t0\tThis node is the replica'* ]]
    echo 2001:db8::5 > "$STATE/ip-6"
    printf 'KC_HINT\nKC_SEEN mode\nKC_INVITE keel1:SECRETTOKEN\nKC_VIP fd00::ffff:1\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9001"
    printf 'KC_HINT\nKC_SEEN join\nKC_SEEN vip\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9002"
    printf 'vip fd00::ffff:1: holder\n3 voter(s)\n' > "$STATE/keel.9001"
    printf 'vip fd00::ffff:1: follower\n' > "$STATE/keel.9002"
    run_cloud
    echo "$output"
    [ -e "$OUT/cloud_simple/one/screens/web-01-site.png" ]
    [ ! -e "$OUT/cloud_simple/one/screens/web-01-notice.png" ]
    [ -e "$OUT/cloud_simple/two/screens/web-01-notice.png" ]
    [ ! -e "$OUT/cloud_simple/two/screens/web-01-site.png" ]
}

@test "cloud: a node with urls and proofs of its own takes them in place of the contract's" {
    # the replica of a Nextcloud pair is closed by design: its site answers
    # 503 and no login over HTTP works there (keel-nextcloud, 2026-11-12)
    cloud_contract
    sed -i "/keys: '{vip}{ret}'/a\\    urls: [{url: 'https://127.0.0.1/', status: 503}]\\n    proofs: [{secret: root, kind: shadow, user: root}, {secret: db, kind: command, run: 'test -n \"\$SECRET\"'}]" "$TMP/c.yaml"
    run python3 -I "$CONTRACT_PY" tsv "$TMP/c.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\nurl\thttps://127.0.0.1/\t200\n'* ]]
    [[ "$output" == *$'\nnurl\ttwo\thttps://127.0.0.1/\t503\n'* ]]
    [[ "$output" == *$'\nnproof\ttwo\tdb\tcommand\ttest -n "$SECRET"\t\t'* ]]
    good_machine
    answering_expect
    printf 'https://127.0.0.1/ 503\n' > "$STATE/urls.9002"
    printf '#!/bin/bash\nexec bash -c "$*"\n' > "$FAKES/pve2"
    chmod +x "$FAKES/pve2"
    export KC_PVE_BR2="$FAKES/pve2" KC_BOOT_TIMEOUT=30
    printf 'KC_HINT\nKC_SEEN mode\nKC_INVITE keel1:SECRETTOKEN\nKC_VIP fd00::ffff:1\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9001"
    printf 'KC_HINT\nKC_SEEN join\nKC_SEEN vip\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9002"
    printf 'vip fd00::ffff:1: holder\n3 voter(s)\n' > "$STATE/keel.9001"
    printf 'vip fd00::ffff:1: follower\n' > "$STATE/keel.9002"
    run_cloud
    echo "$output"
    for want in "pass  one:url.https://127.0.0.1/" "pass  two:url.https://127.0.0.1/" \
        "pass  one:proof.db.mysql" "pass  two:proof.db.command" \
        "pass  one:proof.root.shadow" "pass  two:proof.root.shadow"; do
        [[ "$output" == *"$want"* ]] || { echo "missing: $want"; return 1; }
    done
    grep -qx $'pass\turl.https://127.0.0.1/\t503' "$OUT/cloud_simple/two/record.tsv"
    grep -qx $'pass\turl.https://127.0.0.1/\t200' "$OUT/cloud_simple/one/record.tsv"
    # the node's own lines replace the contract's, they do not add to them
    [ "$(grep -c 'proof.db.mysql' "$OUT/cloud_simple/two/record.tsv")" -eq 0 ]
    [ "$(grep -c 'proof.db.command' "$OUT/cloud_simple/one/record.tsv")" -eq 0 ]
    [ "$(grep -c $'\turl\\.' "$OUT/cloud_simple/two/record.tsv")" -eq 1 ]
}

@test "the urls and proofs of a node are checked as the contract's are" {
    cloud_contract
    cat >> "$TMP/c.yaml" <<'EOF'
  - name: three
    site: br1
    mode: cloud_advanced
    role: primary
    urls: {}
    proofs: [{secret: root, kind: shadow, user: root}, {secret: nope, kind: shadow, user: x}]
  - name: four
    site: br2
    mode: cloud_advanced
    role: replica
    urls: [{url: 'ftp://x/', status: 99}]
    proofs: {}
  - name: five
    site: br1
    mode: cloud_advanced
    role: witness
    contract: core.yaml
    urls: [{url: 'https://127.0.0.1/', status: 200}]
EOF
    printf 'contract: 1\nappliance: core\nsecrets: [root]\nquestions: [{id: r, hook: 30rootpass, prompt: R, answer: "secret:root"}]\nproofs: [{secret: root, kind: shadow, user: root}]\n' > "$TMP/core.yaml"
    run "$KC" --check "$TMP/c.yaml"
    echo "$output"
    [ "$status" -eq 2 ]
    for want in "node three: urls is not a list" "node three: proof of 'nope': not a declared secret" \
        "node three: secret db has no proof" "node four: url 'ftp://x/' is not an http or https URL" \
        "node four: url ftp://x/: status 99 is not an HTTP status" "node four: proofs is not a list" \
        "node five: urls and proofs are for a node of this appliance: core.yaml has its own"; do
        [[ "$output" == *"$want"* ]] || { echo "missing: $want"; return 1; }
    done
}

@test "the text of a screenshot is a usable line" {
    small_contract
    printf 'screenshots:\n  - {name: a, url: /, text: "a\\tb"}\n  - {name: b, url: /, text: [1]}\n' >> "$TMP/c.yaml"
    run "$KC" --check "$TMP/c.yaml"
    [ "$status" -eq 2 ]
    [[ "$output" == *"screenshot a: text 'a\tb' is not usable"* ]]
    [[ "$output" == *"screenshot b: text [1] is not usable"* ]]
    printf 'nodes:\n  - {name: p, site: br1, mode: simple, screenshots: {}}\n' >> "$TMP/c.yaml"
    run "$KC" --check "$TMP/c.yaml"
    [[ "$output" == *"node p: screenshots is not a list"* ]]
}

# the Keel Core witness of a cloud advanced set: a node of another
# appliance, with that appliance's contract (decision 0076)
witness_contract() {
    cat > "$TMP/core.yaml" <<'EOF'
contract: 1
appliance: core
secrets: [root]
questions:
  - {id: root_password, hook: 30rootpass, prompt: Root Password, answer: secret:root}
  - {id: email, hook: 85secalerts, prompt: Email, answer: admin@example.invalid}
proofs:
  - {secret: root, kind: shadow, user: root}
services: [crowdsec]
screenshots:
  - {name: webmin, port: 12321, url: /}
EOF
    cat >> "$TMP/c.yaml" <<'EOF'
  - name: four
    site: br1
    mode: cloud_advanced
    role: primary
  - name: five
    site: br2
    mode: cloud_advanced
    role: replica
    answers:
      - {id: join, prompt: Join a mesh, keys: '{invite:1}{ret}'}
  - name: three
    site: br1
    mode: cloud_advanced
    role: witness
    image: local:vztmpl/core.tar.zst
    contract: core.yaml
    answers:
      - {id: join, prompt: Join a mesh, keys: '{invite:2}{ret}'}
EOF
}

@test "cloud: a node names the contract of its own appliance, the Keel Core witness" {
    cloud_contract
    witness_contract
    run python3 -I "$CONTRACT_PY" tsv "$TMP/c.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'node\tthree\tbr1\tlxc\tlocal:vztmpl/core.tar.zst\tcloud_advanced\twitness\t'"$(realpath "$TMP/core.yaml")"* ]]
    [[ "$output" == *$'node\tone\tbr1\tlxc\t-\tcloud_simple\tprimary\t-'* ]]
    # the witness's own lines: its questions, not the app's
    KC_LIB="$LIB" KC_NODE=three KC_TSV="$output" run bash -c '. "$KC_LIB/nodes.sh"; node_tsv "$0"' "$(realpath "$TMP/core.yaml")"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'appliance\tcore'* ]]
    [[ "$output" == *$'service\tcrowdsec'* || "$output" == *crowdsec* ]]
    [[ "$output" != *"MariaDB password"* ]]
    [[ "$output" == *$'answer\tthree\tjoin\tJoin a mesh\t{invite:2}{ret}'* ]]
    [[ "$output" == *$'capture\tinvite\t'* ]]
    [[ "$output" == *$'wait\tWaiting for the nodes'* ]]
    [[ "$output" != *$'node\t'* ]]
}

@test "cloud: the witness of a cloud advanced pass takes its own contract and image" {
    cloud_contract
    witness_contract
    answering_expect
    good_machine
    printf 'nginx\ncrowdsec\n' > "$STATE/active"
    printf 'KC_HINT\nKC_SEEN mode\nKC_INVITE keel1:FIRSTINVITE\nKC_INVITE keel1:SECONDINVITE\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9001"
    printf 'KC_HINT\nKC_SEEN join\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9002"
    printf 'KC_HINT\nKC_SEEN join\nKC_SEEN root_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9003"
    run "$KC" --contract "$TMP/c.yaml" --template local:vztmpl/t.tar.zst \
        --vmid 9001 --pass cloud_advanced --site br1 --out "$OUT"
    echo "$output"
    [[ "$output" == *"pass  three:keel-init.asked.join"* ]]
    [[ "$output" == *"pass  three:service.crowdsec"* ]]
    [[ "$output" != *"three:keel-init.asked.db_password"* ]]
    [[ "$output" != *"three:proof.db"* ]]
    # the witness is made from its own image, and its console has its own questions
    grep -q 'pct create 9003 local:vztmpl/core.tar.zst' "$LOG"
    run ! grep -q 'MariaDB password' "$TMP/console.9003.exp"
    grep -q 'SECONDINVITE' "$TMP/console.9003.exp"
    # the witness is another appliance: its image is recorded, and it does
    # not count for the sha256 of this appliance's pass
    grep -qx $'own\tno' "$OUT/cloud_advanced/three/meta"
    grep -qx $'image\tlocal:vztmpl/core.tar.zst' "$OUT/cloud_advanced/three/meta"
    grep -qx $'own\tyes' "$OUT/cloud_advanced/four/meta"
}

@test "cloud: the contract a node names is checked" {
    cloud_contract
    witness_contract
    # keel-core's contract has nodes of its own, for its own cloud passes:
    # they are checked, and the contract one of them names is not read
    printf 'nodes:\n  - {name: x, site: br1, mode: simple, contract: never-read.yaml}\n  - {name: Bad, site: br1, mode: simple}\n' >> "$TMP/core.yaml"
    sed -i 's/^secrets: \[root\]$/secrets: [root, other]/' "$TMP/core.yaml"
    printf '  - {name: six, site: br2, mode: simple, contract: nope.yaml}\n  - {name: seven, site: br2, mode: simple, contract: "a b"}\n' >> "$TMP/c.yaml"
    run "$KC" --check "$TMP/c.yaml"
    [ "$status" -eq 2 ]
    [[ "$output" != *"never-read.yaml"* ]]
    [[ "$output" != *"has nodes of its own"* ]]
    for want in "node three: core.yaml: node name 'Bad' is not a lower case name" \
        "node three: contract core.yaml has secrets this one does not declare: other" \
        "node six: contract nope.yaml is not a file" "node seven: contract 'a b' is not a file name"; do
        [[ "$output" == *"$want"* ]] || { echo "missing: $want"; return 1; }
    done
}

@test "cloud: the witness image comes from KC_IMAGE_<NODE>, and a witness without one stops" {
    cloud_contract
    witness_contract
    sed -i '/image: local:vztmpl\/core.tar.zst/d' "$TMP/c.yaml"
    good_machine
    run "$KC" --contract "$TMP/c.yaml" --template local:vztmpl/t.tar.zst \
        --vmid 9001 --pass cloud_advanced --site br1 --out "$OUT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"node three has the contract of another appliance and no image: set KC_IMAGE_THREE"* ]]
    run ! grep -q 'pct create' "$LOG"
    # the variable names a node with "-" in its name with "_"
    KC_LIB="$LIB" KC_IMAGE_ADV_WITNESS=local:vztmpl/w.tar.zst run bash -c \
        '. "$KC_LIB/nodes.sh"; KC_IMAGE=-; node_image adv-witness; echo "$KC_IMAGE"'
    [ "$output" = local:vztmpl/w.tar.zst ]
    answering_expect
    printf 'nginx\ncrowdsec\n' > "$STATE/active"
    printf 'KC_HINT\nKC_SEEN mode\nKC_INVITE keel1:FIRSTINVITE\nKC_INVITE keel1:SECONDINVITE\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9001"
    printf 'KC_HINT\nKC_SEEN join\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9002"
    printf 'KC_HINT\nKC_SEEN join\nKC_SEEN root_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9003"
    KC_IMAGE_THREE=local:vztmpl/core-new.tar.zst run "$KC" --contract "$TMP/c.yaml" \
        --template local:vztmpl/t.tar.zst --vmid 9001 --pass cloud_advanced --site br1 --out "$OUT"
    echo "$output"
    grep -q 'pct create 9003 local:vztmpl/core-new.tar.zst' "$LOG"
    grep -q 'pct create 9001 local:vztmpl/t.tar.zst' "$LOG"
}

@test "cloud: a check runs only in the modes it names" {
    cloud_contract
    witness_contract
    python3 - "$TMP/c.yaml" <<'PY2'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("  checks:\n", "  checks:\n"
    "    - {id: witness-only, at: witness, run: 'keel witness', modes: [cloud_advanced]}\n"
    "    - {id: seeded, at: 'primary,replica', run: 'keel seed', same: true, modes: [cloud_advanced]}\n"
    "    - {id: peers, at: all, run: 'keel peers', match: 'peers: 1', modes: [cloud_simple]}\n"
    "    - {id: peers, at: all, run: 'keel peers', match: 'peers: 2', modes: [cloud_advanced]}\n", 1)
open(p, "w").write(s)
PY2
    run python3 -I "$CONTRACT_PY" tsv "$TMP/c.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'cross\twitness-only\twitness\tkeel witness\t-\t-\t-\t-\tcloud_advanced'* ]]
    [[ "$output" == *$'cross\tpeers\tall\tkeel peers\tpeers: 1\t-\t-\t-\tcloud_simple'* ]]
    # a check with no modes is for every mode: the old contracts stay valid
    [[ "$output" == *$'cross\tholder\tall\tkeel vip status\tholder\t1\t-\t-\t-'* ]]
    good_machine
    answering_expect
    printf 'KC_HINT\nKC_SEEN mode\nKC_INVITE keel1:SECRETTOKEN\nKC_VIP fd00::ffff:1\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9001"
    printf 'KC_HINT\nKC_SEEN join\nKC_SEEN vip\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9002"
    cat > "$GBIN/keel" <<'SH'
#!/bin/bash
case "$1" in
    peers) echo "peers: 1" ;;
    *) cat "$STATE/keel.$KC_FAKE_VMID" 2>/dev/null ;;
esac
SH
    chmod +x "$GBIN/keel"
    printf 'vip fd00::ffff:1: holder\n3 voter(s)\n' > "$STATE/keel.9001"
    run_cloud
    echo "$output"
    [[ "$output" == *"pass  cross.peers                              2 of 2 nodes (all)"* ]]
    [[ "$output" == *"pass  cross.holder"* ]]
    # the checks of cloud advanced, a same check too, are not run on a pair
    [[ "$output" != *"cross.witness-only"* ]]
    [[ "$output" != *"cross.seeded"* ]]
    [ "$(grep -c 'cross.peers' "$OUT/cloud_simple/record.tsv")" -eq 1 ]
}

@test "cloud: the modes of a check say what is wrong" {
    cloud_contract
    python3 - "$TMP/c.yaml" <<'PY2'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("  checks:\n", "  checks:\n"
    "    - {id: m1, at: all, run: 'true', modes: [simple]}\n"
    "    - {id: m2, at: all, run: 'true', modes: cloud_simple}\n"
    "    - {id: m3, at: all, run: 'true', modes: [cloud_advanced]}\n"
    "    - {id: m3, at: all, run: 'true', modes: [cloud_advanced]}\n"
    "    - {id: holder, at: all, run: 'true', modes: [cloud_simple]}\n", 1)
open(p, "w").write(s)
PY2
    run "$KC" --check "$TMP/c.yaml"
    [ "$status" -eq 2 ]
    for want in "cloud check m1: modes ['simple'] is not a list of cloud_advanced, cloud_simple" \
        "cloud check m2: modes 'cloud_simple' is not a list of cloud_advanced, cloud_simple" \
        "cloud check m3 is declared twice for cloud_advanced" \
        "cloud check holder is declared twice for cloud_simple"; do
        [[ "$output" == *"$want"* ]] || { echo "missing: $want"; return 1; }
    done
    [[ "$output" != *"cloud check holder is declared twice for cloud_advanced"* ]]
}

@test "cloud: a check that wants the same output on several nodes" {
    cloud_contract
    cat >> "$TMP/c.yaml" <<'EOF'
  - name: zz
    site: br1
    mode: simple
EOF
    python3 - "$TMP/c.yaml" <<'PY2'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("  checks:\n", "  checks:\n    - {id: seeded, at: 'primary,replica', run: 'keel seed', same: true}\n    - {id: differs, at: 'one,two', run: 'keel node', same: true}\n    - {id: empty, at: all, run: 'keel none', same: true}\n", 1)
open(p, "w").write(s)
PY2
    run python3 -I "$CONTRACT_PY" tsv "$TMP/c.yaml"
    [[ "$output" == *$'cross\tseeded\tprimary,replica\tkeel seed\t-\t-\t-\tsame\t-'* ]]
    [[ "$output" == *$'cross\tholder\tall\tkeel vip status\tholder\t1\t-\t-\t-'* ]]
    printf 'KC_HINT\nKC_SEEN mode\nKC_INVITE keel1:SECRETTOKEN\nKC_VIP fd00::ffff:1\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9001"
    printf 'KC_HINT\nKC_SEEN join\nKC_SEEN vip\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9002"
    # keel of the guest: "seed" the same on both, "node" its own vmid, "none" nothing
    cat > "$GBIN/keel" <<'EOF'
#!/bin/bash
case "$1" in
    seed) printf 'kc9001-boot-row\nsecond line\n' ;;
    node) echo "kc$KC_FAKE_VMID" ;;
    none) exit 0 ;;
    *) cat "$STATE/keel.$KC_FAKE_VMID" 2>/dev/null ;;
esac
EOF
    chmod +x "$GBIN/keel"
    printf 'vip fd00::ffff:1: holder\n3 voter(s)\n' > "$STATE/keel.9001"
    run_cloud
    echo "$output"
    [[ "$output" == *"pass  cross.seeded                             the same output on 2 nodes (primary,replica)"* ]]
    [[ "$output" == *"fail  cross.differs                            the output differs on the 2 nodes (one,two): kc9001 | kc9002"* ]]
    [[ "$output" == *"fail  cross.empty                              2 of 2 nodes (all) gave no output"* ]]
    # a list in at takes roles and node names
    run "$KC" --check "$TMP/c.yaml"
    [ "$status" -eq 0 ]
    sed -i "s/at: 'primary,replica'/at: 'primary,Bad'/; s/same: true}/same: yes-please}/" "$TMP/c.yaml"
    run "$KC" --check "$TMP/c.yaml"
    [ "$status" -eq 2 ]
    [[ "$output" == *"cloud check seeded: at 'primary,Bad' is not a role, a node or all"* ]]
    [[ "$output" == *"cloud check seeded: same 'yes-please' is not true or false"* ]]
}

@test "cloud: no invite in time, a check that fails, and a mode with no node" {
    cloud_contract
    good_machine
    export KC_BOOT_TIMEOUT=2 KC_POLL=0
    printf 'KC_HINT\nKC_DONE\n' > "$STATE/screen"
    printf 'vip x: holder\n' > "$STATE/keel.9001"
    printf 'vip x: holder\n' > "$STATE/keel.9002"
    run_cloud --keep
    [ "$status" -eq 1 ]
    [[ "$output" == *"fail  two:started"* ]]
    # two VIP holders, and no voters on the primary
    [[ "$output" == *"fail  cross.holder                             2 of 2 nodes (all), wants 1"* ]]
    [[ "$output" == *"fail  cross.voters                             0 of 1 nodes (primary), wants 1"* ]]
    # what each node that failed said, and its failed units, follow the
    # fail (release A, 2026-11-09: no-failed-units said only "0 of 2")
    [[ "$output" == *"note  cross.voters                             one said: vip x: holder; failed units: none"* ]]
    [[ "$output" == *"note  cross.holder                             one said: vip x: holder; failed units: none"* ]]
    grep -qx $'note\tcross.voters\tone said: vip x: holder; failed units: none' "$OUT/cloud_simple/record.tsv"
    run grep -c 'pct destroy' "$LOG"
    [ "$output" = 0 ]
    run "$KC" --contract "$TMP/c.yaml" --template local:vztmpl/t.tar.zst \
        --vmid 9001 --pass cloud_advanced --site br1 --out "$OUT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"no node of mode cloud_advanced"* ]]
}

@test "cloud: a check that fails names the failed units of each node that failed it" {
    cloud_contract
    good_machine
    sed -i "s/^    - {id: voters.*/&\n    - {id: no-failed-units, at: all, run: 'systemctl --failed --no-legend --plain | wc -l', match: '^0\$'}/" "$TMP/c.yaml"
    export KC_BOOT_TIMEOUT=2 KC_POLL=0
    printf 'KC_HINT\nKC_DONE\n' > "$STATE/screen"
    printf 'vip x: holder\n' > "$STATE/keel.9001"
    printf 'keel-database-dump.service loaded failed failed keel database: the dump on the standby\n' > "$STATE/failed-units"
    run_cloud
    echo "$output"
    [[ "$output" == *"fail  cross.no-failed-units                    0 of 2 nodes (all), wants 2"* ]]
    [[ "$output" == *"note  cross.no-failed-units                    one said: 1; failed units: keel-database-dump.service"* ]]
    [[ "$output" == *"note  cross.no-failed-units                    two said: 1; failed units: keel-database-dump.service"* ]]
    # a note is no failed check of its own
    [[ "$output" == *"FAIL, 4 checks failed"* ]] || [[ "$output" == *"checks failed"* ]]
    [ "$(grep -c $'^fail\tcross.no-failed-units' "$OUT/cloud_simple/record.tsv")" -eq 1 ]
}

@test "cloud: a node vmid in use is never touched, and a VM node" {
    cloud_contract
    good_machine
    touch "$STATE/exists"
    run_cloud
    [ "$status" -eq 4 ]
    [[ "$output" == *"vmid 9001 of one is in use"* ]]
    rm "$STATE/exists"
    sed -i 's/^    role: replica/    role: replica\n    kind: vm\n    image: local:iso\/n.iso/' "$TMP/c.yaml"
    sed -i 's/^      - {id: join.*//; s/^      - {id: vip.*//' "$TMP/c.yaml"
    touch "$STATE/start-fails"
    run_cloud
    [ "$status" -eq 1 ]
    grep -q "qm create 9002 .*--ide2 'local:iso/n.iso'" "$LOG"
    # a VM node names its CPU type in its own meta
    grep -qx $'cpu\tkvm64' "$OUT/cloud_simple/two/meta"
    grep -q 'qm destroy 9002' "$LOG"
}

# ---- webshot.py and a real browser -----------------------------------------

@test "webshot: usage, and no browser" {
    run python3 -I "$LIB/webshot.py"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage"* ]]
    run env PATH=/nonexistent KC_CHROMIUM= /usr/bin/python3 -I "$LIB/webshot.py" ::1 "$TMP/w" 1
    [ "$status" -eq 2 ]
    [[ "$output" == *"no chromium"* ]]
}

@test "webshot: a page, and a login with the secret, in headless Chromium" {
    command -v chromium >/dev/null || skip "no chromium on this host"
    port=$((20000 + RANDOM % 20000))
    python3 -I "$BATS_TEST_DIRNAME/fixtures/commission/loginsrv.py" "$port" &
    server=$!
    sleep 1
    # app: the login form comes after a challenge page, as behind Anubis
    printf 'shot\tapp\thttp\t%s\t/challenge\t/admin\t#u\tadmin\t#p\tapp\t#go\t0\nshot\tfront\thttp\t%s\t/x\t\t\t\t\t\t\t0\nshot\tbad\thttp\t%s\t/\t\t#nofield\tadmin\t#p\tapp\t#go\t0\n' \
        "$port" "$port" "$port" > "$TMP/shots"
    KC_WEB_WAIT=8 KC_SECRET_app=s3cret run python3 -I "$LIB/webshot.py" 127.0.0.1 "$TMP/w" 1 < "$TMP/shots"
    kill "$server"
    [ "$status" -eq 1 ]
    [[ "$output" == *$'01\tweb-app-after\tweb-01-app-after.png\tafter the login: /admin'* ]]
    [[ "$output" == *$'02\tweb-front\tweb-02-front.png\topen /x'* ]]
    [[ "$output" == *"webshot: bad: the field #nofield did not show in 8 s, so the login was not tried"* ]]
    [[ "$output" != *s3cret* ]]
    [ "$(head -c 8 "$TMP/w/web-01-app-after.png" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ]
}

@test "webshot: the text a page must show, in headless Chromium" {
    command -v chromium >/dev/null || skip "no chromium on this host"
    port=$((20000 + RANDOM % 20000))
    python3 -I "$BATS_TEST_DIRNAME/fixtures/commission/loginsrv.py" "$port" &
    server=$!
    sleep 1
    printf 'shot\tyes\thttp\t%s\t/\t\t\t\t\t\t\t0\tLogin\nshot\tno\thttp\t%s\t/\t\t\t\t\t\t\t0\tThis node is the replica\nshot\tafter\thttp\t%s\t/challenge\t/admin\t#u\tadmin\t#p\tapp\t#go\t0\tDashboard\n' \
        "$port" "$port" "$port" > "$TMP/shots"
    KC_SECRET_app=s3cret run python3 -I "$LIB/webshot.py" 127.0.0.1 "$TMP/w" 1 < "$TMP/shots"
    kill "$server"
    [ "$status" -eq 1 ]
    [[ "$output" == *$'01\tweb-yes\tweb-01-yes.png\topen /'* ]]
    [[ "$output" == *"webshot: no: / does not show 'This node is the replica'"* ]]
    [[ "$output" == *$'03\tweb-after-after\tweb-03-after-after.png\tafter the login: /admin'* ]]
    [[ "$output" != *"webshot: after"* ]]
    [[ "$output" != *"webshot: yes"* ]]
}

@test "webshot: a login form that shows late is waited for, and one that never shows fails" {
    command -v chromium >/dev/null || skip "no chromium on this host"
    port=$((20000 + RANDOM % 20000))
    python3 -I "$BATS_TEST_DIRNAME/fixtures/commission/loginsrv.py" "$port" &
    server=$!
    sleep 1
    # never: the form is in the page, hidden, and never shows
    # late: the page shows it after five seconds, and its submit does
    # nothing before, as the login page of Odoo 18
    printf 'shot\tnever\thttp\t%s\t/never\t/admin\t#u\tadmin\t#p\tapp\t#go\t0\nshot\tlate\thttp\t%s\t/late\t/admin\t#u\tadmin\t#p\tapp\t#go\t0\tDashboard\n' \
        "$port" "$port" > "$TMP/shots"
    KC_WEB_WAIT=8 KC_SECRET_app=s3cret run python3 -I "$LIB/webshot.py" 127.0.0.1 "$TMP/w" 1 < "$TMP/shots"
    kill "$server"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"webshot: never: the field #u did not show in 8 s, so the login was not tried"* ]]
    # the page without its form is still written, as evidence, and no login is tried
    [ -s "$TMP/w/web-01-never.png" ]
    [ ! -e "$TMP/w/web-01-never-after.png" ]
    [[ "$output" == *$'02\tweb-late-after\tweb-02-late-after.png\tafter the login: /admin'* ]]
    [[ "$output" != *"webshot: late"* ]]
}

@test "webshot: a login that ends on an error page, or on its form again, fails" {
    command -v chromium >/dev/null || skip "no chromium on this host"
    port=$((20000 + RANDOM % 20000))
    python3 -I "$BATS_TEST_DIRNAME/fixtures/commission/loginsrv.py" "$port" &
    server=$!
    sleep 1
    # wrong: a wrong password, and /admin answers 403, as Coraza did
    # again: no after page, and the login shows its form again
    printf 'shot\twrong\thttp\t%s\t/\t/admin\t#u\tadmin\t#p\tapp\t#go\t0\nshot\tagain\thttp\t%s\t/stay\t\t#u\tadmin\t#p\tapp\t#go\t0\n' \
        "$port" "$port" > "$TMP/shots"
    KC_SECRET_app=wrong run python3 -I "$LIB/webshot.py" 127.0.0.1 "$TMP/w" 1 < "$TMP/shots"
    kill "$server"
    [ "$status" -eq 1 ]
    [[ "$output" == *"webshot: wrong: after the login: /admin answered HTTP 403"* ]]
    [[ "$output" == *"webshot: again: after the login: the password field #p is still on the page"* ]]
    # the shots are still written, as evidence
    [ -s "$TMP/w/web-01-wrong-after.png" ]
    [ -s "$TMP/w/web-02-again-after.png" ]
}

# --- the alerts of a cloud pass (keel-ntfy, decision 0063) ---------------

# ntfy_env: a test topic and its two token files, and a fake curl that
# answers the topic from STATE/topic and logs its arguments
ntfy_env() {
    printf 'tk_PUBLISHSECRET123\n' > "$TMP/publish"
    printf 'Authorization: Bearer tk_READSECRET456\n' > "$TMP/read"
    chmod 600 "$TMP/publish" "$TMP/read"
    export KC_NTFY_URL=https://ntfy.test/kc-test KC_NTFY_TOKEN_FILE="$TMP/publish" \
        KC_NTFY_READ_FILE="$TMP/read" KC_CURL="$FAKES/curl" KC_ALERT_POLL=0
    cat > "$FAKES/curl" <<'SH'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$LOG"
cat "$STATE/topic" 2>/dev/null
SH
    chmod +x "$FAKES/curl"
    mkdir -p "$GUEST/etc/keel"
    printf 'version: 1\ninstallation:\n  mode: cloud_simple\n' > "$GUEST/etc/keel/instance.yaml"
}

alert_contract() {
    cloud_contract
    sed -i "/^    - {id: voters/a\\    - {id: fell-back, at: replica, run: 'echo stopped', alert: fell back to asynchronous, within: 90}" "$TMP/c.yaml"
}

cloud_screens() {
    printf 'KC_HINT\nKC_SEEN mode\nKC_INVITE keel1:SECRETTOKEN\nKC_VIP fd00::ffff:1\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9001"
    printf 'KC_HINT\nKC_SEEN join\nKC_SEEN vip\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9002"
    printf 'vip fd00::ffff:1: holder\n3 voter(s)\n' > "$STATE/keel.9001"
    printf 'vip fd00::ffff:1: follower\n' > "$STATE/keel.9002"
}

@test "contract: an alert check names the text of the alert and the seconds it waits" {
    alert_contract
    run python3 "$CONTRACT_PY" tsv "$TMP/c.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'cross\tfell-back\treplica\techo stopped\t-\t-\t-\t-\t-\tfell back to asynchronous\t90'* ]]
    sed -i 's/within: 90/within: 900/' "$TMP/c.yaml"
    run python3 "$CONTRACT_PY" tsv "$TMP/c.yaml"
    [ "$status" -ne 0 ]
    [[ "$output" == *"fell-back: within 900 is not 1 to 600 seconds"* ]]
}

@test "cloud: each node sends its alerts to a topic of the pass, and the token stays off every record" {
    alert_contract
    good_machine
    answering_expect
    ntfy_env
    printf '#!/bin/bash\nexec bash -c "$*"\n' > "$FAKES/pve2"
    chmod +x "$FAKES/pve2"
    export KC_PVE_BR2="$FAKES/pve2" KC_BOOT_TIMEOUT=30
    cloud_screens
    printf '{"event":"message","message":"[kc9001] the primary'"'"'s commits fell back to asynchronous"}\n' > "$STATE/topic"
    run_cloud
    echo "$output"
    [[ "$output" == *"pass  one:monitor.ntfy"* ]]
    [[ "$output" == *"pass  two:monitor.ntfy"* ]]
    [[ "$output" == *"pass  cross.fell-back"*"fell back to asynchronous"* ]]
    # the node's spec names the topic of this pass and the token file
    grep -q 'url: https://ntfy.test/kc-test-9001-' "$GUEST/etc/keel/instance.yaml"
    grep -q 'file: /etc/keel/secrets/kc_ntfy_token' "$GUEST/etc/keel/instance.yaml"
    grep -qx 'tk_PUBLISHSECRET123' "$GUEST/etc/keel/secrets/kc_ntfy_token"
    [ "$(stat -c %a "$GUEST/etc/keel/secrets")" = 700 ]
    [ "$(stat -c %a "$GUEST/etc/keel/secrets/kc_ntfy_token")" = 600 ]
    # the read header goes to curl as a file, never on its command line
    grep -q "curl .*-H @$TMP/read .*https://ntfy.test/kc-test-9001-[0-9]*/json?poll=1" "$LOG"
    run grep -rl -e PUBLISHSECRET -e READSECRET "$OUT" "$LOG"
    [ "$status" -ne 0 ]
}

@test "cloud: an alert that does not come within its seconds fails, and so does a pass with no topic" {
    alert_contract
    good_machine
    answering_expect
    ntfy_env
    printf '#!/bin/bash\nexec bash -c "$*"\n' > "$FAKES/pve2"
    chmod +x "$FAKES/pve2"
    export KC_PVE_BR2="$FAKES/pve2" KC_BOOT_TIMEOUT=30
    cloud_screens
    printf '{"event":"message","message":"the primary'"'"'s commits wait for the standby"}\n' > "$STATE/topic"
    sed -i 's/within: 90/within: 2/' "$TMP/c.yaml"
    run_cloud
    echo "$output"
    [[ "$output" == *"fail  cross.fell-back"*"no alert 'fell back to asynchronous' on the topic within 2 s"* ]]
    # with no header that may read the topic, the check fails at once: the
    # servers of decision 0063 let no one read without one
    rm -rf "$OUT"; : > "$LOG"
    unset KC_NTFY_READ_FILE
    run_cloud
    echo "$output"
    [[ "$output" == *"fail  cross.fell-back"*"KC_NTFY_READ_FILE is not set"* ]]
    run ! grep -q '^curl ' "$LOG"
    rm -rf "$OUT"
    unset KC_NTFY_URL
    run_cloud
    echo "$output"
    [[ "$output" == *"fail  cross.fell-back"*"KC_NTFY_URL is not set"* ]]
    [[ "$output" != *"monitor.ntfy"* ]]
}

@test "cloud: a token file that anybody but its owner reads is refused" {
    alert_contract
    ntfy_env
    chmod 644 "$TMP/publish"
    run_cloud
    [ "$status" -eq 2 ]
    [[ "$output" == *"KC_NTFY_TOKEN_FILE"*"mode 600"* ]]
}

@test "a node of a site is made with the nameserver of that site" {
    small_contract
    good_machine
    answering_expect
    export KC_NAMESERVER_BR2='2606:4700:4700::1111 2001:4860:4860::8888'
    run "$KC" --contract "$TMP/c.yaml" --template local:vztmpl/t.tar.zst --vmid 9001 \
        --pass lxc-interactive --site br2 --out "$OUT"
    grep -q "pct create 9001 .*--nameserver '2606:4700:4700::1111 2001:4860:4860::8888'" "$LOG"
    : > "$LOG"; rm -rf "$OUT" "$STATE/exists"
    run "$KC" --contract "$TMP/c.yaml" --template local:vztmpl/t.tar.zst --vmid 9001 \
        --pass lxc-interactive --site br1 --out "$OUT"
    grep -q 'pct create 9001' "$LOG"
    run ! grep -q -- '--nameserver' "$LOG"
    # a bad value of any site stops the pass before a machine is made: a
    # cloud pass has nodes on more than one site
    export KC_NAMESERVER_BR2='1.1.1.1; reboot'
    : > "$LOG"; rm -rf "$OUT" "$STATE/exists"
    run "$KC" --contract "$TMP/c.yaml" --template local:vztmpl/t.tar.zst --vmid 9001 \
        --pass lxc-interactive --site br1 --out "$OUT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"KC_NAMESERVER_BR2"*"is not a list of addresses"* ]]
    run ! grep -q 'pct create' "$LOG"
}

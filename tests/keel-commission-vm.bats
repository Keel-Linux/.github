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
        "installer screen id 'Bad'" "prompt 'a{b}' is not usable" "has characters no key types" \
        "{secret:nope} is not a declared secret" "vm.installer has no screen with last: true" \
        "a screenshot is not a mapping" "screenshot name 'Bad'" "scheme 'ftp'" "port 0 is not a port" \
        "url 'x' is not a path" "after 'y z' is not a path" "wait -1 is not 0 to 120" "login is not a mapping" \
        "login.password_field" "login.submit '' is missing" "login.secret 'nope'" "screenshot name 'two'" \
        "cloud.capture.invite: missing )" "cloud.capture.other is not invite or vip" \
        "cloud.capture.vip has a tab" "a cloud check is not a mapping" "cloud check id 'Bad'" \
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
    printf 'contract: 1\nappliance: x\nsecrets: [root]\nquestions: [{id: r, hook: 30rootpass, prompt: R, answer: "secret:root"}]\nproofs: [{secret: root, kind: shadow, user: root}]\nvm: {installer: []}\ncloud: {capture: [1], checks: {}}\n' > "$TMP/c.yaml"
    run "$KC" --check "$TMP/c.yaml"
    [ "$status" -eq 2 ]
    [[ "$output" == *"vm.installer is not a list of screens"* ]]
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
    # a choice gets its keys and nothing else: no emptied field, no Enter
    grep -qF -- '-ex {Is your email correct} { step; set launched 1; puts "\nKC_SEEN ok"; send -- "y"; exp_continue }' "$TMP/console.exp"
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
    printf 'KC_HINT\nKC_SEEN mode\nInvite a node\nKC_INVITE keel1:SECRETTOKEN\nKC_INVITE keel1:SECRETTOKEN\nKC_VIP fd00::ffff:1\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9001"
    printf 'KC_HINT\nkeel1:SECRETTOKEN pasted\nKC_SEEN join\nKC_SEEN vip\nKC_SEEN root_password\nKC_SEEN db_password\nKC_SEEN email\nKC_DONE\n' > "$STATE/screen.9002"
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
    # node two got the invite and the VIP of node one's screen, as keys
    grep -qF 'send -- "keel1:SECRETTOKEN\r"' "$TMP/console.9002.exp"
    grep -qF 'send -- "fd00::ffff:1\r"' "$TMP/console.9002.exp"
    grep -qF 'send -- "\033\[B\r"' "$TMP/console.9001.exp"
    grep -qF -- '-re {keel1:[A-Za-z0-9_-]+} { puts "\nKC_INVITE $expect_out(0,string)"; exp_continue }' "$TMP/console.9001.exp"
    grep -qF -- '-re {VIP (fd00:[0-9a-f:]+)} { puts "\nKC_VIP $expect_out(1,string)"; exp_continue }' "$TMP/console.9001.exp"
    # each site's own PVE host, the vmids one after the other
    grep -q '^pve2 pct create 9002 ' "$LOG"
    grep -q '^pve pct create 9001 ' "$LOG"
    grep -q '^pve2 pct stop 9002.*pct destroy 9002' "$LOG"
    # no file of the run keeps the invite
    [ -z "$(grep -rl SECRETTOKEN "$OUT")" ]
    grep -q '<invite 1> pasted' "$OUT/cloud_simple/two/console.txt"
    grep -qx $'01\tjoin\tscreens/01-join.txt\t(invite 1 of the first node)<ret>' "$OUT/cloud_simple/two/screens.tsv"
    grep -q '| Step | one, primary (br1) | two, replica (br2) |' "$OUT/guide.md"
    grep -qx $'result\tpass' "$OUT/cloud_simple/meta"
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
    run grep -c 'pct destroy' "$LOG"
    [ "$output" = 0 ]
    run "$KC" --contract "$TMP/c.yaml" --template local:vztmpl/t.tar.zst \
        --vmid 9001 --pass cloud_advanced --site br1 --out "$OUT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"no node of mode cloud_advanced"* ]]
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
    printf 'shot\tapp\thttp\t%s\t/\t/admin\t#u\tadmin\t#p\tapp\t#go\t0\nshot\tfront\thttp\t%s\t/x\t\t\t\t\t\t\t0\nshot\tbad\thttp\t%s\t/\t\t#nofield\tadmin\t#p\tapp\t#go\t0\n' \
        "$port" "$port" "$port" > "$TMP/shots"
    KC_SECRET_app=s3cret run python3 -I "$LIB/webshot.py" 127.0.0.1 "$TMP/w" 1 < "$TMP/shots"
    kill "$server"
    [ "$status" -eq 1 ]
    [[ "$output" == *$'01\tweb-app-after\tweb-01-app-after.png\tafter the login: /admin'* ]]
    [[ "$output" == *$'02\tweb-front\tweb-02-front.png\topen /x'* ]]
    [[ "$output" == *"webshot: bad: no field #nofield on the page"* ]]
    [[ "$output" != *s3cret* ]]
    [ "$(head -c 8 "$TMP/w/web-01-app-after.png" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ]
}

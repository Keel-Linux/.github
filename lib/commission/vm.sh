# shellcheck shell=bash
# The VM from the ISO (decision 0075, pass vm-iso): keel-commission makes a
# VM with qm as an operator does, boots the ISO, installs it, and answers
# the first boot of the disk on tty1.
#
# The screen is read as text through the QEMU guest agent of the ISO and of
# the installed system (qemu-guest-agent is in the boot layer), from
# /dev/vcs1: tkl-installer and inithooks both draw on tty1, and neither
# writes to a serial console (BR1, 2026-11-05). The agent only reads. Every
# answer goes in as keys through qm monitor (sendkey), and every screen the
# driver acts on is saved as a PNG from qm monitor screendump, with its text.
# Before the agent answers (the boot menu, the kernel, the reboot), a
# screenshot is kept each time the picture changes.

KC_VM_STORAGE="${KC_VM_STORAGE:-local-lvm}"
KC_VM_OPTS="${KC_VM_OPTS:-}"
KC_VM_FIRMWARE="${KC_VM_FIRMWARE:-auto}"
# the longest the install, or the first boot of the disk, may take
KC_PHASE_TIMEOUT="${KC_PHASE_TIMEOUT:-3600}"
# where the helpers and the screenshots of a VM wait on the PVE host
KC_HOST_TMP="${KC_HOST_TMP:-/tmp}"

# vm_value KEY: memory, cores or disk of the contract's vm section.
vm_value() {
    grep $'^vm\t'"$1"$'\t' <<< "$KC_TSV" | cut -f3
}

# vm_cpu: the CPU type of the contract's vm.cpu, empty when it names none.
# contract.py accepts only these names; the value goes into the qm create
# command line on the PVE host, so it is checked here again.
vm_cpu() {
    local cpu
    cpu=$(vm_value cpu)
    case "$cpu" in
        ""|kvm64|x86-64-v2|x86-64-v2-AES|x86-64-v3|host) printf '%s' "$cpu" ;;
        *)
            echo "keel-commission: vm.cpu '$cpu' is not kvm64, x86-64-v2, x86-64-v2-AES, x86-64-v3 or host" >&2
            return 1
            ;;
    esac
}

# vm_firmware VOLID: ovmf when the ISO boots by UEFI (it has /EFI), else
# seabios. A host without isoinfo gets seabios; KC_VM_FIRMWARE overrides.
vm_firmware() {
    if [ "$KC_VM_FIRMWARE" != auto ]; then
        echo "$KC_VM_FIRMWARE"
    elif pve "isoinfo -R -f -i \"\$(pvesm path '$1')\" 2>/dev/null | grep -qi '^/efi/'"; then
        echo ovmf
    else
        echo seabios
    fi
}

# vm_create VOLID: the VM as an operator makes it in the web interface:
# the ISO on a CD-ROM, a virtio disk on KC_VM_STORAGE, the guest agent on,
# the disk first in the boot order (an empty disk falls through to the
# CD-ROM). KC_VM_OPTS adds the site's network and other options. The
# contract's vm.cpu gives --cpu; with no vm.cpu the line has no --cpu, and
# the VM has kvm64. The helpers the driver runs on the host go to
# /tmp/kcVMID.
vm_create() {
    local bios="" firmware cpu
    cpu=$(vm_cpu) || return 1
    firmware=$(vm_firmware "$1")
    if [ "$firmware" = ovmf ]; then
        bios="--bios ovmf --machine q35 --efidisk0 $KC_VM_STORAGE:1,efitype=4m,pre-enrolled-keys=0"
    fi
    pve_retry "qm create $KC_VMID --name kc$KC_VMID --memory $(vm_value memory) --cores $(vm_value cores)${cpu:+ --cpu $cpu} --ostype l26 --scsihw virtio-scsi-single --virtio0 $KC_VM_STORAGE:$(vm_value disk) --ide2 '$1',media=cdrom --boot 'order=virtio0;ide2' --agent enabled=1 --vga std $bios $KC_VM_OPTS" || return 1
    pve "mkdir -p $KC_HOST_TMP/kc$KC_VMID && cat > $KC_HOST_TMP/kc$KC_VMID/ppm2png.py" < "$KC_LIB/ppm2png.py"
    pve "cat > $KC_HOST_TMP/kc$KC_VMID/qga.py" < "$KC_LIB/qga.py"
}

vm_start() {
    pve "qm start $KC_VMID"
}

# vm_destroy: remove the VM and the helpers, unless --keep was given.
vm_destroy() {
    [ "$KC_KEEP" = 1 ] && return 0
    pve "qm stop $KC_VMID >/dev/null 2>&1; qm destroy $KC_VMID --purge 1 >/dev/null 2>&1; rm -rf $KC_HOST_TMP/kc$KC_VMID; true"
}

# vm_guest_sh: guest_sh for a VM, through the guest agent.
vm_guest_sh() {
    pve "python3 $KC_HOST_TMP/kc$KC_VMID/qga.py exec $KC_VMID"
}

# vm_screen: the text of tty1, one line per row, trailing blanks and empty
# rows out. Fails when the agent does not answer.
vm_screen() {
    local text
    text=$(pve "python3 $KC_HOST_TMP/kc$KC_VMID/qga.py screen $KC_VMID" 2>/dev/null) || return 1
    sed -e 's/[[:space:]]*$//' <<< "$text" | grep -v '^$'
    return 0
}

# vm_keys KEYS: type KEYS (the key syntax of screens.py) on the VM. A
# secret goes from the environment to qm monitor's stdin, never to a
# command line.
vm_keys() {
    printf '%s' "$1" | python3 -I "$KC_LIB/contract.py" keys qm \
        | pve "qm monitor $KC_VMID >/dev/null 2>&1"
}

# vm_shot LABEL [TEXT]: the next numbered screenshot, KC_DIR/screens/NN-LABEL.png,
# with the text of the screen beside it when there is one. KC_NAME is the
# name of the PNG. It runs in this shell, not in a $( ), so the count goes on.
vm_shot() {
    local name
    KC_SHOT=$((KC_SHOT + 1))
    name=$(printf '%02d-%s' "$KC_SHOT" "$1")
    pve "python3 $KC_HOST_TMP/kc$KC_VMID/qga.py shot $KC_VMID $KC_HOST_TMP/kc$KC_VMID/s.png >/dev/null && cat $KC_HOST_TMP/kc$KC_VMID/s.png" \
        > "$KC_DIR/screens/$name.png" 2>/dev/null
    [ -z "${2:-}" ] || printf '%s\n' "$2" | mask_secrets > "$KC_DIR/screens/$name.txt"
    KC_NAME="$name.png"
}

# mask_secrets: stdin to stdout with each secret value of the run replaced
# by its name. A screen shows what a field echoes, and a key typed on the
# wrong screen echoes a secret: no text file of the run may keep it.
mask_secrets() {
    # a secret is letters and digits only (new_secret), safe in sed
    local name args=(-e "s/$KC_LOGIN_SECRET/<the login password>/g")
    for name in "${!KC_SECRETS[@]}"; do
        args+=(-e "s/${KC_SECRETS[$name]}/<the $name secret>/g")
    done
    sed "${args[@]}"
}

# screen_row FILE ANSWER: a row of the guide for this machine. ANSWER is
# in the key syntax and is masked here: a secret is named, never written.
screen_row() {
    local label="${1%.*}"
    printf '%s\t%s\t%s\t%s\n' "${label%%-*}" "${label#*-}" "screens/$1" \
        "$(printf '%s' "$2" | python3 -I "$KC_LIB/contract.py" mask)" >> "$KC_DIR/screens.tsv"
}

# vm_boot_frame: before the agent answers, keep a screenshot when the
# picture changed since the last one kept.
vm_boot_frame() {
    local sum
    vm_shot "$1"
    sum=$(sha256sum < "$KC_DIR/screens/$KC_NAME" | cut -d' ' -f1)
    if [ "$sum" = "${KC_LAST_FRAME:-}" ]; then
        rm -f "$KC_DIR/screens/$KC_NAME"
        KC_SHOT=$((KC_SHOT - 1))
        return 0
    fi
    KC_LAST_FRAME="$sum"
    screen_row "$KC_NAME" ""
}

# vm_match TABLE TEXT: the first line of TABLE ("ID<TAB>PROMPT<TAB>KEYS<TAB>FLAGS")
# whose prompt is on the screen.
vm_match() {
    local line rows prompt
    mapfile -t rows < "$1"
    for line in "${rows[@]}"; do
        prompt="${line#*$'\t'}"
        if grep -qF -- "${prompt%%$'\t'*}" <<< "$2"; then
            printf '%s\n' "$line"
            return 0
        fi
    done
    return 1
}

# vm_capture TEXT: the invite lines and the VIP on the screen, once each,
# as KC_INVITE and KC_VIP lines of the log.
vm_capture() {
    local row what value rows values regex
    mapfile -t rows < <(grep $'^capture\t' <<< "$KC_TSV" | cut -f2-)
    for row in "${rows[@]}"; do
        what="${row%%$'\t'*}"
        regex="${row#*$'\t'}"
        mapfile -t values < <(python3 -I "$KC_LIB/contract.py" capture "${regex%$'\t'*}" <<< "$1")
        for value in "${values[@]}"; do
            grep -qxF "KC_${what^^} $value" "$KC_LOG" 2>/dev/null || echo "KC_${what^^} $value" >> "$KC_LOG"
        done
    done
}

# vm_act LINE TEXT: answer the screen LINE of the table matched. A question
# (flag question) first comes as the menu Generate or Manual when it is a
# password: that gets m, Manual, as on a container's console. Its field is
# emptied before the answer, which may come with a value in it.
vm_act() {
    local id prompt keys flags
    IFS=$'\t' read -r id prompt keys flags <<< "$1"
    if [[ ",$flags," == *",question,"* ]]; then
        if grep -qF 'Choose how to set this password' <<< "$2"; then
            vm_shot "$id-menu" "$2"
            screen_row "$KC_NAME" "m{ret}"
            vm_keys "m{ret}"
            return 0
        fi
        keys="$(printf '{bksp}%.0s' $(seq 80))$keys{ret}"
    fi
    vm_shot "$id" "$2"
    screen_row "$KC_NAME" "${keys//\{bksp\}/}"
    echo "KC_SEEN $id" >> "$KC_LOG"
    vm_keys "$keys"
    if [[ ",$flags," == *",eject,"* ]]; then
        # the operator takes the medium out: the CD-ROM is emptied
        pve "qm set $KC_VMID --ide2 none,media=cdrom" >/dev/null
    fi
    [[ ",$flags," != *",last,"* ]]
}

# vm_drive PHASE TABLE: answer the screens of the VM until the table's last
# screen is answered (the installer) or the first boot has ended. A screen
# is acted on once it stays the same for one poll. In the first boot, a
# screen that is no entry of the table gets Enter, its default, after
# KC_CONSOLE_TIMEOUT seconds; in the installer it only gets a screenshot.
# Writes KC_SEEN, KC_DONE, KC_STUCK and KC_NOAGENT to KC_LOG.
vm_drive() {
    local phase="$1" table="$2" text prev="" acted="" line poll still=0 idle=0 steps=0 quiet down end
    poll=$(( KC_POLL > 0 ? KC_POLL : 1 ))
    quiet=$(( KC_CONSOLE_TIMEOUT / poll > 0 ? KC_CONSOLE_TIMEOUT / poll : 1 ))
    down=$(( KC_BOOT_TIMEOUT / poll > 0 ? KC_BOOT_TIMEOUT / poll : 1 ))
    # a screen that never stays still (a progress bar) counts no step, so
    # the phase also has an end in time
    end=$((SECONDS + KC_PHASE_TIMEOUT))
    while [ "$steps" -lt "$KC_CONSOLE_STEPS" ] && [ "$SECONDS" -lt "$end" ]; do
        sleep "$KC_POLL"
        if ! text=$(vm_screen); then
            idle=$((idle + 1))
            if [ "$idle" -gt "$down" ]; then
                echo "KC_NOAGENT $phase" >> "$KC_LOG"
                return 1
            fi
            vm_boot_frame "$phase-boot"
            continue
        fi
        idle=0
        if [ "$text" != "$prev" ]; then
            prev="$text" still=0
            continue
        fi
        vm_capture "$text"
        still=$((still + 1))
        if [ "$text" = "$acted" ] && [ "$still" -le "$quiet" ]; then
            continue
        fi
        # the end of the first boot comes before any match: the screen after
        # it (confconsole, a login) can name a prompt, and a key typed there
        # is no answer (an answer typed at the login prompt, BR1 2026-11-05)
        if [ "$phase" = firstboot ] && printf 'grep -qx RUN_FIRSTBOOT=false /etc/default/inithooks\n' | guest_sh >/dev/null 2>&1; then
            vm_shot "$phase-end" "$text"
            screen_row "$KC_NAME" ""
            echo "KC_DONE $phase" >> "$KC_LOG"
            return 0
        fi
        if line=$(vm_match "$table" "$text"); then
            acted="$text" still=0 steps=$((steps + 1))
            vm_act "$line" "$text" || { echo "KC_DONE $phase" >> "$KC_LOG"; return 0; }
            continue
        fi
        if [ "$phase" = installer ]; then
            # tkl-installer asks only what its table names: any other screen
            # is its progress, kept once, and an Enter there went to the next
            # question and answered it (BR1, 2026-11-05)
            if [ "$text" != "$acted" ]; then
                acted="$text"
                vm_shot "$phase-wait" "$text"
                screen_row "$KC_NAME" ""
            fi
        elif [ "$still" -ge "$quiet" ]; then
            acted="$text" still=0 steps=$((steps + 1))
            vm_shot "$phase-screen" "$text"
            screen_row "$KC_NAME" "{ret}"
            vm_keys "{ret}"
        fi
    done
    echo "KC_STUCK $phase" >> "$KC_LOG"
    return 1
}

# vm_tables: the installer table and the first boot table (the node's
# answers, then the questions with the flag question), from the contract.
vm_tables() {
    grep $'^installer\t' <<< "$KC_TSV" | cut -f2- > "$KC_WORK/installer"
    answers_table > "$KC_WORK/firstboot"
}

# answers_table: the node's own screens first, then the questions of the
# contract, as "ID<TAB>PROMPT<TAB>KEYS<TAB>FLAGS" lines, KEYS unresolved.
answers_table() {
    [ -z "${KC_NODE:-}" ] || grep $'^answer\t'"$KC_NODE"$'\t' <<< "$KC_TSV" | cut -f3- | sed 's/$/\t-/'
    # a choice is keys as they are; an input is a literal or {secret:NAME}
    awk -F'\t' -v OFS='\t' '$1 == "question" { if ($6 == "choice") { print $2, $4, $5, "-" } else { a = $5; if (a ~ /^secret:/) a = "{" a "}"; print $2, $4, a, "question" } }' <<< "$KC_TSV"
}

# vm_parse PHASE TABLE: record what the driver did with each screen.
vm_parse() {
    local row id prompt rows
    mapfile -t rows < "$2"
    for row in "${rows[@]}"; do
        id="${row%%$'\t'*}" prompt="${row#*$'\t'}"
        prompt="${prompt%%$'\t'*}"
        if grep -qx "KC_SEEN $id" "$KC_LOG"; then
            record pass "$1.asked.$id" "$prompt"
        else
            record fail "$1.asked.$id" "the $1 never showed '$prompt'"
        fi
    done
    if grep -qx "KC_DONE $1" "$KC_LOG"; then
        record pass "$1.finished" "the $1 ran to its end"
    else
        record fail "$1.finished" "$(grep -oE "^KC_(STUCK|NOAGENT) $1" "$KC_LOG" | head -1 || true): the $1 did not end"
    fi
}

# vm_record_cpu: the CPU type of the VM, as the field cpu at the end of
# KC_DIR/meta and as a note of the record. The fields of meta before it
# keep their names and their order: the release gate reads them.
vm_record_cpu() {
    local cpu how="from vm.cpu of the contract"
    cpu=$(vm_cpu)
    if [ -z "$cpu" ]; then
        cpu=kvm64 how="the default of qm create"
    fi
    printf 'cpu\t%s\n' "$cpu" >> "$KC_DIR/meta"
    record note vm.cpu "the VM has the CPU type $cpu, $how"
}

# pass_vm: install the ISO and answer the first boot of the disk.
pass_vm() {
    vm_create "$KC_IMAGE" >/dev/null || die 3 "qm create failed"
    vm_record_cpu
    vm_start || die 3 "qm start failed"
    vm_tables
    vm_drive installer "$KC_WORK/installer"
    vm_parse installer "$KC_WORK/installer"
    grep -qx "KC_DONE installer" "$KC_LOG" || return 1
    vm_drive firstboot "$KC_WORK/firstboot"
    vm_parse firstboot "$KC_WORK/firstboot"
    grep -qx "KC_DONE firstboot" "$KC_LOG"
}

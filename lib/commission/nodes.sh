# shellcheck shell=bash
# The cloud modes of decision 0076: one pass makes every node of a mode,
# each on its own site, answers their screens (Mode, Role, Join a mesh,
# Invite a node, which are the contract's answers of each node), carries
# the invite line and the VIP from the screen of the first node to the
# others, and then checks across the nodes.
#
# Each node runs in its own subshell, in the background, with the PVE
# host, the options and the vmid of its site: KC_PVE_<SITE>, KC_CT_OPTS_<SITE>,
# KC_VM_OPTS_<SITE> and KC_VM_STORAGE_<SITE> (site in upper case) when they
# are set, KC_PVE and the others when not. The first node is the vmid of
# --vmid, the next ones the vmids after it. A node's record, transcript,
# screens and guide rows are in OUT/PASS/NODE; OUT/PASS/record.tsv has them
# all, each check named NODE:CHECK.

# site_env SITE: the PVE host and the options of SITE.
site_env() {
    local up="${1^^}" var
    for var in KC_PVE KC_CT_OPTS KC_VM_OPTS KC_VM_STORAGE KC_VM_FIRMWARE KC_NAMESERVER; do
        local site_var="${var}_$up"
        if [ -n "${!site_var:-}" ]; then
            printf -v "$var" '%s' "${!site_var}"
        fi
    done
}


# node_rows: the node lines of this pass's mode, "NAME SITE KIND IMAGE ROLE
# CONTRACT".
node_rows() {
    awk -F'\t' -v mode="$KC_PASS" '$1 == "node" && $6 == mode { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $7 "\t" $8 }' <<< "$KC_TSV"
}

# node_tsv CONTRACT: the contract lines of a node of another appliance (the
# Keel Core witness): the questions, proofs, checks and screenshots of its
# own contract, and of this one its answers, its screenshots and the
# screens of the cloud modes (capture, wait).
node_tsv() {
    python3 -I "$KC_LIB/contract.py" tsv "$1" | grep -vE $'^(node|answer|nshot|capture|wait|cross)\t'
    grep -E $'^(answer|nshot)\t'"$KC_NODE"$'\t' <<< "$KC_TSV"
    grep -E $'^(capture|wait)\t' <<< "$KC_TSV"
}

# node_use INDEX: the globals of the node KC_NODES[INDEX]. The loops over
# the nodes call it in a subshell, so each node keeps its own.
node_use() {
    local name site kind image role contract
    IFS=$'\t' read -r name site kind image role contract <<< "${KC_NODES[$1]}"
    KC_NODE="$name" KC_KIND="$kind" KC_VMID=$((KC_BASE_VMID + $1)) KC_IMAGE="$image"
    if [ -n "$contract" ] && [ "$contract" != - ]; then
        KC_TSV=$(node_tsv "$contract")
    fi
    node_image "$name"
    if [ "$KC_IMAGE" = - ]; then
        if [ "$kind" = vm ]; then KC_IMAGE="$KC_ISO"; else KC_IMAGE="$KC_TEMPLATE"; fi
    fi
    site_env "$site"
    KC_DIR="$KC_OUT/$KC_PASS/$name"
    KC_RECORD="$KC_DIR/record.tsv"
    # read by the console and the VM driver
    # shellcheck disable=SC2034
    KC_LOG="$KC_DIR/console.log"
}

# node_image NAME: KC_IMAGE_<NAME> (upper case, "-" as "_") in place of
# the node's image, when it is set. The image of a node of another
# appliance (the Keel Core witness) is a new build for each release, so
# the contract in the appliance repository does not name it.
node_image() {
    local var="KC_IMAGE_${1^^}"
    var="${var//-/_}"
    if [ -n "${!var:-}" ]; then
        KC_IMAGE="${!var}"
    fi
}

# node_images: stop when a node of another appliance has no image: it
# would be made from --template or --iso, the image of this appliance.
node_images() {
    local row name image contract KC_IMAGE
    for row in "${KC_NODES[@]}"; do
        IFS=$'\t' read -r name _ _ image _ contract <<< "$row"
        KC_IMAGE="$image"
        node_image "$name"
        if [ "$contract" != - ] && [ "$KC_IMAGE" = - ]; then
            local var="KC_IMAGE_${name^^}"
            die 2 "node $name has the contract of another appliance and no image: set ${var//-/_}"
        fi
    done
}

# node_wants NAME: the highest invite number the node's answers type, and
# "vip" when they type the VIP.
node_wants() {
    local keys max=0 n
    keys=$(grep $'^answer\t'"$1"$'\t' <<< "$KC_TSV" | cut -f5)
    for n in $(grep -oE '\{invite:[0-9]+\}' <<< "$keys" | tr -dc '0-9\n'); do
        [ "$n" -gt "$max" ] && max="$n"
    done
    printf '%s' "$max"
    grep -q '{vip}' <<< "$keys" && printf ' vip'
    echo
}

# node_wait LOG PID N VIP: wait until the first node's screen gave N invite
# lines (and the VIP), and export them as KC_INVITE_1.. and KC_VIP. Fails
# after KC_NODE_WAIT seconds, or when the first node's run (PID) ended
# without them. The first node shows its invite after its first boot, its
# login and every password of keel-init: more than KC_BOOT_TIMEOUT (BR1,
# 2026-11-06).
node_wait() {
    local waited=0 i line alive=1 lines
    while [ "$(invites "$1" | wc -l)" -lt "$3" ] \
        || { [ -n "$4" ] && ! grep -aq '^KC_VIP ' "$1" 2>/dev/null; }; do
        # one more look after the first node ended: it may have written
        # its last line just before
        if [ "$alive" = 0 ] || [ "$waited" -ge "$KC_NODE_WAIT" ]; then
            return 1
        fi
        kill -0 "$2" 2>/dev/null || alive=0
        sleep "$KC_POLL"
        waited=$((waited + KC_POLL + 1))
    done
    mapfile -t lines < <(invites "$1")
    for i in "${!lines[@]}"; do
        export "KC_INVITE_$((i + 1))=${lines[$i]#KC_INVITE }"
    done
    line=$(grep -a -m1 '^KC_VIP ' "$1" || true)
    [ -z "$line" ] || export "KC_VIP=${line#KC_VIP }"
    return 0
}

# invites LOG: the invite lines of LOG, each once, in the order shown: a
# screen drawn again prints its line again. -a: the raw console holds the
# bytes of the screens, and grep then reads it as a binary file and says
# only that it matches (BR1/BR2, 2026-11-06: the second node waited an hour
# for an invite that was in the log).
invites() {
    grep -a '^KC_INVITE ' "$1" 2>/dev/null | awk '!seen[$0]++'
}

# nodes_mask: an invite line lets a machine into the mesh, so no file of
# the pass keeps one: each is replaced by "<invite N>" once the pass is
# over. So is each piece of it of 12 characters or more: an input box
# narrower than the invite shows it as windows that slide while it is
# typed, and the frame of the join screen kept them (BR2, 2026-11-06).
nodes_mask() {
    local lines
    if [ -n "${KC_NTFY_TOPIC:-}" ]; then
        { cat "$KC_NTFY_TOKEN_FILE"; [ -z "${KC_NTFY_READ_FILE:-}" ] || sed 's/^[^ ]* [^ ]* //' "$KC_NTFY_READ_FILE"; } \
            | python3 -I "$KC_LIB/mask.py" "$KC_OUT/$KC_PASS" token
    fi
    mapfile -t lines < <(invites "$KC_OUT/$KC_PASS/${KC_NODES[0]%%$'\t'*}/console.log")
    [ "${#lines[@]}" -gt 0 ] || return 0
    printf '%s\n' "${lines[@]#KC_INVITE }" | python3 -I "$KC_LIB/mask.py" "$KC_OUT/$KC_PASS"
}

# node_run: one node from its creation to its checks, in its subshell.
node_run() {
    mkdir -p "$KC_DIR/screens"
    : > "$KC_RECORD"
    KC_WORK="$KC_WORK/$KC_NODE"
    mkdir -p "$KC_WORK"
    if [ "$KC_KIND" = vm ]; then
        pass_vm || return 0
    else
        pass_interactive || return 0
    fi
    [ -z "${KC_NTFY_TOPIC:-}" ] || node_monitor
    common_checks
    web_shots
}

# node_free: fail when the vmid of a node is in use on its host.
node_free() {
    local i
    for i in "${!KC_NODES[@]}"; do
        if ( node_use "$i"; pve "qm status $KC_VMID >/dev/null 2>&1 || pct status $KC_VMID >/dev/null 2>&1" ); then
            die 4 "vmid $((KC_BASE_VMID + i)) of ${KC_NODES[$i]%%$'\t'*} is in use; keel-commission only uses a free id"
        fi
    done
}

# node_meta INDEX: OUT/PASS/NODE/meta, what the guide names the column by,
# and the image the node is made from with its sha256 on the node's own
# PVE host: one volume name can hold other bytes on another site. "own"
# says whether the node is of this appliance (no contract of its own).
node_meta() {
    local name site kind image role contract sha
    IFS=$'\t' read -r name site kind image role contract <<< "${KC_NODES[$1]}"
    mkdir -p "$KC_OUT/$KC_PASS/$name"
    image=$( node_use "$1"; printf '%s' "$KC_IMAGE" )
    sha=$( node_use "$1"; template_sha "$KC_IMAGE" 2>/dev/null )
    printf 'node\t%s\nsite\t%s\nkind\t%s\nrole\t%s\nvmid\t%s\nimage\t%s\nsha256\t%s\nown\t%s\n' \
        "$name" "$site" "$kind" "$role" "$((KC_BASE_VMID + $1))" "$image" "$sha" \
        "$([ "${contract:--}" = - ] && echo yes || echo no)" > "$KC_OUT/$KC_PASS/$name/meta"
}

# nodes_sha: the sha256 of the pass, in OUT/PASS/meta, by which the release
# gate finds the record of a template (apt lib/commission.sh): the image of
# the nodes of this appliance. They must all be the same bytes, or the
# pass is the proof of no one image and fails.
nodes_sha() {
    local shas="" row meta
    for row in "${KC_NODES[@]}"; do
        meta="$KC_OUT/$KC_PASS/${row%%$'\t'*}/meta"
        if grep -qx $'own\tyes' "$meta"; then
            shas+="$(sed -n 's/^sha256\t//p' "$meta")"$'\n'
        fi
    done
    shas=$(sort -u <<< "${shas%$'\n'}")
    if [ -z "$shas" ] || [ "$(wc -l <<< "$shas")" -ne 1 ] || [[ ! "$shas" =~ ^[0-9a-f]{64}$ ]]; then
        record fail images.same "the nodes of this appliance do not boot one image: ${shas//$'\n'/ }"
        return 0
    fi
    printf 'sha256\t%s\n' "$shas" >> "$KC_OUT/$KC_PASS/meta"
    record pass images.same "every node of this appliance boots $shas"
}

# pass_nodes: every node of the mode, each in the background as soon as
# the invite lines it types are on the first node's screen, then the
# checks across them.
pass_nodes() {
    local i name wants pids=()
    KC_BASE_VMID="$KC_VMID"
    # the topic of this pass: each pass reads only its own alerts
    if [ -n "${KC_NTFY_URL:-}" ]; then
        KC_NTFY_TOPIC="$KC_NTFY_URL-$KC_BASE_VMID-$(date +%s)"
        export KC_NTFY_TOPIC
    fi
    mapfile -t KC_NODES < <(node_rows)
    [ "${#KC_NODES[@]}" -gt 0 ] || die 2 "the contract has no node of mode $KC_PASS"
    node_images
    node_free
    for i in "${!KC_NODES[@]}"; do
        node_meta "$i"
    done
    nodes_sha
    for i in "${!KC_NODES[@]}"; do
        name="${KC_NODES[$i]%%$'\t'*}"
        read -r -a wants <<< "$(node_wants "$name")"
        if [ "$i" -gt 0 ] && ! node_wait "$KC_OUT/$KC_PASS/${KC_NODES[0]%%$'\t'*}/console.log" "${pids[0]}" "${wants[0]}" "${wants[1]:-}"; then
            record fail "$name:started" "the first node showed no invite line it needs"
            continue
        fi
        ( node_use "$i"; node_run > "$KC_DIR.out" 2>&1 ) &
        pids+=("$!")
    done
    wait "${pids[@]}"
    nodes_merge
    cross_checks
    nodes_mask
    nodes_destroy
}

# nodes_merge: the records of the nodes in the record of the pass, each
# check named NODE:CHECK.
nodes_merge() {
    local row name
    for row in "${KC_NODES[@]}"; do
        name="${row%%$'\t'*}"
        [ -e "$KC_OUT/$KC_PASS/$name/record.tsv" ] || continue
        awk -F'\t' -v OFS='\t' -v n="$name" -v rec="$KC_RECORD" '{ $2 = n ":" $2; print >> rec; printf "%-4s  %-40s %s\n", $1, $2, $3 }' "$KC_OUT/$KC_PASS/$name/record.tsv"
    done
}

# on_nodes WHO: the indexes of the nodes a cross check runs on: those of
# the role WHO, the node named WHO, or all.
on_nodes() {
    local i name site kind image role
    for i in "${!KC_NODES[@]}"; do
        IFS=$'\t' read -r name site kind image role _ <<< "${KC_NODES[$i]}"
        if [ "$1" = all ] || [[ ",$1," == *",$name,"* ]] || [[ ",$1," == *",$role,"* ]]; then
            echo "$i"
        fi
    done
}

# cross_checks: the contract's checks across the nodes, in their order: a
# row written on the primary and read through the VIP, one VIP holder,
# the voters of etcd, the direction of the files, a planned promote and
# its return. Each runs on the nodes AT names, with VIP in its environment
# and SECRET when it names one; it passes on a node when it exits 0 and its
# output matches MATCH, and the check passes when COUNT nodes pass (all of
# them when COUNT is empty).
cross_checks() {
    local row id at run match count secret same modes alert within i passed total value rows targets since said note notes
    mapfile -t rows < <(grep $'^cross\t' <<< "$KC_TSV" | cut -f2-)
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r id at run match count secret same modes alert within <<< "$row"
        # a check of other modes only: the witness of cloud advanced, for
        # example, is not a node of cloud simple
        if [ "${modes:--}" != - ] && [[ ",$modes," != *",$KC_PASS,"* ]]; then
            continue
        fi
        if [ "$same" = same ]; then
            cross_same "$id" "$at" "$run"
            continue
        fi
        passed=0 value=""
        [ "$match" != - ] || match=""
        [ "$count" != - ] || count=""
        [ "$secret" = - ] || value=$(secret_value "$secret")
        mapfile -t targets < <(on_nodes "$at")
        total="${#targets[@]}"
        since=$(date +%s)
        notes=()
        for i in "${targets[@]}"; do
            if said=$( node_use "$i"; cross_one "$value" "$run" "$match" ); then
                passed=$((passed + 1))
            fi
            notes+=("$said")
        done
        if [ "$total" -eq 0 ] || [ "$passed" -ne "${count:-$total}" ]; then
            record fail "cross.$id" "$passed of $total nodes ($at), wants ${count:-$total}"
            # what each node said, and its failed units, so the record
            # names the cause (release A, 2026-11-09: no-failed-units
            # said only "0 of 2 nodes")
            for note in "${!targets[@]}"; do
                record note "cross.$id" "$(cross_note "${targets[$note]}" "${notes[$note]}" "$value")"
            done
        elif [ "${alert:--}" != - ]; then
            alert_wait "$id" "$alert" "$within" "$since"
        else
            record pass "cross.$id" "$passed of $total nodes ($at)"
        fi
    done
}

# alert_wait ID ALERT WITHIN SINCE: pass when a message of the alert topic
# of the pass (KC_NTFY_TOPIC) holds ALERT, from SINCE (epoch seconds) for
# WITHIN seconds. The runner reads the topic itself, with the header in
# KC_NTFY_READ_FILE: the publish token of keel-ntfy may only write
# (decision 0063). curl takes the header as a file (-H @FILE), so it is on
# no command line.
alert_wait() {
    local end out
    if [ -z "${KC_NTFY_TOPIC:-}" ]; then
        record fail "cross.$1" "KC_NTFY_URL is not set: no alert topic to read"
        return
    fi
    if [ -z "${KC_NTFY_READ_FILE:-}" ]; then
        record fail "cross.$1" "KC_NTFY_READ_FILE is not set: the topic cannot be read"
        return
    fi
    # WITHIN counts from the start of the check, which stops the standby
    end=$(( $4 + $3 ))
    while :; do
        out=$("${KC_CURL:-curl}" -s --max-time 10 -H "@$KC_NTFY_READ_FILE" "$KC_NTFY_TOPIC/json?poll=1&since=$4" 2>/dev/null || true)
        if grep -qF -- "$2" <<< "$out"; then
            record pass "cross.$1" "alert '$2' on the topic after $(( $(date +%s) - $4 )) s"
            return
        fi
        [ "$(date +%s)" -lt "$end" ] || break
        sleep "${KC_ALERT_POLL:-5}"
    done
    record fail "cross.$1" "no alert '$2' on the topic within $3 s"
}

# node_monitor: the node sends its alerts to the topic of the pass
# (KC_NTFY_TOPIC): the token of KC_NTFY_TOKEN_FILE goes into a secret file
# of the node, the monitor section of its spec names the topic, and keel
# applies it. The token is in the script on stdin, never on a command line;
# nodes_mask takes it out of every file of the pass. A node without a
# working alert channel says nothing when its standby goes: the alert of
# the PostgreSQL fallback was proven only once the node had one (BR1 and
# BR2, 2026-11-07).
node_monitor() {
    local token
    token=$(cat "$KC_NTFY_TOKEN_FILE")
    # keel will make /etc/keel/secrets at the first boot (a change given to
    # the keel agent on 2026-11-07); until that keel is out, the runner
    # makes it, mode 0700, as the first boot would
    if { printf 'set -e\ninstall -d -m 0700 /etc/keel/secrets\n'
         printf "umask 077\ncat > /etc/keel/secrets/kc_ntfy_token <<'KC_TOKEN'\n%s\nKC_TOKEN\n" "$token"
         printf 'chmod 0600 /etc/keel/secrets/kc_ntfy_token\n'
         printf 'KC_TOPIC=%q python3 - /etc/keel/instance.yaml <<%s\n' "$KC_NTFY_TOPIC" "'PY'"
         cat <<'PY'
import os, sys, yaml
path = sys.argv[1]
with open(path) as handle:
    spec = yaml.safe_load(handle) or {}
monitor = spec.get("monitor") or {}
monitor["enabled"] = True
notify = monitor.get("notify") or {}
notify["ntfy"] = {"url": os.environ["KC_TOPIC"],
                  "token": {"file": "/etc/keel/secrets/kc_ntfy_token"}}
monitor["notify"] = notify
spec["monitor"] = monitor
with open(path, "w") as handle:
    yaml.safe_dump(spec, handle, sort_keys=False)
PY
         printf 'PY\nkeel spec apply --system-only --non-interactive --skip-network --spec /etc/keel/instance.yaml\n'
       } | guest_sh > "$KC_DIR/monitor.out" 2>&1; then
        record pass monitor.ntfy "the node sends its alerts to the topic of the pass"
    else
        record fail monitor.ntfy "the monitor of the node did not take the topic (monitor.out)"
    fi
}

# cross_same ID AT RUN: pass when RUN prints the same output, not empty, on
# every node AT names. Whole outputs are compared, by their digests: two
# equal outputs of two lines were counted as two values (LNPP, BR1 and BR2,
# 2026-11-06).
cross_same() {
    local i out outs=() failed=0
    for i in $(on_nodes "$2"); do
        if out=$( node_use "$i"; { printf 'export VIP=%q\n' "${KC_VIP:-}"; printf '%s\n' "$3"; } | guest_sh 2>/dev/null ) && [ -n "$out" ]; then
            outs+=("$out")
        else
            failed=$((failed + 1))
        fi
    done
    if [ "${#outs[@]}" -lt 2 ] || [ "$failed" -gt 0 ]; then
        record fail "cross.$1" "$failed of $((${#outs[@]} + failed)) nodes ($2) gave no output"
    elif [ "$(for out in "${outs[@]}"; do printf '%s' "$out" | sha256sum; done | sort -u | wc -l)" -eq 1 ]; then
        record pass "cross.$1" "the same output on ${#outs[@]} nodes ($2)"
    else
        record fail "cross.$1" "the output differs on the ${#outs[@]} nodes ($2): $(printf '%s | ' "${outs[@]}" | tr '\n' ' ' | cut -c1-120)"
    fi
}

# cross_one SECRET RUN MATCH: run RUN in the node with VIP and SECRET set;
# what it printed goes to the standard output.
cross_one() {
    local out code=0
    out=$({ printf 'export SECRET=%q VIP=%q\n' "$1" "${KC_VIP:-}"; printf '%s\n' "$2"; } | guest_sh 2>/dev/null) || code=1
    printf '%s' "$out"
    [ "$code" -eq 0 ] || return 1
    [ -z "$3" ] || grep -qE -- "$3" <<< "$out"
}

# cross_note INDEX SAID SECRET: one line for the record of a check that
# failed: the node, the first line it printed (the secret masked, 120
# characters at most), and the units systemd lists as failed there.
cross_note() {
    local name first units
    IFS=$'\t' read -r name _ <<< "${KC_NODES[$1]}"
    first=$(head -n 1 <<< "$2")
    [ -z "$3" ] || first="${first//"$3"/(the secret)}"
    first="${first:0:120}"
    units=$( node_use "$1"; printf 'systemctl --failed --no-legend --plain 2>/dev/null\n' | guest_sh 2>/dev/null | awk '{print $1}' | paste -sd ' ' -)
    printf '%s said: %s; failed units: %s' "$name" "${first:-nothing}" "${units:-none}"
}

# nodes_destroy: remove every node, unless --keep was given.
nodes_destroy() {
    local i
    for i in "${!KC_NODES[@]}"; do
        ( node_use "$i"; if [ "$KC_KIND" = vm ]; then vm_destroy; else ct_destroy; fi )
    done
}

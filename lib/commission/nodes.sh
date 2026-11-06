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
    for var in KC_PVE KC_CT_OPTS KC_VM_OPTS KC_VM_STORAGE KC_VM_FIRMWARE; do
        local site_var="${var}_$up"
        if [ -n "${!site_var:-}" ]; then
            printf -v "$var" '%s' "${!site_var}"
        fi
    done
}


# node_rows: the node lines of this pass's mode, "NAME SITE KIND IMAGE ROLE".
node_rows() {
    awk -F'\t' -v mode="$KC_PASS" '$1 == "node" && $6 == mode { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $7 }' <<< "$KC_TSV"
}

# node_use INDEX: the globals of the node KC_NODES[INDEX]. The loops over
# the nodes call it in a subshell, so each node keeps its own.
node_use() {
    local name site kind image role
    IFS=$'\t' read -r name site kind image role <<< "${KC_NODES[$1]}"
    KC_NODE="$name" KC_KIND="$kind" KC_VMID=$((KC_BASE_VMID + $1)) KC_IMAGE="$image"
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

# node_meta INDEX: OUT/PASS/NODE/meta, what the guide names the column by.
node_meta() {
    local name site kind image role
    IFS=$'\t' read -r name site kind image role <<< "${KC_NODES[$1]}"
    mkdir -p "$KC_OUT/$KC_PASS/$name"
    printf 'node\t%s\nsite\t%s\nkind\t%s\nrole\t%s\nvmid\t%s\n' "$name" "$site" "$kind" \
        "$role" "$((KC_BASE_VMID + $1))" > "$KC_OUT/$KC_PASS/$name/meta"
}

# pass_nodes: every node of the mode, each in the background as soon as
# the invite lines it types are on the first node's screen, then the
# checks across them.
pass_nodes() {
    local i name wants pids=()
    KC_BASE_VMID="$KC_VMID"
    mapfile -t KC_NODES < <(node_rows)
    [ "${#KC_NODES[@]}" -gt 0 ] || die 2 "the contract has no node of mode $KC_PASS"
    node_free
    for i in "${!KC_NODES[@]}"; do
        name="${KC_NODES[$i]%%$'\t'*}"
        node_meta "$i"
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
        IFS=$'\t' read -r name site kind image role <<< "${KC_NODES[$i]}"
        if [ "$1" = all ] || [ "$1" = "$name" ] || [ "$1" = "$role" ]; then
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
    local row id at run match count secret i passed total value rows targets
    mapfile -t rows < <(grep $'^cross\t' <<< "$KC_TSV" | cut -f2-)
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r id at run match count secret <<< "$row"
        passed=0 value=""
        [ "$match" != - ] || match=""
        [ "$count" != - ] || count=""
        [ "$secret" = - ] || value=$(secret_value "$secret")
        mapfile -t targets < <(on_nodes "$at")
        total="${#targets[@]}"
        for i in "${targets[@]}"; do
            if ( node_use "$i"; cross_one "$value" "$run" "$match" ); then
                passed=$((passed + 1))
            fi
        done
        if [ "$total" -gt 0 ] && [ "$passed" -eq "${count:-$total}" ]; then
            record pass "cross.$id" "$passed of $total nodes ($at)"
        else
            record fail "cross.$id" "$passed of $total nodes ($at), wants ${count:-$total}"
        fi
    done
}

# cross_one SECRET RUN MATCH: run RUN in the node with VIP and SECRET set.
cross_one() {
    local out
    out=$({ printf 'export SECRET=%q VIP=%q\n' "$1" "${KC_VIP:-}"; printf '%s\n' "$2"; } | guest_sh 2>/dev/null) || return 1
    [ -z "$3" ] || grep -qE -- "$3" <<< "$out"
}

# nodes_destroy: remove every node, unless --keep was given.
nodes_destroy() {
    local i
    for i in "${!KC_NODES[@]}"; do
        ( node_use "$i"; if [ "$KC_KIND" = vm ]; then vm_destroy; else ct_destroy; fi )
    done
}

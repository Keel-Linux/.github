#!/bin/bash
# Node topology for the appliance gate: the logic that turns one declared
# list of roles into several containers on one bridge, tells each container
# which one it is, and lets a boot test address another one by literal
# IPv6 address.
#
# Why it lives here rather than in each appliance repository. It is shell
# the reusable workflow lends to the repositories that call it, the same
# kind of thing bin/require-changelog is, and the handbook already decided
# that shared boot test logic belongs in this repository because this is
# the one with a gate on that file. Copying it into four appliance
# repositories is the trap docs/traps.md ends with: the same 130 lines in
# four places meant every fix had to be ported by hand, twice.
#
# Nothing here starts a container, writes a file or opens a socket, which
# is decision 0004's split: this file is logic, the effects are in the
# appliance's tests/boot-test.sh. That is also what makes 100 percent line
# coverage of it possible, which is the bar this repository holds.
#
# Sourced by an appliance's tests/boot-test.sh, which the workflow points
# at it with --nodes-lib, and by tests/boot-test-nodes.bats here.
# shellcheck disable=SC2034  # the BTN_* constants are read by the caller

# Where a node is told about itself and about the others, inside its own
# rootfs. Both are shell fragments a first boot hook or a convergence run
# can source, which is the seam the appliance's own replication feature
# will take over: it will read the role from the instance description
# instead, and these two files stop being written by hand.
BTN_NODE_ENV=etc/keel/node.env
BTN_PEERS_ENV=etc/keel/peers.env

# Seconds a reachability probe waits for the other node's port.
BTN_PROBE_TIMEOUT=5

# The ceiling on nodes in one run. Galera needs three and a Spider head
# with two data nodes needs three, so the shape must not assume two; a
# list longer than five is a typo, not a topology, and this runs on a host
# other people share.
BTN_MAX_NODES=5

btn_is_role_name() {
    # A role name is a word: it becomes part of a container name and part
    # of an environment variable name, so it holds no dot, no underscore
    # and no upper case.
    [[ ${1-} =~ ^[a-z][a-z0-9-]*$ ]]
}

btn_is_node_base() {
    # The base the workflow passes as --name. Node names are derived from
    # it, so it has to be what LXC accepts with a suffix added.
    [[ ${1-} =~ ^[a-z0-9][a-z0-9.-]*$ ]]
}

btn_roles() {
    # btn_roles "LIST": the roles of LIST, one per line, in order. Repeats
    # are allowed on purpose, because three Galera nodes hold the same
    # role. Returns 1 with a message on stderr when the list is empty, a
    # word is not a role name, or there are more nodes than this host
    # should be asked to run.
    local list=${1-} role count=0
    for role in $list; do
        if ! btn_is_role_name "$role"; then
            echo "nodes: '$role' is not a role name (lower case, digits, dash)" >&2
            return 1
        fi
        count=$((count + 1))
    done
    if [ "$count" -eq 0 ]; then
        echo "nodes: the role list is empty; name one role per node" >&2
        return 1
    fi
    if [ "$count" -gt "$BTN_MAX_NODES" ]; then
        echo "nodes: $count nodes asked for, $BTN_MAX_NODES is the ceiling" >&2
        return 1
    fi
    for role in $list; do
        printf '%s\n' "$role"
    done
}

btn_node_count() {
    # btn_node_count "LIST": how many containers LIST asks for.
    local list=${1-} role count=0
    btn_roles "$list" > /dev/null || return 1
    for role in $list; do
        count=$((count + 1))
    done
    printf '%s\n' "$count"
}

btn_node_name() {
    # btn_node_name BASE INDEX: the container name of node INDEX. The
    # index and not the role, because roles repeat and container names
    # cannot.
    local base=${1-} index=${2-}
    if ! btn_is_node_base "$base"; then
        echo "nodes: '$base' is not a container name base" >&2
        return 1
    fi
    if [[ ! $index =~ ^[1-9][0-9]*$ ]]; then
        echo "nodes: '$index' is not a node index" >&2
        return 1
    fi
    printf '%s-%s\n' "$base" "$index"
}

btn_nodes() {
    # btn_nodes BASE "LIST": the topology, one node per line, as
    # "INDEX NAME ROLE". This is the single place the mapping from a
    # declared list to container names is made, so the test, the summary
    # and the teardown all agree on it.
    local base=${1-} list=${2-} roles role index=0 name
    roles=$(btn_roles "$list") || return 1
    for role in $roles; do
        index=$((index + 1))
        name=$(btn_node_name "$base" "$index") || return 1
        printf '%s %s %s\n' "$index" "$name" "$role"
    done
}

btn_role_node() {
    # btn_role_node "NODES" ROLE: the container name of the one node that
    # holds ROLE, where NODES is the output of btn_nodes. Refused when no
    # node holds it, and refused when several do: a test that says "the
    # replica" while two exist is not asking a question with an answer, and
    # a topology of three identical nodes has to address them by index.
    #
    # The trailing field is discarded, so the same lines work before the
    # nodes have addresses and after: a caller should not have to keep two
    # shapes of the topology, and it would read the address as part of the
    # role if this took exactly three.
    local nodes=${1-} role=${2-} found="" count=0 index name node_role _rest
    while read -r index name node_role _rest; do
        [ -n "$index" ] || continue
        [ "$node_role" = "$role" ] || continue
        found=$name
        count=$((count + 1))
    done <<< "$nodes"
    if [ "$count" -eq 0 ]; then
        echo "nodes: no node holds the role '$role'" >&2
        return 1
    fi
    if [ "$count" -gt 1 ]; then
        echo "nodes: $count nodes hold the role '$role'; address them by index" >&2
        return 1
    fi
    printf '%s\n' "$found"
}

btn_peer_var() {
    # btn_peer_var ROLE: the variable name a peers file uses for the one
    # node holding ROLE.
    local role=${1-} name
    if ! btn_is_role_name "$role"; then
        echo "nodes: '$role' is not a role name" >&2
        return 1
    fi
    name=${role//-/_}
    printf 'KEEL_PEER_%s\n' "${name^^}"
}

btn_node_env() {
    # btn_node_env INDEX NAME ROLE COUNT: what one node is told about
    # itself, written into its own rootfs at $BTN_NODE_ENV. A node learns
    # which one it is by reading a file in its own filesystem, the way
    # every other appliance setting arrives, and not from its hostname, an
    # address or the order it was started in.
    local index=${1-} name=${2-} role=${3-} count=${4-}
    if [[ ! $index =~ ^[1-9][0-9]*$ ]] || [[ ! $count =~ ^[1-9][0-9]*$ ]]; then
        echo "nodes: node env needs a positive index and count" >&2
        return 1
    fi
    if ! btn_is_node_base "$name" || ! btn_is_role_name "$role"; then
        echo "nodes: node env needs a container name and a role name" >&2
        return 1
    fi
    cat <<ENV
# Written by the appliance gate before this container was started.
# The role is the gate's, by hand, until the instance description carries
# it (handbook decision 0013, phase 2).
KEEL_NODE_NAME=$name
KEEL_NODE_ROLE=$role
KEEL_NODE_INDEX=$index
KEEL_NODE_COUNT=$count
ENV
}

btn_peers_env() {
    # btn_peers_env "NODES_WITH_ADDRESSES": lines of
    # "INDEX NAME ROLE ADDRESS", one per node, and prints the peers file
    # every node gets. Every node is listed by index, which works for any
    # number of them; a role is given its own variable only when exactly
    # one node holds it, because three Galera nodes share a role and one
    # variable could not name them.
    local lines=${1-} index name role addr var
    local -a seen_roles=() once_roles=()
    while read -r index name role addr; do
        [ -n "$index" ] || continue
        seen_roles+=("$role")
    done <<< "$lines"
    local matches other
    for role in "${seen_roles[@]}"; do
        matches=0
        for other in "${seen_roles[@]}"; do
            if [ "$other" = "$role" ]; then
                matches=$((matches + 1))
            fi
        done
        if [ "$matches" -eq 1 ]; then
            once_roles+=("$role")
        fi
    done
    echo "# Written by the appliance gate once every node had an address."
    echo "# Addresses are literal and IPv6: nothing here is resolved."
    printf 'KEEL_NODE_COUNT=%s\n' "${#seen_roles[@]}"
    while read -r index name role addr; do
        [ -n "$index" ] || continue
        if ! btn_is_ipv6_literal "$addr"; then
            echo "nodes: '$addr' is not an IPv6 literal" >&2
            return 1
        fi
        printf 'KEEL_NODE_%s_NAME=%s\n' "$index" "$name"
        printf 'KEEL_NODE_%s_ROLE=%s\n' "$index" "$role"
        printf 'KEEL_NODE_%s_ADDR=%s\n' "$index" "$addr"
        for other in "${once_roles[@]}"; do
            if [ "$other" = "$role" ]; then
                var=$(btn_peer_var "$role") || return 1
                printf '%s=%s\n' "$var" "$addr"
            fi
        done
    done <<< "$lines"
}

btn_is_ipv6_literal() {
    # A literal IPv6 address, which is the only kind of address this gate
    # uses: on Debian `localhost` resolves to 127.0.0.1 alone, so a name
    # anywhere in this path would quietly pick IPv4 (docs/traps.md).
    local addr=${1-}
    [[ $addr == *:* ]] || return 1
    [[ $addr =~ ^[0-9a-fA-F:]+$ ]] || return 1
    return 0
}

btn_tcp_probe_argv() {
    # btn_tcp_probe_argv ADDRESS PORT [TIMEOUT]: the command one container
    # runs to find out whether another one answers on PORT, one argument
    # per line, for a caller that runs it with lxc-attach. Bash opens
    # /dev/tcp/ADDRESS/PORT with getaddrinfo, so an IPv6 literal goes in
    # without brackets; the address is validated first so nothing a role
    # file holds can become part of the path.
    local addr=${1-} port=${2-} timeout=${3:-$BTN_PROBE_TIMEOUT}
    if ! btn_is_ipv6_literal "$addr"; then
        echo "nodes: '$addr' is not an IPv6 literal to probe" >&2
        return 1
    fi
    if [[ ! $port =~ ^[1-9][0-9]*$ ]] || [ "$port" -gt 65535 ]; then
        echo "nodes: '$port' is not a port" >&2
        return 1
    fi
    if [[ ! $timeout =~ ^[1-9][0-9]*$ ]]; then
        echo "nodes: '$timeout' is not a number of seconds" >&2
        return 1
    fi
    # shellcheck disable=SC2016  # the shell inside the container expands these
    printf '%s\n' timeout "$timeout" bash -c \
        'exec 3<>"/dev/tcp/$0/$1"' "$addr" "$port"
}

btn_summary_rows() {
    # btn_summary_rows "NODES_WITH_ADDRESSES": the job summary table body,
    # so what the gate reports about the topology comes from the same
    # lines the test used and cannot drift from them.
    local lines=${1-} index name role addr
    while read -r index name role addr; do
        [ -n "$index" ] || continue
        # shellcheck disable=SC2016  # the backticks are markdown, not a command
        printf '| %s | `%s` | `%s` | `%s` |\n' "$index" "$role" "$name" "${addr:--}"
    done <<< "$lines"
}

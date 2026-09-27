#!/usr/bin/env bats
# Unit tests of lib/boot-test-nodes.sh, the node topology the appliance
# gate lends to every appliance repository. No container, no network, no
# root: every function here is logic, which is why it can be measured.

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib/boot-test-nodes.sh"
    # shellcheck source=../lib/boot-test-nodes.sh
    source "$LIB"
}

# --- role names -------------------------------------------------------

@test "accepts a role name of lower case letters, digits and dashes" {
    btn_is_role_name primary
    btn_is_role_name data-node2
}

@test "refuses a role name with upper case, an underscore or a dot" {
    ! btn_is_role_name Primary
    ! btn_is_role_name data_node
    ! btn_is_role_name node.one
    ! btn_is_role_name 1node
    ! btn_is_role_name ""
}

@test "accepts a container name base and refuses one LXC would not take" {
    btn_is_node_base keel-mariadb-ci-36301670829-1
    btn_is_node_base node.example
    ! btn_is_node_base Keel
    ! btn_is_node_base -leading-dash
    ! btn_is_node_base ""
}

# --- the declared list ------------------------------------------------

@test "expands a role list into one role per line, in order" {
    run btn_roles "primary replica"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = primary ]
    [ "${lines[1]}" = replica ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "allows the same role three times, because Galera needs that" {
    run btn_roles "galera galera galera"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "collapses repeated spaces and a tab in a declared list" {
    run btn_roles "  primary   replica  "
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "refuses an empty role list and names what is missing" {
    run btn_roles ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"role list is empty"* ]]
}

@test "refuses a word that is not a role name" {
    run btn_roles "primary Replica"
    [ "$status" -eq 1 ]
    [[ "$output" == *"'Replica' is not a role name"* ]]
}

@test "refuses more nodes than the ceiling, on a host other people share" {
    run btn_roles "a b c d e f"
    [ "$status" -eq 1 ]
    [[ "$output" == *"6 nodes asked for, 5 is the ceiling"* ]]
}

@test "counts the nodes a list asks for" {
    run btn_node_count "primary replica"
    [ "$status" -eq 0 ]
    [ "$output" = 2 ]
    run btn_node_count "galera galera galera"
    [ "$output" = 3 ]
}

@test "counting refuses a list it would refuse to expand" {
    run btn_node_count "primary Replica"
    [ "$status" -eq 1 ]
}

# --- node names -------------------------------------------------------

@test "names a node after the base and its index" {
    run btn_node_name keel-mariadb-ci-7-1 2
    [ "$status" -eq 0 ]
    [ "$output" = keel-mariadb-ci-7-1-2 ]
}

@test "refuses to name a node from a base LXC would not accept" {
    run btn_node_name Keel 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a container name base"* ]]
}

@test "refuses a node index that is not a positive number" {
    run btn_node_name keel 0
    [ "$status" -eq 1 ]
    [[ "$output" == *"'0' is not a node index"* ]]
    run btn_node_name keel two
    [ "$status" -eq 1 ]
}

@test "builds the topology as index, name and role" {
    run btn_nodes keel-ci "primary replica"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "1 keel-ci-1 primary" ]
    [ "${lines[1]}" = "2 keel-ci-2 replica" ]
}

@test "the topology refuses a bad role list" {
    run btn_nodes keel-ci ""
    [ "$status" -eq 1 ]
}

@test "the topology refuses a base that cannot produce node names" {
    run btn_nodes BASE "primary"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a container name base"* ]]
}

# --- addressing the other node ----------------------------------------

@test "finds the one node holding a role" {
    nodes=$(btn_nodes keel-ci "primary replica")
    run btn_role_node "$nodes" replica
    [ "$status" -eq 0 ]
    [ "$output" = keel-ci-2 ]
}

@test "ignores a blank line in the topology" {
    run btn_role_node "$(printf '1 keel-ci-1 primary\n\n2 keel-ci-2 replica\n')" primary
    [ "$status" -eq 0 ]
    [ "$output" = keel-ci-1 ]
}

@test "finds a role in a topology that already carries addresses" {
    run btn_role_node "$(printf '1 keel-ci-1 primary fc42::1\n2 keel-ci-2 replica fc42::2\n')" replica
    [ "$status" -eq 0 ]
    [ "$output" = keel-ci-2 ]
}

@test "refuses to guess when no node holds the role" {
    nodes=$(btn_nodes keel-ci "primary replica")
    run btn_role_node "$nodes" arbiter
    [ "$status" -eq 1 ]
    [[ "$output" == *"no node holds the role 'arbiter'"* ]]
}

@test "refuses to guess when several nodes hold the role" {
    nodes=$(btn_nodes keel-ci "galera galera galera")
    run btn_role_node "$nodes" galera
    [ "$status" -eq 1 ]
    [[ "$output" == *"3 nodes hold the role 'galera'"* ]]
}

# --- what a node is told ----------------------------------------------

@test "a peer variable is the role in upper case with dashes flattened" {
    run btn_peer_var data-node
    [ "$status" -eq 0 ]
    [ "$output" = KEEL_PEER_DATA_NODE ]
}

@test "a peer variable refuses a role name it cannot become" {
    run btn_peer_var "Data node"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a role name"* ]]
}

@test "a node is told its name, role, index and how many there are" {
    run btn_node_env 2 keel-ci-2 replica 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"KEEL_NODE_NAME=keel-ci-2"* ]]
    [[ "$output" == *"KEEL_NODE_ROLE=replica"* ]]
    [[ "$output" == *"KEEL_NODE_INDEX=2"* ]]
    [[ "$output" == *"KEEL_NODE_COUNT=2"* ]]
}

@test "the node file refuses an index or a count that is not a number" {
    run btn_node_env 0 keel-ci-1 primary 2
    [ "$status" -eq 1 ]
    [[ "$output" == *"positive index and count"* ]]
    run btn_node_env 1 keel-ci-1 primary many
    [ "$status" -eq 1 ]
}

@test "the node file refuses a bad container name or role" {
    run btn_node_env 1 Keel primary 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"container name and a role name"* ]]
    run btn_node_env 1 keel-ci-1 Primary 1
    [ "$status" -eq 1 ]
}

@test "the peers file lists every node by index and each unique role once" {
    lines_in=$(printf '%s\n%s\n' \
        "1 keel-ci-1 primary fc42:5009:ba4b:5ab0::1" \
        "2 keel-ci-2 replica fc42:5009:ba4b:5ab0::2")
    run btn_peers_env "$lines_in"
    [ "$status" -eq 0 ]
    [[ "$output" == *"KEEL_NODE_COUNT=2"* ]]
    [[ "$output" == *"KEEL_NODE_1_NAME=keel-ci-1"* ]]
    [[ "$output" == *"KEEL_NODE_1_ROLE=primary"* ]]
    [[ "$output" == *"KEEL_NODE_1_ADDR=fc42:5009:ba4b:5ab0::1"* ]]
    [[ "$output" == *"KEEL_NODE_2_ADDR=fc42:5009:ba4b:5ab0::2"* ]]
    [[ "$output" == *"KEEL_PEER_PRIMARY=fc42:5009:ba4b:5ab0::1"* ]]
    [[ "$output" == *"KEEL_PEER_REPLICA=fc42:5009:ba4b:5ab0::2"* ]]
}

@test "a role three nodes share gets no single peer variable" {
    lines_in=$(printf '%s\n\n%s\n%s\n' \
        "1 keel-ci-1 galera fc42::1" \
        "2 keel-ci-2 galera fc42::2" \
        "3 keel-ci-3 galera fc42::3")
    run btn_peers_env "$lines_in"
    [ "$status" -eq 0 ]
    [[ "$output" == *"KEEL_NODE_COUNT=3"* ]]
    [[ "$output" == *"KEEL_NODE_3_ADDR=fc42::3"* ]]
    [[ "$output" != *"KEEL_PEER_GALERA"* ]]
}

@test "the peers file refuses an address that is not an IPv6 literal" {
    run btn_peers_env "1 keel-ci-1 primary 10.0.0.1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not an IPv6 literal"* ]]
}

@test "the peers file refuses a role it cannot turn into a variable" {
    run btn_peers_env "1 keel-ci-1 Primary fc42::1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a role name"* ]]
}

# --- IPv6 literals and the reachability probe -------------------------

@test "an IPv6 literal is a literal, and a name or an IPv4 address is not" {
    btn_is_ipv6_literal fc42:5009:ba4b:5ab0::2
    btn_is_ipv6_literal ::1
    ! btn_is_ipv6_literal localhost
    ! btn_is_ipv6_literal 127.0.0.1
    ! btn_is_ipv6_literal "fc42::1/64"
    ! btn_is_ipv6_literal ""
}

@test "the probe is a bash TCP connect to a literal address, unbracketed" {
    run btn_tcp_probe_argv fc42:5009:ba4b:5ab0::2 3306
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = timeout ]
    [ "${lines[1]}" = 5 ]
    [ "${lines[2]}" = bash ]
    [ "${lines[3]}" = -c ]
    [ "${lines[4]}" = 'exec 3<>"/dev/tcp/$0/$1"' ]
    [ "${lines[5]}" = fc42:5009:ba4b:5ab0::2 ]
    [ "${lines[6]}" = 3306 ]
}

@test "the probe takes its own timeout" {
    run btn_tcp_probe_argv ::1 3306 12
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = 12 ]
}

@test "the probe refuses a name, so no resolver can choose IPv4 for it" {
    run btn_tcp_probe_argv replica.example.org 3306
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not an IPv6 literal to probe"* ]]
}

@test "the probe refuses a port that is not a port" {
    run btn_tcp_probe_argv ::1 0
    [ "$status" -eq 1 ]
    [[ "$output" == *"'0' is not a port"* ]]
    run btn_tcp_probe_argv ::1 70000
    [ "$status" -eq 1 ]
    [[ "$output" == *"'70000' is not a port"* ]]
}

@test "the probe refuses a timeout that is not a number of seconds" {
    run btn_tcp_probe_argv ::1 3306 soon
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a number of seconds"* ]]
}

# --- the job summary --------------------------------------------------

@test "the summary rows come from the same lines the test used" {
    lines_in=$(printf '%s\n\n%s\n' \
        "1 keel-ci-1 primary fc42::1" \
        "2 keel-ci-2 replica fc42::2")
    run btn_summary_rows "$lines_in"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = '| 1 | `primary` | `keel-ci-1` | `fc42::1` |' ]
    [ "${lines[1]}" = '| 2 | `replica` | `keel-ci-2` | `fc42::2` |' ]
}

@test "the summary shows a dash for a node with no address yet" {
    run btn_summary_rows "1 keel-ci-1 primary"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = '| 1 | `primary` | `keel-ci-1` | `-` |' ]
}

#!/usr/bin/env bats
# The expect script of console_script run by a real expect against a fake
# console (tests/fixtures/commission/fake-console.sh): which keys reach
# which screen. It needs expect, as the PVE host has it; without expect it
# is skipped.

setup() {
    command -v expect >/dev/null || skip "no expect here"
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$BATS_TEST_TMPDIR"
    # shellcheck source=../lib/commission/console.sh
    . "$REPO/lib/commission/console.sh"
    export KC_CONSOLE_TIMEOUT=4 KC_CONSOLE_STEPS=40 KC_NODE_WAIT=8 KC_VMID=9001 KC_LOGIN_SECRET=x KC_TSV=
    : > "$TMP/questions"
    : > "$TMP/keys"
}

# run_console ANSWERS SCREENS: the script of ANSWERS against the screens
run_console() {
    printf '%s' "$1" > "$TMP/answers"
    printf '%s' "$2" > "$TMP/screens"
    console_script "$TMP/questions" "$TMP/answers" \
        | sed "s|pct console 9001|$REPO/tests/fixtures/commission/fake-console.sh $TMP/keys $TMP/screens|" \
        > "$TMP/console.exp"
    run timeout 120 expect "$TMP/console.exp"
}

@test "the box titled Installation mode after the menu gets no keys, and the Role menu gets its own" {
    # keel-init shows the output of the Mode choice in a box of the same
    # title; its match took the Role screen, and the Role menu got the keys
    # of the Mode (BR1, 2026-11-06)
    run_console $'mode\tInstallation mode\tC\\r\nrole\tRole of this node\tP\\r\n' \
        $'menu Installation mode\nbox Installation mode\nmenu Role of this node\n'
    echo "$output"
    [ "$(cat "$TMP/keys")" = $'Installation mode\tC\nRole of this node\tP' ]
    [[ $output == *KC_DONE* ]]
    [ "$(grep -c 'KC_SEEN' <<< "$output")" -eq 2 ]
}

@test "two screens of one prompt get its answers in the order of the contract" {
    # the primary of cloud advanced invites the replica, then the witness
    run_console $'invite\tInvite a node\tA\\r\ninvite2\tInvite a node\tB\\r\n' \
        $'menu Invite a node\nmenu Invite a node\n'
    echo "$output"
    [ "$(cat "$TMP/keys")" = $'Invite a node\tA\nInvite a node\tB' ]
    [[ $output == *"KC_SEEN invite"* ]]
    [[ $output == *"KC_SEEN invite2"* ]]
}

@test "a hotkey of two letters reaches a menu that does not read yet, one letter at a time" {
    # sent at once, "CC" went to a menu that did not read yet and the Enter
    # took Simple (LNPP cloud advanced, BR2, 2026-11-06)
    run_console $'mode\tInstallation mode\tCC\\r\n' $'slow Installation mode\n'
    echo "$output"
    [ "$(cat "$TMP/keys")" = $'Installation mode\tCC' ]
}


# shellcheck shell=bash
# The single quoted strings are expect and guest scripts: they expand there.
# shellcheck disable=SC2016
# The operator at the console: keel-commission logs in as root the way an
# operator does after `pct create` (a full login, with the profile, on a
# terminal of 40 rows and 120 columns, like the Proxmox console) and
# answers keel-init with the answers of the contract.
#
# The run is an expect script that runs on the PVE host. It prints marker
# lines that console_parse reads back:
#
#   KC_CONFCONSOLE the login opened confconsole before keel-init ran
#   KC_HINT        the login said to run keel-init, before anything ran it
#   KC_SEEN ID     the question ID was on the screen and was answered
#   KC_LAUNCH      the shell prompt came back before any question: the
#                  login did not start keel-init, so the script typed it
#   KC_DONE        the shell prompt came back after keel-init
#   KC_STUCK       too many screens went by without an end
#   KC_EOF         the session ended before the shell prompt came back
#
# A screen that is no question of the contract gets Enter, which takes its
# default, after KC_CONSOLE_TIMEOUT seconds of no change.

# console_script QUESTIONS: print the expect script. QUESTIONS has one
# "ID<TAB>PROMPT<TAB>ANSWER" line per question, the answer already resolved.
console_script() {
    local fmt
    printf 'set timeout %s\n' "$KC_CONSOLE_TIMEOUT"
    printf 'set stty_init "rows 40 columns 120"\n'
    printf 'set launched 0\nset steps 0\n'
    # every screen counts, so no loop between screens runs for ever
    printf 'proc step {} { global steps; incr steps; if {$steps > %s} { puts "\\nKC_STUCK"; exit 0 } }\n' \
        "$KC_CONSOLE_STEPS"
    # quiet: true when the screen stays still for 2 seconds. A prompt that is
    # followed by more output was drawn under a program still running
    # (confconsole), and keys typed then go to that program. -notransfer
    # leaves that output to the patterns, so no question is lost.
    printf 'proc quiet {} { expect -timeout 2 -notransfer -re {.+} { return 0 } timeout { return 1 } eof { return 1 } }\n'
    # pct enter gives a root shell; exec login replaces it by a full login,
    # which runs the profile as the Proxmox console does. The first prompt
    # is the one of pct enter, and is not the end of anything.
    printf 'spawn -noecho env TERM=xterm pct enter %s\n' "$KC_VMID"
    printf 'expect -re {#\\s*(\\x1b\\[[0-9;]*m)*\\s*$}\nsleep 1\n'
    printf 'send -- "exec login -f root\\r"\n'
    printf 'expect {\n'
    # confconsole is no question: a login that opens it and not keel-init
    # is recorded, and it is left as an operator leaves it, by its Advanced
    # Menu and Quit. Escape only moves between its menus, and killing it
    # leaves its dialog on the terminal (both measured on BR2, 2026-11-05).
    # The screen is read to its end before a key is sent: Quit when the
    # Advanced Menu is up, y when it asks whether to quit (No is its
    # default), Enter on the first screen (its one button is Advanced
    # Menu), and Escape back from any other, so no other entry of
    # confconsole is ever chosen (an early Enter chose Networking and asked
    # DHCP again and again, BR2 2026-11-05).
    printf '    -ex {really want to} { step; sleep 0.5; send -- "y"; exp_continue }\n'
    printf '    -ex {Configuration Console} { step; if {!$launched} { puts "\\nKC_CONFCONSOLE" }\n'
    printf '        expect -timeout 2 -ex {really want to} { sleep 0.5; send -- "y" } -re {Quit the configuration console} { send -- "Q"; sleep 0.5; send -- "\\r" } -re {<Advanced Menu>} { send -- "\\r" } timeout { send -- "\\033" }\n'
    printf '        exp_continue }\n'
    fmt='    -ex {%s} { step; puts "\\nKC_SEEN %s"; set launched 1; send -- "%s\\r"; exp_continue }\n'
    awk -F'\t' -v fmt="$fmt" '{ printf fmt, $2, $1, $3 }' "$1"
    printf '    -ex {keel-init} { if {!$launched} { puts "\\nKC_HINT" }; exp_continue }\n'
    printf '    -re {#\\s*(\\x1b\\[[0-9;]*m)*\\s*$} {\n'
    printf '        if {![quiet]} { step; exp_continue }\n'
    printf '        if {!$launched} { set launched 1; puts "\\nKC_LAUNCH"; send -- "keel-init\\r"; exp_continue }\n'
    printf '        puts "\\nKC_DONE"; send -- "exit\\r"; sleep 1; send -- "exit\\r"; expect eof\n'
    printf '    }\n'
    printf '    timeout { step; send -- "\\r"; exp_continue }\n'
    printf '    eof { puts "\\nKC_EOF" }\n'
    printf '}\n'
}

# console_run SCRIPT TRANSCRIPT: run the expect script on the PVE host and
# keep what the screen showed.
console_run() {
    pve 'f=$(mktemp); cat > "$f"; expect "$f"; rc=$?; rm -f "$f"; exit $rc' \
        < "$1" > "$2" 2>&1
}

# console_parse TRANSCRIPT QUESTIONS: record what the console did.
console_parse() {
    local raw="$1" transcript="${1%.log}.txt" id prompt first_seen launch qlines line
    # the screen as text: the escape sequences out, one marker per line
    sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\x1b[()][0-9A-B]//g' "$raw" | LC_ALL=C tr -cd '[:print:]\n' > "$transcript"
    first_seen=$(grep -n '^KC_SEEN ' "$transcript" | head -1 | cut -d: -f1)
    launch=$(grep -n '^KC_LAUNCH' "$transcript" | head -1 | cut -d: -f1)
    if grep -q '^KC_HINT' "$transcript"; then
        record pass login.keel-init "the login says to run keel-init"
    elif [ -n "$first_seen" ] && { [ -z "$launch" ] || [ "$first_seen" -lt "$launch" ]; }; then
        record pass login.keel-init "the login starts keel-init"
    elif grep -q '^KC_CONFCONSOLE' "$transcript"; then
        record fail login.keel-init "the login opens confconsole, and neither starts keel-init nor says to run it"
    else
        record fail login.keel-init "the login neither starts keel-init nor says to run it"
    fi
    mapfile -t qlines < "$2"
    for line in "${qlines[@]}"; do
        id="${line%%$'\t'*}"
        prompt="${line#*$'\t'}"
        prompt="${prompt%%$'\t'*}"
        if grep -qx "KC_SEEN $id" "$transcript"; then
            record pass "keel-init.asked.$id" "$prompt"
        else
            record fail "keel-init.asked.$id" "keel-init never showed '$prompt'"
        fi
    done
    if grep -q '^KC_DONE' "$transcript"; then
        record pass keel-init.finished "the shell prompt came back"
    else
        record fail keel-init.finished \
            "$(grep -oE '^KC_(STUCK|EOF)' "$transcript" | head -1 || true): keel-init did not come back to the shell"
    fi
    if grep -qE 'fatal \[|Traceback' "$transcript"; then
        record fail keel-init.no-fatal "$(grep -oE '(fatal \[[^]]*\].{0,100}|Traceback.*)' "$transcript" | head -1)"
    else
        record pass keel-init.no-fatal "no fatal and no traceback on the screen"
    fi
}

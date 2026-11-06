# shellcheck shell=bash
# The single quoted strings are expect and guest scripts: they expand there.
# shellcheck disable=SC2016
# The operator at the console: keel-commission logs in as root on the
# console of the container, tty1, which is the console of the Proxmox web
# interface (pct console), with the password pct create gave, on a
# terminal of 40 rows and 120 columns, and answers keel-init with the
# answers of the contract.
#
# The run is an expect script that runs on the PVE host. It prints marker
# lines that console_parse reads back:
#
#   KC_NOLOGIN     the console gave no login prompt, or refused the password
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

# console_script QUESTIONS [ANSWERS]: print the expect script. QUESTIONS has
# one "ID<TAB>PROMPT<TAB>ANSWER" line per question, the answer already
# resolved. ANSWERS has the screens of a node of a cloud mode (Mode, Role,
# Join a mesh, ...), one "ID<TAB>PROMPT<TAB>KEYS" line each, KEYS a Tcl
# string body. The invite lines and the VIP that a capture of the contract
# finds on the screen are printed as KC_INVITE and KC_VIP lines.
console_script() {
    local fmt what regex captures
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
    # settle: the rest of the screen, read until it stays still for a
    # second. A title is drawn before the text of its box, so a question is
    # told from the menu of the same title only once the box is all there.
    printf 'proc settle {} { set s ""; expect -timeout 1 -re {.+} { append s $expect_out(buffer); exp_continue } timeout {} eof {}; return $s }\n'
    # pct console is tty1 of the container. Enter shows the login prompt
    # again; the password is the one pct create gave, which is not a
    # secret of the contract, so a proof cannot pass on it.
    printf 'spawn -noecho env TERM=xterm pct console %s\n' "$KC_VMID"
    # The first boot hands tty1 to confconsole --usage (inithooks.service),
    # and the login prompt comes when the operator leaves it with Quit, its
    # one button: Enter, once its title is on the screen. Enter on a screen
    # with no prompt draws it again.
    printf 'set tries 0\nsleep 1\nsend -- "\\r"\n'
    printf 'expect -timeout 15 -re {login: *$} { send -- "root\\r" } -ex {appliance services} { sleep 1; send -- "\\r"; exp_continue } timeout { incr tries; if {$tries > 8} { puts "\\nKC_NOLOGIN"; exit 0 }; send -- "\\r"; exp_continue }\n'
    printf 'expect -timeout 30 -ex {Password:} { send -- "%s\\r" } timeout { puts "\\nKC_NOLOGIN"; exit 0 }\n' \
        "$KC_LOGIN_SECRET"
    printf 'expect {\n'
    printf '    -ex {Login incorrect} { puts "\\nKC_NOLOGIN"; exit 0 }\n'
    # a capture comes before any answer, which would take its screen
    mapfile -t captures < <(grep $'^capture\t' <<< "$KC_TSV" | cut -f2-)
    for regex in "${captures[@]}"; do
        IFS=$'\t' read -r what regex group <<< "$regex"
        printf '    -re {%s} { puts "\\nKC_%s $expect_out(%s,string)"; exp_continue }\n' "$regex" "${what^^}" "$group"
    done
    # a screen of the node and a choice of keel-init get their keys once the
    # screen stays still: a title is drawn before its menu, and keys sent on
    # the title were lost, so the Mode screen of a cloud node chose nothing
    # (BR1, 2026-11-06). Then they get their keys as they
    # are: no field to empty and no Enter after them
    awk -F'\t' 'FILENAME != ARGV[1] || $4 == "choice" { printf "    -ex {%s} { step; set launched 1; settle; puts \"\\nKC_SEEN %s\"; send -- \"%s\"; exp_continue }\n", $2, $1, $3 }' \
        "$1" "${2:-/dev/null}"
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
    # A password of keel-init comes first as a menu of the same title,
    # Generate or Manual (get_password of libinithooks). Enter there takes
    # Generate, and the machine gets a password nobody typed (BR2,
    # 2026-11-05): the menu gets M and Enter, Manual. Then the password box
    # and its confirmation get the answer. Each answer is typed into an
    # emptied field: an input box can come with a value in it.
    fmt='    -ex {%s} { step; set launched 1; set s "$expect_out(buffer)[settle]"; if {[string match {*Choose how to set this password*} $s]} { send -- "M"; sleep 0.3; send -- "\\r" } else { puts "\\nKC_SEEN %s"; send -- "[string repeat "\\x7f" 80]%s\\r" }; exp_continue }\n'
    awk -F'\t' -v fmt="$fmt" '$4 != "choice" { printf fmt, $2, $1, $3 }' "$1"
    printf '    -ex {keel-init} { if {!$launched} { puts "\\nKC_HINT" }; exp_continue }\n'
    printf '    -re {#\\s*(\\x1b\\[[0-9;]*m)*\\s*$} {\n'
    printf '        if {![quiet]} { step; exp_continue }\n'
    printf '        if {!$launched} { set launched 1; puts "\\nKC_LAUNCH"; send -- "keel-init\\r"; exp_continue }\n'
    # exit logs out to the login prompt of tty1; Ctrl-a q leaves pct console
    printf '        puts "\\nKC_DONE"; send -- "exit\\r"; sleep 1; send -- "\\001q"; expect eof\n'
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

# console_frames TRANSCRIPT TABLE: the screens of the console as text
# frames, one for each answered screen: KC_DIR/screens/NN-ID.txt holds what
# the console showed since the frame before, and a row of the guide names
# it with the answer, masked. TABLE is answers_table's (vm.sh).
console_frames() {
    local id keys i ids
    mkdir -p "$KC_DIR/screens"
    # the last 60 lines before each KC_SEEN, the size of the terminal and more
    awk -v dir="$KC_DIR/screens" '/^KC_SEEN / { n++; f = sprintf("%s/%02d-%s.txt", dir, n, $2); for (i = (c > 60 ? c - 59 : 1); i <= c; i++) print buf[i] > f; close(f); c = 0; next } /^KC_/ { next } { buf[++c] = $0 }' "$1"
    mapfile -t ids < <(sed -n 's/^KC_SEEN //p' "$1")
    for i in "${!ids[@]}"; do
        id="${ids[$i]}"
        keys=$(awk -F'\t' -v id="$id" '$1 == id { print $3; exit }' "$2")
        screen_row "$(printf '%02d-%s.txt' "$((i + 1))" "$id")" "$keys"
    done
}

# console_parse TRANSCRIPT QUESTIONS [ANSWERS]: record what the console did.
console_parse() {
    local raw="$1" transcript="${1%.log}.txt" id prompt first_seen launch qlines line
    # the screen as text: the escape sequences out, one marker per line
    sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\x1b[()][0-9A-B]//g' "$raw" | LC_ALL=C tr -cd '[:print:]\n' > "$transcript"
    if grep -q '^KC_NOLOGIN' "$transcript"; then
        record fail console.login "no root login on tty1 with the password pct create gave"
    else
        record pass console.login "root logged in on tty1"
    fi
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
    # the node's own screens (ANSWERS, when there is one) count as questions
    mapfile -t qlines < <(cat "${3:-/dev/null}" "$2")
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

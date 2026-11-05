# shellcheck shell=bash
# The web screenshots of a pass: the pages the contract's screenshots list
# names (the application, its backend before and after the login, Webmin),
# as a TurnKey appliance gallery shows them. Headless Chromium runs here,
# beside keel-commission, and reaches the machine through a SOCKS tunnel
# that ssh opens through the PVE host (ssh -N -D): the browser asks for
# the machine's own address, so a page that sends it to its own name or
# address still loads. The pictures go to KC_DIR/screens/web-NN-NAME.png.

KC_WEBSHOT="${KC_WEBSHOT:-python3 -I $KC_LIB/webshot.py}"

# web_address: the address of the machine: its first stable global IPv6
# address, else its first global IPv4 one. IPv6 first: on BR1 the PVE host
# reaches a guest on its VLAN by IPv6 only (2026-11-05).
web_address() {
    printf '%s\n' "ip -o -6 addr show scope global | grep -v temporary | awk '{ sub(\"/.*\", \"\", \$4); print \$4 }'" \
        "ip -o -4 addr show scope global | awk '{ sub(\"/.*\", \"\", \$4); print \$4 }'" \
        | guest_sh 2>/dev/null | head -1
}

# web_tunnel PORT: a SOCKS proxy on 127.0.0.1:PORT through the PVE host,
# KC_TUNNEL or else KC_PVE with ssh's -N -D. Prints its pid; fails when
# the port does not open in 15 seconds.
web_tunnel() {
    local pid tries=0
    # shellcheck disable=SC2086
    ${KC_TUNNEL:-$KC_PVE} -N -D "127.0.0.1:$1" </dev/null >/dev/null 2>&1 &
    pid=$!
    until (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -gt 15 ] || ! kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            return 1
        fi
        sleep 1
    done
    echo "$pid"
}

# web_shots: take the screenshots of the contract and add them to the
# guide. The password of a login goes to the browser from the environment
# (KC_SECRET_NAME): no file and no command line has it.
web_shots() {
    local rows addr port pid rc=0
    rows=$(grep $'^shot\t' <<< "$KC_TSV") || return 0
    addr=$(web_address)
    if [ -z "$addr" ]; then
        record fail web.screenshots "the machine has no global address"
        return 0
    fi
    port=$((20000 + RANDOM % 20000))
    if ! pid=$(web_tunnel "$port"); then
        record fail web.screenshots "no SOCKS tunnel through the PVE host"
        return 0
    fi
    # shellcheck disable=SC2086
    KC_WEB_PROXY="socks5://127.0.0.1:$port" $KC_WEBSHOT "$addr" "$KC_DIR/screens" 1 \
        <<< "$rows" > "$KC_WORK/web.tsv" 2> "$KC_WORK/web.err" || rc=$?
    kill "$pid" 2>/dev/null
    # the guide's rows: the file is under screens/ of the machine
    awk -F'\t' -v OFS='\t' '{ $3 = "screens/" $3; print }' "$KC_WORK/web.tsv" >> "$KC_DIR/screens.tsv"
    if [ "$rc" = 0 ]; then
        record pass web.screenshots "$(wc -l < "$KC_WORK/web.tsv") pages of $addr"
    else
        record fail web.screenshots "$(head -1 "$KC_WORK/web.err")"
    fi
}

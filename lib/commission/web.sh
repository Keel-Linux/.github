# shellcheck shell=bash
# The web screenshots of a pass: the pages the contract's screenshots list
# names (the application, its backend before and after the login, Webmin),
# as a TurnKey appliance gallery shows them. Headless Chromium runs here,
# beside keel-commission, and reaches the machine through a SOCKS tunnel
# that ssh opens through the PVE host (ssh -N -D): the browser asks for
# the machine's own address, so a page that sends it to its own name or
# address still loads. The pictures go to KC_DIR/screens/web-NN-NAME.png.

KC_WEBSHOT="${KC_WEBSHOT:-python3 -I $KC_LIB/webshot.py}"

# web_addresses: the addresses of the machine, its stable global IPv6 ones
# first, then its global IPv4 ones, one a line.
web_addresses() {
    printf '%s\n' "ip -o -6 addr show scope global | grep -v temporary | awk '{ sub(\"/.*\", \"\", \$4); print \$4 }'" \
        "ip -o -4 addr show scope global | awk '{ sub(\"/.*\", \"\", \$4); print \$4 }'" \
        | guest_sh 2>/dev/null
}

# web_address PORT: the first address of the machine that the PVE host
# reaches on PORT, else the first address. The sites differ: on BR1 the
# PVE host reaches a guest on its VLAN by IPv6 only, on BR2 by IPv4 only
# (2026-11-05 and 2026-11-06), and the tunnel goes through the PVE host.
web_address() {
    local addr first="" addrs
    addrs=$(web_addresses)
    while read -r addr; do
        [ -n "$addr" ] || continue
        [ -n "$first" ] || first=$addr
        # kc-probe names the probe for the tests' PVE host
        if pve "kc_probe=1 timeout 5 bash -c '</dev/tcp/\$0/\$1' '$addr' '$1'" </dev/null >/dev/null 2>&1; then
            echo "$addr"
            return 0
        fi
    done <<< "$addrs"
    [ -z "$first" ] || echo "$first"
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

# web_first_port ROWS: the port of the first screenshot, 443 unless named
web_first_port() {
    local port
    port=$(head -1 <<< "$1" | cut -f4)
    echo "${port:-443}"
}

# web_rows: the screenshots of this machine. A node of a cloud pass with
# screenshots of its own (nshot lines) takes them in place of the
# contract's: the replica cannot record a login, and shows a notice
# instead (BR2, 2026-11-06).
web_rows() {
    local own
    own=$(grep -F "nshot"$'\t'"${KC_NODE:-}"$'\t' <<< "$KC_TSV" | grep $'^nshot\t')
    if [ -n "${KC_NODE:-}" ] && [ -n "$own" ]; then
        sed $'s/^nshot\t[^\t]*\t/shot\t/' <<< "$own"
    else
        grep $'^shot\t' <<< "$KC_TSV"
    fi
}

# web_shots: take the screenshots of the contract and add them to the
# guide. The password of a login goes to the browser from the environment
# (KC_SECRET_NAME): no file and no command line has it.
web_shots() {
    local rows addr port pid rc=0
    rows=$(web_rows) || return 0
    addr=$(web_address "$(web_first_port "$rows")")
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

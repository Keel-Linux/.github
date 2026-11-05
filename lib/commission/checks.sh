# shellcheck shell=bash
# The single quoted strings are expect and guest scripts: they expand there.
# shellcheck disable=SC2016
# The checks of keel-commission. Each one runs inside the machine through
# guest_sh and writes one line to the record with record().
#
# The record is KC_RECORD, one line per check: "pass|fail<TAB>CHECK<TAB>DETAIL".
# A secret value never goes to the record, to the transcript or to stdout.

# record pass|fail CHECK DETAIL
record() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$KC_RECORD"
    printf '%-4s  %-40s %s\n' "$1" "$2" "$3"
}

# in_guest SECRET SCRIPT: run SCRIPT in the machine with SECRET in the
# environment variable SECRET, so it is on no command line.
in_guest() {
    { printf 'export SECRET=%q\n' "$1"; printf '%s\n' "$2"; } | guest_sh >/dev/null 2>&1
}

# check_proof SECRET_NAME KIND ARG1 ARG2 ARG3: prove the secret by a login
# with it.
check_proof() {
    local name="$1" kind="$2" a1="$3" a2="$4" a3="$5" value script
    value=$(secret_value "$name")
    case "$kind" in
        shadow)
            script="h=\$(getent shadow $(printf %q "$a1") | cut -d: -f2); perl -e 'exit(crypt(\$ENV{SECRET}, \$ARGV[0]) eq \$ARGV[0] ? 0 : 1)' \"\$h\""
            ;;
        mysql)
            script="MYSQL_PWD=\"\$SECRET\" mysql --protocol=TCP -h $(printf %q "${a2:-127.0.0.1}") -u $(printf %q "$a1") -N -e 'SELECT 1'"
            ;;
        pgsql)
            script="PGPASSWORD=\"\$SECRET\" psql -h $(printf %q "${a2:-127.0.0.1}") -U $(printf %q "$a1") -d $(printf %q "${a3:-postgres}") -Atc 'SELECT 1'"
            ;;
        command)
            script="$a1"
            ;;
    esac
    if in_guest "$value" "$script"; then
        record pass "proof.$name.$kind" "a login with the $name secret works"
    else
        record fail "proof.$name.$kind" "a login with the $name secret fails"
    fi
}

check_service() {
    if in_guest "" "systemctl is-active --quiet $(printf %q "$1")"; then
        record pass "service.$1" active
    else
        record fail "service.$1" "not active"
    fi
}

check_url() {
    local got
    got=$(printf 'curl -sk -o /dev/null -m 20 -w %%{http_code} %q\n' "$1" | guest_sh 2>/dev/null)
    if [ "$got" = "$2" ]; then
        record pass "url.$1" "$got"
    else
        record fail "url.$1" "answers ${got:-nothing}, wants $2"
    fi
}

check_forbid() {
    local kind="$1" name="$2" script
    case "$kind" in
        mysql-database)
            script="test -z \"\$(mysql -N -e \"SHOW DATABASES LIKE '$name'\" 2>/dev/null)\"" ;;
        pgsql-database)
            script="test -z \"\$(runuser -u postgres -- psql -Atc \"SELECT 1 FROM pg_database WHERE datname='$name'\" 2>/dev/null)\"" ;;
        hook)
            script="test ! -e /usr/lib/inithooks/firstboot.d/$name" ;;
        path)
            script="test ! -e $(printf %q "$name")" ;;
    esac
    if in_guest "" "$script"; then
        record pass "forbid.$kind.$name" "absent"
    else
        record fail "forbid.$kind.$name" "present, and the contract forbids it"
    fi
}

# check_hygiene: what every first boot must leave behind, whatever the
# appliance.
check_hygiene() {
    local line
    line=$(printf 'grep -aE "fatal \\[|Traceback" /var/log/inithooks.log | head -1\n' | guest_sh 2>/dev/null)
    if [ -z "$line" ]; then
        record pass firstboot.no-fatal "no fatal in /var/log/inithooks.log"
    else
        record fail firstboot.no-fatal "$line"
    fi
    line=$(printf 'command -v postconf >/dev/null || { echo NOPOSTFIX; exit; }; echo "$(postconf -h myhostname) $(hostname) $(hostname -f)"\n' | guest_sh 2>/dev/null)
    if [ "$line" = NOPOSTFIX ]; then
        record pass postfix.myhostname "no postfix in the image"
    else
        # shellcheck disable=SC2086
        set -- $line
        if [ -n "${1:-}" ] && { [ "$1" = "${2:-}" ] || [ "$1" = "${3:-}" ]; }; then
            record pass postfix.myhostname "$1"
        else
            record fail postfix.myhostname "postfix says '${1:-}', the machine is '${3:-${2:-}}'"
        fi
    fi
}

# check_mail: after KC_MAIL_WAIT seconds, in which the cron has run, root
# has no mail. A mail to root on a fresh machine is an error report.
check_mail() {
    local count
    sleep "$KC_MAIL_WAIT"
    count=$(printf 'grep -c "^From " /var/mail/root 2>/dev/null || true\n' | guest_sh 2>/dev/null)
    if [ "${count:-0}" -eq 0 ]; then
        record pass mail.root-empty "no mail to root after ${KC_MAIL_WAIT}s"
    else
        record fail mail.root-empty "$count mails to root after ${KC_MAIL_WAIT}s"
    fi
}

# check_not_deferred HOOK: in a preseeded pass no question is left for
# keel-init.
check_not_deferred() {
    if in_guest "" "! grep -q '\\[$1\\] not asked' /var/log/inithooks.log"; then
        record pass "preseed.answered.$1" "the description answered it"
    else
        record fail "preseed.answered.$1" "deferred to keel-init although the description answers it"
    fi
}

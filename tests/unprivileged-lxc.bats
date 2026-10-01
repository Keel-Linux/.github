#!/usr/bin/env bats
# unprivileged-lxc: the boot test runs as root in a user namespace, and its
# LXC commands reach a broker outside it that runs them as the runner.
#
# lxc-usernsexec, systemd-run and the LXC commands are replaced by fakes
# that record what they were asked to do, so the cases below check the
# wiring: which mappings the namespace gets, what lxc-start is given on top
# of the boot test's own config, that stdin and the exit status make the
# round trip, and that tar forgives only the device nodes.

# The stand-ins are written in single quotes on purpose: they expand when
# they run, inside the namespace.
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

ulx() {
    run "$BATS_TEST_DIRNAME/../bin/unprivileged-lxc" "$@"
}

setup() {
    TMP="$(mktemp -d)"
    SCRATCH="$TMP/scratch"
    FAKES="$TMP/fakes"
    LOG="$TMP/log"
    mkdir -p "$SCRATCH" "$FAKES"
    : > "$LOG"
    printf '%s:100000:65536\n' "$(id -un)" > "$TMP/subuid"
    printf '%s:200000:65536\n' "$(id -un)" > "$TMP/subgid"
    ULX_SUBUID="$TMP/subuid"
    ULX_SUBGID="$TMP/subgid"
    ULX_OWNER="$(id -u):$(id -g)"
    ULX_POLL=0.01
    PATH="$FAKES:$PATH"
    export TMP SCRATCH FAKES LOG ULX_SUBUID ULX_SUBGID ULX_OWNER ULX_POLL PATH

    # lxc-usernsexec: record the mappings, then run what follows --.
    cat > "$FAKES/lxc-usernsexec" <<'FAKE'
#!/bin/bash
maps=()
while [ "$1" != -- ]; do maps+=("$1"); shift; done
shift
echo "usernsexec ${maps[*]}" >> "$LOG"
exec "$@"
FAKE
    # systemd-run: record the options, then run what follows --.
    cat > "$FAKES/systemd-run" <<'FAKE'
#!/bin/bash
opts=()
while [ "$1" != -- ]; do opts+=("$1"); shift; done
shift
echo "systemd-run ${opts[*]}" >> "$LOG"
exec "$@"
FAKE
    # The real LXC commands: record the arguments and stdin, answer with
    # the exit status asked for in FAKE_STATUS_<command>.
    for command in lxc-attach lxc-info lxc-start lxc-stop; do
        cat > "$FAKES/$command" <<'FAKE'
#!/bin/bash
name=$(basename "$0")
echo "$name $*" >> "$LOG"
[ "$name" != lxc-attach ] || sed 's/^/stdin: /' >> "$LOG"
echo "$name says hello"
echo "$name complains" >&2
var=FAKE_STATUS_${name//-/_}
exit "${!var:-0}"
FAKE
    done
    chmod +x "$FAKES"/*
}

teardown() {
    [ -z "${TMP:-}" ] || rm -rf "$TMP"
}

# boot_test BODY: a stand-in for tests/boot-test.sh that runs BODY.
boot_test() {
    printf '#!/bin/bash\nset -eu\n%s\n' "$1" > "$TMP/boot-test.sh"
    chmod +x "$TMP/boot-test.sh"
}

# --- the namespace -----------------------------------------------------

@test "the command runs with the subordinate range at 0 and the runner at 65536" {
    boot_test 'echo "inside, lxc-start is $(command -v lxc-start)"'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 0 ]
    grep -qx "usernsexec -m u:0:100000:65536 -m g:0:200000:65536 -m u:65536:$(id -u):1 -m g:65536:$(id -g):1" "$LOG"
    [[ "$output" == *"inside, lxc-start is $SCRATCH/userns/bin/lxc-start"* ]]
}

@test "the command's exit status is the exit status of run" {
    boot_test 'exit 7'

    ulx run "$SCRATCH" "$TMP/boot-test.sh"

    [ "$status" -eq 7 ]
    [ ! -e "$SCRATCH/userns/broker.pid" ]
}

@test "run without a command is refused" {
    ulx run "$SCRATCH" --

    [ "$status" -eq 2 ]
    [[ "$output" == *"run needs a command"* ]]
}

@test "a relative scratch path is refused" {
    ulx run scratch -- true

    [ "$status" -eq 2 ]
    [[ "$output" == *"must be an absolute path"* ]]
}

@test "a scratch path that climbs is refused" {
    ulx cleanup "$TMP/../etc"

    [ "$status" -eq 2 ]
    [[ "$output" == *"refusing SCRATCH"* ]]
}

@test "a user without a subordinate range of 65536 ids is refused" {
    printf '%s:100000:1000\n' "$(id -un)" > "$TMP/subuid"
    boot_test 'true'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 2 ]
    [[ "$output" == *"no range of 65536 ids"* ]]
}

@test "anything else prints the usage" {
    ulx

    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: unprivileged-lxc run SCRATCH"* ]]
}

# --- the broker --------------------------------------------------------

@test "lxc-start gets the idmap and the profile, inside a delegated scope" {
    boot_test 'lxc-start -P /lxc -n box -d'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 0 ]
    grep -qx 'systemd-run --user --scope --quiet -p Delegate=yes' "$LOG"
    grep -qx 'lxc-start -s lxc.include=/usr/share/lxc/config/userns.conf -s lxc.idmap=u 0 100000 65536 -s lxc.idmap=g 0 200000 65536 -s lxc.apparmor.profile=lxc-container-default-with-nesting -s lxc.apparmor.allow_nesting=0 -P /lxc -n box -d' "$LOG"
}

@test "stdout, stderr and the exit status of a forwarded command come back" {
    boot_test 'lxc-info -P /lxc -n box -i'
    export FAKE_STATUS_lxc_info=3

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 3 ]
    [[ "$output" == *"lxc-info says hello"* ]]
    [[ "$output" == *"lxc-info complains"* ]]
    grep -qx 'lxc-info -P /lxc -n box -i' "$LOG"
}

@test "lxc-attach is given the piped stdin, inside a scope" {
    boot_test 'printf "select 1;\n" | lxc-attach -P /lxc -n box -- mysql'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 0 ]
    grep -qx 'systemd-run --user --scope --quiet' "$LOG"
    grep -qx 'lxc-attach -P /lxc -n box -- mysql' "$LOG"
    grep -qx 'stdin: select 1;' "$LOG"
}

@test "lxc-attach without piped stdin reads nothing" {
    boot_test 'lxc-attach -P /lxc -n box -- true < /dev/null'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 0 ]
    run ! grep -q '^stdin:' "$LOG"
}

@test "other LXC commands run as they are" {
    boot_test 'lxc-stop -P /lxc -n box -k'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 0 ]
    grep -qx 'lxc-stop -P /lxc -n box -k' "$LOG"
    run ! grep -q '^systemd-run' "$LOG"
}

@test "a command that is not forwarded is refused by the broker" {
    boot_test 'ln -s "$(readlink -f "$(command -v lxc-start)")" "$ULX_DIR/bin/lxc-create"
lxc-create -n box'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"lxc-create is not forwarded"* ]]
}

@test "a malformed request id is ignored and the next one served" {
    boot_test 'echo "../escape" > "$ULX_DIR/fifo"
lxc-stop -P /lxc -n box'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"ignoring request '../escape'"* ]]
    grep -qx 'lxc-stop -P /lxc -n box' "$LOG"
}

# --- the client --------------------------------------------------------

@test "an LXC link outside run says so" {
    ln -s "$BATS_TEST_DIRNAME/../bin/unprivileged-lxc" "$TMP/lxc-info"

    run env -u ULX_DIR -u ULX_BROKER "$TMP/lxc-info" -n box

    [ "$status" -eq 2 ]
    [[ "$output" == *"not under 'unprivileged-lxc run'"* ]]
}

@test "a client whose broker is gone stops waiting" {
    ln -s "$BATS_TEST_DIRNAME/../bin/unprivileged-lxc" "$TMP/lxc-info"
    mkdir -p "$TMP/dir/requests"
    : > "$TMP/dir/fifo"

    run env ULX_DIR="$TMP/dir" ULX_BROKER=999999999 "$TMP/lxc-info" -n box

    [ "$status" -eq 2 ]
    [[ "$output" == *"the broker has gone away"* ]]
}

# --- tar ---------------------------------------------------------------

# fake_tar STATUS STDERR: the tar the link runs.
fake_tar() {
    printf '#!/bin/bash\necho "tar $*" >> "$LOG"\nprintf "%%b" "%s" >&2\nexit %s\n' \
        "$2" "$1" > "$FAKES/real-tar"
    chmod +x "$FAKES/real-tar"
    ln -s "$BATS_TEST_DIRNAME/../bin/unprivileged-lxc" "$TMP/tar"
    export ULX_TAR="$FAKES/real-tar"
}

@test "tar that succeeds is left alone" {
    fake_tar 0 ''

    run "$TMP/tar" --extract --file=-

    [ "$status" -eq 0 ]
    grep -qx 'tar --extract --file=-' "$LOG"
}

@test "tar refused only device nodes: the extract succeeds and says how many" {
    fake_tar 2 '/usr/bin/tar: ./dev/null: Cannot mknod: Operation not permitted\ntar: ./dev/zero: Cannot mknod: Operation not permitted\n/usr/bin/tar: Exiting with failure status due to previous errors\n'

    run "$TMP/tar" --extract

    [ "$status" -eq 0 ]
    [[ "$output" == *"tar skipped 2 device nodes"* ]]
}

@test "tar refused a device node and something else: it fails with both" {
    fake_tar 2 'tar: ./dev/null: Cannot mknod: Operation not permitted\ntar: ./etc/x: Cannot open: Permission denied\ntar: Exiting with failure status due to previous errors\n'

    run "$TMP/tar" --extract

    [ "$status" -eq 2 ]
    [[ "$output" == *"./etc/x: Cannot open"* ]]
    [[ "$output" == *"./dev/null: Cannot mknod"* ]]
}

@test "tar failing without a word about device nodes still fails" {
    fake_tar 2 'tar: Exiting with failure status due to previous errors\n'

    run "$TMP/tar" --extract

    [ "$status" -eq 2 ]
    [[ "$output" != *"skipped"* ]]
}

# --- cleanup -----------------------------------------------------------

@test "cleanup stops the broker and removes the scratch tree in the namespace" {
    mkdir -p "$SCRATCH/userns" "$SCRATCH/lxc/box/rootfs"
    sleep 300 &
    broker=$!
    echo "$broker" > "$SCRATCH/userns/broker.pid"

    ulx cleanup "$SCRATCH"

    [ "$status" -eq 0 ]
    [ ! -e "$SCRATCH" ]
    grep -q '^usernsexec -m u:0:100000:65536' "$LOG"
    run wait "$broker"
    [ "$status" -eq 143 ]
}

@test "cleanup of a scratch tree that is already gone does nothing" {
    rm -rf "$SCRATCH"

    ulx cleanup "$SCRATCH"

    [ "$status" -eq 0 ]
    [ ! -s "$LOG" ]
}

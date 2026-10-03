#!/usr/bin/env bats
# unprivileged-lxc: the boot test runs as root in a user namespace, and its
# LXC commands reach a broker outside it that runs them as the runner.
#
# lxc-usernsexec, systemd-run and the LXC commands are replaced by fakes
# that record what they were asked to do, so the cases below check the
# wiring: which mappings the namespace gets, what lxc-start is given on top
# of the boot test's own config, that stdin and the exit status make the
# round trip, that the first lxc-start of a container is preceded by an
# upgrade boot with the first boot masked, and that tar forgives only the
# device nodes. bin/upgrade-rootfs only ever reaches the container on
# stdin here; tests/upgrade-rootfs.bats tests it.

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
    # An lxc-attach with --clear-env is the broker's, during the upgrade
    # boot: it answers as a container whose systemd is FAKE_SYSTEM, whose
    # first boot units are FAKE_MASKED, and whose upgrade prints
    # FAKE_CHANGES and exits FAKE_STATUS_script.
    for command in lxc-attach lxc-info lxc-start lxc-stop lxc-wait; do
        cat > "$FAKES/$command" <<'FAKE'
#!/bin/bash
name=$(basename "$0")
echo "$name $*" >> "$LOG"
if [ "$name" = lxc-attach ] && [[ " $* " == *" --clear-env "* ]]; then
    case " $* " in
        *" is-system-running "*) echo "${FAKE_SYSTEM:-running}" ;;
        *" is-enabled "*)
            for unit in "${@: -4}"; do echo "${FAKE_MASKED:-masked-runtime}"; done ;;
        *" sh -c "*" /tmp/keel-ci-upgrade/archive "*)
            tar -tf - | sed 's/^/archived: /' >> "$LOG"; exit "${FAKE_STATUS_archive:-0}" ;;
        *" sh -c "*) sed "s/^/copied ${*: -1}: /" >> "$LOG"; exit "${FAKE_STATUS_copy:-0}" ;;
        *" bash -s "*)
            sed 's/^/script: /' >> "$LOG"
            printf '%b' "${FAKE_CHANGES-}"
            echo "the upgrade says what it does" >&2
            exit "${FAKE_STATUS_script:-0}" ;;
    esac
    exit 0
fi
[ "$name" != lxc-stop ] || [[ " $* " != *" -t "* ]] || exit "${FAKE_STATUS_clean_stop:-0}"
[ "$name" != lxc-attach ] || sed 's/^/stdin: /' >> "$LOG"
echo "$name says hello"
echo "$name complains" >&2
var=FAKE_STATUS_${name//-/_}
exit "${!var:-0}"
FAKE
    done
    # curl -fsS ... -o FILE URL: the archive, as the runner fetches it.
    cat > "$FAKES/curl" <<'FAKE'
#!/bin/bash
url=${*: -1}
out=$(sed -n 's/.* -o \([^ ]*\) .*/\1/p' <<< "$*")
echo "curl $url" >> "$LOG"
[[ $url != *"${FAKE_CURL_FAILS:-never}"* ]] || exit 22
mkdir -p "${out%/*}"
case "$url" in
    */InRelease) echo "signed index" > "$out" ;;
    */Packages) printf 'Package: keel\nFilename: %s\n\nPackage: inithooks\nFilename: pool/main/i/inithooks/inithooks_23_all.deb\n' \
                    "${FAKE_FILENAME:-pool/main/k/keel/keel_0.15.4_all.deb}" > "$out" ;;
    *) echo "a package" > "$out" ;;
esac
FAKE
    chmod +x "$FAKES"/*
    # bin/upgrade-rootfs as the container receives it: on stdin.
    echo "THE UPGRADE SCRIPT" > "$TMP/upgrade-rootfs"
    ULX_UPGRADE="$TMP/upgrade-rootfs"
    ULX_PAUSE=0
    FAKE_CHANGES='inithooks\t21\t23\nnew-thing\t-\t2\n'
    unset GITHUB_STEP_SUMMARY ULX_DEBS
    export ULX_UPGRADE ULX_PAUSE FAKE_CHANGES
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

# --- the upgrade boot before the first start ---------------------------

MASK='lxc.init.cmd=/sbin/init systemd.mask=inithooks.service systemd.mask=keel-host-keys.service systemd.mask=turnkey-init-fence.service systemd.mask=systemd-machine-id-commit.service'

@test "the first start of a container is an upgrade boot, with the first boot masked" {
    boot_test 'lxc-start -P /lxc -n box -d
lxc-stop -P /lxc -n box
lxc-start -P /lxc -n box -d'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 0 ]
    grep -qx "lxc-start -s lxc.include=/usr/share/lxc/config/userns.conf -s lxc.idmap=u 0 100000 65536 -s lxc.idmap=g 0 200000 65536 -s lxc.apparmor.profile=lxc-container-default-with-nesting -s lxc.apparmor.allow_nesting=0 -s $MASK -P /lxc -n box -d" "$LOG"
    grep -qx 'lxc-wait -P /lxc -n box -s RUNNING -t 60' "$LOG"
    grep -qx 'lxc-attach -P /lxc -n box --clear-env -- env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8 DEBIAN_FRONTEND=noninteractive HOME=/root bash -s --' "$LOG"
    grep -qx 'script: THE UPGRADE SCRIPT' "$LOG"
    [ "$(grep -c -- "-s $MASK" "$LOG")" -eq 1 ]
    [ "$(grep -c '^lxc-start' "$LOG")" -eq 3 ]
    # upgrade boot, its stop, then the start the test asked for
    [ "$(grep -E '^lxc-(start|stop)' "$LOG" | sed -n 2p)" = 'lxc-stop -P /lxc -n box -t 30' ]
    [ "$(grep -E '^lxc-(start|stop)' "$LOG" | sed -n 3p)" = 'lxc-start -s lxc.include=/usr/share/lxc/config/userns.conf -s lxc.idmap=u 0 100000 65536 -s lxc.idmap=g 0 200000 65536 -s lxc.apparmor.profile=lxc-container-default-with-nesting -s lxc.apparmor.allow_nesting=0 -P /lxc -n box -d' ]
    [[ "$output" == *"box: 2 packages differ from the published layer"* ]]
    [[ "$output" == *"  inithooks 21 -> 23"* ]]
    [[ "$output" == *"the upgrade says what it does"* ]]
}

@test "each container gets its upgrade boot, found by the long options too" {
    boot_test 'lxc-start --lxcpath /lxc --name box -d
lxc-start --lxcpath=/lxc --name=other -d'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 0 ]
    grep -q -- "-s $MASK -P /lxc -n box -d\$" "$LOG"
    grep -q -- "-s $MASK -P /lxc -n other -d\$" "$LOG"
}

@test "the changed versions go to the job summary, a table only when there are some" {
    export GITHUB_STEP_SUMMARY="$TMP/summary"
    boot_test 'lxc-start -P /lxc -n box -d'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 0 ]
    grep -qx '### box, upgraded before its first boot' "$GITHUB_STEP_SUMMARY"
    grep -qx '| `inithooks` | `21` | `23` |' "$GITHUB_STEP_SUMMARY"
    grep -qx '| `new-thing` | `-` | `2` |' "$GITHUB_STEP_SUMMARY"

    : > "$GITHUB_STEP_SUMMARY"
    export FAKE_CHANGES=''
    boot_test 'lxc-start -P /lxc -n other -d'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 0 ]
    grep -q '^0 packages differ' "$GITHUB_STEP_SUMMARY"
    run ! grep -q '^| Package' "$GITHUB_STEP_SUMMARY"
}

@test "the packages in ULX_DEBS are copied in and handed to the upgrade" {
    mkdir -p "$TMP/debs"
    echo "deb bytes" > "$TMP/debs/keel-core_0.1.3_all.deb"
    : > "$TMP/debs/keel-core_0.1.3.dsc"
    boot_test 'lxc-start -P /lxc -n box -d'

    ULX_DEBS="$TMP/debs" ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 0 ]
    grep -qx 'copied keel-core_0.1.3_all.deb: deb bytes' "$LOG"
    grep -q 'sh -c mkdir -p "$1" && cat > "$1/$2" sh /tmp/keel-ci-upgrade/debs keel-core_0.1.3_all.deb$' "$LOG"
    grep -q 'bash -s -- /tmp/keel-ci-upgrade/debs/keel-core_0.1.3_all.deb$' "$LOG"
}

@test "a package that cannot be copied in stops the upgrade" {
    mkdir -p "$TMP/debs"
    : > "$TMP/debs/keel-core_0.1.3_all.deb"
    export FAKE_STATUS_copy=1
    boot_test 'lxc-start -P /lxc -n box -d'

    ULX_DEBS="$TMP/debs" ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"keel-core_0.1.3_all.deb could not be copied into box"* ]]
    run ! grep -q '^script:' "$LOG"
}

@test "the runner fetches the archive once, and each container gets a copy" {
    boot_test 'lxc-start -P /lxc -n box -d
lxc-start -P /lxc -n other -d'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 0 ]
    [ "$(grep -c '^curl https://archive.keellinux.org/dists/trixie-testing/InRelease$' "$LOG")" -eq 1 ]
    grep -qx 'curl https://archive.keellinux.org/dists/trixie/main/binary-amd64/Packages' "$LOG"
    [ "$(grep -c '^curl https://archive.keellinux.org/pool/main/k/keel/keel_0.15.4_all.deb$' "$LOG")" -eq 1 ]
    [ "$(grep -c '^archived: ./dists/trixie-testing/InRelease$' "$LOG")" -eq 2 ]
    [ "$(grep -c '^archived: ./pool/main/i/inithooks/inithooks_23_all.deb$' "$LOG")" -eq 2 ]
    [ "$(grep -n '^archived:' "$LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n '^script:' "$LOG" | head -1 | cut -d: -f1)" ]
}

@test "an archive that cannot be fetched starts nothing" {
    export FAKE_CURL_FAILS=trixie-testing/InRelease
    boot_test 'lxc-start -P /lxc -n box -d'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot fetch https://archive.keellinux.org/dists/trixie-testing/InRelease"* ]]
    run ! grep -q '^lxc-start' "$LOG"
}

@test "an index that names anything but a pool file is refused" {
    export FAKE_FILENAME=pool/../../etc/passwd.deb
    boot_test 'lxc-start -P /lxc -n box -d'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"the trixie index names 'pool/../../etc/passwd.deb', not a pool file"* ]]
    run ! grep -q 'etc/passwd' <(grep '^curl' "$LOG")
    run ! grep -q '^lxc-start' "$LOG"
}

@test "an archive that cannot be copied in stops the upgrade" {
    export FAKE_STATUS_archive=1
    boot_test 'lxc-start -P /lxc -n box -d'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"the archive could not be copied into box"* ]]
    run ! grep -q '^script:' "$LOG"
}

@test "a ULX_DEBS with no package in it is refused, nothing is started" {
    mkdir -p "$TMP/debs"
    boot_test 'lxc-start -P /lxc -n box -d'

    ULX_DEBS="$TMP/debs" ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"holds no .deb; box is not started"* ]]
    run ! grep -q '^lxc-start' "$LOG"
}

@test "a failed upgrade stops the container and does not start it" {
    export FAKE_STATUS_script=100
    boot_test 'lxc-start -P /lxc -n box -d'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"the upgrade inside box failed"* ]]
    [[ "$output" == *"lxc-start: box is not started"* ]]
    [ "$(grep -c '^lxc-start' "$LOG")" -eq 1 ]
    grep -qx 'lxc-stop -P /lxc -n box -t 30' "$LOG"
    [ ! -e "$SCRATCH/userns/upgraded/box.changes" ]
}

@test "a container whose clean stop fails is killed" {
    export FAKE_STATUS_clean_stop=1
    boot_test 'lxc-start -P /lxc -n box -d'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 0 ]
    grep -qx 'lxc-stop -P /lxc -n box -k' "$LOG"
}

@test "a first boot that is not masked is not upgraded" {
    export FAKE_MASKED=enabled
    boot_test 'lxc-start -P /lxc -n box -d'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"the first boot of box is not held: enabled"* ]]
    run ! grep -q '^script:' "$LOG"
}

@test "a container that never settles is not upgraded" {
    export FAKE_SYSTEM=starting ULX_TRIES=3
    boot_test 'lxc-start -P /lxc -n box -d'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"box did not settle with a network"* ]]
    [ "$(grep -c 'is-system-running' "$LOG")" -eq 3 ]
}

@test "a container that does not reach RUNNING is not upgraded" {
    export FAKE_STATUS_lxc_wait=1
    boot_test 'lxc-start -P /lxc -n box -d'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"box did not reach RUNNING"* ]]
}

@test "an upgrade boot that does not start fails lxc-start" {
    export FAKE_STATUS_lxc_start=1
    boot_test 'lxc-start -P /lxc -n box -d'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"the upgrade boot of box did not start"* ]]
    [ "$(grep -c '^lxc-start' "$LOG")" -eq 1 ]
}

@test "lxc-start without a plain container name is refused" {
    boot_test 'lxc-start -P /lxc -n ../box -d'

    ulx run "$SCRATCH" -- "$TMP/boot-test.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"-P and a plain -n are needed"* ]]
    run ! grep -q '^lxc-start' "$LOG"
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

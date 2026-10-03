#!/usr/bin/env bats
# upgrade-rootfs: inside the appliance container, the system is upgraded
# from Debian and trixie-testing and the pull request's packages installed,
# with no service started and the image's sources left alone.
#
# UR_ROOT points the script at a scratch tree instead of /. apt-get,
# dpkg-query and dpkg-deb are fakes: the installed packages are files
# under $TMP/state, which the fake apt-get changes as the real one would.
# The real run is the appliance gate's, cited in the pull request that
# added this.

# The stand-ins are written in single quotes on purpose: they expand when
# they run.
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

ur() {
    run --separate-stderr "$BATS_TEST_DIRNAME/../bin/upgrade-rootfs" "$@"
}

setup() {
    TMP="$(mktemp -d)"
    UR_ROOT="$TMP/root"
    FAKES="$TMP/fakes"
    LOG="$TMP/log"
    STATE="$TMP/state"
    SEEN="$TMP/seen"
    mkdir -p "$FAKES" "$STATE" "$SEEN" "$UR_ROOT/tmp" "$UR_ROOT/usr/sbin" \
        "$UR_ROOT/etc/apt/sources.list.d" "$UR_ROOT/var/lib/apt/lists/partial" \
        "$UR_ROOT/var/cache/apt/archives/partial"
    : > "$LOG"
    keel_sources 'Enabled: no'
    cp "$UR_ROOT/etc/apt/sources.list.d/keel.sources" "$TMP/keel.sources.image"
    # The published layer: what dpkg calls installed.
    printf 'inithooks 21\nkeel 0.15.3\nkeel-core 0.1.2\nold-thing 1\n' > "$STATE/installed"
    printf 'inithooks 23\nkeel 0.15.3\nkeel-core 0.1.2\nnew-thing 2\n' > "$STATE/upgraded"
    PATH="$FAKES:$PATH"
    export TMP UR_ROOT FAKES LOG STATE SEEN PATH

    # apt-get: record, keep what it saw, change the installed state.
    cat > "$FAKES/apt-get" <<'FAKE'
#!/bin/bash
echo "apt-get $*" >> "$LOG"
echo "apt-get talks"
cp -r "$UR_ROOT/tmp/keel-ci-upgrade/sources.list.d" "$SEEN/"
cp "$UR_ROOT/usr/sbin/policy-rc.d" "$SEEN/policy-rc.d"
: > "$UR_ROOT/var/lib/apt/lists/deb.debian.org_debian_dists_trixie_InRelease"
case " $* " in
    *" full-upgrade "*)
        cp "$STATE/upgraded" "$STATE/installed"
        : > "$UR_ROOT/var/cache/apt/archives/inithooks_23_all.deb" ;;
    *" install "*)
        for arg in "$@"; do
            case "$arg" in
                *.deb)
                    IFS=_ read -r package version _ <<< "${arg##*/}"
                    grep -v "^$package " "$STATE/installed" > "$STATE/next" || true
                    echo "$package ${FAKE_INSTALLS:-$version}" >> "$STATE/next"
                    mv "$STATE/next" "$STATE/installed" ;;
            esac
        done ;;
esac
exit "${FAKE_STATUS_apt:-0}"
FAKE
    # dpkg-query -W -f=FORMAT [PACKAGE]
    cat > "$FAKES/dpkg-query" <<'FAKE'
#!/bin/bash
if [ -n "${3-}" ]; then
    awk -v p="$3" '$1 == p { printf "%s", $2 }' "$STATE/installed"
else
    awk '{ printf "ii \t%s\t%s\n", $1, $2 }' "$STATE/installed"
    printf 'rc \tgone\t9\n'
fi
FAKE
    # dpkg-deb -f DEB FIELD, read off the name PACKAGE_VERSION_ARCH.deb
    cat > "$FAKES/dpkg-deb" <<'FAKE'
#!/bin/bash
IFS=_ read -r package version _ <<< "${2##*/}"
case "$3" in Package) echo "$package" ;; Version) echo "$version" ;; esac
FAKE
    chmod +x "$FAKES"/*
}

teardown() {
    [ -z "${TMP:-}" ] || rm -rf "$TMP"
}

# keel_sources TESTING-ENABLED [EXTRA-STANZA]: the image's keel.sources.
keel_sources() {
    cat > "$UR_ROOT/etc/apt/sources.list.d/keel.sources" <<SOURCES
Types: deb
URIs: https://archive.keellinux.org
Suites: trixie
Components: main
Enabled: yes
Signed-By: /usr/share/keyrings/keel-archive-keyring.gpg

Types: deb
URIs: https://archive.keellinux.org/
Suites: trixie-testing
Components: main
$1
Signed-By: /usr/share/keyrings/keel-archive-keyring.gpg
${2-}
SOURCES
}

# --- the sources -------------------------------------------------------

@test "apt reads the image's keel.sources, trixie-testing on, from the copy, and Debian" {
    ur

    [ "$status" -eq 0 ]
    grep -q "^apt-get -q -o Dir::Etc::SourceList=$UR_ROOT/tmp/keel-ci-upgrade/sources.list -o Dir::Etc::SourceParts=$UR_ROOT/tmp/keel-ci-upgrade/sources.list.d .* update --error-on=any\$" "$LOG"
    grep -q ' -y full-upgrade$' "$LOG"
    [ "$(sed -n '/^Suites: trixie-testing$/,/^$/p' "$SEEN/sources.list.d/keel.sources" | grep -c '^Enabled: yes$')" -eq 1 ]
    [ "$(grep -c "^URIs: file:$UR_ROOT/tmp/keel-ci-upgrade/archive\$" "$SEEN/sources.list.d/keel.sources")" -eq 2 ]
    [ "$(grep -c '^Signed-By: /usr/share/keyrings/keel-archive-keyring.gpg$' "$SEEN/sources.list.d/keel.sources")" -eq 2 ]
    run ! grep -q 'https://archive' "$SEEN/sources.list.d/keel.sources"
    grep -qx 'URIs: http://deb.debian.org/debian' "$SEEN/sources.list.d/debian.sources"
    grep -qx 'URIs: http://deb.debian.org/debian-security' "$SEEN/sources.list.d/debian.sources"
    [ "$(ls "$SEEN/sources.list.d")" = "$(printf 'debian.sources\nkeel.sources')" ]
    cmp "$TMP/keel.sources.image" "$UR_ROOT/etc/apt/sources.list.d/keel.sources"
}

@test "an image without keel.sources is refused" {
    rm "$UR_ROOT/etc/apt/sources.list.d/keel.sources"

    ur

    [ "$status" -eq 2 ]
    [[ "$stderr" == *"the image has no /etc/apt/sources.list.d/keel.sources"* ]]
    [ ! -s "$LOG" ]
}

@test "a keel.sources without trixie-testing is refused" {
    sed -i '/^$/,$d' "$UR_ROOT/etc/apt/sources.list.d/keel.sources"

    ur

    [ "$status" -eq 2 ]
    [[ "$stderr" == *"has no trixie-testing stanza"* ]]
    [ ! -s "$LOG" ]
}

@test "a keel.sources stanza without Signed-By is refused" {
    sed -i '$d' "$UR_ROOT/etc/apt/sources.list.d/keel.sources"
    sed -i '$d' "$UR_ROOT/etc/apt/sources.list.d/keel.sources"

    ur

    [ "$status" -eq 2 ]
    [[ "$stderr" == *"keel.sources is refused: stanza 2 has no Signed-By"* ]]
    [ ! -s "$LOG" ]
}

@test "a trusted or insecure keel.sources stanza is refused" {
    keel_sources 'Trusted: yes'

    ur

    [ "$status" -eq 2 ]
    [[ "$stderr" == *"stanza 2 is trusted or allows insecure"* ]]

    keel_sources 'Allow-Insecure: Yes'

    ur

    [ "$status" -eq 2 ]
    [[ "$stderr" == *"stanza 2 is trusted or allows insecure"* ]]
    [ ! -s "$LOG" ]
}

@test "a keel.sources stanza naming another host is refused" {
    keel_sources 'Enabled: yes' "
Types: deb
URIs: https://archive.keellinux.org http://elsewhere.example/keel
Suites: trixie
Components: main
Signed-By: /usr/share/keyrings/keel-archive-keyring.gpg"

    ur

    [ "$status" -eq 2 ]
    [[ "$stderr" == *"stanza 3 names http://elsewhere.example/keel"* ]]
    [ ! -s "$LOG" ]
}

# --- the upgrade -------------------------------------------------------

@test "no service starts during the upgrade, and the policy goes afterwards" {
    ur

    [ "$status" -eq 0 ]
    [ "$(cat "$SEEN/policy-rc.d")" = "$(printf '#!/bin/sh\nexit 101')" ]
    [ ! -e "$UR_ROOT/usr/sbin/policy-rc.d" ]
}

@test "the image's own policy-rc.d is put back" {
    printf '#!/bin/sh\nexit 0\n' > "$UR_ROOT/usr/sbin/policy-rc.d"

    ur

    [ "$status" -eq 0 ]
    grep -qx 'exit 101' "$SEEN/policy-rc.d"
    grep -qx 'exit 0' "$UR_ROOT/usr/sbin/policy-rc.d"
}

@test "the system keeps no lists, archives or work files of the upgrade" {
    : > "$UR_ROOT/var/lib/apt/lists/lock"

    ur

    [ "$status" -eq 0 ]
    [ ! -e "$UR_ROOT/tmp/keel-ci-upgrade" ]
    [ "$(ls "$UR_ROOT/var/lib/apt/lists")" = "$(printf 'lock\npartial')" ]
    [ "$(ls "$UR_ROOT/var/cache/apt/archives")" = partial ]
}

@test "stdout is the versions that changed, and nothing else" {
    ur

    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'inithooks\t21\t23\nnew-thing\t-\t2\nold-thing\t1\t-')" ]
    [[ "$stderr" == *"apt-get talks"* ]]
}

@test "an upgrade that changes nothing prints nothing" {
    cp "$STATE/installed" "$STATE/upgraded"

    ur

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a failed apt-get fails the upgrade and still cleans up" {
    export FAKE_STATUS_apt=100

    ur

    [ "$status" -eq 100 ]
    [ ! -e "$UR_ROOT/usr/sbin/policy-rc.d" ]
    [ ! -e "$UR_ROOT/tmp/keel-ci-upgrade" ]
}

# --- the pull request's packages ---------------------------------------

@test "the pull request's package is installed over the archive's, and logged" {
    mkdir -p "$TMP/debs"
    : > "$TMP/debs/keel-core_0.1.3_all.deb"

    ur "$TMP/debs/keel-core_0.1.3_all.deb"

    [ "$status" -eq 0 ]
    grep -q " install -y --reinstall --allow-downgrades $TMP/debs/keel-core_0.1.3_all.deb\$" "$LOG"
    [ "$(grep -n ' full-upgrade$' "$LOG" | cut -d: -f1)" -lt "$(grep -n ' install ' "$LOG" | cut -d: -f1)" ]
    [[ "$stderr" == *"installed keel-core 0.1.3 from this run's keel-core_0.1.3_all.deb"* ]]
    [[ "$output" == *"$(printf 'keel-core\t0.1.2\t0.1.3')"* ]]
}

@test "a package argument that is not a .deb file is refused" {
    : > "$TMP/notes.txt"

    ur "$TMP/notes.txt"

    [ "$status" -eq 2 ]
    [[ "$stderr" == *"'$TMP/notes.txt' is not a .deb file"* ]]
    run ! grep -q ' install ' "$LOG"
}

@test "a package that does not end up installed at its version fails" {
    mkdir -p "$TMP/debs"
    : > "$TMP/debs/keel-core_0.1.3_all.deb"
    export FAKE_INSTALLS=0.1.4

    ur "$TMP/debs/keel-core_0.1.3_all.deb"

    [ "$status" -eq 2 ]
    [[ "$stderr" == *"keel-core 0.1.3 from keel-core_0.1.3_all.deb is not what is installed (0.1.4)"* ]]
}

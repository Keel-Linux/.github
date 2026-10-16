#!/usr/bin/env bats
# staged-release-verify: the runner accepts a staged release only when its
# MANIFEST is the one the build host named, carries a good signature by
# the staging key, and lists every file in the directory with its size and
# sha256 (handbook decision 0061). gpg is real, against throwaway keys
# made in a scratch GNUPGHOME.

bats_require_minimum_version 1.5.0

srv() {
    run "$BATS_TEST_DIRNAME/../bin/staged-release-verify" "$@"
}

# make_key NAME: a signing key without a passphrase in SIGNHOME, and its
# public key, armored, at $TMP/NAME.asc.
make_key() {
    gpg --homedir "$SIGNHOME" --batch --passphrase '' \
        --quick-gen-key "$1 <$1@example.invalid>" ed25519 sign 1d 2> /dev/null
    gpg --homedir "$SIGNHOME" --batch --armor --export "$1@example.invalid" > "$TMP/$1.asc"
}

setup_file() {
    export KEYS="$BATS_FILE_TMPDIR/keys"
    export SIGNHOME="$KEYS/gnupg"
    mkdir -p "$SIGNHOME"
    chmod 700 "$SIGNHOME"
    TMP=$KEYS make_key staging
    TMP=$KEYS make_key other
}

setup() {
    TMP="$(mktemp -d)"
    DIR="$TMP/build"
    mkdir -p "$DIR/layers" "$DIR/images"
    echo "a layer" > "$DIR/layers/core.tar.zst"
    printf 'layer core\nproduct_commit 0123456789abcdef0123456789abcdef01234567\n' > "$DIR/layers/core.manifest"
    echo "an image" > "$DIR/images/debian-13-keel-core_19.0-1_amd64.tar.zst"
    export TMP DIR
}

teardown() {
    [ -z "${TMP:-}" ] || rm -rf "$TMP"
}

# manifest: the MANIFEST keel-release --staging writes over DIR.
manifest() {
    local file
    {
        printf 'release 2026-10-16\nrevision 1\nappliances core\nchannel staging\n'
        printf '\n# size sha256 path\n'
        (cd "$DIR" && find . -type f ! -name MANIFEST ! -name MANIFEST.staging.asc | sed 's|^\./||' | sort) |
            while read -r file; do
                printf '%s %s %s\n' "$(stat -c %s "$DIR/$file")" \
                    "$(sha256sum "$DIR/$file" | cut -d ' ' -f 1)" "$file"
            done
    } > "$DIR/MANIFEST"
}

# sign KEY: MANIFEST.staging.asc, a detached signature by KEY.
sign() {
    gpg --homedir "$SIGNHOME" --batch --yes --local-user "$1@example.invalid" \
        --armor --detach-sign --output "$DIR/MANIFEST.staging.asc" "$DIR/MANIFEST" 2> /dev/null
}

digest() {
    sha256sum "$DIR/MANIFEST" | cut -d ' ' -f 1
}

@test "a staged release signed by the staging key, with every digest right, passes" {
    manifest
    sign staging

    srv "$DIR" "$(digest)" "$KEYS/staging.asc"

    [ "$status" -eq 0 ]
    [[ "$output" == *"good staging signature"* ]]
    [[ "$output" == *"3 files match the MANIFEST"* ]]
    [ "${lines[-1]}" = "appliances core" ]
}

@test "a MANIFEST other than the one the build host named is refused" {
    manifest
    sign staging

    srv "$DIR" "$(printf '%064d' 0)" "$KEYS/staging.asc"

    [ "$status" -eq 3 ]
    [[ "$output" == *"is not the MANIFEST the build host named"* ]]
}

@test "a signature by another key is refused" {
    manifest
    sign other

    srv "$DIR" "$(digest)" "$KEYS/staging.asc"

    [ "$status" -eq 4 ]
    [[ "$output" == *"no good signature by the staging key"* ]]
}

@test "a missing signature is refused" {
    manifest

    srv "$DIR" "$(digest)" "$KEYS/staging.asc"

    [ "$status" -eq 4 ]
}

@test "a MANIFEST that does not say channel staging is refused" {
    manifest
    sed -i '/^channel staging$/d' "$DIR/MANIFEST"
    sign staging

    srv "$DIR" "$(digest)" "$KEYS/staging.asc"

    [ "$status" -eq 5 ]
    [[ "$output" == *"does not say channel staging"* ]]
}

@test "a file whose content changed after the signature is refused" {
    manifest
    sign staging
    echo "changed" >> "$DIR/layers/core.tar.zst"

    srv "$DIR" "$(digest)" "$KEYS/staging.asc"

    [ "$status" -eq 5 ]
    [[ "$output" == *"layers/core.tar.zst does not match the MANIFEST"* ]]
}

@test "a listed file that is missing is refused" {
    manifest
    sign staging
    rm "$DIR/images/debian-13-keel-core_19.0-1_amd64.tar.zst"

    srv "$DIR" "$(digest)" "$KEYS/staging.asc"

    [ "$status" -eq 5 ]
    [[ "$output" == *"is listed and missing"* ]]
}

@test "a path that leaves the directory is refused" {
    manifest
    printf '1 %064d ../outside\n' 0 >> "$DIR/MANIFEST"
    sign staging

    srv "$DIR" "$(digest)" "$KEYS/staging.asc"

    [ "$status" -eq 5 ]
    [[ "$output" == *"is not a path this accepts"* ]]
}

@test "a line that is not size, sha256 and path is refused" {
    manifest
    echo "nonsense" >> "$DIR/MANIFEST"
    sign staging

    srv "$DIR" "$(digest)" "$KEYS/staging.asc"

    [ "$status" -eq 5 ]
    [[ "$output" == *"is not a size, a sha256 and a path"* ]]
}

@test "a file that the MANIFEST does not list is refused" {
    manifest
    sign staging
    echo "extra" > "$DIR/layers/extra.tar.zst"

    srv "$DIR" "$(digest)" "$KEYS/staging.asc"

    [ "$status" -eq 6 ]
    [[ "$output" == *"layers/extra.tar.zst is not in the MANIFEST"* ]]
}

@test "a MANIFEST that lists no file is refused" {
    rm -r "$DIR/layers" "$DIR/images"
    manifest
    sign staging

    srv "$DIR" "$(digest)" "$KEYS/staging.asc"

    [ "$status" -eq 5 ]
    [[ "$output" == *"lists no file"* ]]
}

@test "a keyring that cannot be read is refused" {
    manifest
    sign staging
    echo "not a key" > "$TMP/bad.asc"

    srv "$DIR" "$(digest)" "$TMP/bad.asc"

    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot read the keyring"* ]]
}

@test "arguments that are not usable are refused" {
    manifest

    srv "$DIR" "short" "$KEYS/staging.asc"
    [ "$status" -eq 2 ]
    srv "$TMP/none" "$(digest)" "$KEYS/staging.asc"
    [ "$status" -eq 2 ]
    srv "$DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: staged-release-verify"* ]]
}

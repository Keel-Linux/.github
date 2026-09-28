#!/usr/bin/env bats
# appliance-gate: what the appliance gate may claim from the mirror's answer.
#
# The rule these cases hold is the one the gate broke: a check may only be
# named for what it proves. A layer that was never published was booted by
# nothing, so the job must not conclude success on its own; a layer that is
# published was built before this branch existed, so the wording must not
# read as evidence about the branch.

gate() {
    run "$BATS_TEST_DIRNAME/../bin/appliance-gate" "$@"
}

setup() {
    TMP="$(mktemp -d)"
    export TMP
    GITHUB_OUTPUT="$TMP/output"
    GITHUB_STEP_SUMMARY="$TMP/summary"
    export GITHUB_OUTPUT GITHUB_STEP_SUMMARY
    : > "$GITHUB_OUTPUT"
    : > "$GITHUB_STEP_SUMMARY"
}

teardown() {
    [ -z "${TMP:-}" ] || rm -rf "$TMP"
}

# --- the layer is published -------------------------------------------

@test "a published layer is there to be pulled, verified and booted" {
    gate 200 core https://mirror.keellinux.org/layers false

    [ "$status" -eq 0 ]
    [[ "$output" == *"answers 200"* ]]
    [[ "$output" == *"core.manifest"* ]]
    grep -qx 'published=true' "$GITHUB_OUTPUT"
}

@test "a published layer is not called evidence about the branch" {
    gate 200 core https://mirror.keellinux.org/layers false

    [ "$status" -eq 0 ]
    [[ "$output" == *"not evidence about this branch"* ]]
}

@test "the exemption is left out entirely, which is the common caller" {
    gate 200 core https://mirror.keellinux.org/layers

    [ "$status" -eq 0 ]
    grep -qx 'published=true' "$GITHUB_OUTPUT"
}

# --- the layer has never been published -------------------------------

@test "a layer that has never been published fails the job" {
    gate 404 redis https://mirror.keellinux.org/layers false

    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::"* ]]
    [[ "$output" == *"has never been published"* ]]
    [ ! -s "$GITHUB_OUTPUT" ]
}

@test "the failure says how to publish the layer and how to exempt the repository" {
    gate 404 redis https://mirror.keellinux.org/layers false

    [ "$status" -eq 1 ]
    grep -q "Nothing was booted" "$GITHUB_STEP_SUMMARY"
    grep -q "bt-layer redis" "$GITHUB_STEP_SUMMARY"
    grep -q "allow_unpublished: true" "$GITHUB_STEP_SUMMARY"
}

@test "only the exact word true is the exemption" {
    gate 404 redis https://mirror.keellinux.org/layers yes

    [ "$status" -eq 1 ]
}

# --- the bootstrap exemption ------------------------------------------

@test "a declared exemption lets an unpublished layer through, booting nothing" {
    gate 404 sonewlayer https://mirror.keellinux.org/layers true

    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::"* ]]
    [[ "$output" == *"allow_unpublished"* ]]
    grep -qx 'published=false' "$GITHUB_OUTPUT"
    grep -q "Nothing was booted" "$GITHUB_STEP_SUMMARY"
}

@test "the one path that passes without booting says how it fails to expire" {
    gate 404 sonewlayer https://mirror.keellinux.org/layers true

    [ "$status" -eq 0 ]
    grep -q "blocks no merge" "$GITHUB_STEP_SUMMARY"
    grep -q "A typo in" "$GITHUB_STEP_SUMMARY"
}

@test "the exemption becomes an error once the layer is published" {
    gate 200 redis https://mirror.keellinux.org/layers true

    [ "$status" -eq 2 ]
    [[ "$output" == *"::error::"* ]]
    [[ "$output" == *"allow_unpublished"* ]]
    [ ! -s "$GITHUB_OUTPUT" ]
    grep -q "Remove" "$GITHUB_STEP_SUMMARY"
}

# --- the mirror is not answering yes or no ----------------------------

@test "a server error is not a skip" {
    gate 503 core https://mirror.keellinux.org/layers false

    [ "$status" -eq 3 ]
    [[ "$output" == *"answered 503"* ]]
    [ ! -s "$GITHUB_OUTPUT" ]
}

@test "a redirect or a forbidden answer is not a skip either" {
    gate 403 core https://mirror.keellinux.org/layers true

    [ "$status" -eq 3 ]
    [[ "$output" == *"answered 403"* ]]

    gate 301 core https://mirror.keellinux.org/layers false

    [ "$status" -eq 3 ]
    [[ "$output" == *"answered 301"* ]]
}

# --- arguments --------------------------------------------------------

@test "a status that is not a three digit code is a usage error" {
    gate 0 core https://mirror.keellinux.org/layers false

    [ "$status" -eq 4 ]
    [[ "$output" == *"usage:"* ]]
}

@test "a missing appliance or source is a usage error" {
    gate 200

    [ "$status" -eq 4 ]
}

# --- the decision has to be written down ------------------------------

# The one failure the first version of this script did not have: the
# append to GITHUB_OUTPUT failed, nothing was recorded, and the script
# still exited 0. Every boot step is guarded by published == 'true', so
# that is a job which skips all of them and concludes success, which is
# the defect this whole script exists to remove. ENOSPC on the runner
# that assembles multi gigabyte rootfs trees is how it happens.

@test "a decision that cannot be written down is fatal, not silent" {
    GITHUB_OUTPUT="$TMP/no-such-directory/output"

    gate 200 core https://mirror.keellinux.org/layers false

    [ "$status" -eq 5 ]
    [[ "$output" == *"cannot record the decision"* ]]
    [[ "$output" == *"booted nothing"* ]]
}

@test "the same holds for the exemption, which is the path that passes" {
    GITHUB_OUTPUT="$TMP/no-such-directory/output"

    gate 404 redis https://mirror.keellinux.org/layers true

    [ "$status" -eq 5 ]
}

# --- outside Actions --------------------------------------------------

@test "with no step output or summary to write to, the summary is printed instead" {
    unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY
    gate 404 redis https://mirror.keellinux.org/layers true

    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing was booted"* ]]
}

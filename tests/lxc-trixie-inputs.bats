#!/usr/bin/env bats
# lxc-trixie-inputs: what lxc-trixie.yml accepts before it creates a
# container. The case worth a test above all is the artifact directory: /src
# holds the checkout, .git included, so an artifact-dir that names /src in
# any spelling would publish the repository's git configuration.

bats_require_minimum_version 1.5.0

check() {
    # Only the four inputs are cleared: kcov follows the script through
    # the environment, so env -i would hide it from the coverage report.
    run env -u RUN -u SCRIPT -u DOWNLOAD_DIR -u ARTIFACT_DIR "$@" \
        "$BATS_TEST_DIRNAME/../bin/lxc-trixie-inputs"
}

@test "commands and a directory below /src pass" {
    check RUN="make" ARTIFACT_DIR=dist DOWNLOAD_DIR=dist

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a script and no artifact pass" {
    check SCRIPT=ci/build.sh DOWNLOAD_DIR=dist

    [ "$status" -eq 0 ]
}

@test "run and script together are refused" {
    check RUN=make SCRIPT=ci/build.sh DOWNLOAD_DIR=dist

    [ "$status" -eq 1 ]
    [[ "$output" == *"set run or script, not both"* ]]
}

@test "neither run nor script is refused" {
    check DOWNLOAD_DIR=dist

    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::set run or script"* ]]
}

@test "artifact-dir . is refused: it would upload the checkout and .git" {
    check RUN=make ARTIFACT_DIR=. DOWNLOAD_DIR=dist

    [ "$status" -eq 1 ]
    [[ "$output" == *"artifact-dir '.' names the top of the repository"* ]]
}

@test "every other spelling of the top of /src is refused as artifact-dir" {
    local dir
    for dir in ./ .// ././ / dist/..; do
        check RUN=make ARTIFACT_DIR="$dir" DOWNLOAD_DIR=dist
        echo "artifact-dir '$dir': $output"
        [ "$status" -eq 1 ]
    done
}

@test "an absolute artifact-dir is refused" {
    check RUN=make ARTIFACT_DIR=/etc DOWNLOAD_DIR=dist

    [ "$status" -eq 1 ]
    [[ "$output" == *"must be relative"* ]]
}

@test "a path that climbs out of /src is refused" {
    check RUN=make ARTIFACT_DIR=dist/../../root DOWNLOAD_DIR=dist

    [ "$status" -eq 1 ]
    [[ "$output" == *"may not climb"* ]]
}

@test "a path with a character outside the set is refused" {
    check SCRIPT='ci/$(id).sh' DOWNLOAD_DIR=dist

    [ "$status" -eq 1 ]
    [[ "$output" == *"may only hold"* ]]
}

@test "a script that names the top of the repository is refused" {
    check SCRIPT=. DOWNLOAD_DIR=dist

    [ "$status" -eq 1 ]
    [[ "$output" == *"script '.' names the top"* ]]
}

@test "download-dir may be the top of /src" {
    check RUN=make DOWNLOAD_DIR=.

    [ "$status" -eq 0 ]
}

@test "every finding is reported, not only the first" {
    check ARTIFACT_DIR=. DOWNLOAD_DIR=/tmp

    [ "$status" -eq 1 ]
    [ "$(grep -c '::error::' <<< "$output")" -eq 3 ]
}

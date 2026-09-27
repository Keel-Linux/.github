#!/usr/bin/env bats
# require-changelog: what may be merged without a changelog entry
#
# The rule exists because a change that ships and has no entry cannot be
# installed: it sits on the default branch, the gate is green, and no machine
# ever sees it. Every case below is one of those states.

load helpers

setup() { repo_setup; }
teardown() { repo_teardown; }

script() {
    run "$BATS_TEST_DIRNAME/../bin/require-changelog" "$@"
}

@test "a change that ships with a new greater entry passes" {
    printf 'changed\n' > thing.py
    bump 1.1
    commit "change and bump"

    script "$BASE" "$HEAD_SHA"

    [ "$status" -eq 0 ]
    [[ "$output" == *"1.0 to 1.1"* ]]
}

@test "a change that ships without a new entry is refused" {
    printf 'changed\n' > thing.py
    commit "change only"

    script "$BASE" "$HEAD_SHA"

    [ "$status" -eq 1 ]
    [[ "$output" == *"still starts with the entry of the base branch"* ]]
    [[ "$output" == *"thing.py"* ]]
}

@test "a test only change needs no entry" {
    printf 'more test\n' > tests/test_thing.py
    commit "tests only"

    script "$BASE" "$HEAD_SHA"

    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing that ships changed"* ]]
}

@test "documentation, CI, README, coverage, licence and gitignore need no entry" {
    printf 'docs\n' > docs/guide.md
    printf 'ci\n' > .github/workflows/tests.yml
    printf 'readme\n' > README.md
    printf 'cov\n' > COVERAGE.md
    printf 'licence\n' > LICENSE
    printf 'ignore\n' > .gitignore
    commit "nothing that ships"

    script "$BASE" "$HEAD_SHA"

    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing that ships changed"* ]]
}

@test "a changelog only change passes" {
    bump 1.1
    commit "bump only"

    script "$BASE" "$HEAD_SHA"

    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing that ships changed"* ]]
}

@test "an entry that does not increase the version is refused" {
    printf 'changed\n' > thing.py
    bump 0.9
    commit "change and go backwards"

    script "$BASE" "$HEAD_SHA"

    [ "$status" -eq 2 ]
    [[ "$output" == *"not greater"* ]]
}

@test "a rewritten entry at the same version is refused" {
    printf 'changed\n' > thing.py
    printf 'thing (1.0) trixie; urgency=high\n\n  * reworded\n' > debian/changelog
    commit "same version, different line"

    script "$BASE" "$HEAD_SHA"

    [ "$status" -eq 2 ]
    [[ "$output" == *"not greater"* ]]
}

@test "a repository without a changelog requires nothing" {
    git rm -q debian/changelog
    printf 'changed\n' > thing.py
    commit "no changelog at all"

    script "$BASE" "$HEAD_SHA"

    [ "$status" -eq 0 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "a changelog added by the pull request passes" {
    git rm -q debian/changelog
    commit "drop the changelog"
    base_without="$HEAD_SHA"
    mkdir -p debian
    printf 'thing (1.0) trixie; urgency=low\n\n  * first\n' > debian/changelog
    printf 'changed\n' > thing.py
    commit "add the changelog and change code"

    script "$base_without" "$HEAD_SHA"

    [ "$status" -eq 0 ]
    [[ "$output" == *"none to 1.0"* ]]
}

@test "the changelog path and the exempt expression can be given" {
    mkdir -p pkg
    printf 'thing (2.0) trixie; urgency=low\n\n  * first\n' > pkg/changelog
    printf 'vendor\n' > vendor.js
    commit "another layout"

    script "$BASE" "$HEAD_SHA" pkg/changelog '^(vendor\.js|debian/)'

    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing that ships changed"* ]]
}

@test "a missing argument is a usage error" {
    script "$BASE"

    [ "$status" -eq 3 ]
    [[ "$output" == *"usage:"* ]]
}

@test "a commit that is not here is refused" {
    printf 'changed\n' > thing.py
    commit "change"

    script 0000000000000000000000000000000000000000 "$HEAD_SHA"

    [ "$status" -eq 3 ]
    [[ "$output" == *"is not here"* ]]
}

@test "outside a git repository it exits 3" {
    cd "$TMP" || return 1
    mkdir -p elsewhere
    cd elsewhere || return 1
    run env GIT_CEILING_DIRECTORIES="$TMP" \
        "$BATS_TEST_DIRNAME/../bin/require-changelog" a b

    [ "$status" -eq 3 ]
    [[ "$output" == *"not a git repository"* ]]
}

@test "a version in the source name is read as the upstream part" {
    printf 'thing-18.1 (1) turnkey; urgency=low\n\n  * old\n' > debian/changelog
    printf 'code\n' > thing.py
    commit "the 18.1 state"
    base_18="$HEAD_SHA"
    printf 'thing-19.0 (1) turnkey; urgency=low\n\n  * rebuilt on the new base\n\nthing-18.1 (1) turnkey; urgency=low\n\n  * old\n' > debian/changelog
    printf 'changed\n' > thing.py
    commit "the 19.0 rebuild"

    script "$base_18" "$HEAD_SHA"

    [ "$status" -eq 0 ]
    [[ "$output" == *"18.1-1 to 19.0-1"* ]]
}

@test "a revision that goes backwards is still refused when the name carries the version" {
    printf 'thing-19.0 (2) turnkey; urgency=low\n\n  * two\n' > debian/changelog
    printf 'code\n' > thing.py
    commit "revision two"
    base_two="$HEAD_SHA"
    printf 'thing-19.0 (1) turnkey; urgency=low\n\n  * back to one\n' > debian/changelog
    printf 'changed\n' > thing.py
    commit "revision one again"

    script "$base_two" "$HEAD_SHA"

    [ "$status" -eq 2 ]
    [[ "$output" == *"not greater"* ]]
}

@test "a name with no version in it keeps the Debian reading" {
    printf 'thing (1.0) trixie; urgency=low\n\n  * one\n' > debian/changelog
    printf 'code\n' > thing.py
    commit "plain debian"
    base_plain="$HEAD_SHA"
    printf 'thing (1.1) trixie; urgency=low\n\n  * two\n\nthing (1.0) trixie; urgency=low\n\n  * one\n' > debian/changelog
    printf 'changed\n' > thing.py
    commit "plain debian bumped"

    script "$base_plain" "$HEAD_SHA"

    [ "$status" -eq 0 ]
    [[ "$output" == *"1.0 to 1.1"* ]]
}

# Shared helpers for the bats tests of this repository.

# repo_setup: a scratch git repository with a package and a changelog, and
# BASE pointing at its first commit.
repo_setup() {
    TMP="$(mktemp -d)"
    export TMP
    cd "$TMP" || return 1
    git init -q -b main
    git config user.name "Test"
    git config user.email "test@example.invalid"
    mkdir -p debian tests docs .github/workflows
    printf 'thing (1.0) trixie; urgency=low\n\n  * first\n' > debian/changelog
    printf 'code\n' > thing.py
    printf 'test\n' > tests/test_thing.py
    git add -A
    git commit -q -m "first"
    BASE="$(git rev-parse HEAD)"
    export BASE
}

repo_teardown() {
    cd / || true
    [ -z "${TMP:-}" ] || rm -rf "$TMP"
}

# commit MESSAGE: commit whatever is in the tree and export HEAD.
commit() {
    git add -A
    git commit -q -m "$1"
    HEAD_SHA="$(git rev-parse HEAD)"
    export HEAD_SHA
}

# bump VERSION: put a new entry on top of the changelog.
bump() {
    local version="$1" rest
    rest="$(cat debian/changelog)"
    printf 'thing (%s) trixie; urgency=low\n\n  * changed\n\n%s\n' \
        "$version" "$rest" > debian/changelog
}

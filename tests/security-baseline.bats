#!/usr/bin/env bats
# security-baseline: which findings of a scanner fail the security check
#
# The check fails on exactly the findings that nobody has decided about yet:
# those outside the repository's baseline. A baseline entry is a decision,
# so one without a justification is refused rather than read as silence.

bats_require_minimum_version 1.5.0

setup() {
    TMP="$(mktemp -d)"
    cd "$TMP" || return 1
    git init -q -b main
    mkdir -p bin lib tests/fixtures
    printf '#!/usr/bin/python3\nimport subprocess\nsubprocess.call(cmd, shell=True)\n' > bin/tool
    printf 'import os\nos.system(x)\n' > lib/mod.py
    printf '#!/bin/sh\necho $1\n' > bin/run
    printf '#!/usr/bin/env bash\necho hi\n' > bin/envrun
    printf 'echo plain\n' > lib/helper.sh
    printf 'not code\n' > README
    printf '#!/bin/sh\necho fixture\n' > tests/fixtures/fake.sh
    printf 'import os\n' > tests/test_mod.py
    printf 'x = 1\n' > "lib/with space.py"
    ln -s mod.py lib/link.py
    git add -A
}

teardown() {
    cd / || true
    rm -rf "$TMP"
}

sb() {
    run "$BATS_TEST_DIRNAME/../bin/security-baseline" "$@"
}

bandit_report() {
    cat > bandit.json <<'EOF'
{"errors": [], "results": [
 {"test_id": "B602", "filename": "./bin/tool", "line_number": 3,
  "issue_severity": "HIGH", "issue_text": "shell=True\twith a tab"},
 {"test_id": "B605", "filename": "lib/mod.py", "line_number": 2,
  "issue_severity": "MEDIUM", "issue_text": "os.system"}]}
EOF
}

fp() {
    local text
    text="$(sed -n "${3}p" "$2" | tr -d '[:space:]')"
    printf '%s:%s:%s\n' "$1" "${2// /%20}" "$(printf '%s' "$text" | sha256sum | cut -c1-12)"
}

@test "python targets: by extension and by interpreter, never tests or links" {
    list="$("$BATS_TEST_DIRNAME/../bin/security-baseline" targets python | tr '\0' '\n' | sort)"
    [ "$list" = "$(printf 'bin/tool\nlib/mod.py\nlib/with space.py')" ]
}

@test "shell targets: sh, bash and env bash, by extension or interpreter" {
    list="$("$BATS_TEST_DIRNAME/../bin/security-baseline" targets shell | tr '\0' '\n' | sort)"
    [ "$list" = "$(printf 'bin/envrun\nbin/run\nlib/helper.sh')" ]
}

@test "an unknown language is refused" {
    sb targets perl
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown language 'perl'"* ]]
}

@test "with no baseline every finding is new and fails" {
    bandit_report
    sb check bandit bandit.json .security-baseline
    [ "$status" -eq 1 ]
    [[ "$output" == *"bandit: 2 findings, 0 in the baseline, 2 new"* ]]
    [[ "$output" == *"::error file=bin/tool,line=3,title=bandit B602 (HIGH)::shell=True with a tab"* ]]
    [[ "$output" == *"$(fp bandit:B602 bin/tool 3) <why>"* ]]
}

@test "a justified baseline entry silences its finding, the rest still fails" {
    bandit_report
    {
        echo "# decisions"
        echo
        echo "$(fp bandit:B602 bin/tool 3)  cmd is a constant"
    } > .security-baseline
    sb check bandit bandit.json .security-baseline
    [ "$status" -eq 1 ]
    [[ "$output" == *"2 findings, 1 in the baseline, 1 new"* ]]
    [[ "$output" != *"B602 (HIGH)"* ]]
    [[ "$output" == *"B605 (MEDIUM)"* ]]
}

@test "everything in the baseline passes, and the fingerprint ignores the line number" {
    bandit_report
    {
        echo "$(fp bandit:B602 bin/tool 3) cmd is a constant"
        printf '%s\tonly the caller reaches it' "$(fp bandit:B605 lib/mod.py 2)"
    } > .security-baseline
    # The flagged line moves down: same text, same fingerprint.
    printf 'import os\n\nos.system(x)\n' > lib/mod.py
    sed -i 's/"line_number": 2/"line_number": 3/' bandit.json
    sb check bandit bandit.json .security-baseline
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 findings, 2 in the baseline, 0 new"* ]]
}

@test "an entry that matches nothing is reported as stale, not as a failure" {
    printf '{"errors": [], "results": []}' > bandit.json
    {
        echo "bandit:B101:gone.py:000000000000 it was removed"
        echo "semgrep:x:y:000000000000 another tool's entry is not stale here"
    } > .security-baseline
    sb check bandit bandit.json .security-baseline
    [ "$status" -eq 0 ]
    [[ "$output" == *"bandit: 0 findings, 0 in the baseline, 0 new"* ]]
    [[ "$output" == *"1 baseline entries match nothing"* ]]
    [[ "$output" == *"  bandit:B101:gone.py:000000000000"* ]]
    [[ "$output" != *"semgrep:x:y"* ]]
}

@test "an entry without a justification is refused" {
    bandit_report
    echo "$(fp bandit:B602 bin/tool 3)" > .security-baseline
    sb check bandit bandit.json .security-baseline
    [ "$status" -eq 2 ]
    [[ "$output" == *".security-baseline:1: the entry has no justification"* ]]
}

@test "an entry whose justification is still TODO is refused" {
    bandit_report
    printf '# x\n%s   TODO later\n' "$(fp bandit:B602 bin/tool 3)" > .security-baseline
    sb check bandit bandit.json .security-baseline
    [ "$status" -eq 2 ]
    [[ "$output" == *".security-baseline:2: the entry has no justification"* ]]
}

@test "an unreadable baseline is an error" {
    [ "$(id -u)" -ne 0 ] || skip "root reads everything"
    bandit_report
    echo "x y" > .security-baseline
    chmod 000 .security-baseline
    sb check bandit bandit.json .security-baseline
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot read the baseline"* ]]
}

@test "the SARIF holds the new findings only, with their levels" {
    bandit_report
    echo "$(fp bandit:B602 bin/tool 3) cmd is a constant" > .security-baseline
    sb check bandit bandit.json .security-baseline out.sarif
    [ "$status" -eq 1 ]
    [ "$(jq -r '.version' out.sarif)" = "2.1.0" ]
    [ "$(jq -r '.runs[0].tool.driver.name' out.sarif)" = "bandit" ]
    [ "$(jq '.runs[0].results | length' out.sarif)" -eq 1 ]
    [ "$(jq -r '.runs[0].results[0] | "\(.ruleId) \(.level) \(.locations[0].physicalLocation.region.startLine)"' out.sarif)" = "B605 warning 2" ]
    [ "$(jq -r '.runs[0].results[0].partialFingerprints["keelBaseline/v1"]' out.sarif)" = "$(fp bandit:B605 lib/mod.py 2)" ]
}

@test "with nothing new the SARIF is an empty run, which closes old alerts" {
    printf '{"errors": [], "results": []}' > bandit.json
    sb check bandit bandit.json .security-baseline out.sarif
    [ "$status" -eq 0 ]
    [ "$(jq '.runs[0].results | length' out.sarif)" -eq 0 ]
}

@test "a SARIF that cannot be written is an error" {
    bandit_report
    sb check bandit bandit.json .security-baseline no/such/dir/out.sarif
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot write no/such/dir/out.sarif"* ]]
}

@test "semgrep reports are read, an ERROR is an error in SARIF" {
    cat > semgrep.json <<'EOF'
{"errors": [], "results": [{"check_id": "python.lang.x", "path": "lib/mod.py",
  "start": {"line": 2}, "extra": {"severity": "ERROR", "message": "m\nn"}}]}
EOF
    sb check semgrep semgrep.json none out.sarif
    [ "$status" -eq 1 ]
    [[ "$output" == *"title=semgrep python.lang.x (ERROR)::m n"* ]]
    [ "$(jq -r '.runs[0].results[0].level' out.sarif)" = "error" ]
}

@test "shellcheck reports are read, codes become SC rules, info is a note" {
    cat > sc.json <<'EOF'
{"comments": [{"file": "bin/run", "line": 2, "level": "warning", "code": 2086,
  "message": "Double quote"}, {"file": "bin/run", "line": 1, "level": "info",
  "code": 1000, "message": "info"}]}
EOF
    sb check shellcheck sc.json none out.sarif
    [ "$status" -eq 1 ]
    [[ "$output" == *"title=shellcheck SC2086 (warning)::Double quote"* ]]
    [ "$(jq -r '[.runs[0].results[].level] | join(" ")' out.sarif)" = "warning note" ]
}

@test "a path with a space is written %20 in the fingerprint" {
    printf '{"results": [{"test_id": "B1", "filename": "lib/with space.py", "line_number": 1, "issue_severity": "LOW", "issue_text": "t"}]}' > b.json
    sb check bandit b.json none
    [ "$status" -eq 1 ]
    [[ "$output" == *"bandit:B1:lib/with%20space.py:"* ]]
}

@test "write lists one TODO entry per fingerprint, which check then refuses" {
    bandit_report
    sb write bandit bandit.json
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "${lines[0]}" == "$(fp bandit:B602 bin/tool 3) TODO B602 HIGH bin/tool:3: shell=True with a tab" ]]
    printf '%s\n' "${lines[@]}" > .security-baseline
    sb check bandit bandit.json .security-baseline
    [ "$status" -eq 2 ]
}

@test "write of a clean report prints nothing" {
    printf '{"results": []}' > bandit.json
    sb write bandit bandit.json
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "an unknown tool is refused" {
    bandit_report
    sb check pylint bandit.json none
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown tool 'pylint'"* ]]
}

@test "a missing report is refused" {
    sb write bandit nothing.json
    [ "$status" -eq 2 ]
    [[ "$output" == *"no report at nothing.json"* ]]
}

@test "a report that is not the tool's JSON is refused" {
    echo '{"comments": []}' > wrong.json
    sb check bandit wrong.json none
    [ "$status" -eq 2 ]
    [[ "$output" == *"wrong.json is not a bandit JSON report"* ]]
}

@test "usage errors" {
    sb
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: security-baseline targets|check|write"* ]]
    sb targets
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: security-baseline targets python|shell"* ]]
    sb check bandit
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: security-baseline check TOOL"* ]]
    sb write bandit
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: security-baseline write TOOL REPORT"* ]]
    sb lint
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown command 'lint'"* ]]
}

@test "jq is required" {
    PATH=/nonexistent sb targets python
    [ "$status" -eq 2 ]
    [[ "$output" == *"jq is required"* ]]
}

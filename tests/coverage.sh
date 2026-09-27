#!/bin/bash
# Runs the bats suite under kcov and fails when a measured file (bin/* and
# lib/*) is below the threshold: 95 percent of executed lines, the bar for
# project-authored code (decisions 0003 and 0004).
#
# lib/ is measured for the same reason bin/ is: it is shell this repository
# lends to the repositories that call the reusable workflows, so it is
# tested here rather than copied into each of them.
#
#   tests/coverage.sh [OUTDIR]     threshold from COVERAGE_THRESHOLD (default 95)
#
# Needs bats, kcov, git and dpkg (for dpkg --compare-versions).
set -euo pipefail

THRESHOLD="${COVERAGE_THRESHOLD:-95}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="${1:-$REPO/coverage}"

for tool in bats kcov git dpkg; do
    if ! command -v "$tool" >/dev/null; then
        echo "coverage.sh: $tool not found" >&2
        exit 2
    fi
done

rm -rf "$OUTDIR"
kcov --include-path="$REPO/bin,$REPO/lib" --exclude-path="$REPO/tests" \
    "$OUTDIR" bats "$REPO/tests"

REPORT="$(find "$OUTDIR" -path '*/bats.*/coverage.json' | head -1)"
if [ -z "$REPORT" ]; then
    echo "coverage.sh: no coverage.json under $OUTDIR" >&2
    exit 1
fi

# kcov writes one file per line:
#   {"file": "PATH", "percent_covered": "P", "covered_lines": "C", "total_lines": "T"},
echo
echo "kcov line coverage (threshold $THRESHOLD percent):"
awk -F'"' -v threshold="$THRESHOLD" -v repo="$REPO/" '
    /^ *\{"file":/ {
        file = $4
        sub(repo, "", file)
        percent = $8 + 0
        mark = (percent >= threshold) ? "ok" : "BELOW THRESHOLD"
        if (percent < threshold) {
            low = 1
        }
        printf "%7.2f  %4s/%-4s  %-24s %s\n", percent, $12, $16, file, mark
    }
    /^  "percent_covered":/ {
        printf "%7.2f  total\n", $4 + 0
    }
    END {
        exit low
    }' "$REPORT"

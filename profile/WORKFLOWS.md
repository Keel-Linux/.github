# Reusable workflows

Every repository in the organization calls one of these from a short workflow
of its own, with its threshold. The coverage check is a required status on the
default branch.

- `test-python.yml`: pytest under coverage.py, branch coverage, `fail-under`
  from the `threshold` input. Inputs: `threshold`, `package`, `tests`,
  `python-version`, `apt-packages`.
- `test-shell.yml`: the repository's `tests/coverage.sh` (bats under kcov)
  with `COVERAGE_THRESHOLD` exported. Inputs: `threshold`, `coverage-script`,
  `apt-packages`.
- `test-appliance.yml`: builds the appliance layer with bt-layer on the
  self-hosted LXC runner (label `keel-lxc`), verifies it, assembles it and
  boots it; the repository provides `tests/boot-test.sh`. Inputs:
  `appliance`, `parent`.

Example caller, in a repository with Python code:

```
name: tests
on:
  pull_request:
  push:
    branches: [main]
jobs:
  coverage:
    uses: keel-linux/.github/.github/workflows/test-python.yml@main
    with:
      threshold: 95
      package: keel
```

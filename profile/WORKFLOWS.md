# Reusable workflows

Every repository in the organization calls one of these from a short workflow
of its own, with its threshold. The coverage check is a required status on the
default branch (per-repository branch protection; the full procedure is in
docs/ci-cd.md of the keel repository).

## Status check names

GitHub names the check after the caller's job id and the reusable job id:
`<caller job id> / <reusable job id>`. The callers below all use the job id
`tests`, so the checks are:

| Reusable workflow | Reusable job id | Check name with caller job `tests` |
| --- | --- | --- |
| `test-python.yml` | `coverage` | `tests / coverage` |
| `test-shell.yml` | `coverage` | `tests / coverage` |
| `test-appliance.yml` | `build-and-boot` | `appliance / build-and-boot` (caller job id `appliance`) |
| `build-deb.yml` | `deb` | `package / deb` (caller job id `package`) |

Renaming a caller job renames the check and breaks the protection rule that
requires it, so keep the job id `tests`.

## This repository's own gate

`lint.yml` is not reusable: it guards the four workflows above. Every other
repository calls them at `@main`, so a mistake here breaks the gate of the
whole organization at once and nothing downstream can catch it. actionlint,
pinned by version and by digest, parses each workflow, checks the expressions,
the runner labels (`.github/actionlint.yaml` declares `keel-lxc`) and the
action inputs, and runs shellcheck over every `run` block. Any report fails
the job, informational ones included. The check is named after the job alone,
`actionlint`, because this workflow is not called through another one, and it
is required on `main`.

## require-changelog

`require-changelog.yml` is reusable and enforces one rule: a pull request that
changes a file the package ships must also add a changelog entry, with a
greater version. Changes to tests, documentation and CI ship nothing and are
exempt. Its logic is `bin/require-changelog` of this repository, which the job
checks out and runs, so the rule is a tested script rather than shell inside a
workflow. Inputs: `changelog` (default `debian/changelog`) and `exempt`, an
extended regular expression. A caller job named `package` produces the check
`package / changelog`.

The rule exists because on 2026-09-26 the Instance menu and the console mark
were merged into confconsole with no entry, so the newest installable
confconsole stayed at the previous version and neither change reached an
appliance: the code was on the default branch, the gate was green, and the
image did not have it.

## The workflows

- `test-python.yml`: pytest under coverage.py, branch coverage,
  `coverage report --fail-under=<threshold>`. Inputs: `threshold`, `package`,
  `tests` (default `tests`), `python-version` (default 3.13), `apt-packages`.
  Runs on hosted `ubuntu-latest` (a plain virtual machine). The report goes to
  the job summary and to the `coverage-report` artifact.
- `test-shell.yml`: runs the repository's coverage script (default
  `tests/coverage.sh`: bats under kcov) with the threshold exported as
  `COVERAGE_THRESHOLD`. The script must read that variable; no positional
  argument is passed. Inputs: `threshold`, `coverage-script`, `apt-packages`.
  Bootstrap rule: if the script is absent and the threshold is 0 the job
  passes with a notice (nothing is measured yet); if the script is absent and
  the threshold is above 0 the job fails. shellcheck runs first, advisory.
- `test-appliance.yml`: fetches the appliance's layers from
  `https://mirror.keellinux.org/layers` over IPv6 on the self-hosted LXC
  runner (labels `self-hosted, keel-lxc`), verifies them, assembles the chain
  into a scratch rootfs, boots it in an LXC container named after the run and
  runs the repository's `tests/boot-test.sh` against it; the container and
  the scratch tree are destroyed in a cleanup step that also runs after a
  failure. It builds nothing: the runner has no fab, deck or buildtasks, so
  the build host publishes the layers and this job consumes them. `keel`
  comes from a checkout of `keel-linux/keel` at `main`, because nothing is
  packaged or signed yet (decision 0005). Inputs: `appliance`, `parent`
  (checked against the parent the published manifest records, not used to
  fetch), `timeout` (minutes, default 60). When the layer has never been
  published, meaning its manifest answers 404, the job passes with a notice
  and says so in the job summary, so a repository can carry the gate before
  its first layer exists. Any other answer, including a name that does not
  resolve, fails the job: skipping on an outage would be a green check that
  tested nothing.
- `build-deb.yml`: `dpkg-buildpackage -us -uc -b` on the self-hosted LXC
  runner, the `.deb` uploaded as a workflow artifact (input `artifact-name`,
  default `deb`; `source-dir`; `retention-days`). Inactive until the runner
  is registered: a job targeting the `keel-lxc` label stays queued until
  GitHub cancels it after 24 hours, so callers gate it on the organization
  variable `KEEL_LXC_RUNNER` (`if: vars.KEEL_LXC_RUNNER == 'true'`), which
  the maintainer sets to `true` once the runner is online. The runner needs
  passwordless sudo for `apt-get` (build dependencies).

## Example callers

Python repository (keel, turnkey-chroot):

```yaml
name: tests
on:
  pull_request:
  push:
    branches: [main]
jobs:
  tests:
    uses: keel-linux/.github/.github/workflows/test-python.yml@main
    with:
      threshold: 95
      package: keel
```

Shell repository (tkldev, buildtasks, fab, common, inithooks, tklbam-profiles):

```yaml
name: tests
on:
  pull_request:
  push:
    branches: [master]
jobs:
  tests:
    uses: keel-linux/.github/.github/workflows/test-shell.yml@main
    with:
      threshold: 0
```

The threshold is the measured baseline from the repository's `COVERAGE.md`
and is only ever raised, never lowered (decision 0006).

Appliance repository (keel-core, keel-nodebb), alongside the coverage
caller:

```yaml
  appliance:
    if: vars.KEEL_LXC_RUNNER == 'true'
    uses: keel-linux/.github/.github/workflows/test-appliance.yml@main
    with:
      appliance: nodebb
      parent: nodejs-nginx
```

Debian package, added once the runner exists:

```yaml
name: package
on:
  push:
    tags: ['v*']
jobs:
  package:
    if: vars.KEEL_LXC_RUNNER == 'true'
    uses: keel-linux/.github/.github/workflows/build-deb.yml@main
```

## The site (keel-linux.github.io)

The organization site is static HTML on the `main` branch of
`keel-linux/keel-linux.github.io`. GitHub Pages for an organization site
publishes `main` at path `/` automatically (build type `legacy`, `.nojekyll`
present, HTTPS enforced); no `pages.yml` workflow is needed and none is
provided. The status is `GET /repos/keel-linux/keel-linux.github.io/pages`;
if it ever reports Pages disabled, re-enable with
`POST /repos/keel-linux/keel-linux.github.io/pages` and the body
`{"source": {"branch": "main", "path": "/"}}`. A workflow-based deployment
(`actions/deploy-pages`) becomes necessary only if the site gains a build
step; until then a push to `main` is the deployment.

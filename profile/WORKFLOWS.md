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
| `test-appliance.yml` | `boot-published-layer` | `appliance / boot-published-layer` (caller job id `appliance`) |
| `build-deb.yml` | `deb` | `package / deb` (caller job id `package`) |

Renaming a caller job renames the check and breaks the protection rule that
requires it, so keep the job id `tests`. Renaming a reusable job does the
same thing to every caller at once: `build-and-boot` became
`boot-published-layer` on 2026-09-28, and the protection rule of each
appliance repository had to be renamed with it or the gate would have stopped
applying without saying so.

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

## What the appliance gate proves

`test-appliance.yml` boots the layer the mirror **publishes**. That is worth
having: it catches a published layer that no longer boots, and it catches a
layer whose recorded parent is not the one the repository declares. It is not
evidence about a branch. On a pull request that changes the recipe, the layer
on the mirror is the one built from the default branch, so the change is never
exercised: the job pulls code that is already merged, boots it, goes green and
proves nothing about the diff. Building from the branch instead would need the
build host, which is serialised behind a lock, so it does not fit a
per-pull-request check and this workflow does not attempt it.

The job id is therefore `boot-published-layer` and not `build-and-boot`. The
old name read like "this branch was built and booted", and on 2026-09-28 that
is how it was read when branch protection was applied to keel-lamp, keel-lapp
and keel-apache-php. A check may only be named for what it proves. The job
summary repeats it in as many words, with the `product_commit` and pool date
the booted layer was built from, so a reviewer can see how old the thing that
booted is.

### A layer that has never been published

The job fails. Until 2026-09-28 it passed with a `::notice::` and a job
summary saying "Nothing was built, assembled or booted", which is honest
prose attached to a dishonest conclusion: branch protection and
`gh pr checks` read the conclusion. keel-redis#5 carried a green
`appliance / build-and-boot` produced in 11 seconds by a job that pulled,
verified and booted nothing, and looked ready to merge.

GitHub leaves no third answer to reach for. A job skipped by `if:` reports
success and does not block a merge, and `exit 78`, the old neutral
conclusion, is a plain failure now (measured on this repository, run
36372853847). Failure is the only conclusion a workflow job can produce that
withholds a merge, so that is what an unpublished layer gets.

A repository whose first layer genuinely does not exist yet declares it:

```yaml
  appliance:
    if: vars.KEEL_LXC_RUNNER == 'true'
    uses: keel-linux/.github/.github/workflows/test-appliance.yml@main
    with:
      appliance: somethingnew
      parent: core
      allow_unpublished: true
```

The exemption then lives in that repository's own workflow file, where
whoever reviews it sees it, rather than in the shared gate where nobody
does. It dies on its own: once the manifest answers 200, `allow_unpublished`
is an error telling you to remove the line, so it cannot outlive the
bootstrap it was granted for.

The decision taken from the mirror's answer is `bin/appliance-gate` of this
repository, which the job checks out and runs, so the honesty of the gate is
a tested script rather than shell inside a workflow (decision 0004). It is
unit tested in `tests/appliance-gate.bats` and measured by
`tests/coverage.sh` with everything else here.

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
- `test-appliance.yml`: fetches the appliance's **published** layers from
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
  fetch), `roles` (see below, default empty, which is one container),
  `allow_unpublished` (see below, default `false`), `timeout` (minutes,
  default 60). Read [what it proves](#what-the-appliance-gate-proves) before
  requiring it for merge. An answer that is neither 200 nor 404, including a
  name that does not resolve, fails the job: reading an outage as "not
  published" would be a green check that tested nothing.
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

## Several nodes in the appliance gate

Replication cannot be proved on one machine, so `test-appliance.yml` boots as
many containers as the caller declares. One input carries it:

```yaml
  appliance:
    if: vars.KEEL_LXC_RUNNER == 'true'
    uses: keel-linux/.github/.github/workflows/test-appliance.yml@main
    with:
      appliance: mariadb
      parent: core
      roles: primary replica
```

`roles` is one role name per node, separated by spaces. The node count is the
number of names, so `galera galera galera` is three and nothing in the
workflow assumes two; repeats are allowed because Galera nodes share a role,
and five nodes is the ceiling because this runner is shared. Empty, the
default, is one container and exactly what every caller does today: no new
step runs and the boot test is called with the arguments it was called with
before.

Three things had to be decided, and all three keep the shape a single node
boot test already has:

- **How a repository declares it.** The `roles` input, beside `appliance` and
  `parent`, in the caller's own short workflow. It is the same kind of thing
  an appliance author already writes there, and it is one line.
- **How a node learns which one it is.** Container names are derived from the
  run's name, `NAME-1`, `NAME-2`, and the boot test writes
  `/etc/keel/node.env` into each rootfs before starting it:
  `KEEL_NODE_NAME`, `KEEL_NODE_ROLE`, `KEEL_NODE_INDEX`, `KEEL_NODE_COUNT`. A
  node reads a file in its own filesystem, which is how every other appliance
  setting arrives, and not its hostname or the order it was started in. Once
  every node has an address the test writes `/etc/keel/peers.env` into all of
  them, with `KEEL_NODE_<i>_ADDR` for every node and `KEEL_PEER_<ROLE>` for a
  role exactly one node holds. Those two files are the seam the appliance's
  own replication feature takes over when the instance description carries
  the role (handbook decision 0013).
- **How the test addresses another node.** By literal IPv6 address, never by
  name: on Debian `localhost` resolves to IPv4 alone, so a name in this path
  would quietly pick the wrong family. `btn_role_node` names the container
  holding a role, `btn_tcp_probe_argv` builds the bash `/dev/tcp` connect one
  container runs against another's literal address, and the appliance's own
  `bt_wait_for` turns it into a wait with a deadline.

The logic is `lib/boot-test-nodes.sh` of this repository, unit tested in
`tests/boot-test-nodes.bats` and measured by `tests/coverage.sh`, because it
is shell this repository lends to others and this is the repository with a
gate on it. The job clones it, hands it to the boot test with `--nodes-lib`
and records the commit it used in the job summary. An appliance boot test
that wants several nodes therefore accepts `--roles`, `--nodes-lib` and
`--nodes-report`; nothing else about it changes.

Teardown runs whatever the outcome, cancellation included, because the step's
condition is `always()`. It enumerates the containers from LXC rather than
recomputing them from the role list, so a node the test renamed or started
just before failing goes too. It stops all of them first and removes the
scratch tree last: `keel-ci-cleanup` stops one container and deletes the tree
in a single call, so calling it once per node would delete the configuration
of the nodes not stopped yet and leave their init processes running on a
rootfs that no longer exists. `lxc-stop` and `lxc-destroy` are already in the
runner's sudo policy, so several nodes need it no wider than one node did.

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

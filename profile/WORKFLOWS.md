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
| `lxc-trixie.yml` | `trixie` | `build / trixie` (caller job id `build`) |

Renaming a caller job renames the check, so keep the job id `tests`. Renaming
a reusable job renames it for every caller at once: `build-and-boot` became
`boot-published-layer` on 2026-09-28.

What happens when the protection rule is not renamed with it is worth being
exact about, because the intuition runs the wrong way. GitHub **fails
closed**. A required context that is never reported does not quietly stop
applying; the pull request stays blocked, waiting for a status that will
never arrive. Measured in this organization on 2026-09-28: two pull requests
in keel-mariadb under the same rule, every reported check green on both.
Number 16, reporting `appliance / build-and-boot`, was `clean`. Number 17,
reporting `appliance / boot-published-layer` and identical otherwise, was
`blocked`. keel-core#10 the same; keel-redis#6, in the one repository that
does not require the context, `clean`.

So the cost of renaming a reusable job without renaming the rules is a
lockout of every repository that requires the old name, not an open gate, and
where `enforce_admins` is on (keel-core and keel-mariadb) an owner cannot
merge past it either. Rename the rules in the same change.

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
does. The run carries a `::warning::` annotation saying nothing was booted,
and once the manifest answers 200 the input becomes an error telling you to
remove the line.

Two ways that expiry does not happen on its own, both printed in the summary
of any run that uses the exemption, because an exemption whose limits are not
written down is the next unearned green:

- The expiry is an error **on this check**. It stops somebody only where the
  check is a required status. In keel-nodejs-nginx there is no protection at
  all and in keel-redis this check is not required, and those are exactly the
  repositories an exemption would sit in, because the exemption is for
  repositories that have not published.
- The expiry keys on the name in `appliance:`. `appliance: wordpres` answers
  404 for ever, so an exemption behind a typo never expires and the job stays
  green having booted nothing. Without the exemption the typo fails loudly on
  the first run, which is the default for that reason.

### Checking a change to this workflow before it merges

Nothing does it automatically. `tests / coverage` runs `bin/appliance-gate`
on its own under bats, and no job runs it in place: the tooling checkout is
`ref: ${{ inputs.tooling_ref }}`, default `main`, so a pull request here runs
a new workflow against **main's** copy of the script. It should be
`github.job_workflow_sha`, which needs no input and no procedure; actionlint
1.7.7 does not know that property and the lint gate fails on any finding.

Until then the check is manual, and this is it:

1. Push the branch of `keel-linux/.github`.
2. In an appliance repository, on a throwaway branch, point the caller at it
   and add the matching `tooling_ref`:

   ```yaml
     appliance:
       uses: keel-linux/.github/.github/workflows/test-appliance.yml@my-branch
       with:
         appliance: core
         parent: ""
         tooling_ref: my-branch
   ```

3. Open a pull request, read the job, close it and delete the branch.

Any run whose `tooling_ref` is not `main` carries a `::warning::` saying so
and a line in the job summary naming the ref, on every path including the
exemption path that passes without booting; the step that checks the tooling
out records the commit it resolved to in the summary as well, unconditionally.
The reason is the one that applies to `allow_unpublished`: an input that
substitutes the logic deciding what the job may claim does not get to be
invisible, and the way it goes wrong is somebody lifting the block above into
a caller that merges.

Pick the repository for the state being checked: keel-core for a published
single node layer, keel-mariadb for the two node path, a repository whose
layer is 404 for the unpublished paths. Record the run ids in the pull
request, because that is the only evidence anyone gets.

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
  the threshold is above 0 the job fails. shellcheck runs first, advisory,
  except for one check that blocks, `Negations that assert`: a bats negation
  that is not the last command of its test body. Such a `! cmd` asserts
  nothing, because bash does not apply errexit to a negated command, so the
  test passes whatever the code does. shellcheck reports the ones at the top
  level of the body (SC2314 for `! cmd`, SC2315 for `! [[ ... ]]`, severity
  error only, so a negation in final position is not a failure); a short awk
  program reports the ones shellcheck does not see, nested after `&&`, `||`
  or `;`, in a loop, a branch, a group or a substitution, on any line of the
  body but its last. Write it `run ! cmd` and declare
  `bats_require_minimum_version 1.5.0`. This one runs before the coverage
  work and without a coverage script, since a suite that is not asserting is
  not worth measuring.
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
  `allow_unpublished` (see below, default `false`), `tooling_ref` (see below,
  default `main`, and no ordinary caller sets it), `timeout` (minutes,
  default 60). Read [what it proves](#what-the-appliance-gate-proves) before
  requiring it for merge. An answer that is neither 200 nor 404, including a
  name that does not resolve, fails the job: reading an outage as "not
  published" would be a green check that tested nothing.
- `lxc-trixie.yml`: runs the caller's commands (input `run`) or a script
  of the repository (input `script`) as root in `/src` of a Debian trixie
  system container: an unprivileged LXC container with its own systemd,
  created from the download template, started and destroyed by the runner
  user on the self-hosted runner, with no sudo, as `bin/unprivileged-lxc`
  starts the appliance gate's containers. It is how a job gets trixie in
  this organization, which runs no application containers: no
  `container:` job key, no service images, no Docker or podman. Inputs:
  `systemd` (wait until systemd is running or degraded, for tests that
  drive units), `backports` (enable trixie-backports), `fetch-depth` (0 for
  gbp), `download` and `download-dir` (an artifact of the run put in
  `/src/<download-dir>`), `artifact-dir` and `artifact-name` (a directory
  of `/src` uploaded after the commands succeed), `timeout`. The commands
  install what they need inside the container; nothing is installed on the
  runner. The job is skipped for pull requests from forks and for
  `pull_request_target`, so a fork pull request gets no build, lint or test
  evidence from it. It replaces `build-deb.yml`, retired on 2026-10-01: it
  called `sudo apt-get` on the runner, had no callers, and the runner has
  had no sudo since that day.

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

Debian package (anubis, libcoraza, keel-core): build and lint in a trixie
system container, gbp with backports here.

```yaml
name: package
on:
  pull_request:
  push:
    branches: [keel/trixie]
jobs:
  build:
    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
    uses: keel-linux/.github/.github/workflows/lxc-trixie.yml@main
    with:
      backports: true
      fetch-depth: 0
      artifact-dir: dist
      artifact-name: debs
      run: |
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends git git-buildpackage devscripts equivs lintian
        (cd /tmp && mk-build-deps --install --remove --tool 'apt-get -y -qq --no-install-recommends' /src/debian/control)
        gbp buildpackage --git-ignore-branch --git-builder='dpkg-buildpackage -us -uc'
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
scratch tree last, because removing the tree first would delete the
configuration of the nodes not stopped yet and leave their init processes
running on a rootfs that no longer exists.

### Without root on the runner

Every appliance's `tests/boot-test.sh` insists on being root: it assembles
the rootfs with `keel assemble` and starts the container itself. Since
2026-10-01 the runner has no sudo, so the job runs the test through
`bin/unprivileged-lxc run`, unit tested in `tests/unprivileged-lxc.bats`.
The test is root in a user namespace (`lxc-usernsexec`) whose uid 0 is the
first id of the runner's subordinate range, the range the container's
`lxc.idmap` uses, so what the assemble writes has the owners the container
sees; the runner's own uid is mapped in at 65536 so the workspace stays
writable. Root there cannot put a veth on the host bridge or enter a
container's cgroup, so the test's `lxc-*` commands are links to the same
script that forward to a broker running outside the namespace as the
runner: `lxc-start` gets the idmap, `userns.conf` and the AppArmor profile
`lxc-container-default-with-nesting` on top of the config the test wrote,
inside a delegated `systemd-run --user --scope`; `lxc-attach` runs in a
scope of the same user manager and gets the stdin the test piped to it. The
broker has the runner's rights and no more. `tar` is a link too, because a
user namespace may not create device nodes: it forgives exactly that
refusal and nothing mixed with it, and LXC mounts its own `/dev` over the
rootfs anyway. `unprivileged-lxc cleanup` removes the scratch tree through
the same namespace. No appliance repository had to change.

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

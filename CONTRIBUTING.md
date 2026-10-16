# Contributing to Keel Linux

The source of every Keel Linux repository is
<https://git.pop.coop/Keel-Linux>. The repositories on
<https://github.com/Keel-Linux> are mirrors of it. You can contribute on
either server. A bridge bot copies issues, comments and pull requests to
the other server, so the maintainers see your work in one place.

## Path 1: GitHub

1. Open an issue or a pull request on the GitHub repository, as usual.
2. The bridge bot makes a copy on git.pop.coop in about two minutes. It
   adds a comment with a link to the copy.
3. Comments, labels and the open or closed state sync both ways. You can
   reply on GitHub. You do not need an account on git.pop.coop.
4. A GitHub pull request runs a light CI on GitHub-hosted runners: unit
   tests, lint, the package build and the security scan.
5. The full CI runs on git.pop.coop, on the copy of the pull request,
   after a maintainer reads the change and approves the run.
6. The maintainers merge on git.pop.coop. The mirror then shows your pull
   request on GitHub as merged. If GitHub does not, the bot closes it with
   a link to the merge commit.

To update a pull request, push new commits to its branch on GitHub. The
bridge copies them.

## Path 2: git.pop.coop

1. Sign in on git.pop.coop. Registration is closed: ask a maintainer for
   an account.
2. Open an issue, or fork the repository and open a pull request.
3. The bridge copies issues to GitHub, so GitHub users can see and
   comment on them. Pull requests from git.pop.coop stay there.
4. The CI of a pull request from a fork starts after a maintainer approves
   it.

## What the copies look like

Each copy starts with "Mirrored from ...", the link to the original and
the name of its author, because the bot posts it. The issue numbers on
the two servers are different. A reference such as `#12` in a copy is a
link to the original server.

## Rules for every contribution

- Write in English, in Simplified Technical English (ASD-STE100): short
  sentences, active voice, one instruction for each sentence. See
  `docs/writing.md` in the handbook repository.
- One logical change for each commit. Use the format
  `type: description` (feat, fix, refactor, docs, test, chore, perf, ci).
- A change that ships in a Debian package adds an entry to
  `debian/changelog`.
- Tests come with the change. Code that the project writes has a
  coverage gate of 95 percent.
- Do not put secrets, keys or tokens in a commit, an issue or a pull
  request.
- Report a security problem in private to the maintainers, not in a
  public issue.

The design of the mirror and the bridge is in decision 0056 of the
handbook.

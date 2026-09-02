# Project Instructions

## Project Overview

Workspace for bulk edits and cross-repository operations across the RTLDEV middleware
repositories. Every repository is a git submodule under `repos/`; this repository holds
tooling and pinned commits, never product source.

- **Language / runtime:** bash (the tooling), Node only for prettier/husky
- **Package name:** `rtldev-middleware-workspace` (private, never published)
- **Default branch:** `main`

## Architecture

- **`.gitmodules` is the register; GitHub is the source of truth it is reconciled
  against.** Nothing walks `repos/` to decide what exists. A directory that is present
  but unregistered, or registered but empty, is a state the tooling reports — never one
  it silently adopts.
- **A repository is identified by its namespace _and_ its name.** The repositories are
  split across `centralnicgroup-opensource` and the multi-department `centralnicgroup`,
  and that split is permanent: consolidating them needs the base permission of
  `centralnicgroup-opensource` lowered from Read to No permission, which will not be
  done, so RSRMID-3022 was cancelled. There is no single organisation to hardcode.
  `WS_ORGS` in `scripts/repos.sh` is the list; never write an organisation name into a
  path, a URL or a query.
- **There are three registers, and they answer different questions.** `.gitmodules` lists
  what is checked out for bulk _code_ edits — non-archived, excluding this repository and
  anything the exclusion register names. `.github/repo-settings/_register.tsv` lists what
  this workspace manages the _GitHub settings_ of, which must cover the archived and this
  repository too, and carries the namespace per row. `.github/repos-exclude.tsv` declares,
  with a reason, what is deliberately in neither — sandboxes, websites, third-party forks.
  None is derivable from another; do not try to merge them. Note that the `exclude`
  _profile_ in `_register.tsv` is a fourth, different thing: "ours, checked out, settings
  deliberately unmanaged", which is what `dnscontrol` is.
- **Visibility is not a filter any more.** Both registers cover the private and internal
  repositories. A repository that releases over a deploy key needs its ruleset managed
  whether or not the public can read it.
- **Submodule paths are `repos/<namespace>/<full-repository-name>`.** The namespace is
  there because of the rule above. The full name is there because opening one as its own
  devcontainer resolves `${localWorkspaceFolderBasename}` to the directory name, so a
  shortened directory would give that container a different name and workspace path than
  the same repository cloned standalone. Short names are for humans typing arguments;
  `ws_full_name`/`ws_short_name`/`ws_path`/`ws_org_of` in `scripts/repos.sh` convert.
- **Tracked branches are not uniform.** The older repositories are on `master`, the
  newer on `main`. The branch is recorded per submodule in `.gitmodules`; never
  hardcode either.
- **Registration does not clone.** `ws.sh add --apply` writes the `.gitmodules` entry
  and the gitlink from `git ls-remote`. `git submodule add` would transfer 2 GB for
  `whmcs` just to record one SHA.

## Coding Standards

- **Style:** bash with `set -uo pipefail`, formatted to `.editorconfig` (4-space indent
  in `.sh`). Everything under `scripts/` must pass `shellcheck --severity=warning`.
- Subcommands in `scripts/ws.sh` are `cmd_<name>` and dispatched from `main`.
- Non-result output goes to **stderr** (`ws_info`/`ws_warn`/`ws_die`), so `ws.sh status`
  and `ws.sh grep` stay pipeable.
- Per-repository failures are appended to `FAILED` and reported once via
  `ws_report_failures` — never `exit` from inside a repository loop.
- No zsh scripts in this repository. shellcheck cannot parse zsh, so a zsh script here
  is unlintable rather than merely unlinted.

## Rules the tooling must keep

These are the properties that make bulk operations safe. A change that weakens one is a
change that loses someone's work at the scale of every repository at once.

- A dirty or diverged repository is **skipped with a reason**, never forced, never
  stashed.
- `pull` is `--ff-only`. Always.
- `push` refuses the tracked branch; `commit` refuses a message that is not Conventional
  Commits with a scope.
- Only `push`, `pr` and `add --apply` write anything. `status`, `sync`, `pull`, `grep`,
  `foreach` and `add` must stay safe to run at any time. `org-settings.sh` writes only
  with `--apply`, and `node-policy.sh` and `deploykey-policy.sh` have no write mode at all — a manifest edit belongs
  in that repository's own history and review, never in a bulk apply from here.
- Discovery that returns nothing is an error, not "zero repositories" — an API blip must
  never be read as "everything was deleted". **Per namespace**, not just overall: a
  fine-grained PAT answers a listing for any other organisation with `[]` rather than an
  error, so a whole namespace coming back empty is the likeliest shape a credential
  mistake takes here.
- **A credential problem must never look like an absence.** Three layers, and all three
  are load-bearing: a missing token for a namespace that needs one fails before the query
  (`ws_assert_credentials`); an empty per-namespace result is fatal; and every repository
  either register names must appear in its namespace's discovery result
  (`ws_assert_discovery_covers_registers`). The last is the credential self-test, and what
  it can catch is the private rows — **never probe cross-namespace reach with a public
  repository**, which any authenticated token can read whatever its resource owner, so
  such a probe cannot fail and establishes nothing. Use a private repository, or a call
  needing more than public read such as `GET /repos/{owner}/{repo}/keys`.
- **One token per namespace, applied per call.** `ws_with_token`/`ws_gh` set `GH_TOKEN`
  for the length of one command. Never `gh auth switch`: it is global and stateful, so a
  script that switched and then died leaves the next command talking to the wrong
  namespace.
- **A setting a repository's visibility does not offer is unreadable, not drift.** Secret
  scanning needs GitHub Advanced Security on a non-public repository and private
  vulnerability reporting is public-only; reported as drift they would be three permanent
  lines on every private repository, which is how a drift report stops being read.
- **Rulesets are resolved with `includes_parents=false`.** The parameter defaults to
  _true_, and `centralnicgroup` sets an organisation ruleset that every repository there
  inherits. Without it, an organisation ruleset sharing the managed name would make an
  apply 404 while never creating the repository-level ruleset, and make a check read the
  organisation's empty bypass list and report an unprotected repository as clean.
- **A settings field with no opinion is `@unmanaged`, never `""`.** An empty value is a
  request to blank the field, and an org-wide apply would blank it everywhere at once.
  Only `DESCRIPTION`, `HOMEPAGE` and `TOPICS` may opt out; every other setting is a
  policy with one right answer, so opting out of one silently must stay impossible.
- **The settings drift job enumerates from GitHub, not from the register.** An _active_
  repository present in either organisation and absent from `_register.tsv` fails the run. A
  register that is internally consistent but incomplete is the failure the central model
  exists to prevent. Archived repositories are exempt: they are retired, and GitHub
  rejects settings writes on them, so a register entry could never be applied.
- **A repository we stop maintaining is archived, not deleted outright** — deleting it
  later, once it has been archived a while, is a per-case decision. Public if it is
  customer-facing, internal otherwise — and the visibility is set _before_ archiving,
  because GitHub will not change it afterwards. Archiving takes it out of the checks: out
  of `_register.tsv`, out of `.gitmodules`. See "Retiring a repository" in the README.

## Testing

There is no test framework here. Verify changes by running the command:

```sh
shellcheck --severity=warning scripts/*.sh .devcontainer/*.sh
./scripts/ws.sh status                     # cheap, read-only, exercises the register
./scripts/ws.sh credentials                # which token each namespace resolves to
./scripts/ws.sh add                        # read-only: discovery + the credential self-test
./scripts/ws.sh sync devcontainer-features # smallest repository, ~200 KB
./scripts/node-policy.sh                   # read-only, needs an org-wide token
./scripts/deploykey-policy.sh              # read-only, needs deploy-key read scope
pnpm prettier
```

`ws.sh add` is the cheapest thing that exercises the whole credential path, and the one
worth running after touching `scripts/repos.sh`: it pages both namespaces, and it fails if
either comes back empty or misses a repository a register names.

Never `npx` anything here — we install with pnpm, and `npx` reaches for npm's registry
client. `pnpm prettier` runs the version the lockfile pins; `pnpm dlx` is the equivalent
of `npx` for a package that is genuinely not a dependency.

## Build, CI & Policies

- **CI never checks out the submodules.** Their code is gated by their own CI. The
  `register` job in `quality.yml` validates `.gitmodules` against the index without
  cloning anything.
- `repos-drift.yml` runs weekly and **fails** when a `rtldev-middleware-*` repository
  exists in either namespace and is in neither register here — the failure mode where
  every subsequent bulk operation silently covers one repository fewer. `repos-exclude.tsv`
  is what makes that survivable: before it existed, the only way to stop the job
  complaining about a sandbox nobody wants was to stop running it.
- `node-policy-drift.yml` runs weekly and **fails** when a repository's `engines`,
  `devEngines.packageManager` or committed lockfile disagrees with
  `.github/node-policy.conf`, or that still carries a `packageManager` field.
  Comparison is literal string equality, never semver evaluation — deciding that two
  ranges "mean the same thing" is what let six spellings of `engines.node` accumulate.
  It needs no register: it enumerates from GitHub and checks everything with a
  `package.json`. It has **no trigger on `pull_request`**, deliberately — the job fails
  on drift that only a commit in _another_ repository can fix. It is the one check still
  scoped to `centralnicgroup-opensource` alone, for that same reason: needing no register
  means widening it adds every `centralnicgroup` manifest at once, none ever compared
  against the policy. RSRMID-3036 widens script and workflow together.
- `deploykey-policy-drift.yml` runs weekly and **fails** when a repository's
  `releases-via-deploykey` trait disagrees with what the repository does: a release
  config or a write-enabled deploy key without the trait, or the trait with anything
  other than exactly one write key. Two signals, because the cause (`@semantic-release/git`
  in the plugins array) is unreadable for a distribution repository like `whmcs`, and the
  mechanism (the deploy key) is what catches it. The plugins array is **parsed, never
  grepped** — `@semantic-release/git` is a prefix of `@semantic-release/github`. Like the
  Node job it has **no `pull_request` trigger** and no write mode.
- **Devcontainer:** the frame is in `.devcontainer/`; shared behaviour comes from the
  `devbase` Feature by version. Never fork its scripts here. No language runtimes are
  installed — that is a decision, not an omission (see README).

## Git Conventions

- **Commit messages:** Conventional Commits with **mandatory scope** —
  `<type>(<scope>): <summary>`. Never append a `Co-Authored-By:` trailer. Common scopes
  here: `repos` (register and pinned commits), `ws` (the CLI), `devcontainer`.
- A commit that only moves submodule pointers is `chore(repos): update pinned commits`,
  and is made **after** the submodule commits are pushed — a superproject commit
  pointing at a commit that exists only on one machine is a broken workspace for
  everyone else.
- **Branch creation:** `git checkout main && git pull --ff-only` before `git checkout -b`.
- **Branch naming:** prefix with the Jira issue ID — `RSRMID-1234/short-description`.
  The same branch name is used across the submodules a change touches; `ws.sh branch`
  exists to keep them identical.
- **Merging:** rebase-merge (`gh pr merge --rebase`).

## Working inside `repos/`

- **Always update the pin.** A submodule change is not finished until this repository
  points at it: `ws.sh pin`, then `chore(repos): update pinned commits`. Leaving the
  pointer behind is not the neutral option it looks like — a fresh clone of this
  workspace still gets the old code, so the change effectively exists only for whoever
  made it.
- **Pin only what is already on the tracked branch**, never a local commit — see the
  ordering rule under Git Conventions. That constraint outranks the one above: if the
  submodule work is not merged yet, the pin waits, it does not get forced.
- **A pin bump carries more than your own change.** Advancing a pin to the tracked-branch
  tip also brings in every other commit that landed there since the last bump. That is
  intended: a pin records the commit this workspace tracks, not the commit you wrote. Say
  so in the PR when the span is wide.
- Each submodule has its own `CLAUDE.md`, linters and conventions — read the one in the
  repository you are editing before changing its code. This file does not govern them.
- Formatting a submodule's files uses **its** prettier config:
  `./scripts/ws.sh foreach 'pnpm prettier:fix'`, never `prettier --write` from here.

## Atlassian / JIRA

Work is tracked in **Jira Cloud**, project `RSRMID` — not GitHub Issues (which are
disabled on this repository).

- **Descriptions must be ADF** (Atlassian Document Format, JSON) — never markdown, which
  renders literal `\n`.
- **Log time before Done:** an issue will not stay in **Done** without a worklog —
  automation stamps `missing-time-spent` and reopens it. Sequence: (1) add worklog;
  (2) remove the label; (3) transition to Done.

## Tool-Output Hygiene

Every tool result is spent context, and this repository makes it easy to spend a great
deal of it at once: an unbounded search here reads every registered codebase. A `PreToolUse`
hook (`.claude/hooks/tool-output-hygiene.sh`) denies the worst shapes and names the
replacement — take the replacement rather than working around it.

- **Searching across repositories:** `./scripts/ws.sh grep <pattern> -l` for locations
  first, then read the specific files. Never an unbounded `rg`/`grep -r` over `repos/`.
- **Reading part of a file:** **Read** with `offset`/`limit`, never `sed -n '<from>,<to>p'`
  or a bare `cat`.
- **Status across repositories:** `./scripts/ws.sh status`, not `foreach 'git status'` —
  one table instead of one screen per repository.
- **`foreach` output is multiplied by the number of registered repositories.** Bound the
  command itself (`git log -1 --oneline`, `| head -5`), not the result.

## Model Routing

Opus decides, Sonnet implements: plan and review in the main thread, hand the mechanical
work down. Definitions live in `.claude/agents/`.

- **Implementation** of an already-settled change goes to the `implementer` subagent.
- **Review** goes to the `reviewer` subagent (Opus) or stays in the main thread. Never
  route a review to Sonnet.
- **Fan-out reads across repositories** go to `Explore` or `general-purpose`, so every
  repository's worth of file content lands in the subagent's context instead of this
  one. A subagent reports conclusions, not file contents.

## Do NOT

- Add dependencies without explicit request
- Add `Co-Authored-By:` trailers to commit messages
- Fork the `devbase` devcontainer Feature's scripts into this repository
- Add language runtimes to `.devcontainer/Dockerfile` — per-repository work belongs in
  the per-repository devcontainer
- Run `prettier --write` over `repos/`, or add `repos/` content to this repository's
  linting
- Use `git submodule add` — it clones to register; `ws.sh add --apply` does not
- Write an organisation name into a path, a URL or a query — take it from `WS_ORGS`,
  `ws_org_of` or the register row
- Use `gh auth switch`, or set `GH_TOKEN` globally for a whole script — one token per
  namespace, per call, via `ws_with_token`/`ws_gh`
- Commit a token, or print one. `ws.sh credentials` reports the _source_, never the value

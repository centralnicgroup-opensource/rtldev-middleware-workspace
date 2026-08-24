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
- **Submodule directories keep the full repository name** (`repos/rtldev-middleware-php-sdk`).
  Opening one as its own devcontainer resolves `${localWorkspaceFolderBasename}` to the
  directory name, so a shortened directory would give that container a different name
  and workspace path than the same repository cloned standalone. Short names are for
  humans typing arguments; `ws_full_name`/`ws_short_name` in `scripts/repos.sh` convert.
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
change that loses someone's work at eighteen times the usual scale.

- A dirty or diverged repository is **skipped with a reason**, never forced, never
  stashed.
- `pull` is `--ff-only`. Always.
- `push` refuses the tracked branch; `commit` refuses a message that is not Conventional
  Commits with a scope.
- Only `push`, `pr` and `add --apply` write anything. `status`, `sync`, `pull`, `grep`,
  `foreach` and `add` must stay safe to run at any time.
- Discovery that returns nothing is an error, not "zero repositories" — an API blip must
  never be read as "everything was deleted".

## Testing

There is no test framework here. Verify changes by running the command:

```sh
shellcheck --severity=warning scripts/*.sh .devcontainer/*.sh
./scripts/ws.sh status                     # cheap, read-only, exercises the register
./scripts/ws.sh sync devcontainer-features # smallest repository, ~200 KB
npx prettier@3 --check .
```

## Build, CI & Policies

- **CI never checks out the submodules.** Their code is gated by their own CI. The
  `register` job in `quality.yml` validates `.gitmodules` against the index without
  cloning anything.
- `repos-drift.yml` runs weekly and **fails** when a `rtldev-middleware-*` repository
  exists on GitHub but is not registered here — the failure mode where every subsequent
  bulk operation silently covers one repository fewer.
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

- Never commit inside a submodule from this repository's context without also deciding
  what happens to the pin. Either `ws.sh pin` afterwards, or leave the pointer alone
  deliberately.
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
deal of it at once: an unbounded search here reads eighteen codebases. A `PreToolUse`
hook (`.claude/hooks/tool-output-hygiene.sh`) denies the worst shapes and names the
replacement — take the replacement rather than working around it.

- **Searching across repositories:** `./scripts/ws.sh grep <pattern> -l` for locations
  first, then read the specific files. Never an unbounded `rg`/`grep -r` over `repos/`.
- **Reading part of a file:** **Read** with `offset`/`limit`, never `sed -n '<from>,<to>p'`
  or a bare `cat`.
- **Status across repositories:** `./scripts/ws.sh status`, not `foreach 'git status'` —
  one table instead of eighteen screens.
- **`foreach` output is multiplied by eighteen.** Bound the command itself
  (`git log -1 --oneline`, `| head -5`), not the result.

## Model Routing

Opus decides, Sonnet implements: plan and review in the main thread, hand the mechanical
work down. Definitions live in `.claude/agents/`.

- **Implementation** of an already-settled change goes to the `implementer` subagent.
- **Review** goes to the `reviewer` subagent (Opus) or stays in the main thread. Never
  route a review to Sonnet.
- **Fan-out reads across repositories** go to `Explore` or `general-purpose`, so
  eighteen repositories' worth of file content lands in the subagent's context instead
  of this one. A subagent reports conclusions, not file contents.

## Do NOT

- Add dependencies without explicit request
- Add `Co-Authored-By:` trailers to commit messages
- Fork the `devbase` devcontainer Feature's scripts into this repository
- Add language runtimes to `.devcontainer/Dockerfile` — per-repository work belongs in
  the per-repository devcontainer
- Run `prettier --write` over `repos/`, or add `repos/` content to this repository's
  linting
- Use `git submodule add` — it clones to register; `ws.sh add --apply` does not

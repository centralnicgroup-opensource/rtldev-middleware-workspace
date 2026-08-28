# rtldev-middleware-workspace

One checkout, every RTLDEV middleware repository — for the changes that are the same
in all of them.

A dependency bump, a workflow rename, a licence header, a devcontainer Feature version:
each is a small edit, and each has to land in every registered repository, with its own
branch, its own commit and its own pull request. This repository turns that into one
command, and turns "what is the state of all of them" into one table.

It holds no source of its own. Every repository is a git submodule under `repos/`, so
the code always belongs to the repository that owns it — this workspace only ever
records _which commit_ of each it is pointing at.

## Quick start

```sh
git clone https://github.com/centralnicgroup-opensource/rtldev-middleware-workspace.git
cd rtldev-middleware-workspace

# Open in VS Code and reopen in the devcontainer (F1 -> Dev Containers: Reopen in
# Container). The container carries git, gh, ripgrep, fd, jq and parallel; it does not
# carry PHP, Go, Java or Python — see "Devcontainer" below.

./scripts/ws.sh sync      # populate the checkouts (~2.4 GB uncompressed; blobless)
./scripts/ws.sh status    # the table
```

`sync` takes repository names, so you rarely need all of them:

```sh
./scripts/ws.sh sync php-sdk node-sdk python-sdk
```

## The repositories

Eighteen public, non-archived `rtldev-middleware-*` repositories. The register lives in
[.gitmodules](.gitmodules) and is reconciled against GitHub by `./scripts/ws.sh add` —
run weekly by [repos-drift.yml](.github/workflows/repos-drift.yml), which fails when a
new repository exists that nobody has registered here.

Directories under `repos/` keep the **full** repository name. That looks redundant, and
it is load-bearing: opening `repos/rtldev-middleware-php-sdk` as its own devcontainer
resolves `${localWorkspaceFolderBasename}` to the directory name, so a shortened
directory would give that container a different name and workspace path than the same
repository cloned on its own. Everywhere you _type_ a repository, the short name works:
`./scripts/ws.sh status php-sdk`.

## A cross-repository change, start to finish

```sh
./scripts/ws.sh pull                                   # every checkout to its tip
./scripts/ws.sh branch RSRMID-1234/bump-node           # same branch everywhere

./scripts/ws.sh foreach 'sed -i "s/lts.20/lts.22/" .github/workflows/*.yml'
./scripts/ws.sh grep 'lts\.2[02]'                      # verify before committing
./scripts/ws.sh status                                 # who actually changed

./scripts/ws.sh commit 'ci(workflows): move to Node 22'
./scripts/ws.sh push
./scripts/ws.sh pr 'ci: move to Node 22' 'RSRMID-1234'

./scripts/ws.sh pin && git commit -m 'chore(repos): update pinned commits'
```

Every step is skippable per repository and none of them force anything:

- A repository with uncommitted changes is **skipped**, never stashed — a bulk stash is
  a pile of unlabelled stashes nobody goes back for.
- `pull` is `--ff-only`, always. A bulk pull that can merge is a bulk pull that can
  leave a conflicted worktree in every repository at once, from one keystroke.
- `push` refuses to push the tracked branch, and `commit` refuses a message that is not
  Conventional Commits with a scope — a malformed bulk message lands in every history at
  once, and semantic-release reads those messages to pick versions.
- Failures are collected and named at the end, so a partially applied operation always
  tells you which repositories to look at.

Run `./scripts/ws.sh help` for the full command list.

### `foreach` is the general case

The command runs under `bash -c` in each checkout with `$WS_REPO`, `$WS_REPO_SHORT` and
`$WS_REPO_DIR` set, which is what makes one invocation work across a PHP, a Go and a
Node repository:

```sh
./scripts/ws.sh foreach '[ -f composer.json ] && composer validate --strict || true'
./scripts/ws.sh foreach -j 'gh run list --limit 1'     # -j: parallel, output grouped
```

`-j` uses GNU `parallel --group` rather than `xargs -P` deliberately: a dozen or more
commands writing to one terminal concurrently produces interleaved output nobody can
read.

## Why the checkouts are blobless

The full set is about 2.4 GB, most of it file contents from history nobody reads in a
workspace context — `whmcs` alone is 2 GB and `blesta` 220 MB. `sync` therefore clones
with `--filter=blob:none`: every commit and tree is present, so `log`, `blame`, `diff`
and `checkout` all work normally, and file contents are fetched on demand. Pass
`--full` when you need complete history offline.

For the same reason, **registering a repository does not clone it**.
`./scripts/ws.sh add --apply` writes the `.gitmodules` entry and the gitlink from a
single `git ls-remote` round trip — no objects transferred. `git submodule add` would
have downloaded 2 GB to record one SHA.

## Devcontainer

The same frame as [rtldev-middleware-template](https://github.com/centralnicgroup-opensource/rtldev-middleware-template),
with the shared behaviour coming from the `devbase` Feature by version, never copied.
Two differences, both specific to what a workspace is:

**No language runtimes.** A workspace checkout holds PHP, Go, Java, Python and Node
repositories at once. Installing all five would produce a slow, enormous image whose
versions drift from the ones each repository pins. Per-repository work belongs in that
repository's own devcontainer — open `repos/<name>` as its own container, which works
because every one of them ships one. This container is for what spans repositories: git,
gh, ripgrep, fd, jq and parallel, added in [.devcontainer/Dockerfile](.devcontainer/Dockerfile).

**Nothing is cloned on attach.** `postAttachCommand` reports how many checkouts are
populated and stops there. Which repositories you want is a per-session decision, and an
automatic `git submodule update --init` would turn every first attach into a multi-minute
download of repositories the session may never touch.

## What lives here, and what does not

| Path                                | Purpose                                                              |
| ----------------------------------- | -------------------------------------------------------------------- |
| `scripts/ws.sh`                     | The workspace CLI — every bulk operation                             |
| `scripts/repos.sh`                  | Shared library: naming, the register, GitHub discovery               |
| `scripts/org-settings.sh`           | Reconciles GitHub settings for _every_ `rtldev-middleware-*` repo    |
| `scripts/repo-settings.sh`          | The single-repository settings engine `org-settings.sh` drives       |
| `.github/repo-settings/`            | The settings themselves: baseline, profiles, per-repo overrides      |
| `scripts/node-policy.sh`            | Reports repositories whose Node/npm/pnpm declaration has drifted     |
| `.github/node-policy.conf`          | The one Node toolchain every repository is meant to declare          |
| `repos/`                            | The submodule checkouts. Nothing in here is edited from here         |
| `.github/workflows/quality.yml`     | Prettier, actionlint, shellcheck, and the register consistency check |
| `.github/workflows/repos-drift.yml` | Weekly: has a new repository appeared that is not registered?        |

### Repository settings

GitHub settings are managed here for the whole organisation, not repository by
repository. `.github/repo-settings/` holds one baseline, two audience profiles
(`customer-facing` — issues on; `internal` — issues off) and a per-repository override
file where a repository genuinely differs. `_register.tsv` lists which repository takes
which profile.

```sh
pnpm repo:settings                  # report drift everywhere, change nothing
pnpm repo:settings:resolve php-sdk  # show the effective config for one repository
pnpm repo:settings:apply            # make GitHub match (needs an org-wide token)
```

The three layers are concatenated and sourced as shell, so precedence is simply the
order they appear in — there is no merge algorithm to reason about.

Two properties are worth knowing. `DESCRIPTION`, `HOMEPAGE` and `TOPICS` accept
`@unmanaged`, which means "hold no opinion" and is **not** the same as an empty value —
an empty value is a request to blank the field, which on an org-wide apply would erase
every description at once. And the drift job enumerates from the GitHub API rather than
from the register, so a repository that exists in the organisation but is absent from
`_register.tsv` is a **failure**, not a silence. That is the whole reason this is
central: a per-repository drift job cannot report a repository that never received the
job.

Archived repositories stay listed with their profile and are skipped at run time —
GitHub rejects settings writes on them, so archiving one needs no edit here.

### The Node toolchain policy

We install with pnpm, and every repository is meant to say the same thing about which
Node, which npm floor and which pnpm it expects. Nothing enforced that, and six different
spellings of `engines.node` accumulated across the manifests without anyone noticing.
`.github/node-policy.conf` holds the one canonical answer;
[node-policy-drift.yml](.github/workflows/node-policy-drift.yml) reports weekly on
anything that disagrees.

```sh
pnpm node:policy            # report drift everywhere
pnpm node:policy --verbose  # and list the repositories that are clean
```

Three things about it are deliberate. Comparison is **literal string equality**, with no
semver evaluation anywhere — "these two ranges mean the same thing" is exactly the
judgement that let six spellings of one intent accumulate. `engines.npm` is **not** a
claim that we install with npm: devbase reads that field and upgrades the container's npm
to match it, and it only parses the `>=` spelling, so `^12.0.0` would silently disable the
upgrade rather than fail. And no Node release bundles npm 12, so that floor cannot be
folded into `engines.node` — it has to be stated.

The pnpm pin lives in `devEngines.packageManager` as a **range**, and `packageManager`
must be **absent**. The older field takes one exact version and pnpm 10+ acts on it
silently — it downloads that version and re-executes itself as it — so every pnpm patch
release becomes a commit in every manifest, and skipping that commit is invisible.
It decayed exactly that way: `semantic-release-plugins` sat a whole major behind at
`pnpm@10.24.0`. `devEngines` validates instead of switching, so a pnpm outside the range
fails the command by name rather than quietly becoming a different pnpm. Carrying both
fields would mean two sources of truth that disagree by design — `pnpm/action-setup`
reads `devEngines` first, pnpm's own self-management reads only `packageManager` — so the
policy treats the old field as drift.

Declaring `devEngines` makes pnpm lock itself: the next install prepends a
`packageManagerDependencies` document to `pnpm-lock.yaml` resolving pnpm to an exact
version, and `pnpm i --frozen-lockfile` fails until that is committed. So a repository
moving across commits the manifest edit and the regenerated lockfile together. That is the
point rather than a side effect — the range states intent in the manifest, the exact
version sits in the lockfile with every other exact version, and the dependency refresh
job bumps it like anything else.

Coverage needs no register, which is the one way this improves on the settings drift job
above. It enumerates from the organisation and checks everything with a `package.json`, so
a new repository is covered the moment it exists; one without a `package.json` is reported
and counted rather than skipped in silence. The script is read-only and has no write mode
— a manifest edit belongs in that repository's own history and review.

CI never checks out the submodules. Their code is gated by their own CI; re-linting it
here would duplicate that and fail on findings this repository cannot fix. For the same
reason `repos/` is the first entry in [.prettierignore](.prettierignore) — each of those
repositories has its own prettier config and formatting history.

## Committing in this repository

Conventional Commits with a mandatory scope, like everywhere else. The scope that comes
up most is `repos`:

```
feat(repos): register rtldev-middleware-something-new
chore(repos): update pinned commits
feat(ws): add a --dry-run flag to foreach
```

A commit that only moves submodule pointers is `chore(repos)`. Run
`./scripts/ws.sh pin` after the submodule commits are **pushed** — a superproject commit
pointing at a commit that exists only on your disk is a broken workspace for everyone
else.

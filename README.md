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

Every non-archived `rtldev-middleware-*` repository, whatever its visibility, across both
GitHub namespaces — except the ones
[repos-exclude.tsv](.github/repos-exclude.tsv) declares out of scope with a reason. The
register lives in [.gitmodules](.gitmodules) and is reconciled against GitHub by
`./scripts/ws.sh add` — run weekly by
[repos-drift.yml](.github/workflows/repos-drift.yml), which fails when a repository exists
in either namespace and is in neither register.

Checkouts live at `repos/<namespace>/<full-repository-name>`:

```
repos/centralnicgroup-opensource/rtldev-middleware-php-sdk
repos/centralnicgroup/rtldev-middleware-whmcs-src
```

Both halves of that path are load-bearing. The **namespace** is there because a repository
is identified by its organisation and its name together, and the two organisations are
permanent — consolidating them would mean lowering the base permission of
`centralnicgroup-opensource` from Read to No permission, which will not be done, so the
migration was cancelled. The **full** repository name is there because opening
`repos/<namespace>/rtldev-middleware-php-sdk` as its own devcontainer resolves
`${localWorkspaceFolderBasename}` to the directory name, so a shortened directory would
give that container a different name and workspace path than the same repository cloned on
its own.

You never type either. Repositories are addressed by short name and the namespace is
looked up: `./scripts/ws.sh status php-sdk`.

### Two namespaces, two tokens

A fine-grained GitHub PAT has exactly one resource owner, and asked about any other
organisation it returns an **empty list rather than an error**. A token without
private-repository scope omits exactly the repositories that need one. Both read as "those
repositories do not exist" — the same failure `repos-drift.yml` exists to catch, arriving
through the credential layer instead of the register. So there is one token per namespace,
and three things refuse to accept a short answer:

- a missing credential for a namespace that needs one fails **before** the query;
- an empty result for any single namespace is fatal, never "that namespace has none";
- every repository either register names must appear in its namespace's result. This is
  the credential self-test, and it is the only one worth having: what it can actually
  catch is the private rows, because a public repository is visible to any authenticated
  token whatever its resource owner. A self-test pointed at a public repository is a test
  that cannot fail.

```sh
./scripts/ws.sh credentials             # where each namespace's token comes from
./scripts/ws.sh credentials --install   # teach git to pick the token by URL path
```

Tokens are read from `$WS_TOKEN_<NAMESPACE>` in the environment, or from a file named
after the namespace in `~/.config/rtldev-middleware-workspace/tokens/`, which the
devcontainer mounts **read-only** from the host. Nothing is ever committed, and
`ws.sh credentials` prints where a token came from but never the token.

`.gitmodules` stays uniformly HTTPS, so git itself has to choose between the two tokens on
every fetch and push. `credential.<url>` config cannot express that — a path in the
pattern must match _exactly_, so scoping by namespace that way would mean one section per
repository — so [git-credential-ws.sh](scripts/git-credential-ws.sh) reads the URL path
and answers for the whole namespace. `ws.sh` puts it in force for its own network calls
whether or not you have run `--install`; `--install` is for the git commands you type
yourself.

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
| `scripts/repos.sh`                  | Shared library: naming, the registers, credentials, discovery        |
| `scripts/git-credential-ws.sh`      | git credential helper: picks the token by namespace                  |
| `.github/repos-exclude.tsv`         | Repositories deliberately not registered here, each with a reason    |
| `scripts/org-settings.sh`           | Reconciles GitHub settings for _every_ `rtldev-middleware-*` repo    |
| `scripts/repo-settings.sh`          | The single-repository settings engine `org-settings.sh` drives       |
| `.github/repo-settings/`            | The settings themselves: baseline, profiles, per-repo overrides      |
| `scripts/node-policy.sh`            | Reports repositories whose Node/npm/pnpm declaration has drifted     |
| `.github/node-policy.conf`          | The one Node toolchain every repository is meant to declare          |
| `scripts/deploykey-policy.sh`       | Reports repositories whose deploy-key release trait is wrong         |
| `repos/<namespace>/`                | The submodule checkouts. Nothing in here is edited from here         |
| `.github/workflows/quality.yml`     | Prettier, actionlint, shellcheck, and the register consistency check |
| `.github/workflows/repos-drift.yml` | Weekly: has a new repository appeared that is not registered?        |

### Repository settings

GitHub settings are managed here for both organisations, not repository by repository.
`.github/repo-settings/` holds one baseline, two audience profiles (`customer-facing` —
issues on; `internal` — issues off) and a per-repository override file where a repository
genuinely differs. `_register.tsv` lists which namespace each repository is in and which
profile it takes, and each repository is reconciled with its own namespace's token, set
for that one engine invocation.

That namespace column is not decoration. While a single organisation was hardcoded, a row
for the other one resolved to a repository that does not exist — which is why
`rtldev-middleware-whmcs-src`, whose deploy-key ruleset bypass this register is the only
record of, could not be registered here at all.

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

Archived repositories are out of scope — see "Retiring a repository" below. The coverage
question is asked of the active repositories only, so an archived one is neither required
in `_register.tsv` nor a failure when absent from it. Anything named in
`repos-exclude.tsv` is out too: a repository declared not to be part of this workspace at
all is not a settings gap, and recording that decision in two files would mean the drift
job stayed red until both had it.

Three settings cannot be satisfied on a private or internal repository:
`SECRET_SCANNING` and `SECRET_SCANNING_PUSH_PROTECTION` need GitHub Advanced Security
there, and `PRIVATE_VULNERABILITY_REPORTING` is public-only whatever the plan. The engine
reports those as **unavailable** and counts them with the fields it could not read, never
as drift. That is a decision, not an accident of the API: reported as drift they would be
three permanent lines on every private repository for ever, and a drift report with
permanent entries is one nobody reads.

One more thing the engine now does by construction rather than by luck: it resolves
rulesets with `includes_parents=false`. That parameter defaults to _true_, so the listing
otherwise includes the organisation's own rulesets — and `centralnicgroup` sets one,
inherited by every repository in it. Had an organisation ruleset ever been named
`default-branch-protection`, the obvious name and the one this baseline uses, an apply
would have 404'd while never creating the repository-level ruleset, and a check would have
read the organisation ruleset's empty bypass list and reported a repository with no
protection of its own as present and clean. Inherited rulesets are printed as context,
because their rules are enforced as the union with ours, but they are not ours to manage.

### Retiring a repository

When we stop maintaining an `rtldev-middleware-*` repository:

| Step       | Rule                                                                              |
| ---------- | --------------------------------------------------------------------------------- |
| Outcome    | **Archive it.** Never delete _instead_ — archiving is reversible, deletion is not |
| Visibility | Customer-facing → archive **public**. Everything else → **internal**              |
| Coverage   | It leaves the checks: out of `_register.tsv`, out of `.gitmodules`                |

**Set the visibility before archiving.** GitHub will not change the visibility of an
archived repository, so an internal-bound one has to be made internal first and archived
second. Doing it the other way round means unarchiving to fix it.

Two repositories archived before this rule existed are `private` rather than `internal`
(`app` and `whmcs-changelog-monitor`, both in `centralnicgroup`). Private is stricter than
internal, not weaker, so there is nothing to repair — and repairing it would mean
unarchiving them to widen their access. Left as they are, deliberately.

They also show the other half of the archive rule working as intended: deletion is a
separate, later, per-case decision, and three of their neighbours — `fmonitor`,
`registrant-email-verification` and `statistics` — reached it on 2026-09-02, having been
archived first.

A public repository that is archived rather than made internal stays public on purpose.
Moving it out of `centralnicgroup-opensource` would not unpublish it — forks, clones and
any published package pointing at it all persist — so for anything customer-facing the
honest end state is an archived public repository, not a hidden one.

**Deleting it later is a separate, per-case decision.** Archiving is the retirement step
and deletion is never a shortcut past it, but a repository that has been archived for a
while and that nothing depends on any more may still be deleted — judged at that point,
on that repository, rather than mandated or forbidden here.

Nothing needs to be added anywhere to retire a repository; things need to be **removed**.
`org-settings.sh`, `node-policy.sh` and `deploykey-policy.sh` all skip archived repositories at run time
already, and the settings drift job stops demanding a register entry once the repository
is archived.

### The deploy-key release trait

Ten repositories release by pushing the version bump and the changelog straight to their
default branch, which only works because the branch ruleset names a deploy key as its one
bypass actor. That is the `releases-via-deploykey` trait in `_register.tsv`, and until
RSRMID-3035 nothing derived it from what the repositories actually do — so the register
could be perfectly self-consistent and still wrong about one of them. RSRMID-3025 was six
days of broken releases from exactly that.

```sh
pnpm deploykey:policy            # report drift everywhere
pnpm deploykey:policy --verbose  # and list the repositories that are clean
```

The rule it checks is **(release config OR write deploy key) implies the trait, and the
trait implies exactly one write deploy key**. Two signals, because neither alone is
enough. The release config is the _cause_ — `@semantic-release/git` in a repository's own
plugins array, or another repository naming it as a `distributionRepo` in
`release-products.json`. A write-enabled deploy key is the _mechanism_, and it is what
catches `whmcs`, which is built zips and a `release.json` with no release config at all
for a config-only check to read.

The "exactly one" is not tidiness. GitHub grants the bypass to deploy keys **as a class** —
the API requires `actor_id` null for `actor_type` `DeployKey` — so a second write-enabled
key on a trait repository silently widens the bypass from "the release push" to "anything
holding any write key here".

Two traps are worth knowing, because both were hit while cross-checking this by hand.
`@semantic-release/git` is a **prefix of** `@semantic-release/github`, so a grep over the
config file reports every repository that publishes a GitHub release; the plugins array is
parsed and compared with string equality instead. And it enumerates from GitHub rather
than `repos/`, because `whmcs` and `dnscontrol` are usually not checked out — a check
reading working trees would skip `whmcs`, the one repository the key signal exists for.

It also checks every name in `_register.tsv`, including one the organisation listing did
not return, and fails on it rather than passing quietly. That is deliberately different
from `org-settings.sh`, which now aborts on the same condition: here the row has to be
_checked and fail_, one repository at a time, because a register row can land before the
token that can read it does and must not certify itself in the meantime — and the report
on every other repository is worth having while that is true.

It reads **both** namespaces, unlike its sibling `node-policy.sh`. It has to: the
repository whose bypass this policy exists to protect, `whmcs-src`, is private and in
`centralnicgroup`. Listing deploy keys is `administration:read`, the scope none of the
other drift jobs needs and the one most likely to go missing after a rotation — so a
uniformly red run is the credential, not drift.

Read-only, with no write mode at all. The fix is a register row in a pull request here or
a deploy key removed over there, and which of the two it is takes a person deciding.

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

It is scoped to `centralnicgroup-opensource` alone, and that is the one thing here still
waiting. Because coverage needs no register, widening it adds every `centralnicgroup`
manifest at once — none of which has ever been compared against `node-policy.conf` — and
with literal string comparison each of them is drift until a commit lands in that
repository. A weekly job that is red for something this repository cannot fix is a job
nobody reads, so RSRMID-3036 widens the script and the workflow together, after finding
out what the drift actually is.

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

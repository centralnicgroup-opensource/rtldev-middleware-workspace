# Contributing

This repository is tooling for the middleware team: a workspace that applies one change
across the `rtldev-middleware-*` repositories. Work is tracked in Jira (`RSRMID`) — GitHub
Issues are disabled here — so please discuss a change with the repository owners before
making it.

Please note we have a code of conduct; please follow it in all your interactions with the
project.

## Development

The repository ships a devcontainer, so **Reopen in Container** is the supported setup —
it brings git, `gh` (already authenticating your pushes), ripgrep, fd, jq and parallel,
plus `cz` and the prettier/husky toolchain. Working outside it is possible but
unsupported.

The container deliberately carries **no** PHP, Go, Java or Python. Work on a specific
repository happens in that repository's own devcontainer: open `repos/<name>` as its own
container. See the [README](README.md#devcontainer) for why.

Coding standards and the invariants the bulk tooling must preserve are documented in
[CLAUDE.md](CLAUDE.md). Before opening a pull request:

```sh
shellcheck --severity=warning scripts/*.sh .devcontainer/*.sh
npx prettier@3 --check .
./scripts/ws.sh status
```

CI runs the same checks plus a consistency check on the submodule register, so a green
local run is a green build.

## Changing the submodule register

Adding or removing a repository is a change to `.gitmodules` **and** to the index, and the
two have to stay in step — the `register` job in CI fails when they do not.

- To add: `./scripts/ws.sh add --apply`, then commit. Never `git submodule add` — it
  clones the repository (2 GB for `whmcs`) just to record one SHA.
- To remove: `git rm repos/<full-name>` and drop the `.gitmodules` section. This discards
  whatever is in that worktree, which is why the tooling reports removals but never
  applies them.
- Changing a tracked branch means editing `submodule.repos/<name>.branch`. `ws.sh pull`
  and `ws.sh branch` both read it, and the repositories are genuinely split between
  `main` and `master`.

## Changing the bulk tooling

`scripts/ws.sh` runs unattended over every registered repository, so the safety properties
listed under "Rules the tooling must keep" in [CLAUDE.md](CLAUDE.md) are not style
preferences. In particular: skip rather than force, `--ff-only` rather than merge, and
report every per-repository failure by name. Test a change against the smallest
repository (`devcontainer-features`, ~200 KB) before running it across the set.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/) with a **mandatory
scope**:

```text
<type>(<scope>): <summary>
```

`fix` and `feat` are reserved for changes to the source, because they trigger a
release. Everything else takes a non-releasing type:

| Type       | Use for                                         |
| ---------- | ----------------------------------------------- |
| `fix`      | a bug fix in the source — **releases a patch**  |
| `feat`     | a feature in the source — **releases a minor**  |
| `ci`       | workflows, devcontainer                         |
| `build`    | build tooling and scripts                       |
| `docs`     | documentation only                              |
| `test`     | tests only                                      |
| `refactor` | internal restructuring with no behaviour change |
| `chore`    | anything else                                   |

Nothing in this repository is released — it is private to the org and publishes no
package — so `fix` and `feat` here mean "a fix or a feature in the workspace tooling"
rather than a version bump. Scopes in practice: `repos` for the register and the pinned
commits, `ws` for the CLI, `devcontainer` for the container.

`cz` (commitizen) is installed in the devcontainer and will prompt for the parts.

**Breaking changes** add a `BREAKING CHANGE: <summary>` line to the commit body,
after a blank line. That triggers a major bump, so it also needs a migration note
for consumers in the same change.

Do **not** add `Co-Authored-By:` trailers.

## Branches and pull requests

- Branch from an up-to-date default branch: `git checkout main && git pull --ff-only`
  before `git checkout -b`. Never branch from a stale local default branch or from
  another feature branch.
- Name branches after the Jira issue: `RSRMID-1234/short-description`.
- Include the Jira issue link in the PR description, and add the PR URL as a comment
  on the Jira issue after opening it.
- **Rebase-merge** (`gh pr merge --rebase`). Squash merges are disabled at the
  repository level, because the release tooling reads the individual commits.

## Formatting

Prettier owns everything it understands (Markdown, JSON, YAML) and runs in CI, not
just as a local nag — unformatted Markdown is a red build. The pre-commit hook runs
`lint-staged` over what you staged, so in practice it is fixed before it reaches CI.

`repos/` is excluded from all of it — those files belong to the repositories that own
them, each with its own prettier config. Format them with
`./scripts/ws.sh foreach 'pnpm prettier:fix'`.

## Code of Conduct

### Our Pledge

In the interest of fostering an open and welcoming environment, we as contributors
and maintainers pledge to making participation in our project and our community a
harassment-free experience for everyone, regardless of age, body size, disability,
ethnicity, gender identity and expression, level of experience, nationality,
personal appearance, race, religion, or sexual identity and orientation.

### Our Standards

Examples of behavior that contributes to creating a positive environment include:

- Using welcoming and inclusive language
- Being respectful of differing viewpoints and experiences
- Gracefully accepting constructive criticism
- Focusing on what is best for the community
- Showing empathy towards other community members

Examples of unacceptable behavior by participants include:

- The use of sexualized language or imagery and unwelcome sexual attention or
  advances
- Trolling, insulting/derogatory comments, and personal or political attacks
- Public or private harassment
- Publishing others' private information, such as a physical or electronic address,
  without explicit permission
- Other conduct which could reasonably be considered inappropriate in a professional
  setting

### Our Responsibilities

Project maintainers are responsible for clarifying the standards of acceptable
behavior and are expected to take appropriate and fair corrective action in response
to any instances of unacceptable behavior.

Project maintainers have the right and responsibility to remove, edit, or reject
comments, commits, code, wiki edits, issues, and other contributions that are not
aligned to this Code of Conduct, or to ban temporarily or permanently any
contributor for other behaviors that they deem inappropriate, threatening,
offensive, or harmful.

### Scope

This Code of Conduct applies both within project spaces and in public spaces when an
individual is representing the project or its community. Examples of representing a
project or community include using an official project e-mail address, posting via
an official social media account, or acting as an appointed representative at an
online or offline event. Representation of a project may be further defined and
clarified by project maintainers.

### Enforcement

Instances of abusive, harassing, or otherwise unacceptable behavior may be reported
by contacting the project team. All complaints will be reviewed and investigated and
will result in a response that is deemed necessary and appropriate to the
circumstances. The project team is obligated to maintain confidentiality with regard
to the reporter of an incident. Further details of specific enforcement policies may
be posted separately.

Project maintainers who do not follow or enforce the Code of Conduct in good faith
may face temporary or permanent repercussions as determined by other members of the
project's leadership.

### Attribution

This Code of Conduct is adapted from the [Contributor Covenant][homepage], version
1.4, available at [http://contributor-covenant.org/version/1/4][version]

[homepage]: http://contributor-covenant.org
[version]: http://contributor-covenant.org/version/1/4/

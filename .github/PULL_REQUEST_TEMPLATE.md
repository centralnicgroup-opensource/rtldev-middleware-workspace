# Summary

<!-- What changes, and why. One or two sentences; the commit history has the detail. -->

**Jira:** RSRMID-<!-- id -->

## Type of change

- [ ] Workspace tooling (`feat` / `fix` with scope `ws`)
- [ ] Submodule register — repositories added or removed (`feat`/`chore` scope `repos`)
- [ ] Pinned commits moved (`chore(repos)`)
- [ ] Devcontainer or CI (`ci`)
- [ ] Documentation only (`docs`)

## How this was verified

<!-- What you actually ran, and what it said. "It works" is not verification;
     "./scripts/ws.sh sync devcontainer-features — populated, status ok" is.
     For a tooling change, say which repositories you ran it against. -->

## Checklist

- [ ] Commit messages follow `<type>(<scope>): <summary>` with a scope
- [ ] `shellcheck --severity=warning` and `prettier --check .` pass locally
- [ ] `.gitmodules` and the index agree (the `register` CI job covers this)
- [ ] Pinned commits point at commits that are **pushed**, not local-only
- [ ] Bulk commands still skip rather than force on a dirty or diverged repository
- [ ] No secrets, credentials or internal hostnames in the diff

## Notes for the reviewer

<!-- Anything worth a second pair of eyes: a decision you were unsure about, a
     trade-off you took, something deliberately left out of scope. -->

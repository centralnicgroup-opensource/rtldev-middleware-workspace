# Development image for the workspace repository.
#
# Deliberately thin, for the same reason as in rtldev-middleware-template: the
# packages, timezone, zsh configuration and commitizen setup live in the devbase
# Feature, not here.
#
# The one addition over the template's Dockerfile is the cross-repository search and
# reporting toolchain. It sits here rather than in devbase because it is what makes
# *this* repository what it is — bulk grep/replace and status tables over 18
# checkouts — and not something every product repository needs in its image.

FROM mcr.microsoft.com/devcontainers/base:2-ubuntu-24.04

# Not set as an image-level ENV: DEBIAN_FRONTEND at image level persists into the
# running container, so an interactive `apt` in a shell session also loses its
# frontend. Layers that need it set it for themselves, as the one below does.
ENV TERM=xterm-256color

# ripgrep  - the bulk-search workhorse; respects .gitignore, so it skips node_modules
#            and vendor/ across every submodule without a prune list.
# fd-find  - path-side equivalent, used by scripts/ws.sh to locate files by name.
#            Ubuntu ships the binary as `fdfind`; the symlink restores the upstream
#            name that every fd invocation and its own docs use.
# jq       - reads the GitHub API in scripts/repos.sh and the hook payload in
#            .claude/hooks/tool-output-hygiene.sh, which denies without it.
# parallel - bounded fan-out for `ws.sh foreach`; xargs -P cannot keep each repo's
#            output as one uninterleaved block, and interleaved output from 18 repos
#            is unreadable.
# hadolint ignore=DL3008
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && apt-get -y install --no-install-recommends \
       ripgrep \
       fd-find \
       jq \
       parallel \
    && ln -s "$(command -v fdfind)" /usr/local/bin/fd \
    && apt-get -y autoremove \
    && apt-get -y clean \
    && rm -rf /var/lib/apt/lists/*

# GNU parallel prints a citation notice on first run per user and blocks on it in a
# non-interactive shell. Silencing it is the documented opt-out.
RUN mkdir -p /home/vscode/.parallel \
    && touch /home/vscode/.parallel/will-cite \
    && chown -R vscode:vscode /home/vscode/.parallel

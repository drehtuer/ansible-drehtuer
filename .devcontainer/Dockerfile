# syntax=docker/dockerfile:1
# https://docs.docker.com/reference/dockerfile/
FROM  ubuntu:26.04

LABEL name="Ansible controller" \
    description="Control node running Ubuntu 26.04" \
    version="1.18"

ARG   DEBIAN_FRONTEND=noninteractive
ARG   ARG_USER

ENV   LANG=en_US.utf8

RUN   \
    # apt cache folders as tmpfs, discarded after build.
    # No need to delete these folders later
    --mount=type=tmpfs,target=/var/lib/apt/lists \
    --mount=type=tmpfs,target=/var/cache/apt \
    \
    apt-get update \
    && apt-get upgrade \
    --yes \
    -qq \
    && apt-get install \
    --no-install-recommends \
    --yes \
    -qq \
    # Ansible. ansible-lint is not installed here - see the pinned
    # pip install below.
    ansible \
    # Let's be on the safe side,
    # our default shell should be
    # available
    bash \
    bash-completion \
    # git within devcontainer
    git \
    # locales support
    locales \
    # Python support
    python3.14 \
    python-is-python3 \
    # Invoke to organize cmd commands
    python3-invoke \
    # Molecule and its Docker driver, for the role
    # tests. pip is needed because neither is
    # packaged for Ubuntu 26.04.
    python3-pip \
    python3-venv \
    # community.docker's modules, which molecule's docker driver uses
    # to create and destroy test containers, talk to the daemon over
    # HTTP with `requests` - the collection dropped the docker SDK in
    # v5. It has to be on the *system* interpreter rather than in
    # /opt/molecule: the driver runs its create/destroy playbooks
    # against localhost, where Ansible picks /usr/bin/python3, so a
    # copy inside molecule's virtualenv is never the one imported.
    #
    # Without it every scenario fails at `destroy` with "Failed to
    # import the required Python library (requests) on dev_host's
    # Python /usr/bin/python3" - which names the interpreter, and is
    # the detail that says where to install it.
    python3-requests \
    # Antora is a Node application and is what `invoke docs` builds
    # the documentation site with. Ubuntu packages Node 22, which is
    # comfortably above the 16 Antora asks for, so this needs no
    # third-party apt repository.
    nodejs \
    npm \
    # User may become root
    sudo \
    # Editor
    neovim \
    luarocks \
    # Documentation. Every page under doc/ is AsciiDoc, and this one
    # package is both halves of handling it: it renders the pages (the
    # `include::.attributes-page.adoc[]` at the top of each already
    # asks for html5, :data-uri: and a table of contents), and it is
    # the structural linter for them. `--failure-level=WARN` is what
    # makes it the latter - a dropped table cell, a missing include or
    # a section level skipped becomes a non-zero exit instead of a
    # warning that scrolls past.
    #
    # Know what it does NOT catch, measured rather than assumed: an
    # unresolved cross-reference produces no warning at any failure
    # level, in either the `<<id>>` or the `xref:id[]` form. It is
    # rendered as a dead link reading `[id]` and the build succeeds.
    # The prose-style linters (vale and friends) would not help - they
    # check writing rather than structure - so this gap is open rather
    # than covered by something else.
    #
    # Unpinned here because Ubuntu 26.04 packages 2.0.26, which is
    # current enough to have the checks above. That is not true of
    # every release and the difference is not cosmetic: 24.04 ships
    # 2.0.20, which is *silent* on the incomplete-table error that was
    # dropping 44 KB of doc/STATUS.adoc from its own render. That is
    # why .github/workflows/lint.yml installs a pinned gem rather than
    # the runner's apt package - see the comment there.
    asciidoctor \
    # Network
    ca-certificates \
    curl \
    iputils-ping \
    ssh \
    sshpass \
    wget \
    # Docker CLI, so molecule's docker driver can create and destroy
    # test containers over the host's docker socket, bind-mounted in
    # by devcontainer.json - no daemon runs in the container itself.
    # Ubuntu 26.04 packages its own build, so no extra apt repo (and
    # its distro-version gating) is needed.
    docker.io \
    docker-compose-v2 \
    # The deployment-test VM (.claude/skills/testlab). QEMU runs the
    # guest right here in the container against /dev/kvm, which
    # devcontainer.json passes through - the WSL2 kernel exposes KVM
    # and this host has nested virtualization enabled. No libvirt and
    # no root: the guest uses user-mode networking with a forwarded
    # SSH port, so nothing needs a bridge or NET_ADMIN.
    qemu-system-x86 \
    qemu-utils \
    # cloud-localds, which builds the cloud-init seed image that
    # gives the guest its user, SSH key and hostname on first boot.
    cloud-image-utils \
    # Attaches a terminal to the guest's serial console, which is the
    # way back in when SSH is broken.
    socat \
    # `wg genkey`/`wg pubkey`/`wg genpsk`, for the key material
    # roles/wireguard/scripts/ generates on the controller rather than
    # on the target - the server's own key and the configuration of
    # any peer that cannot generate its own (a Windows box, a phone).
    # The tunnel is never brought up here; only the tools are needed.
    wireguard-tools \
    # Renders a peer configuration as a QR code
    # (roles/wireguard/scripts/show-peer.sh --qr), which is how a
    # phone gets one without anybody typing 44 base64 characters.
    qrencode \
    # GitHub CLI apt repo, added below,
    # needs its keyring dir to exist first
    && install -d -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install \
    --no-install-recommends \
    --yes \
    -qq \
    # GitHub CLI, not in Ubuntu's own repos
    gh \
    # Generate en_US.UTF-8 locales. No --alias-file: Ubuntu's
    # locales package no longer ships /usr/share/locale/locale.alias.
    && localedef \
    --inputfile=en_US \
    --force \
    --charmap=UTF-8 \
    en_US.UTF-8 \
    # Add non-root user
    && useradd \
    --create-home \
    --user-group \
    --shell /usr/bin/bash \
    ${ARG_USER} \
    # Passwordless sudo: this is a single-user dev environment, not a
    # multi-user host, and fix-docker-gid.sh (run every container
    # start, see devcontainer.json) needs it to fix up group
    # membership for the bind-mounted host docker socket.
    && echo "${ARG_USER} ALL=(ALL) NOPASSWD:ALL" \
    > /etc/sudoers.d/${ARG_USER} \
    && chmod 440 /etc/sudoers.d/${ARG_USER} \
    && inv \
    --print-completion-script=bash \
    > /etc/bash_completion.d/invoke \
    && gh completion \
    --shell bash \
    > /etc/bash_completion.d/gh

# Keep in sync with the versions installed by
# .github/workflows/lint.yml, so CI and the Dev
# Container lint with the same ansible-lint.
# Ubuntu's own ansible-lint package has no version
# pin, which previously let it drift out from under
# the repo silently - see doc/TODO.adoc. yamllint is
# pinned alongside it: Ubuntu only ships it as a
# dependency of the (now unused) ansible-lint
# package, and ansible-lint itself requires a newer
# yamllint than Ubuntu 26.04 packages.
ARG   ANSIBLE_LINT_VERSION=26.8.0
ARG   YAMLLINT_VERSION=1.38.0

RUN   \
    # --system-site-packages, not a fully isolated
    # venv like molecule's below: ansible-lint has to
    # see the same ansible-core and collections the
    # rest of the toolchain uses, not a separate copy
    # of its own, or it aborts with "versions do not
    # match". Installing straight into the system
    # Python instead of a venv was tried first and
    # rejected - Ubuntu's `ansible` package pulls in
    # python3-ansible-compat as a dependency, which
    # has no pip RECORD file and can't be upgraded in
    # place, so pip aborts.
    python3 -m venv \
    --system-site-packages \
    /opt/ansible-lint \
    && /opt/ansible-lint/bin/pip install \
    --quiet \
    --no-cache-dir \
    "ansible-lint==${ANSIBLE_LINT_VERSION}" \
    "yamllint==${YAMLLINT_VERSION}" \
    && ln -s /opt/ansible-lint/bin/ansible-lint /usr/local/bin/ansible-lint \
    && ln -s /opt/ansible-lint/bin/yamllint /usr/local/bin/yamllint

# Keep in sync with the version installed by
# .github/workflows/lint.yml, so CI and the
# Dev Container lint with the same ruff.
ARG   RUFF_VERSION=0.16.3

RUN   \
    # Python linter/formatter, not packaged for
    # Ubuntu 26.04, so install the pinned release
    # binary. uname -m maps to the x86_64/aarch64
    # build names used by upstream.
    curl \
    --location \
    --fail \
    --silent \
    --show-error \
    "https://github.com/astral-sh/ruff/releases/download/${RUFF_VERSION}/ruff-$(uname -m)-unknown-linux-gnu.tar.gz" \
    | tar \
    --extract \
    --gzip \
    --directory=/usr/local/bin \
    --strip-components=1 \
    "ruff-$(uname -m)-unknown-linux-gnu/ruff"

# Keep in sync with .github/workflows/docs.yml.
#
# kramdoc converts the Markdown skill definitions to
# AsciiDoc, which is what lets Antora render them -
# it reads AsciiDoc and nothing else. Ubuntu does not
# package it, so it is a pinned gem.
ARG   KRAMDOC_VERSION=2.1.1

RUN   gem install \
    --no-document \
    kramdown-asciidoc \
    --version "${KRAMDOC_VERSION}"

# The documentation site generator. Pinned like
# everything else here: Antora's output changes with
# its version, and a site that reorganises itself
# because a build tool moved is exactly the drift
# this repository pins against elsewhere.
#
# The CLI and the site generator are separate
# packages and must match; installing one alone gives
# "generator not found".
ARG   ANTORA_VERSION=3.1.15

RUN   npm install \
    --global \
    --no-fund \
    --no-audit \
    "@antora/cli@${ANTORA_VERSION}" \
    "@antora/site-generator@${ANTORA_VERSION}"

# Keep in sync with the versions installed by
# .github/workflows/test.yml, so CI and the Dev
# Container test with the same molecule.
ARG   MOLECULE_VERSION=26.8.0
ARG   MOLECULE_PLUGINS_VERSION=26.7.15

RUN   \
    # Neither is packaged for Ubuntu 26.04, and pip
    # refuses to install into the system Python
    # (PEP 668), so molecule gets its own virtualenv
    # with the entry point linked onto PATH.
    python3 -m venv /opt/molecule \
    && /opt/molecule/bin/pip install \
    --quiet \
    --no-cache-dir \
    "molecule==${MOLECULE_VERSION}" \
    "molecule-plugins[docker]==${MOLECULE_PLUGINS_VERSION}" \
    && ln -s /opt/molecule/bin/molecule /usr/local/bin/molecule

# The Claude Code CLI, so `claude` works in a container
# terminal and not just through the VS Code extension
# listed in devcontainer.json. Pinned like every other
# tool here, and bumped by editing this line.
ARG   CLAUDE_CODE_VERSION=2.1.228

RUN   \
    # Anthropic's install.sh is deliberately not used: it
    # installs under $HOME/.claude, which devcontainer.json
    # bind-mounts from the host, so anything written there at
    # build time is shadowed the moment the container starts.
    # The released binary is self-contained, so fetch the
    # pinned build straight from the release channel and drop
    # it on PATH system-wide instead. `claude update` cannot
    # replace a root-owned binary - rebuild the image to move
    # to a newer version.
    #
    # The download path names architectures x64/arm64, which
    # is what dpkg's amd64/arm64 maps onto with the one
    # substitution below.
    arch="$(dpkg --print-architecture | sed 's/amd64/x64/')" \
    && base="https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}" \
    && curl \
    --location \
    --fail \
    --silent \
    --show-error \
    "${base}/linux-${arch}/claude" \
    -o /usr/local/bin/claude \
    # The per-release manifest carries the SHA256 for each
    # platform; check the download against it rather than
    # pinning a hash here that would have to be updated in
    # lockstep with the version above.
    && curl \
    --location \
    --fail \
    --silent \
    --show-error \
    "${base}/manifest.json" \
    | python3 -c \
    "import json,sys;print(json.load(sys.stdin)['platforms']['linux-${arch}']['checksum'] + '  /usr/local/bin/claude')" \
    | sha256sum --check - \
    && chmod 755 /usr/local/bin/claude

COPY \
    --chmod=644 \
    ansible-galaxy.yml \
    /ansible-galaxy.yml

RUN \
    ansible-galaxy \
    install \
    --role-file \
    /ansible-galaxy.yml \
    # Collections go to a system-wide path rather than the default
    # ~/.ansible of whoever runs this (root, at build time - the
    # non-root user would never see them). /usr/share/ansible is
    # searched by every ansible-core, including the one inside the
    # molecule virtualenv, which has no collections of its own.
    #
    # --force-with-deps, and without it this step silently does
    # nothing. Ubuntu's `ansible` package bundles ~50 collections into
    # /usr/lib/python3/dist-packages/ansible_collections, these three
    # among them, so ansible-galaxy finds them already installed and
    # prints "Nothing to do. All requested collections are already
    # installed" - then exits 0, leaving --collections-path empty and
    # the build green. That is invisible until molecule runs: its
    # virtualenv cannot see dist-packages, so it fails at the
    # dependency stage with "Collection 'community.docker' not found".
    #
    # `--force` alone is not enough. It reinstalls what was asked for
    # but not what those depend on, so community.docker lands without
    # community.library_inventory_filtering_v1 and its modules break
    # on import. Both were measured here rather than reasoned about.
    && ansible-galaxy \
    collection \
    install \
    --force-with-deps \
    --requirements-file \
    /ansible-galaxy.yml \
    --collections-path \
    /usr/share/ansible/collections


COPY \
    --chmod=755 \
    fix-docker-gid.sh \
    /usr/local/share/fix-docker-gid.sh

COPY \
    --chmod=755 \
    fix-kvm-perms.sh \
    /usr/local/share/fix-kvm-perms.sh

USER ${ARG_USER}

# Can't set default user here, USER takes
# only a string, but our user name is stored
# in a secret file. Don't want to add an additional
# environment variable, we set the user
# in devcontainer.json via 'remoteUser'.
# This also takes care of mapping uid:gid correctly.

# Keep container running, vscode needs
# to attach to it
CMD [ "sleep", "infinity" ]

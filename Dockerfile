FROM ubuntu:24.04

ARG NODE_MAJOR=24
ARG PYTHON_VERSION=3.12

ENV DEBIAN_FRONTEND=noninteractive
ENV SHELL=/usr/bin/zsh
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV FNM_DIR=/home/ubuntu/.local/share/fnm

# ── Core packages ──────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg git openssh-client sudo \
    zsh fzf ripgrep jq unzip wget \
    tmux \
    tree htop lsof file \
    build-essential \
    python${PYTHON_VERSION} python${PYTHON_VERSION}-venv python${PYTHON_VERSION}-dev python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Make the installed python the default
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python${PYTHON_VERSION} 1 \
    && update-alternatives --install /usr/bin/python python /usr/bin/python${PYTHON_VERSION} 1

# ── Neovim (latest stable) ────────────────────────────────────────────
RUN curl -fsSL https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz \
    | tar -xz -C /opt \
    && ln -sf /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim

# ── GitHub CLI ────────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ── Google Cloud CLI ─────────────────────────────────────────────────
RUN curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
      | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
      > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update && apt-get install -y --no-install-recommends google-cloud-cli \
    && rm -rf /var/lib/apt/lists/*

# ── Configure existing ubuntu user ────────────────────────────────────
RUN chsh -s /usr/bin/zsh ubuntu \
    && echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu

USER ubuntu
WORKDIR /home/ubuntu

# ── Shell setup via dotzsh ────────────────────────────────────────────
RUN git clone https://github.com/kurtb/dotzsh ${HOME}/dev/dotzsh \
    && cp /etc/zsh/newuser.zshrc.recommended ${HOME}/.zshrc \
    && ${HOME}/dev/dotzsh/install.sh

# ── Node.js (fnm) ────────────────────────────────────────────────────
RUN curl -fsSL https://fnm.vercel.app/install | bash \
    && export PATH="${FNM_DIR}:$PATH" \
    && fnm install ${NODE_MAJOR} \
    && fnm default ${NODE_MAJOR}

ENV PATH=/home/ubuntu/.local/bin:${FNM_DIR}/aliases/default/bin:${PATH}

# ── Pulumi ────────────────────────────────────────────────────────────
RUN curl -fsSL https://get.pulumi.com | bash

ENV PATH=/home/ubuntu/.pulumi/bin:${PATH}

# ── Claude Code ───────────────────────────────────────────────────────
RUN curl -fsSL https://claude.ai/install.sh | bash

# ── Vim setup via dotvim ────────────────────────────────────────────
RUN git clone https://github.com/kurtb/dotvim ${HOME}/dev/dotvim \
    && ${HOME}/dev/dotvim/install.sh

# ── Working directory for mounted source code ─────────────────────────
RUN mkdir -p /home/ubuntu/workspace
WORKDIR /home/ubuntu/workspace

ENTRYPOINT ["/usr/bin/zsh"]

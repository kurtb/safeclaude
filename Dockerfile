FROM ubuntu:24.04

ARG NODE_MAJOR=22
ARG PYTHON_VERSION=3.12

ENV DEBIAN_FRONTEND=noninteractive
ENV SHELL=/usr/bin/zsh
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV NVM_DIR=/home/ubuntu/.nvm

# ── Core packages ──────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg git openssh-client sudo \
    zsh fzf ripgrep jq unzip wget \
    neovim tmux \
    tree htop lsof file \
    build-essential \
    python${PYTHON_VERSION} python${PYTHON_VERSION}-venv python${PYTHON_VERSION}-dev python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Make the installed python the default
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python${PYTHON_VERSION} 1 \
    && update-alternatives --install /usr/bin/python python /usr/bin/python${PYTHON_VERSION} 1

# ── Configure existing ubuntu user ────────────────────────────────────
RUN chsh -s /usr/bin/zsh ubuntu \
    && echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu

USER ubuntu
WORKDIR /home/ubuntu

# ── Shell setup via dotzsh ────────────────────────────────────────────
RUN git clone --recurse-submodules https://github.com/kurtb/dotzsh ${HOME}/dev/dotzsh \
    && cp /etc/zsh/newuser.zshrc.recommended ${HOME}/.zshrc \
    && ${HOME}/dev/dotzsh/install.sh

# ── Node.js (nvm) ────────────────────────────────────────────────────
RUN curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash \
    && . "$NVM_DIR/nvm.sh" \
    && nvm install ${NODE_MAJOR} \
    && nvm alias default ${NODE_MAJOR} \
    && ln -sf "$(dirname "$(nvm which default)")" "$NVM_DIR/current"

ENV PATH=/home/ubuntu/.local/bin:${NVM_DIR}/current:${PATH}

# ── Claude Code ───────────────────────────────────────────────────────
RUN curl -fsSL https://claude.ai/install.sh | bash

# ── Working directory for mounted source code ─────────────────────────
RUN mkdir -p /home/ubuntu/workspace
WORKDIR /home/ubuntu/workspace

ENTRYPOINT ["/usr/bin/zsh"]

FROM python:3.12-slim

ARG NODE_MAJOR=20
ARG TTYD_VERSION=1.7.7

# ── System dependencies ──────────────────────────────────────────────
# build-essential + python3-dev + libffi-dev: needed by install.sh for
#   node-gyp (native node-pty) and native Python wheels.
# xz-utils: needed to extract Node.js .tar.xz archives.
# libatomic1: required by Node.js binary on slim images.
# file, procps, less: general utilities that slim omits.
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget gnupg ca-certificates apt-transport-https \
    git openssh-client iptables iproute2 bash \
    build-essential python3-dev libffi-dev \
    xz-utils libatomic1 file procps less \
    && curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ── ttyd (web terminal) ──────────────────────────────────────────────
# curl -fsSL fails on HTTP errors (wget -qO silently writes error pages).
# Verify the binary actually runs before continuing.
RUN curl -fsSL -o /usr/local/bin/ttyd \
      "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" \
    && chmod +x /usr/local/bin/ttyd \
    && /usr/local/bin/ttyd --version

# ── Non-root user (must exist before hermes install) ─────────────────
RUN useradd -m -s /bin/bash hermes \
    && mkdir -p /workspace && chown hermes:hermes /workspace \
    && mkdir -p /home/hermes/.hermes && chown -R hermes:hermes /home/hermes/.hermes

# ── gosu (root → hermes privilege drop) ──────────────────────────────
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL -o /usr/local/bin/gosu \
      "https://github.com/tianon/gosu/releases/download/1.17/gosu-${ARCH}" \
    && chmod +x /usr/local/bin/gosu \
    && gosu --version

# ── Hermes Agent (official installer) ────────────────────────────────
# --dir /opt/hermes-agent: code + venv live in the image, never mounted.
# --hermes-home /home/hermes/.hermes: data/config dir (safe to bind-mount).
# Then copy the launcher to /usr/local/bin — always on PATH.
RUN chown hermes:hermes /opt \
    && gosu hermes bash -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- \
    --skip-browser --skip-computer-use --skip-setup --no-skills \
    --dir /opt/hermes-agent --hermes-home /home/hermes/.hermes' \
    && cp /home/hermes/.local/bin/hermes /usr/local/bin/hermes \
    && chmod +x /usr/local/bin/hermes \
    && hermes --version

# ── OpenCode CLI ─────────────────────────────────────────────────────
RUN npm i -g opencode-ai@latest

# ── Antigravity CLI ─────────────────────────────────────────────────
RUN gosu hermes bash -c 'curl -fsSL https://antigravity.google/cli/install.sh | bash' \
    && for f in /home/hermes/.local/bin/*; do \
         [ -f "$f" ] && cp "$f" "/usr/local/bin/$(basename "$f")" 2>/dev/null; \
       done; true

# ── GitHub CLI ───────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ── Security hardening ───────────────────────────────────────────────
RUN find / -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true

# PATH for hermes + opencode (ENV so it works in every shell, not just .bashrc)
ENV PATH="/home/hermes/.local/bin:/home/hermes/.opencode/bin:/usr/local/bin:${PATH}"

# ── Entrypoint scripts ───────────────────────────────────────────────
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace
EXPOSE 7681

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO /dev/null http://localhost:7681 || exit 1

ENTRYPOINT ["/entrypoint.sh"]

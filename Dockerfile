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
    && gosu hermes hermes --version \
    && chown -R hermes:hermes /opt/hermes-agent

# ── AI Coding CLIs ──────────────────────────────────────────────────
RUN npm i -g opencode-ai@latest \
    && npm i -g @openai/codex@latest \
    && npm i -g @anthropic-ai/claude-code@latest \
    && npm i -g @mimo-ai/cli@latest

# ── Antigravity CLI ─────────────────────────────────────────────────
RUN gosu hermes bash -c 'curl -fsSL https://antigravity.google/cli/install.sh | bash' \
    && for f in /home/hermes/.local/bin/*; do \
         [ -f "$f" ] && cp "$f" "/usr/local/bin/$(basename "$f")" 2>/dev/null; \
       done; true

# ── GitHub CLI (standalone binary, no apt needed) ─────────────────────
RUN GH_VERSION="2.101.0" \
    && ARCH=$(dpkg --print-architecture) \
    && curl -fsSL -o /tmp/gh.tar.gz \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH}.tar.gz" \
    && tar xzf /tmp/gh.tar.gz -C /tmp \
    && mv /tmp/gh_${GH_VERSION}_linux_${ARCH}/bin/gh /usr/local/bin/gh \
    && rm -rf /tmp/gh* \
    && gh --version

# ── Security hardening ───────────────────────────────────────────────
RUN find / -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true

# PATH for hermes + opencode (ENV so it works in every shell, not just .bashrc)
ENV PATH="/home/hermes/.local/bin:/home/hermes/.opencode/bin:/usr/local/bin:${PATH}"

# TMPDIR must NOT be /tmp: Docker mounts it with the noexec option (default for
# tmpfs entries), so native libraries extracted there at runtime (e.g. opencode's
# OpenTUI renderer) cannot be dlopen()'d — "failed to map segment from shared
# object". The .hermes volume is exec-capable. entrypoint.sh creates and cleans
# this dir at startup.
ENV TMPDIR=/home/hermes/.hermes/cache/tmp

# ── Entrypoint scripts ───────────────────────────────────────────────
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace
EXPOSE 7681

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO /dev/null http://localhost:7681 || exit 1

ENTRYPOINT ["/entrypoint.sh"]

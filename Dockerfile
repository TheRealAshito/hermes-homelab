FROM python:3.12-slim

ARG NODE_MAJOR=20
ARG TTYD_VERSION=1.7.7

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget gnupg ca-certificates apt-transport-https \
    git openssh-client iptables iproute2 bash \
    && curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ttyd
RUN wget -qO /usr/local/bin/ttyd \
    "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" \
    && chmod +x /usr/local/bin/ttyd

# Non-root user (must exist before hermes install)
RUN useradd -m -s /bin/bash hermes \
    && mkdir -p /workspace && chown hermes:hermes /workspace \
    && mkdir -p /home/hermes/.hermes && chown -R hermes:hermes /home/hermes/.hermes

# Hermes Agent (official curl installer — sets up venv + launcher)
RUN su - hermes -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash'

# OpenCode CLI
RUN npm i -g opencode-ai@latest

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ── Security hardening ──────────────────────────────────────────────

RUN find / -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true

# PATH for hermes + opencode
RUN echo 'export PATH="$HOME/.local/bin:$HOME/.opencode/bin:/usr/local/bin:$PATH"' >> /home/hermes/.bashrc \
    && chown hermes:hermes /home/hermes/.bashrc

# gosu
RUN ARCH=$(dpkg --print-architecture) && \
    wget -qO /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/1.17/gosu-${ARCH}" \
    && chmod +x /usr/local/bin/gosu

COPY entrypoint.sh /entrypoint.sh
COPY gh-mcp-init.sh /gh-mcp-init.sh
RUN chmod +x /entrypoint.sh /gh-mcp-init.sh

WORKDIR /workspace
EXPOSE 7681

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO /dev/null http://localhost:7681 || exit 1

ENTRYPOINT ["/entrypoint.sh"]
CMD ["ttyd", "--writable", "-t", "fontSize=14", "-t", "theme={\"background\":\"#1e1e2e\",\"foreground\":\"#cdd6f4\"}", "bash"]

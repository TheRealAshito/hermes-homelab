FROM python:3.12-slim

ARG NODE_MAJOR=20
ARG TTYD_VERSION=1.7.7

# System deps — minimal attack surface
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget gnupg ca-certificates apt-transport-https \
    git openssh-client iptables iproute2 \
    && curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ttyd — web-based terminal
RUN wget -qO /usr/local/bin/ttyd \
    "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" \
    && chmod +x /usr/local/bin/ttyd

# Hermes Agent
RUN pip install --no-cache-dir hermes-agent

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ── Security hardening ──────────────────────────────────────────────

# Remove setuid/setgid binaries (defense-in-depth)
RUN find / -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true

# Non-root user
RUN useradd -m -s /bin/bash hermes \
    && mkdir -p /workspace && chown hermes:hermes /workspace

# Helpful .bashrc
RUN echo 'echo ""' >> /home/hermes/.bashrc \
    && echo 'echo "  Welcome to Hermes Homelab"' >> /home/hermes/.bashrc \
    && echo 'echo "  Workspace: /workspace"' >> /home/hermes/.bashrc \
    && echo 'echo "  Run \"hermes setup\" to configure your AI provider"' >> /home/hermes/.bashrc \
    && echo 'echo "  Run \"hermes chat\" to start chatting"' >> /home/hermes/.bashrc \
    && echo 'echo ""' >> /home/hermes/.bashrc \
    && chown hermes:hermes /home/hermes/.bashrc

# gosu — lightweight privilege drop
RUN ARCH=$(dpkg --print-architecture) && \
    wget -qO /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/1.17/gosu-${ARCH}" \
    && chmod +x /usr/local/bin/gosu

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace
EXPOSE 7681

ENTRYPOINT ["/entrypoint.sh"]
CMD ["ttyd", "--writable", "-t", "fontSize=14", "-t", "theme={\"background\":\"#1e1e2e\",\"foreground\":\"#cdd6f4\"}", "bash"]

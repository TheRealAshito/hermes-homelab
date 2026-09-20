#!/bin/bash
# ── GitHub MCP Auto-Config ──────────────────────────────────────────
# Checks if `gh auth login` is done and auto-configures the GitHub
# MCP server in Hermes. Idempotent — safe to run on every startup.
#
# Runs as the hermes user before the main ttyd process starts.
# ═══════════════════════════════════════════════════════════════════

GITHUB_MCP_PKG="@modelcontextprotocol/server-github"

# Check if gh is authenticated
if ! gh auth status >/dev/null 2>&1; then
  echo "[gh-mcp] GitHub CLI not authenticated. Run 'gh auth login' to enable GitHub MCP."
  exit 0
fi

# Check if GitHub MCP is already configured in hermes
if hermes mcp list 2>/dev/null | grep -q "github"; then
  echo "[gh-mcp] GitHub MCP already configured."
  exit 0
fi

# Extract the token
TOKEN=$(gh auth token 2>/dev/null)
if [ -z "$TOKEN" ]; then
  echo "[gh-mcp] Could not extract GitHub token. Skipping MCP setup."
  exit 0
fi

# Add GitHub MCP server to Hermes
echo "[gh-mcp] Configuring GitHub MCP server..."
hermes mcp add github \
  --command npx \
  --args -y "$GITHUB_MCP_PKG" \
  --env "GITHUB_PERSONAL_ACCESS_TOKEN=$TOKEN" \
  --connect-timeout 30 \
  2>&1

if [ $? -eq 0 ]; then
  echo "[gh-mcp] GitHub MCP configured successfully."
else
  echo "[gh-mcp] Failed to configure GitHub MCP (non-fatal, hermes will still work)."
fi

# hermes-homelab

Run [Hermes Agent](https://github.com/nousresearch/hermes-agent) as a sandboxed Docker container on your homelab. Access it from any browser.

## What it does

- Runs Hermes Agent in an isolated Docker container
- Web-based terminal on port 7681 (works on desktop and mobile)
- **Filesystem isolation**: AI can only write to `/workspace` inside the container
- **Network isolation**: blocks all LAN access (192.168.x, 10.x, 172.16-31.x), internet-only for cloud API calls
- Persistent storage for chats, memory, skills, and workspace files
- Supports any OpenAI-compatible API (MiMo, DeepSeek, Claude, OpenAI, etc.)
- GitHub MCP auto-config when `gh auth login` is done inside the container
- Backup/restore for all persistent data

## Requirements

- Docker + Docker Compose on your homelab
- ~500MB RAM available
- A cloud AI API key (OpenAI-compatible endpoint)

## Quick start

```bash
# 1. Clone
git clone https://github.com/TheRealAshito/hermes-homelab.git
cd hermes-homelab

# 2. Set your web terminal password
nano .env    # change TTYD_USER and TTYD_PASSWORD

# 3. Build and run
make build
make up

# 4. Open in browser
# http://<your-homelab-ip>:7681
```

On first connect you'll land in a bash shell. Run:

```bash
hermes setup
```

This walks you through configuring your AI provider (API key, endpoint, model).

## Nginx Proxy Manager setup

To make it available as `hermes.lan`:

1. Add a new Proxy Host in NPM
2. Domain: `hermes.lan`
3. Forward to: `<homelab-ip>:7681`
4. Enable WebSocket support (required for ttyd)
5. Optional: add SSL cert

## Usage

Once inside the web terminal:

```bash
# Start a chat with Hermes
hermes chat

# One-shot mode
hermes -z "write a python script that fetches weather data"

# Configure model/provider
hermes config set provider.openai.api_key sk-...
hermes config set provider.openai.model gpt-4o

# Check status
hermes status
```

## GitHub MCP Integration

The container auto-configures the GitHub MCP server when you authenticate with `gh`:

```bash
# Inside the web terminal:
gh auth login          # follow the prompts
# GitHub MCP is automatically configured on next container restart
# Or trigger it manually:
/gh-mcp-init.sh
```

This gives Hermes access to GitHub repos, issues, PRs, etc. via MCP tools.

## Security

See [SECURITY-AUDIT.md](SECURITY-AUDIT.md) for the full threat model.

### Security layers

| Layer | What it does |
|---|---|
| Non-root user | Container runs as uid 1000 (hermes), not root |
| read_only rootfs | Container filesystem is read-only, only /workspace and /tmp are writable |
| no-new-privileges | Setuid binaries cannot escalate to root |
| setuid removal | All setuid/setgid binaries stripped at build and runtime |
| IPv4 iptables | All RFC1918 ranges (10.x, 172.16-31.x, 192.168.x) blocked |
| IPv6 fully blocked | ip6tables DROP all + sysctl disable_ipv6 |
| Multicast blocked | No LAN discovery via mDNS/SSDP |
| DNS forced | Only 1.1.1.1 and 8.8.8.8 (no Docker internal DNS leaking LAN names) |
| cap_drop ALL | All Linux capabilities dropped except NET_ADMIN |
| No Docker socket | Docker socket is NOT mounted — no container escape |
| Resource limits | nproc=512 (fork bomb protection), nofile=65536 |
| TTYD basic auth | Web terminal requires username/password |
| Health check | Docker HEALTHCHECK verifies ttyd is responding |

### Running security tests

After starting the container:

```bash
# From inside the web terminal:
bash /workspace/security-test.sh

# Or from the host:
make test-security
```

### Running persistence tests

From the host:

```bash
make test-persistence
```

## Backup & Restore

Back up all persistent data (workspace, hermes config, home directory):

```bash
# Create a backup
make backup
# → ./backups/hermes-backup-20260920-143000.tar.gz

# Restore from backup
bash restore.sh ./backups/hermes-backup-20260920-143000.tar.gz
```

Backups are compressed tarballs of all three Docker volumes. Restore overwrites current data and restarts the container.

## Makefile commands

```
make build              Build the Docker image
make up                 Start the container
make down               Stop the container
make restart            Restart the container
make logs               Follow container logs
make test-security      Run security verification inside container
make test-persistence   Run persistence verification from host
make update             Rebuild image + restart (preserves volumes)
make status             Show container status + RAM usage
make backup             Backup all volumes to ./backups/
make clean              ⚠ Delete ALL volumes (destroys hermes data)
```

## Updating

```bash
# Pull latest changes and rebuild (preserves all data)
git pull
make update
```

To update the Hermes Agent version itself:

```bash
# Edit Dockerfile: change hermes-agent version if pinned
# Then rebuild:
make update
```

Your chats, memory, skills, and workspace files are preserved across updates (they live in Docker volumes, not in the image).

## Architecture

```
Browser  →  NPM (:443)  →  Docker Container (:7681)
                               ├── ttyd (web terminal, basic auth)
                               ├── hermes (AI agent CLI)
                               ├── git + gh (GitHub operations)
                               ├── GitHub MCP (auto-configured)
                               └── node.js (MCP servers)
                                    │
                                    ├── /workspace    (volume — your files)
                                    ├── ~/.hermes      (volume — chats, memory, skills)
                                    └── network: LAN blocked, internet OK
```

## RAM usage

Expected runtime memory: **300–500 MB**

| Component | RAM |
|---|---|
| Python + Hermes | ~200MB |
| Node.js (when MCPs active) | ~80MB |
| ttyd | ~2MB |
| OS overhead | ~50MB |

## Troubleshooting

**Terminal says "WARNING: iptables not available"**
→ The container needs NET_ADMIN capability. Check that `cap_add: - NET_ADMIN` is in docker-compose.yml.

**Can't connect to AI API**
→ Check that your API key is set (`hermes config`). The container allows outbound HTTPS (port 443) and HTTP (port 80) but blocks all other ports.

**"Permission denied" on workspace files**
→ Run `docker exec hermes-homelab chown -R hermes:hermes /workspace` from the host.

**Forgot web terminal password**
→ Edit `.env` and run `docker compose up -d` to restart with new credentials.

**GitHub MCP not working**
→ Make sure `gh auth login` completed successfully inside the container. Run `/gh-mcp-init.sh` to manually trigger MCP configuration. Check with `hermes mcp list`.

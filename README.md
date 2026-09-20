# hermes-homelab

Run [Hermes Agent](https://github.com/nousresearch/hermes-agent) as a sandboxed Docker container on your homelab. Access it from any browser.

## What it does

- Runs Hermes Agent in an isolated Docker container
- Web-based terminal on port 7681 (works on desktop and mobile)
- **Filesystem isolation**: AI can only write to `/workspace` inside the container
- **Network isolation**: blocks all LAN access (192.168.x, 10.x, 172.16-31.x), internet-only for cloud API calls
- Persistent storage for chats, memory, skills, and workspace files
- Supports any OpenAI-compatible API (MiMo, DeepSeek, Claude, OpenAI, etc.)

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
docker compose up -d --build

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

# Or use one-shot mode
hermes -z "write a python script that fetches weather data"

# Configure model/provider at any time
hermes config set provider.openai.api_key sk-...
hermes config set provider.openai.model gpt-4o

# Check status
hermes status
```

## Architecture

```
Browser  →  NPM (:443)  →  Docker Container (:7681)
                               ├── ttyd (web terminal)
                               ├── hermes (AI agent CLI)
                               ├── git + gh (GitHub operations)
                               └── node.js (MCP servers)
                                    │
                                    ├── /workspace    (volume — your files)
                                    ├── ~/.hermes      (volume — chats, memory, skills)
                                    └── network: LAN blocked, internet OK
```

## Security model

| Threat | Mitigation |
|---|---|
| AI accesses your media files | Only `/workspace` is mounted; no access to host filesystem |
| AI scans your LAN | iptables drops all RFC1918 traffic inside container |
| AI resolves LAN hostnames | DNS forced to 1.1.1.1 and 8.8.8.8 |
| Container breakout | Non-root user, read-only rootfs, cap_drop ALL (NET_ADMIN for iptables only) |
| Unauthorized web access | Basic auth on ttyd (set in `.env`) |

## Volumes

| Volume | Container path | Purpose |
|---|---|---|
| `hermes-workspace` | `/workspace` | AI-created files, projects, code |
| `hermes-config` | `/home/hermes/.hermes` | Chats, memory, skills, MCP config |
| `hermes-home` | `/home/hermes` | Git config, gh auth, shell history |

## Updating

```bash
cd hermes-homelab
docker compose build --no-cache
docker compose up -d
```

## RAM usage

Expected runtime memory: **300–500 MB**

- Python + Hermes: ~200MB
- Node.js (when MCPs are active): ~80MB
- ttyd: ~2MB
- OS overhead: ~50MB

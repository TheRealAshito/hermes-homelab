#!/bin/bash
# ──────────────────────────────────────────────────────────────────────
# hermes-homelab — one-command install & run
#
# Usage:
#   ./run.sh              Build + run (creates ./data/ if needed)
#   ./run.sh update       Rebuild + restart (preserves ./data/)
#   ./run.sh stop         Stop the container
#   ./run.sh logs         Follow container logs
#
# Data persists in ./data/ relative to this script.
# Override with: DATA_DIR=/some/path ./run.sh
# ──────────────────────────────────────────────────────────────────────
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${DATA_DIR:-$SCRIPT_DIR/data}"
IMAGE="hermes-homelab"
CONTAINER="hermes-homelab"
PORT="${PORT:-7681}"
TTYD_USER="${TTYD_USER:-hermes}"
TTYD_PASSWORD="${TTYD_PASSWORD:-changeme}"

# ── Commands ──────────────────────────────────────────────────────────

do_build() {
    echo "Building image..."
    docker build -t "$IMAGE" "$SCRIPT_DIR"
}

do_run() {
    # Create data dirs if they don't exist
    mkdir -p "$DATA_DIR/workspace"
    mkdir -p "$DATA_DIR/hermes-config"

    # Stop existing container if running
    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm "$CONTAINER" 2>/dev/null || true

    echo "Starting container..."
    echo "  Data:  $DATA_DIR"
    echo "  Login: $TTYD_USER / $TTYD_PASSWORD"
    echo "  URL:   http://localhost:$PORT"
    echo ""

    docker run -d \
        --name "$CONTAINER" \
        --restart unless-stopped \
        --cap-add NET_ADMIN \
        --cap-add SETUID \
        --cap-add SETGID \
        --cap-add DAC_OVERRIDE \
        --cap-add CHOWN \
        --security-opt no-new-privileges:true \
        --dns 1.1.1.1 \
        --dns 8.8.8.8 \
        -p "$PORT:7681" \
        -e TTYD_USER="$TTYD_USER" \
        -e TTYD_PASSWORD="$TTYD_PASSWORD" \
        -v "$DATA_DIR/workspace:/workspace" \
        -v "$DATA_DIR/hermes-config:/home/hermes/.hermes" \
        "$IMAGE"

    echo ""
    echo "Done! Open http://<your-ip>:$PORT in a browser."
    echo "Run 'hermes setup' inside the terminal to configure your AI provider."
}

case "${1:-run}" in
    run)
        do_build
        do_run
        ;;
    update)
        do_build
        do_run
        ;;
    stop)
        docker stop "$CONTAINER" 2>/dev/null || true
        docker rm "$CONTAINER" 2>/dev/null || true
        echo "Stopped."
        ;;
    logs)
        docker logs -f "$CONTAINER"
        ;;
    *)
        echo "Usage: $0 [run|update|stop|logs]"
        exit 1
        ;;
esac

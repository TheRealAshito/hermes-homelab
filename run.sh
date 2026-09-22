#!/bin/bash
# ──────────────────────────────────────────────────────────────────────
# hermes-homelab — one-command install & run
#
# Usage:
#   ./run.sh              Build + run (prompts for password on first run)
#   ./run.sh update       Rebuild + restart (preserves ./data/ and login)
#   ./run.sh stop         Stop the container
#   ./run.sh logs         Follow container logs
#
# Data persists in ./data/ relative to this script.
# Login saved in .env (git-ignored).
# Override with: DATA_DIR=/some/path PORT=8080 ./run.sh
# ──────────────────────────────────────────────────────────────────────
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${DATA_DIR:-$SCRIPT_DIR/data}"
ENV_FILE="$SCRIPT_DIR/.env"
IMAGE="hermes-homelab"
CONTAINER="hermes-homelab"

# ── Load or prompt for settings ──────────────────────────────────────

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

PORT="${PORT:-7681}"
TTYD_USER="${TTYD_USER:-}"

# First run: ask for credentials
if [ -z "$TTYD_USER" ] || [ -z "$TTYD_PASSWORD" ]; then
    echo ""
    echo "  ┌──────────────────────────────────────────┐"
    echo "  │  hermes-homelab — first-time setup        │"
    echo "  └──────────────────────────────────────────┘"
    echo ""
    read -rp "  Username [$TTYD_USER]: " input_user
    TTYD_USER="${input_user:-$TTYD_USER:-hermes}"

    # Prompt for password with hidden input + confirmation
    while true; do
        read -rsp "  Password: " pass1; echo
        read -rsp "  Confirm:  " pass2; echo
        if [ -z "$pass1" ]; then
            echo "  Password cannot be empty."
        elif [ "$pass1" != "$pass2" ]; then
            echo "  Passwords don't match, try again."
        else
            TTYD_PASSWORD="$pass1"
            break
        fi
    done

    # Save to .env (git-ignored)
    cat > "$ENV_FILE" <<EOF
PORT=$PORT
TTYD_USER=$TTYD_USER
TTYD_PASSWORD=$TTYD_PASSWORD
EOF
    chmod 600 "$ENV_FILE"
    echo ""
    echo "  Saved to $ENV_FILE (chmod 600)"
fi

# ── Commands ──────────────────────────────────────────────────────────

do_build() {
    echo "Building image..."
    docker build -t "$IMAGE" "$SCRIPT_DIR"
}

do_run() {
    mkdir -p "$DATA_DIR/workspace"
    mkdir -p "$DATA_DIR/hermes-config"

    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm "$CONTAINER" 2>/dev/null || true

    echo ""
    echo "  Starting container..."
    echo "  Data:    $DATA_DIR"
    echo "  Login:   $TTYD_USER"
    echo "  URL:     http://localhost:$PORT"
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

    echo "Done! Open http://<your-ip>:$PORT in a browser."
    echo "Run 'hermes setup' inside the terminal to configure your AI provider."
}

case "${1:-run}" in
    run|update)
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

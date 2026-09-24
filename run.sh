#!/bin/bash
# ──────────────────────────────────────────────────────────────────────
# hermes-homelab — one-command install & run
#
# Usage:
#   ./run.sh              Build + run (prompts for password on first run)
#   ./run.sh update       Rebuild + restart (preserves ./data/ and login)
#   ./run.sh passwd       Change web terminal password
#   ./run.sh shell        Open a shell in the running container
#   ./run.sh status       Show container status + resource usage
#   ./run.sh stop         Stop the container
#   ./run.sh logs         Follow container logs
#
# Data persists in ./data/ relative to this script.
# Login saved in .env (git-ignored, chmod 600).
# Override with: DATA_DIR=/some/path PORT=8080 ./run.sh
# ──────────────────────────────────────────────────────────────────────
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${DATA_DIR:-$SCRIPT_DIR/data}"
ENV_FILE="$SCRIPT_DIR/.env"
IMAGE="hermes-homelab"
CONTAINER="hermes-homelab"
PROXY_IMAGE="hermes-egress-proxy"
PROXY_CONTAINER="hermes-egress-proxy"
NETWORK="hermes-homelab-net"

# ── Load saved settings (safe parse, no source) ──────────────────────

PORT="${PORT:-7681}"
TTYD_USER="${TTYD_USER:-hermes}"
TTYD_PASSWORD="${TTYD_PASSWORD:-}"

if [ -f "$ENV_FILE" ]; then
    _v=$(grep '^PORT=' "$ENV_FILE" | cut -d= -f2-)
    [ -n "$_v" ] && PORT="$_v"
    _v=$(grep '^TTYD_USER=' "$ENV_FILE" | cut -d= -f2-)
    [ -n "$_v" ] && TTYD_USER="$_v"
    _v=$(grep '^TTYD_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)
    [ -n "$_v" ] && TTYD_PASSWORD="$_v"
fi

# ── Prompt for password if missing or default ─────────────────────────

need_password() {
    [ -z "$TTYD_PASSWORD" ] || [ "$TTYD_PASSWORD" = "changeme" ] || [ "$TTYD_PASSWORD" = "yourpassword" ]
}

prompt_password() {
    echo ""
    read -rp "  Username [$TTYD_USER]: " input_user
    TTYD_USER="${input_user:-$TTYD_USER}"

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

    umask 077
    cat > "$ENV_FILE" <<EOF
PORT=$PORT
TTYD_USER=$TTYD_USER
TTYD_PASSWORD=$TTYD_PASSWORD
EOF
    chmod 600 "$ENV_FILE"
    echo "  Saved to $ENV_FILE (chmod 600)"
}

# ── Commands ──────────────────────────────────────────────────────────

do_build() {
    echo "Building image..."
    docker build "$@" -t "$IMAGE" "$SCRIPT_DIR"
    echo "Building egress proxy image..."
    docker build "$@" -t "$PROXY_IMAGE" "$SCRIPT_DIR/egress-proxy"
}

do_run() {
    mkdir -p "$DATA_DIR/workspace"
    mkdir -p "$DATA_DIR/hermes-config"

    bash "$SCRIPT_DIR/egress-proxy/seed.sh"

    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm "$CONTAINER" 2>/dev/null || true

    # User-defined network so container names resolve (the app finds the
    # egress proxy by name). Idempotent.
    docker network create "$NETWORK" >/dev/null 2>&1 || true

    # Egress allowlist proxy — the app's only exit to the internet.
    docker rm -f "$PROXY_CONTAINER" 2>/dev/null || true
    docker run -d \
        --name "$PROXY_CONTAINER" \
        --restart unless-stopped \
        --memory 128m \
        --dns 1.1.1.1 \
        --dns 8.8.8.8 \
        --network "$NETWORK" \
        -v "$DATA_DIR/egress-allowlist.conf:/etc/egress/allowlist" \
        "$PROXY_IMAGE"

    echo ""
    echo "  Starting container..."
    echo "  Data:    $DATA_DIR"
    echo "  Login:   $TTYD_USER"
    echo "  URL:     http://localhost:$PORT"
    echo ""

    docker run -d \
        --name "$CONTAINER" \
        --restart unless-stopped \
        --runtime "${HERMES_RUNTIME:-runc}" \
        --memory "${HERMES_MEM_LIMIT:-2g}" \
        --cpus "${HERMES_CPUS:-2.0}" \
        --cap-drop ALL \
        --cap-add NET_ADMIN \
        --cap-add SETUID \
        --cap-add SETGID \
        --cap-add DAC_OVERRIDE \
        --cap-add CHOWN \
        --security-opt no-new-privileges:true \
        --tmpfs /tmp:size=256m \
        --tmpfs /run:size=64m \
        --ulimit nproc=512 \
        --ulimit nofile=65536 \
        --dns 1.1.1.1 \
        --dns 8.8.8.8 \
        --network "$NETWORK" \
        -p "$PORT:7681" \
        -e TTYD_USER="$TTYD_USER" \
        -e TTYD_PASSWORD="$TTYD_PASSWORD" \
        -e HTTP_PROXY="http://$PROXY_CONTAINER:8888" \
        -e HTTPS_PROXY="http://$PROXY_CONTAINER:8888" \
        -e http_proxy="http://$PROXY_CONTAINER:8888" \
        -e https_proxy="http://$PROXY_CONTAINER:8888" \
        -e NO_PROXY="localhost,127.0.0.1" \
        -e no_proxy="localhost,127.0.0.1" \
        -e EGRESS_MODE="${EGRESS_MODE:-proxy}" \
        -v "$DATA_DIR/workspace:/workspace" \
        -v "$DATA_DIR/hermes-config:/home/hermes/.hermes" \
        "$IMAGE"

    echo "Done! Open http://<your-ip>:$PORT in a browser."
    echo "Tools: hermes, opencode, codex, claude, mimo, agy, gh"
    echo "Run 'hermes setup' inside the terminal to configure your AI provider."
}

case "${1:-run}" in
    run|update)
        if need_password; then
            echo ""
            echo "  ┌──────────────────────────────────────────┐"
            echo "  │  hermes-homelab — terminal login setup    │"
            echo "  └──────────────────────────────────────────┘"
            prompt_password
        fi
        # update = --no-cache (like make update) so hermes + CLI versions
        # actually refresh; plain run keeps the build cache for speed.
        if [ "${1:-run}" = "update" ]; then
            do_build --no-cache
        else
            do_build
        fi
        do_run
        ;;
    passwd)
        prompt_password
        echo ""
        echo "  Restart to apply: ./run.sh stop && ./run.sh run"
        ;;
    shell)
        # hermes user, not root — root shells leave root-owned files in
        # /opt/hermes-agent that break `hermes update`.
        docker exec -it -u hermes "$CONTAINER" bash
        ;;
    status)
        docker ps -a --filter "name=$CONTAINER" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        docker stats "$CONTAINER" --no-stream --format "  CPU: {{.CPUPerc}}  MEM: {{.MemUsage}}" 2>/dev/null || true
        ;;
    stop)
        docker stop "$CONTAINER" 2>/dev/null || true
        docker rm "$CONTAINER" 2>/dev/null || true
        docker rm -f "$PROXY_CONTAINER" 2>/dev/null || true
        echo "Stopped."
        ;;
    logs)
        docker logs -f "$CONTAINER"
        ;;
    *)
        echo "Usage: $0 [run|update|passwd|shell|status|stop|logs]"
        exit 1
        ;;
esac

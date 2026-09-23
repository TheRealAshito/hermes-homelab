#!/bin/bash
# ──────────────────────────────────────────────────────────────────────
# hermes-homelab — safe updater
#
#   ./updater.sh        Update without losing ANY deployed configuration
#
# Steps:
#   1. Full data backup (backup.sh → ./backups/)
#   2. Snapshot the container's HOME layer — everything NOT in ./data/:
#      gh auth, claude/codex/mimo/opencode configs + auths, ~/reports, ...
#   3. git pull
#   4. Rebuild + recreate (auto-detects docker compose vs ./run.sh)
#   5. Restore the home snapshot into the new container
#   6. Health check + rollback pointers
#
# Plain `git pull && make update` (or `./run.sh update`) preserves ./data/
# but RESETS the container home layer — auth logins and CLI configs stored
# there are lost. Use this script instead.
# ──────────────────────────────────────────────────────────────────────
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTAINER="hermes-homelab"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$SCRIPT_DIR/backups"
HOME_SNAPSHOT="$BACKUP_DIR/hermes-home-$TIMESTAMP.tar.gz"

cd "$SCRIPT_DIR"
mkdir -p "$BACKUP_DIR"

echo "[updater] 1/6 Data backup (workspace + hermes config)..."
bash "$SCRIPT_DIR/backup.sh" "$BACKUP_DIR"

echo "[updater] 2/6 Home snapshot (auth + CLI configs + reports)..."
if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    # --user root: never depends on the image's USER. --ignore-failed-read:
    # unreadable leftovers must not spam or fail the run (stderr goes to a
    # log). The snapshot is the ONLY copy of home — empty means abort.
    docker exec --user root "$CONTAINER" tar -C /home/hermes --exclude=./.hermes \
        --numeric-owner --ignore-failed-read --warning=no-failed-read -czf - . \
        > "$HOME_SNAPSHOT" 2> "$BACKUP_DIR/hermes-home-$TIMESTAMP.log" || true
    if [ -s "$HOME_SNAPSHOT" ]; then
        echo "          saved: $HOME_SNAPSHOT ($(du -h "$HOME_SNAPSHOT" | cut -f1))"
        if [ -s "$BACKUP_DIR/hermes-home-$TIMESTAMP.log" ]; then
            echo "          note: some files were skipped — see hermes-home-$TIMESTAMP.log"
        fi
    else
        echo "          ERROR: home snapshot came out empty — aborting before touching anything."
        exit 1
    fi
else
    HOME_SNAPSHOT=""
    echo "          WARNING: container not running — home snapshot skipped."
    echo "          (a previous snapshot may exist in ./backups/hermes-home-*.tar.gz)"
fi

echo "[updater] 3/6 git pull..."
git pull

echo "[updater] 4/6 Rebuild + recreate..."
bash "$SCRIPT_DIR/egress-proxy/seed.sh"
# Auto-use gVisor when installed (see README "Sandboxing with gVisor").
if [ -z "${HERMES_RUNTIME:-}" ] && docker info 2>/dev/null | grep -q runsc; then
    export HERMES_RUNTIME=runsc
    echo "          gVisor (runsc) detected — HERMES_RUNTIME=runsc"
fi
COMPOSE_PROJECT=$(docker inspect "$CONTAINER" \
    --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)
if [ -n "$COMPOSE_PROJECT" ] && [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
    echo "          method: docker compose (project: $COMPOSE_PROJECT)"
    docker compose build --no-cache
    docker compose up -d
else
    echo "          method: ./run.sh"
    bash "$SCRIPT_DIR/run.sh" update
fi

echo "[updater] 5/6 Restore home snapshot..."
sleep 3
if [ -n "$HOME_SNAPSHOT" ] && docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    if docker exec --user root -i "$CONTAINER" tar -C /home/hermes --numeric-owner -xzf - < "$HOME_SNAPSHOT"; then
        echo "          restored: $HOME_SNAPSHOT"
    else
        echo "          WARNING: restore reported errors (continuing). Snapshot kept at: $HOME_SNAPSHOT"
    fi
    # Ownership fixup is BEST-EFFORT: USB/NAS storage (root-squash, CIFS)
    # refuses chown and GNU chown would then spam one error per file.
    docker exec --user root "$CONTAINER" chown -R hermes:hermes /home/hermes 2>/dev/null \
        || echo "          note: chown not permitted on this storage (USB/NAS?) — files keep their snapshot owners."
else
    echo "          nothing to restore."
fi

echo "[updater] 6/6 Health check..."
sleep 2
docker ps --filter "name=$CONTAINER" --format "          {{.Names}}  {{.Status}}  {{.Ports}}"

echo ""
echo "[updater] Done. Rollback points in ./backups/:"
echo "  data:  bash restore.sh ./backups/hermes-backup-$TIMESTAMP.tar.gz"
echo "  home:  docker exec -i $CONTAINER tar -C /home/hermes -xzf - < ./backups/hermes-home-$TIMESTAMP.tar.gz"
echo "  verify: make test-security && make test-persistence"

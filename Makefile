.PHONY: build up down restart logs test-security test-persistence test clean backup restore status update setup

setup:
	@echo "Run: sudo bash setup-host.sh [/path/to/external/storage]"
	@echo "This sets up host-level network isolation and storage directory."

build:
	docker compose build

up:
	docker compose up -d

down:
	docker compose down

restart:
	docker compose restart

logs:
	docker compose logs -f

test-security:
	@echo "Running security tests inside container..."
	@cat security-test.sh | docker exec -i --user hermes hermes-homelab bash

test-persistence:
	@echo "Running persistence tests..."
	@docker exec --user hermes hermes-homelab bash -c "echo 'ws' > /workspace/.pt && echo 'cfg' > /home/hermes/.hermes/.pt" && \
		docker restart hermes-homelab && sleep 5 && \
		WS=$$(docker exec --user hermes hermes-homelab cat /workspace/.pt 2>&1) && \
		CFG=$$(docker exec --user hermes hermes-homelab cat /home/hermes/.hermes/.pt 2>&1) && \
		docker exec --user hermes hermes-homelab bash -c "rm -f /workspace/.pt /home/hermes/.hermes/.pt" && \
		echo "workspace=$$WS config=$$CFG" && \
		[ "$$WS" = "ws" ] && [ "$$CFG" = "cfg" ] && echo "✓ 2/2 passed" || echo "✗ Failed"

test: test-security
	@echo ""
	@echo "Run 'make test-persistence' separately (restarts container)."

clean:
	docker compose down -v
	rm -rf ./data
	@echo "⚠  All volumes and data deleted."

update:
	docker compose build --no-cache
	docker compose up -d
	@echo "✅ Rebuilt and restarted. Data preserved."

status:
	@docker compose ps
	@echo ""
	@echo "RAM usage:"
	@docker stats hermes-homelab --no-stream --format "  {{.MemUsage}}"

backup:
	@bash backup.sh

restore:
	@echo "Usage: bash restore.sh ./backups/hermes-backup-YYYYMMDD-HHMMSS.tar.gz"

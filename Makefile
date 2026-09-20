.PHONY: build up down restart logs test-security test-persistence test clean

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
	docker exec hermes-homelab bash -c "cat > /tmp/security-test.sh && bash /tmp/security-test.sh" < security-test.sh

test-persistence:
	@echo "Running persistence tests from host..."
	bash persistence-test.sh

test: test-security
	@echo ""
	@echo "Run 'make test-persistence' separately (requires container restarts)."

clean:
	docker compose down -v
	@echo "⚠  All volumes deleted. Hermes data is gone."

update:
	docker compose build --no-cache
	docker compose up -d
	@echo "✅ Rebuilt and restarted. Volumes preserved."

status:
	@docker compose ps
	@echo ""
	@echo "RAM usage:"
	@docker stats hermes-homelab --no-stream --format "  {{.MemUsage}}"

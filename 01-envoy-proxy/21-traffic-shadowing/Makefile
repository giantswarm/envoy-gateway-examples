.PHONY: up verify reload down logs logs-shadow

REPO_ROOT := $(shell git rev-parse --show-toplevel)
PORTS     := 10000 9901

up:
	@$(REPO_ROOT)/scripts/free-ports $(PORTS)
	docker compose up -d --build

reload:
	docker compose restart envoy

verify:
	./verify.sh

logs:
	docker compose logs -f envoy

# Tail the shadow backend specifically — interesting to watch while
# driving traffic to the primary.
logs-shadow:
	docker compose logs -f shadow

down:
	docker compose down -v

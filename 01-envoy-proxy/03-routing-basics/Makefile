.PHONY: up verify down logs

REPO_ROOT := $(shell git rev-parse --show-toplevel)
PORTS     := 10000 9901

up:
	@$(REPO_ROOT)/scripts/free-ports $(PORTS)
	docker compose up -d --build

verify:
	./verify.sh

logs:
	docker compose logs -f envoy

down:
	docker compose down

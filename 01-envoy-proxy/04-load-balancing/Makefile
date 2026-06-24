.PHONY: up verify down logs reload

REPO_ROOT := $(shell git rev-parse --show-toplevel)
PORTS     := 10000 9901

up:
	@$(REPO_ROOT)/scripts/free-ports $(PORTS)
	docker compose up -d --build

# After editing envoy.yaml, the bind-mounted config is on disk but the
# running envoy hasn't reread it. Use this to pick up changes without
# tearing down the helloworld backends (faster than `make down && up`).
reload:
	docker compose restart envoy

verify:
	./verify.sh

logs:
	docker compose logs -f envoy

down:
	docker compose down

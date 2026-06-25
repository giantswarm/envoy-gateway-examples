.PHONY: up verify reload down logs jaeger-ui

REPO_ROOT := $(shell git rev-parse --show-toplevel)
PORTS     := 10000 9901 16686

up:
	@$(REPO_ROOT)/scripts/free-ports $(PORTS)
	docker compose up -d --build

reload:
	docker compose restart envoy

verify:
	./verify.sh

logs:
	docker compose logs -f envoy

jaeger-ui:
	@echo "Open http://localhost:16686 in your browser."
	@echo "Service: envoy-tutorial-18"

down:
	docker compose down -v

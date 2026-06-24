.PHONY: up verify down logs admin

REPO_ROOT := $(shell git rev-parse --show-toplevel)
PORTS     := 10000 9901

up:
	@$(REPO_ROOT)/scripts/free-ports $(PORTS)
	docker compose up -d --build

verify:
	./verify.sh

logs:
	docker compose logs -f envoy

admin:
	@echo "Admin endpoints:"
	@echo "  http://localhost:9901/             — index"
	@echo "  http://localhost:9901/ready        — readiness"
	@echo "  http://localhost:9901/config_dump  — full live config"
	@echo "  http://localhost:9901/clusters     — clusters + endpoints"
	@echo "  http://localhost:9901/listeners    — listeners"
	@echo "  http://localhost:9901/stats        — counters/gauges/histograms"

down:
	docker compose down

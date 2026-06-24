.PHONY: up verify tour traffic down logs

REPO_ROOT := $(shell git rev-parse --show-toplevel)
PORTS     := 10000 9901

up:
	@$(REPO_ROOT)/scripts/free-ports $(PORTS)
	docker compose up -d --build

# A short, scripted tour of the most important admin endpoints.
verify tour:
	./verify.sh

# Generate some real traffic so the counters in /stats and /clusters move.
# Run this in one terminal, then `make tour` in another to see live numbers.
traffic:
	@echo "Sending 50 requests to / ..."
	@for i in $$(seq 1 50); do curl -s -o /dev/null http://localhost:10000/ ; done
	@echo "done."

logs:
	docker compose logs -f envoy

down:
	docker compose down

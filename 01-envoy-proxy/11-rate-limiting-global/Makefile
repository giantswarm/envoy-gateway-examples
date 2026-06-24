.PHONY: up verify reload down logs ratelimit-logs

REPO_ROOT := $(shell git rev-parse --show-toplevel)
PORTS     := 10000 9901

up:
	@$(REPO_ROOT)/scripts/free-ports $(PORTS)
	docker compose up -d --build

reload:
	docker compose restart envoy

# Re-load the ratelimit policy after editing ratelimit-config/config.yaml.
# Restarting the service drains Redis-side state — but Redis itself is
# fine, so after restart the policy is re-applied to existing counters.
reload-rl:
	docker compose restart ratelimit

verify:
	./verify.sh

logs:
	docker compose logs -f envoy

ratelimit-logs:
	docker compose logs -f ratelimit

down:
	docker compose down

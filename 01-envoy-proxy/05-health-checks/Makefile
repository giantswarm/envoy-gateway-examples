.PHONY: up verify reload down logs kill-c heal-c

REPO_ROOT := $(shell git rev-parse --show-toplevel)
PORTS     := 10000 9901

up:
	@$(REPO_ROOT)/scripts/free-ports $(PORTS)
	docker compose up -d --build

reload:
	docker compose restart envoy

verify:
	./verify.sh

# Convenience targets for ad-hoc churn during demos / exercises.
kill-c:
	docker compose stop hello-c

heal-c:
	docker compose start hello-c

logs:
	docker compose logs -f envoy

down:
	docker compose down

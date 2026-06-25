.PHONY: up verify reload down logs check-tools

REPO_ROOT := $(shell git rev-parse --show-toplevel)
PORTS     := 10000 9901

up:
	@$(REPO_ROOT)/scripts/free-ports $(PORTS)
	docker compose up -d --build

reload:
	docker compose restart envoy

verify: check-tools
	./verify.sh

logs:
	docker compose logs -f envoy

down:
	docker compose down -v

# websocat is the curl-of-WebSocket. brew install websocat.
check-tools:
	@command -v websocat >/dev/null 2>&1 || { \
	  echo "websocat missing. Install: brew install websocat" ; exit 1 ; }

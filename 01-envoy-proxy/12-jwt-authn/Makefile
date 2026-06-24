.PHONY: keys up verify reload down logs token clean-keys

REPO_ROOT := $(shell git rev-parse --show-toplevel)
PORTS     := 10000 9901

keys:
	./gen-keys.sh

up: keys
	@$(REPO_ROOT)/scripts/free-ports $(PORTS)
	docker compose up -d --build

reload:
	docker compose restart envoy

verify:
	./verify.sh

# Mint and print a single default token. Use env vars to customise:
#   make token SUB=bob EXP=100   # expired token for bob
token:
	@./mint-token.sh

logs:
	docker compose logs -f envoy

down:
	docker compose down

clean-keys:
	rm -rf keys/

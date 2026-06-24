.PHONY: certs up verify reload down logs clean-certs

REPO_ROOT := $(shell git rev-parse --show-toplevel)
PORTS     := 10000 9901 10443

certs:
	./gen-certs.sh

up: certs
	@$(REPO_ROOT)/scripts/free-ports $(PORTS)
	docker compose up -d --build

reload:
	docker compose restart envoy

verify:
	./verify.sh

logs:
	docker compose logs -f envoy

down:
	docker compose down

clean-certs:
	rm -rf certs/

.PHONY: up verify burst watch reload down logs

REPO_ROOT := $(shell git rev-parse --show-toplevel)
PORTS     := 10000 9901
N         ?= 15
SECONDS   ?= 3

up:
	@$(REPO_ROOT)/scripts/free-ports $(PORTS)
	docker compose up -d --build

reload:
	docker compose restart envoy

verify:
	./verify.sh

# Fire N concurrent requests (default 15) at /?seconds=$(SECONDS). Use to
# replay the burst manually after editing envoy.yaml + make reload.
burst:
	@echo "Firing $(N) concurrent requests; each backend hop sleeps $(SECONDS)s..."
	@tmp=$$(mktemp -d) ; \
	for i in $$(seq 1 $(N)); do \
	  curl -sS -o /dev/null -w "%{http_code}\n" \
	    "http://localhost:10000/?seconds=$(SECONDS)" > $$tmp/$$i & \
	done ; \
	wait ; \
	cat $$tmp/* | sort | uniq -c ; \
	rm -rf $$tmp

# Tail the relevant counters live.
watch:
	watch -n1 "curl -s 'http://localhost:9901/stats?filter=cluster\\.cluster_slow\\.(upstream_(cx|rq)_overflow|upstream_rq_pending_overflow|circuit_breakers)' | sort"

logs:
	docker compose logs -f envoy

down:
	docker compose down

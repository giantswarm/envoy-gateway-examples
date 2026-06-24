.PHONY: up verify reload down logs tail-json tail-errors clean-logs traffic

REPO_ROOT := $(shell git rev-parse --show-toplevel)
PORTS     := 10000 9901

up:
	@$(REPO_ROOT)/scripts/free-ports $(PORTS)
	docker compose up -d --build

reload:
	docker compose restart envoy

verify:
	./verify.sh

# Tail the stdout (text) sink.
logs:
	docker compose logs -f envoy

# Tail the JSON file sink; pretty-print with jq.
tail-json:
	tail -F logs/access.json | jq .

# Tail the errors-only file sink (only 5xx will show up).
tail-errors:
	tail -F logs/errors.log

# Pump a small mix of normal + error + slow requests, useful while
# tailing one of the logs in another terminal.
traffic:
	@for i in 1 2 3 4 5; do curl -sS -o /dev/null http://localhost:10000/; done
	@for i in 1 2;       do curl -sS -o /dev/null 'http://localhost:10000/fail?code=503'; done
	@for i in 1;         do curl -sS -o /dev/null 'http://localhost:10000/slow?seconds=1'; done
	@echo "Sent 5x200, 2x503, 1x slow."

clean-logs:
	rm -f logs/access.json logs/errors.log

down:
	docker compose down

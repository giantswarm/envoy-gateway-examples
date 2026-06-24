.PHONY: build-wasm up verify reload down logs clean-wasm

REPO_ROOT := $(shell git rev-parse --show-toplevel)
PORTS     := 10000 9901

WASM := filter/target/wasm32-wasip1/release/hello_wasm.wasm

# Build the Wasm filter inside a throwaway Rust container so the host
# doesn't need a Rust toolchain. First run downloads ~1.5GB of base
# image and takes ~2min; subsequent rebuilds are fast (incremental).
$(WASM): filter/src/lib.rs filter/Cargo.toml
	@echo "Building Wasm filter (Rust in Docker)..."
	docker run --rm \
	  -v $(PWD)/filter:/work \
	  -w /work \
	  rust:1.78 \
	  sh -c 'rustup target add wasm32-wasip1 >/dev/null && cargo build --target wasm32-wasip1 --release'
	@ls -lh $(WASM)

build-wasm: $(WASM)

up: build-wasm
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

clean-wasm:
	rm -rf filter/target/

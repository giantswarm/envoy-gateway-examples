// Tiny proxy-wasm filter, written in Rust. Built as a wasm32-wasip1
// cdylib, mounted into Envoy as a single .wasm file, loaded by
// envoy.filters.http.wasm.
//
// What it does, per request:
//   - If `x-wasm-block: <anything>` header is present, return 403 with
//     a fixed body. Never reaches the upstream.
//   - Otherwise pass the request through.
// Per response:
//   - Add `x-wasm-filter: hello-from-wasm` so you can see the filter
//     ran without poking at logs.
//
// On startup, log one info line so you can see the filter loaded
// (look for "wasm log" in `docker compose logs envoy`).

use log::info;
use proxy_wasm::traits::*;
use proxy_wasm::types::*;

proxy_wasm::main! {{
    proxy_wasm::set_log_level(LogLevel::Info);
    proxy_wasm::set_http_context(|_, _| -> Box<dyn HttpContext> {
        Box::new(HelloFilter)
    });
}}

struct HelloFilter;

impl Context for HelloFilter {}

impl HttpContext for HelloFilter {
    fn on_http_request_headers(&mut self, _: usize, _: bool) -> Action {
        let path = self
            .get_http_request_header(":path")
            .unwrap_or_else(|| String::from("?"));

        // Short-circuit: any request with x-wasm-block gets denied.
        if self.get_http_request_header("x-wasm-block").is_some() {
            info!("wasm filter: blocking request to {}", path);
            self.send_http_response(
                403,
                vec![
                    ("content-type", "text/plain"),
                    ("x-wasm-filter", "blocked"),
                ],
                Some(b"blocked by wasm filter\n"),
            );
            // Action::Pause stops further filters; with send_http_response
            // above it terminates the request entirely.
            return Action::Pause;
        }

        // Optional debug breadcrumb.
        if let Some(greet) = self.get_http_request_header("x-wasm-greet") {
            info!("wasm filter: greet from caller = {}", greet);
        }

        Action::Continue
    }

    fn on_http_response_headers(&mut self, _: usize, _: bool) -> Action {
        self.add_http_response_header("x-wasm-filter", "hello-from-wasm");
        Action::Continue
    }
}

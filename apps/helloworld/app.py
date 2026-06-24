"""Tiny helloworld app used across every Envoy/Envoy Gateway example.

The endpoints are deliberately minimal but cover what the examples need:

  GET  /            -> { "msg": "hello, world", "from": $NAME }
  GET  /headers     -> echoes the request headers Envoy forwarded
  GET  /slow        -> sleeps ?seconds=N (default 2) before responding
  GET  /fail        -> returns ?code=N (default 500); use for retry/outlier demos
  ANY  /echo        -> echoes method, path, headers, query, body

Set NAME to identify the replica (useful when running multiple instances behind
a load-balancing or shadowing example).
"""

import os
import time

from flask import Flask, jsonify, request

app = Flask(__name__)
NAME = os.environ.get("NAME", "helloworld")

# BREAK=true makes EVERY request to this replica return BREAK_CODE (default
# 500). Used by the health-checks / outlier-detection / circuit-breaker
# examples to stand up an intentionally broken backend in the same cluster.
BREAK = os.environ.get("BREAK", "").lower() in ("1", "true", "yes")
BREAK_CODE = int(os.environ.get("BREAK_CODE", "500"))


@app.before_request
def _maybe_break():
    if BREAK:
        return jsonify(error="broken backend", from_=NAME), BREAK_CODE


@app.get("/")
def root():
    return jsonify(msg="hello, world", from_=NAME)


@app.get("/headers")
def headers():
    return jsonify(from_=NAME, headers=dict(request.headers))


@app.get("/slow")
def slow():
    delay = float(request.args.get("seconds", "2"))
    time.sleep(delay)
    return jsonify(from_=NAME, slept=delay)


@app.get("/fail")
def fail():
    code = int(request.args.get("code", "500"))
    return jsonify(from_=NAME, error=code), code


@app.route("/echo", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
def echo():
    return jsonify(
        from_=NAME,
        method=request.method,
        path=request.path,
        headers=dict(request.headers),
        args=request.args.to_dict(),
        body=request.get_data(as_text=True),
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))

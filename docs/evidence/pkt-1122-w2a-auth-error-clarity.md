# PKT-1122 W2A raw tunnel-facing curl evidence

Captured 2026-07-13 from the W2A regression's live NIO server using
`/usr/bin/curl`. The server used synthetic ES256 test keys and a configured
legacy static bearer. Secret inputs are intentionally omitted.

## Expired OAuth JWT

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer error="invalid_token", error_description="auth_failed", resource_metadata="http://127.0.0.1:9700/.well-known/oauth-protected-resource", correlation_id="838bd4f4-426d-49d4-9eda-5ba00ff23ed4"
Content-Type: application/json
transfer-encoding: chunked

{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid Request: auth_failed correlation_id=838bd4f4-426d-49d4-9eda-5ba00ff23ed4"},"id":null}
```

Local audit mapping:

```text
correlation_id=838bd4f4-426d-49d4-9eda-5ba00ff23ed4 reason=oauth_expired
```

## Bad legacy static bearer while OAuth is active

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer error="invalid_token", error_description="auth_failed", resource_metadata="http://127.0.0.1:9700/.well-known/oauth-protected-resource", correlation_id="c1bd5bd4-cfca-471e-92b3-560f9534d5de"
Content-Type: application/json
transfer-encoding: chunked

{"error":{"code":-32600,"message":"Invalid Request: auth_failed correlation_id=c1bd5bd4-cfca-471e-92b3-560f9534d5de"},"jsonrpc":"2.0","id":null}
```

Local audit mapping:

```text
correlation_id=c1bd5bd4-cfca-471e-92b3-560f9534d5de reason=static_bearer_mismatch
```

## Valid OAuth JWT while the legacy static bearer is configured

```http
HTTP/1.1 200 OK
Content-Type: application/json
MCP-Session-Id: 1EEAF739-3807-457A-93C4-2E380BBC11CC
transfer-encoding: chunked

{"jsonrpc":"2.0","result":{"tools":[]},"id":1122}
```

Local audit result: no authentication failure; the OAuth-authenticated request
dispatched. This is the HTTP-level precedence proof: the configured static
bearer was not consulted after connector OAuth authentication succeeded.

## Reproduction

`TheBridgeTests/RemoteOAuthBearerTests.swift` starts the real NIO listener on a
temporary port, invokes `/usr/bin/curl` for all three requests, asserts the
public response and local correlation mapping, and emits a fresh secret-free
copy at the path printed as `raw-curl evidence:` during `make test-floor`.

Fresh verification result: `3156 passed, 0 failed, floor=3156`.

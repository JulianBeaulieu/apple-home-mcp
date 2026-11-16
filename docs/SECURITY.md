# Security

## Transport

* MCP **streamable HTTP** at `/mcp` (POST; JSON responses; GET returns 405, no server-initiated stream).
* Default bind: `127.0.0.1:8737` only.
* `Host` header must be a loopback name in loopback mode and browser `Origin`s must be loopback (or listed in
  `allowed_origins`). This blocks DNS-rebinding attacks from web pages, as the MCP spec requires.
* Bodies are limited to 1 MiB, headers to 32 KiB; chunked uploads are rejected.

## API key

* Generated in-app (32 random bytes from `SecRandomCopyBytes`, prefixed `ahmcp_`), stored in the Keychain.
* Sent as `Authorization: Bearer <key>` (or `X-API-Key`).
* Compared in constant time (SHA-256 of both sides, XOR-accumulate), so neither content nor length leaks via timing.
* Required in network mode, always. Required on loopback by default (`require_api_key_on_loopback`), because any
  local process could otherwise drive your home.
* *Regenerate API key* in the menu invalidates the old key immediately.

## Network mode

*Expose on network* binds to all interfaces. Traffic is plain HTTP, so the key would cross the LAN in clear text.
Prefer one of:

* **Tailscale**: keep the app on loopback and use `tailscale serve --bg --https=8443 http://127.0.0.1:8737`
  (TLS + tailnet ACLs; no LAN exposure at all).
* **Reverse proxy with TLS** on the same Mac (Caddy example):

  ```
  homekit-mcp.example.lan {
      tls internal
      reverse_proxy 127.0.0.1:8737
  }
  ```

  With a proxy, keep *Expose on network* **off**; the proxy talks to loopback. Add the proxy's origin to
  `allowed_origins` only if a browser client needs it.

## Write safety

See README › Safety. The policy lives in `Packages/MCPKit/Sources/MCPKit/Policy.swift` and is unit-tested.
The denylist and the HA URL live in the local config; the HA token lives in the Keychain.

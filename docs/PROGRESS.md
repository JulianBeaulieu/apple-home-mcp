# Progress log

## 2026-11-16 – v0.1.0

Research (Xcode 26.3, macOS 26.2 SDK):
* `HMAccessorySetupManager` / `HMAccessorySetupPayload` are unavailable on macOS and Mac Catalyst → adding
  accessories is a guided iPhone step + `wait_for_new_accessory`.
* HomeKit's Matter XPC controller (`matterControllerID`, `matterControllerXPCConnectBlock`, `matterNodeID`) is public.
* HomeKit entitlement is not allowed in Developer ID profiles → Development-signed builds; releases ship source + CLI.

Implemented:
* MCPKit package: HTTP/1.1 server, MCP streamable HTTP, API key auth (constant-time), DNS-rebinding checks,
  safety policy, config, Keychain, Home Assistant WebSocket client, floors/areas sync planner, 22 tests.
* Catalyst app: 33 tools (read, organize, floors, pairing, Home Assistant, gated control); AppKit menu bar plugin;
  stdio bridge CLI.

Verified on a real home (macOS 15.7.4, app in background):
* reads, live reads, room/zone create/rename/delete, accessory rename + room move (undone), outlet power write
  (restored), denylist + lock refusals, control-disabled refusal, API key via menu → bearer → 200, stdio bridge.
* Matter: attribute reads, fabric listing, **opening and closing a multi-admin commissioning window** via HomeKit XPC.

Open:
* End-to-end `matter_share_to_home_assistant` on a device that is not yet in Home Assistant.
* `ha_sync_areas` against a live Home Assistant (dry run first).
* Notarized bridge CLI release (needs `notarytool store-credentials`).

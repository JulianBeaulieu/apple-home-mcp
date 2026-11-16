First release.

**What's in it**
- Source code for the Apple Home MCP menu bar app (Mac Catalyst + AppKit menu bar plugin) and the MCPKit package.
- `apple-home-mcp-bridge`: a stdio ↔ streamable-HTTP bridge for MCP clients that only speak stdio (universal binary, Developer ID signed and notarized).

**Why there is no ready-made .app**
Apple does not allow the HomeKit entitlement in Developer ID builds, so a downloadable notarized app cannot see your homes.
Build the app with your own Apple Developer account: see the README and `docs/SIGNING.md`.

**Highlights**
- Read homes, rooms, zones, floors, accessories and live values; organize rooms, zones, floors and names.
- Guided onboarding of new accessories (`add_accessory` → iPhone → `wait_for_new_accessory`).
- Matter multi-admin: open/close a commissioning window on Apple-Home Matter accessories through HomeKit's public
  Matter XPC controller and commission the code into Home Assistant (`matter_share_to_home_assistant`).
- Mirror floors/rooms to Home Assistant floors/areas (additive, dry run by default).
- Hard safety rails: locks, garage doors and security systems are never controlled; local denylist; control writes off by default.

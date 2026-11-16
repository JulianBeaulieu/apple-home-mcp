# Apple Home MCP

An open-source [MCP](https://modelcontextprotocol.io) server for **Apple Home (HomeKit)** that runs as a small
Mac menu bar app. It lets AI agents read your home, organize it (rooms, zones, floors, names), onboard new
Matter/Thread accessories, and hand Matter accessories over to **Home Assistant** (multi-admin), with hard
safety rails around locks, garage doors and alarms.

```
MCP client (Claude Code, …) ──HTTP──▶ 127.0.0.1:8737/mcp   (streamable HTTP, bearer API key)
   or stdio ─▶ apple-home-mcp-bridge ─┘
                                        Apple Home MCP.app  (Mac Catalyst, menu bar only)
                                          ├─ HomeKit (HMHomeManager)            read / organize / control
                                          ├─ Matter.framework over HomeKit XPC  pairing window on the Apple fabric
                                          └─ Home Assistant WebSocket API      matter/commission, floors, areas
```

## Why

Thread border routers in many homes are Apple devices (HomePod, Apple TV), so the easiest way to bring a new
Thread/Matter device online is to add it to Apple Home first, then share it to Home Assistant for automations.
This server lets an agent do that workflow end to end:

1. `add_accessory` – the human adds the device in the Home app on an iPhone (macOS cannot run HomeKit setup, see below)
2. `wait_for_new_accessory` – the agent sees it arrive
3. `rename_accessory`, `move_accessory`, `set_room_floor` – tidy it up
4. `matter_share_to_home_assistant` – open a Matter pairing window and commission it into HA's Matter integration
5. `ha_sync_areas` – mirror floors/rooms to HA floors/areas

## Tools

| Group | Tools |
|---|---|
| Read | `list_homes`, `get_home`, `list_rooms`, `list_zones`, `list_floors`, `list_accessories`, `get_accessory`, `list_scenes`, `get_policy` |
| Organize | `rename_accessory`, `move_accessory`, `create_room`, `rename_room`, `delete_room`, `create_zone`, `rename_zone`, `delete_zone`, `add_room_to_zone`, `remove_room_from_zone`, `create_floor`, `rename_floor`, `set_room_floor` |
| Pairing | `add_accessory` (guided), `wait_for_new_accessory`, `matter_info`, `matter_open_pairing_window`, `matter_close_pairing_window`, `matter_share_to_home_assistant` |
| Home Assistant | `ha_status`, `ha_commission_matter`, `ha_sync_areas` |
| Control (off by default) | `set_characteristic`, `run_scene` |

Deletes, pairing and Home Assistant writes need `confirm: true`, which agents are told to set only after the human
approved the specific action.

## Safety

* **Locks, garage doors, security systems**: control writes are always refused (cannot be disabled).
* **Denylist** (local config, never in the repo): every write to a matching accessory is refused, including
  rename/move and sharing. Entries can be UUIDs, names, `Room/Name` or `*glob*`; matching ignores case and umlauts.
* **Control writes** to everything else are off until you enable *Allow control writes* in the menu.
* Scenes are refused if any action touches a protected/denylisted accessory.

See [docs/SECURITY.md](docs/SECURITY.md).

## Install / build

HomeKit is a restricted entitlement and Apple does **not** allow it in Developer ID builds, so a downloadable
notarized app cannot talk to HomeKit. You build it with your own (paid) Apple Developer account:

```bash
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # your team id + a bundle id you own
scripts/build.sh                                          # Development-signed, HomeKit entitled
scripts/install.sh                                        # copies to /Applications and starts it
```

Details and the reasoning: [docs/SIGNING.md](docs/SIGNING.md).

## Connect a client

The menu bar item has *Copy Claude Code setup command*, which produces:

```bash
claude mcp add --transport http apple-home http://127.0.0.1:8737/mcp --header "Authorization: Bearer <key>"
```

For stdio-only clients use the bridge: `APPLE_HOME_MCP_API_KEY=<key> apple-home-mcp-bridge`.

## Configuration

`~/Library/Application Support/AppleHomeMCP/config.json` (created on first launch):

```json
{
  "port": 8737,
  "expose_on_network": false,
  "require_api_key_on_loopback": true,
  "control_enabled": false,
  "denylist": ["Front Door", "*garage*", "Kitchen/Aquarium Pump"],
  "protected_kinds": ["garage_door", "lock", "security_system"],
  "default_home": "",
  "floor_zone_prefix": "",
  "home_assistant": { "url": "https://homeassistant.local:8123" }
}
```

The API key and the Home Assistant token live in the Keychain, not in this file.

### Home Assistant

Menu bar › *Home Assistant…*: base URL + a long-lived access token (HA profile › Security). The Matter commission
and floor/area registry calls are WebSocket-only APIs, so generic HA connectors that only expose states/services
are not enough. On first use macOS asks to allow **Local Network** access for the app; allow it, or HA on your
LAN is unreachable (`NSURLErrorDomain -1009`).

## Docs

* [docs/PAIRING.md](docs/PAIRING.md) – adding accessories and sharing Matter accessories with Home Assistant: what the public APIs allow
* [docs/FLOORS.md](docs/FLOORS.md) – floors ↔ zones ↔ Home Assistant floors/areas
* [docs/BACKGROUND.md](docs/BACKGROUND.md) – running HomeKit from a menu-bar-only Catalyst app
* [docs/SIGNING.md](docs/SIGNING.md) – entitlements, provisioning profiles, releases
* [docs/SECURITY.md](docs/SECURITY.md) – transport, API key, network mode, TLS
* [docs/PROGRESS.md](docs/PROGRESS.md) – status log

## License

MIT

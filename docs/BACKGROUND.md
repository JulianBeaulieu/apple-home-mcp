# Running HomeKit from a menu-bar-only Mac Catalyst app

## Setup

* `LSUIElement = YES` (no Dock icon, never frontmost by itself).
* Mac Catalyst cannot create an `NSStatusItem`, so the menu bar UI is an AppKit bundle
  (`MenuBar.bundle`, in `Contents/PlugIns`) loaded at launch. It talks to the app via an `@objc` protocol
  (`Shared/MenuBarBridge.swift`).
* The scene delegate attaches a 1×1 transparent window that the plugin keeps ordered out, and the app holds a
  `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)` assertion so App Nap does not throttle the
  HTTP server.

## Measured (2026-11-16, macOS 15.7.4, MacBook, Development-signed build)

All with another app (Finder) frontmost, so Apple Home MCP was in the background:

| Operation | 1×1 helper window | no window (`-AHMNoWindow YES`) |
|---|---|---|
| Load homes, rooms, zones, accessories | works | works |
| Live characteristic reads (`readValue`) | works | works |
| Home config writes (create/rename/delete room & zone, add room to zone) | works | works |
| Accessory writes (rename, assign room) | works | works |
| Characteristic write (outlet power off/on) | not tested | works |
| Matter over HomeKit XPC: read attributes | works | works |
| Matter over HomeKit XPC: open/close commissioning window | works | works |

So on current macOS, a Catalyst app with the HomeKit entitlement does **not** need a visible or key window for
HomeKit reads or writes. The helper window is kept as a cheap safeguard (some older reports describe
"background access" errors on Catalyst), and `-AHMNoWindow YES` disables it for diagnostics.

Not yet measured: behaviour with the screen locked / user logged out (a LaunchAgent cannot run a GUI app without a
login session; HomeKit needs the user's iCloud session anyway). For an always-on host (Mac Studio), keep the user
logged in and enable *Launch at login* in the menu.

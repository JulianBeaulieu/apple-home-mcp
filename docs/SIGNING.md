# Signing, entitlements and releases

## The constraint

* HomeKit is only available to Mac apps through **Mac Catalyst** (there is no HomeKit for native AppKit apps).
* `com.apple.developer.homekit` is a restricted entitlement: it must be authorized by a **provisioning profile**.
* Apple's macOS capability matrix does not offer HomeKit for **Developer ID** distribution: a Developer ID
  provisioning profile cannot carry it (confirmed by other HomeKit-on-Mac projects, e.g. iMCP PR #275 and
  HomeClaw, whose release dry runs failed for exactly this reason). A Developer ID signed, notarized app starts
  fine but HomeKit returns no homes.
* What does carry HomeKit on macOS: **Mac Catalyst App Development** profiles (registered Macs only) and
  **Mac App Store / TestFlight** distribution.

## What this repo does

* `project.yml` (XcodeGen) + `Config/Base.xcconfig`. Your team id and bundle id go in the git-ignored
  `Config/Local.xcconfig`. Nothing team-specific is committed.
* `scripts/build.sh` builds with automatic signing (`-allowProvisioningUpdates`), which creates the App ID, enables
  the HomeKit capability and downloads a Mac Catalyst development profile. On a brand-new bundle id it first does
  an iOS build, which is what registers the HomeKit capability on the App ID, then retries the Catalyst build.
* The Mac must be a registered device in your team (Xcode does this with `-allowProvisioningDeviceRegistration`).
  For a second Mac (e.g. a Mac Studio), build on that Mac or add its Provisioning UDID in the developer portal
  and rebuild.

## Releases

GitHub releases contain the **source** and a notarized **`apple-home-mcp-bridge`** CLI. They do not contain a
ready-to-run app, because:

* a Developer ID build cannot use HomeKit (above), and
* a development-signed build only runs on the publisher's registered Macs.

To run the app you build it with your own Apple Developer Program membership (paid; the free tier cannot use
HomeKit). A Mac App Store / TestFlight build would be the only way to ship a downloadable HomeKit app; that
needs App Sandbox and App Review and is not done here.

## Notarization (bridge CLI)

```bash
xcrun notarytool store-credentials apple-home-mcp --apple-id <you> --team-id <TEAM>   # once, interactive
scripts/release.sh v0.1.0
```

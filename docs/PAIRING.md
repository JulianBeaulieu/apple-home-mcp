# Pairing: adding accessories and sharing them with Home Assistant

## (a) Adding a new accessory to Apple Home

**Not possible from a Mac.** In the current SDK (macOS 26.2 SDK, Xcode 26.3) `HMAccessorySetupManager`,
`HMAccessorySetupRequest` and `HMAccessorySetupPayload` are all `API_UNAVAILABLE(macos, macCatalyst)`. The
Mac Home app cannot add accessories either. `MatterSupport` (`MatterAddDeviceRequest`) is iOS-only as well.

What the server does instead:

1. `add_accessory` returns the exact steps for the human (iPhone/iPad Home app › + › Add Accessory), optionally
   validates a Matter setup code (vendor/product/discriminator; the passcode is never echoed back), and returns
   `started_at`.
2. `wait_for_new_accessory(since=started_at)` blocks until `HMHomeDelegate home(_:didAdd:)` fires and returns the
   new accessory with its services and Matter node id.
3. The agent continues: rename, room, floor, share to Home Assistant.

## (b) Sharing an Apple Home Matter accessory with Home Assistant (multi-admin)

### Public API path (implemented)

HomeKit exposes Apple's Matter controller to entitled third-party apps:

* `HMAccessory.matterNodeID` (iOS 16.1 / Mac Catalyst 16.1) – the node id on Apple's fabric
* `HMHome.matterControllerID` + `HMHome.matterControllerXPCConnectBlock` (iOS 16.1) – documented in `HMHome.h` as
  the arguments for `+[MTRDeviceController sharedControllerWithID:xpcConnectBlock:]` (Matter.framework, 16.4+)
* `HMHome.matterStartupParametersXPCConnectBlock` (iOS 18.2) for `MTRXPCDeviceControllerParameters`

With that controller the app talks to the device *as Apple's fabric admin*:

1. generate a random passcode (`MTRSetupPayload.generateRandomSetupPasscode`), discriminator and salt,
2. compute the SPAKE2+ verifier (`MTRDeviceController.computePASEVerifierForSetupPasscode:iterations:salt:`),
3. timed-invoke `AdministratorCommissioning.OpenCommissioningWindow` on endpoint 0
   (falls back to `MTRBaseDevice.openCommissioningWindowWithSetupPasscode:…`),
4. encode the 11-digit manual code (`MTRSetupPayload.manualEntryCode`),
5. call Home Assistant's WebSocket command `matter/commission` with `{code, network_only: true}`.

The device stays in Apple Home and joins HA's fabric as an additional admin; Thread devices keep using the Apple
border routers.

**Verified on 2026-11-16 (macOS 15.7.4):** `homed` accepted the timed `OpenCommissioningWindow` invoke from this
third-party app on an IKEA Thread contact sensor. The device then advertised `_matterc._udp` (commissionable) and
`AdministratorCommissioning.WindowStatus` read `EnhancedWindowOpen`; `matter_close_pairing_window`
(`RevokeCommissioning`) closed it again. So, contrary to the common assumption, **public APIs do let an entitled
third-party app create a multi-admin pairing code for an Apple-fabric Matter accessory.**

Not yet verified end to end: the Home Assistant `matter/commission` step with such a code (every Matter device in
the test home was already on Home Assistant's fabric; re-commissioning would duplicate it). It uses HA's standard
WebSocket command, the same one the HA UI uses for "Add Matter device › already in use".

`matter_info` (read-only) shows Basic Information, the commissioning window status and the fabrics on a device
(vendor id + label, e.g. Apple Home 0x1349, Home Assistant 0x134B), so an agent can tell whether a device is
already shared with Home Assistant before sharing it.

Accessories that Apple Home reaches over HAP (including entities exposed by Home Assistant's HomeKit Bridge)
report `matterNodeID == 0`; they are not Matter devices and cannot be shared this way.

### Fallback (always works)

If Apple Home refuses to open the window, the tool returns the human steps:

1. Home app › accessory › settings › **Turn On Pairing Mode**, copy the setup code (valid ~15 min).
2. Give the code to the agent: `matter_share_to_home_assistant(accessory, pairing_code=…, confirm=true)` or
   `ha_commission_matter(code, confirm=true)`. The HA side is fully automatic.

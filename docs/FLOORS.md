# Floors, zones and Home Assistant areas

Apple Home has homes → rooms, plus **zones** (named groups of rooms, a room can be in several zones).
It has **no floors**. Home Assistant has floors → areas.

| Concept | Apple Home | This server | Home Assistant |
|---|---|---|---|
| Floor | – | a zone (all zones, or only zones starting with `floor_zone_prefix`) | floor |
| Room | room | room | area |
| Zone that is not a floor | zone | zone (only if a prefix is set) | (not mirrored; use HA labels if needed) |

* `floor_zone_prefix: ""` (default): every zone is a floor. Simple when you only use zones for floors.
* `floor_zone_prefix: "Floor: "`: only zones like `Floor: Upstairs` are floors (name `Upstairs`); other zones such
  as `Downstairs lights` stay ordinary zones. The prefix includes its separator.
* A room is on at most one floor. `set_room_floor` removes the room from other *floor* zones and adds it to the
  target one; non-floor zones are never touched.

## Mirroring to Home Assistant

`ha_sync_areas` (dry run by default) plans and applies an **additive** sync:

* missing HA floors are created for Apple floors,
* missing HA areas are created for Apple rooms (on the matching floor),
* existing areas without a floor get one; areas that already have a different floor are only moved with
  `reassign_floors: true`.

It never deletes or renames anything in Home Assistant. Names are matched case- and accent-insensitively.
Device→area assignment in HA is left to the user / HA (Matter device names from HA rarely match HomeKit names).

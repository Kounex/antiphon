# Antiphon design system

The design system lives in the local Swift package **`Packages/AntiphonDesign`**. It comes from the design system artifact (`TXKAkq1pkYhFFF593kxH63`); the screens follow the storyboard (`BF77MNwKAG2ZbZNv6mL15Q`). Light and dark mode are both first-class: every color has both appearances, and the person can choose System, Light or Dark in Settings.

The old dark-only "glassmorphic" theme (`Antiphon/UI/Theme`, `appBackground`, `spotifyGreen`…) was removed in M8. Don't bring it back.

## Tokens (`Sources/AntiphonDesign/Tokens`)

- **Colors** (`Color.<name>`, generated from `tokens.json` by `scripts/generate_color_assets.py` into `Resources/Colors.xcassets`):
  - **Ground:** `canvas`, `canvasRaised` (cards and rows), `canvasSunken`, `hairline`, `focusRing`.
  - **Text:** `ink`, `inkMuted`, `inkFaint`.
  - **Brand:** `thread` (gold) and `threadSoft`, `onThread`. Use thread for the one primary action on a screen.
  - **Services:** `spotify`, `applemusic`, `onSpotify`, `onApplemusic`.
  - **Status:** `statusSynced`, `statusReview`, `statusFailed`, `statusMissing`, plus `…Soft` backgrounds.
  - **Placeholder artwork:** `art-dusk/ember/moss/sand/tide`, through `CoverPlaceholder(seed:)`.
- **Type** (`Font.<name>`, built on Dynamic Type styles): `antiphonLargeTitle`, `antiphonTitle1/2/3`, `statusLabel` (with `TypeMetrics.statusLabelTracking`), `code`, `metric`, `metricSmall`.
- **Layout:**
  - `Space.s1…s8` (4–32 pt), `Space.tap` (44).
  - `Radius.coverSmall/cover/row/card`.
  - `Opacity.missing` (dims unavailable rows), `Opacity.disabled`.

## Components (`Sources/AntiphonDesign/Components`)

`SeamLine` (two covers stitched; drifts while monitoring, honours Reduce Motion) · `SyncCard` · `TrackRow` (states: synced, syncing, pending, review, missing, failed, removed, plain) · `CoverArt` (with an optional service dot) · `PlatformDot` / `PlatformBadge` · `StatusPill` · `StatTile(s)` · `ChipBar` · `DirectionPicker` · `MonitorToggle` · `Banner` · `ConfidenceMeter` · `SyncAccessory` · `glassButton(.primary/.secondary)` · tab-bar helpers.

The DEBUG component catalog shows each one: `-AntiphonScreen catalog` or `catalog/<Component>`.

## Rules the screens follow

- Lists are `.insetGrouped` on `Color.canvas` with rows on `canvasRaised`. `.plainRow()` gives full-width content in a list.
- Hero screens (seam detail, playlist detail) work like Apple Music: no title in the navigation bar, glass toolbar buttons, cover colours bleeding under the toolbar (`backgroundExtensionEffect`), and `scrollEdgeEffectStyle(.soft)`.
- One gold primary action per screen; everything else is `.secondary` glass or plain.
- Every setting shows its current value. Every choice states its consequence in one sentence of plain words, with no jargon and no promises iOS doesn't keep.
- Check light, dark and AX5 (`accessibility-extra-extra-extra-large`) with `scripts/screenshot.sh`.

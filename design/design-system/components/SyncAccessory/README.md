# SyncAccessory

While a sync runs, a glass capsule floats above the tab bar, like Music's mini player: the playlist, progress in tracks, and a ring. Tap opens the live sync sheet.

- Provide: the running seam, `done`, `total`, direction.
- Placement: `.tabViewBottomAccessory`. When the tab bar minimizes it collapses inline; read `@Environment(\.tabViewBottomAccessoryPlacement)` and drop the second line when `.inline`.
- Several syncs: show "Syncing 3 playlists" and the combined count.
- Also mirror it as a Live Activity (Lock Screen and Dynamic Island) for syncs longer than 20 seconds.

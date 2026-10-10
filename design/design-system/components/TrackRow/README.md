# TrackRow

One track in a seam, with its sync state as a trailing symbol. Used in the seam's track list, the review queue, and history entries.

- Provide: title, artist, album, artwork, `state` (`synced` | `syncing` | `review(confidence)` | `missing(reason)` | `failed(reason)`).
- Second line changes with state: album normally; the match confidence and reason for review; the reason for missing or failed.
- Missing rows dim to `dim-missing`. Failed rows don't dim: they need action.
- Tap opens Track match detail. Review rows swipe: leading Accept match, trailing Skip track.
- In SwiftUI, a `List` row with `.listRowBackground(Color("canvas-raised"))`; the trailing symbol uses `.symbolRenderingMode(.hierarchical)` and the syncing symbol `.symbolEffect(.rotate)`.

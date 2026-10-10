# SyncCard

A seam at a glance on the Syncs tab: the stitched covers, the playlist name, direction and freshness, a three-part health bar, and the one or two pills that matter.

- Provide: the seam (both playlists), counts (`synced`, `review`, `missing`, `total`), last-checked date, monitoring state.
- Surface: opaque `canvas-raised`, `radius-card`, padding `space-4`. Not glass.
- Health bar segments: `status-synced`, `status-review`, `ink-faint` (missing). Give it an accessibility value like "48 synced, 3 to review, 1 missing".
- Show at most two pills. Priority: Failed > Review > Syncing > Monitoring > In sync.
- Swipe actions: leading Sync now; trailing Pause and Unlink (Unlink asks first and never deletes either playlist).
- Context menu preview: the seam detail.

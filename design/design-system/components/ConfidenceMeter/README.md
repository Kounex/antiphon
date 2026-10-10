# ConfidenceMeter

How sure Antiphon is that two tracks are the same recording, with the reason.

- Provide: confidence 0–100 and the match reason.
- Bands: 90–100 `status-synced` (auto-accepted), 60–89 `status-review` (asks you), below 60 `status-failed` (not added; shown as alternatives).
- Reasons, strongest first: ISRC match; title + artist + duration within 2s; title + artist with a version difference (remaster, live, explicit/clean); title only.
- Show the ISRC in `code` when available.

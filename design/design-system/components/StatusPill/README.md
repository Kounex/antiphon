# StatusPill

A compact capsule naming one state with a symbol and a word. Used on sync cards, list headers and the track detail.

| State | Symbol | Token |
| --- | --- | --- |
| In sync | checkmark.circle.fill | `status-synced` on `status-synced-soft` |
| Syncing | arrow.triangle.2.circlepath (rotating) | `thread` on `thread-soft` |
| Monitoring | eye | `thread` on `thread-soft` |
| Review *n* | questionmark.circle.fill | `status-review` on `status-review-soft` |
| Failed / Sign in | exclamationmark.triangle.fill | `status-failed` on `status-failed-soft` |
| Not on *platform* | circle.slash | `status-missing`, dashed outline |

- Provide: `state` and an optional count.
- Label: `caption-1`, uppercase. Keep to two words.
- Never place a pill on a thread fill.

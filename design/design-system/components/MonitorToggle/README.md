# MonitorToggle

A settings row with a title, a one-line consequence, and a switch. Used for monitoring and every sync rule.

- Provide: title, description that states what will happen, bound `Bool`.
- The switch tint is `thread` (`.tint(Color("thread"))`).
- Turning monitoring on schedules a `BGAppRefreshTask` and registers the seam with the server watcher; the description must show the real interval.
- Turning it off shows a glass toast: "Paused. Antiphon won't change Late Night Drive until you turn this back on."

# SeamLine

The signature element: two playlist covers joined by a stitched golden thread, with a knot that shows the direction. It appears on every sync card, the seam detail hero, and the setup flow.

- Provide: source and target covers (each with its platform dot), `direction` (`oneWay` | `twoWay`), `isMonitoring`.
- Monitoring: stitches drift at one per second in the sync direction (two-way drifts toward the middle). Not monitoring: still and `ink-faint`, with a pause knot.
- Source is always on the leading side. In a two-way seam, the playlist that existed first is leading.
- SwiftUI: draw the stitch as a `Path` stroked with `StrokeStyle(lineWidth: 2, lineCap: .round, dash: [7, 5], dashPhase: phase)` and animate `phase` with `TimelineView(.animation)`. The knot is a 28pt circle with `.glassEffect(.regular, in: .circle)` on the hero; opaque `canvas-raised` inside cards.
- Reduce Motion: no drift; a 4pt thread-colored dot pulses once per 2s at the knot.

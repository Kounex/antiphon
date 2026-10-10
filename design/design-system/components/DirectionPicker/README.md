# DirectionPicker

A glass segmented control for the two seam decisions: direction (One way / Both ways) and removal policy (Add only / Mirror removals).

- Provide: the options and the bound selection.
- Selected segment: `thread` on `thread-soft`. The arrow symbol morphs between `arrow.right` and `arrow.left.arrow.right` with `.contentTransition(.symbolEffect(.replace))`.
- Always place a one-line plain-language consequence directly under it that updates with the choice.
- SwiftUI: `Picker` with `.pickerStyle(.segmented)` inside a `GlassEffectContainer` on the setup sheet; the system draws the glass.

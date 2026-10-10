# GlassButton

Capsule buttons on Liquid Glass. One prominent (thread-tinted) button per screen, for the thing the screen is for; everything else is regular glass. Over album art, use clear glass.

**SwiftUI**

```swift
Button("Sync now", systemImage: "arrow.triangle.2.circlepath") { sync() }
    .buttonStyle(.glassProminent)
    .tint(Color("thread"))

Button("Link existing", systemImage: "link") { link() }
    .buttonStyle(.glass)

// Over artwork
Button("Pause monitoring", systemImage: "pause.fill") { pause() }
    .labelStyle(.iconOnly)
    .buttonStyle(.glass(.clear))
```

- Provide: a verb-first label and an SF Symbol. Icon-only buttons need an accessibility label.
- Group adjacent glass buttons in `GlassEffectContainer(spacing: 8)` so they merge when close.
- Do: keep the hit target at least `tap`. Don't: tint regular glass with a status color.

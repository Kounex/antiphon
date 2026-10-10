Antiphon keeps playlists in step across Spotify and Apple Music. An antiphon is a call and its answer, sung by two choirs facing each other; here the two choirs are your Spotify and Apple Music libraries. The design has one idea: **two libraries, one thread.** Every playlist pair is drawn as two covers stitched together by a golden seam. The stitch tells you the direction, whether Antiphon is watching, and whether anything needs you. Everything else stays quiet so the album art and that thread carry the screen.

Built for iOS 26 and SwiftUI with Liquid Glass. Dark is the signature theme; light is fully supported.

## Principles

1. **Art is the content, glass is the controls.** Album covers fill the content layer. Liquid Glass is only for the navigation layer floating above it: the tab bar, toolbars, the sync accessory, floating action buttons, sheets. Never put glass on list rows or cards inside a scroll view. Use `canvas-raised` for those.
2. **Status by shape first, color second.** Every state carries an SF Symbol and a word. Color confirms it. Synced is blue (`status-synced`), never green, so it can't be confused with Spotify.
3. **Say what will happen to the playlist.** Before anything writes to a library, the screen states the outcome in plain numbers: "Adds 12 tracks to Late Night Drive on Apple Music. Removes nothing."
4. **Nothing destructive by default.** New seams are one-way and add-only. Removals and two-way sync are opt-in, explained in place, and reversible from History.
5. **One thread per screen.** `thread` (gold) marks at most one primary action and the live stitch. If two things are gold, one is wrong.

## Content

- Voice: a calm, precise librarian. Short sentences, present tense, second person. "Antiphon found 3 tracks it couldn't match." Not "Oops! Some songs went missing 😅".
- No emoji anywhere in UI copy.
- Sentence case for everything: buttons, titles, settings. Status pill labels are the one uppercase exception (`caption-1`, +0.6pt tracking).
- Name things the way people do: *playlist*, *track*, *library*, *seam* (a linked pair), *monitoring*. Never *job*, *webhook*, *diff*, *endpoint*.
- Directions are written with arrows in titles and plain words in body copy: "Spotify → Apple Music" / "Copies new tracks from Spotify to Apple Music."
- Numbers are exact and use monospaced digits: "48 of 52 tracks", "Last checked 4 min ago". Round only for durations over an hour ("2 h 14 min").
- Verbs on buttons: Link, Sync now, Create playlist, Keep both, Skip track, Pause monitoring. Confirmation toasts echo the verb in past tense: "Synced", "Paused".

Real copy:

| Situation | Copy |
| --- | --- |
| Empty Syncs tab | **No seams yet.** Pick a playlist on one side and Antiphon will find or create its twin on the other. |
| Fuzzy match | **Is this the same track?** Spotify has the 2018 remaster. Apple Music only has the original. 86% match. |
| Region lock | Not available on Apple Music in Germany. Antiphon will check again weekly. |
| Two-way explainer | Changes on either side are copied to the other. If a track is removed on one side, Antiphon asks before removing it on the other. |
| Expired sign-in | Spotify signed you out. Monitoring is paused for 4 seams until you sign in again. |

## Color

- Ground: `canvas`; opaque cells: `canvas-raised`; wells: `canvas-sunken`.
- Text: `ink`, then `ink-muted`. `ink-faint` is decoration only (chevrons, disabled).
- Accent: `thread` with `on-thread` for labels on it, `thread-soft` behind thread text. Set `.tint(Color("thread"))` app-wide.
- Platforms: `spotify` and `applemusic` appear only as small marks (the source dot, the sign-in capsule). They never color text, never mean a state.
- States: `status-synced` (checkmark.circle.fill), `status-review` (questionmark.circle.fill), `status-failed` (exclamationmark.triangle.fill), `status-missing` (circle.slash, dashed outline, row at `dim-missing`). Syncing in progress uses `thread` with the animated stitch, not a status color.
- The five `art-*` tokens are placeholder cover fields for previews and for playlists without artwork. Pair two of them in a soft diagonal blend.

## Type

SF Pro via the system font; never bundle another face. Use Dynamic Type styles only (`large-title` … `caption-2`), never fixed sizes, so every screen scales to AX5. Numbers use the rounded design with monospaced digits: `metric-xl` once per screen for the hero count, `metric` in stat tiles, `metric-sm` in cards. ISRCs and IDs use `code` (SF Mono).

## Layout and spacing

- One gutter: `space-4` (16pt) from the screen edge. Sections are `space-6` apart.
- Rows: 40pt cover, `space-3` gap, two text lines, trailing status. Row height grows with Dynamic Type; never clip.
- Every hit target is at least `tap` (44×44pt).
- Corners are concentric with the device: cards inset 16pt use `radius-card` (26pt); covers inside a card use `radius-cover` (12pt); capsules use `radius-pill`.

## Liquid Glass

Use the system first; reach for custom glass only for Antiphon's own floating controls.

- **Tab bar:** a standard `TabView` with `Tab` items gets glass for free. Add `.tabBarMinimizeBehavior(.onScrollDown)`. Search is `Tab(role: .search)`, shown as its own glass circle.
- **Sync accessory:** while a sync runs, `.tabViewBottomAccessory { SyncAccessory() }` floats above the tab bar like Music's mini player. It collapses inline when the tab bar minimizes.
- **Toolbars:** plain `ToolbarItem`s; group related ones, and separate groups with `ToolbarSpacer(.fixed)`. Don't add backgrounds.
- **Custom controls:** `.glassEffect(.regular.interactive(), in: .capsule)`. Over album art use `.glass(.clear)` so the art reads through. Wrap nearby glass shapes in `GlassEffectContainer(spacing: 8)` so they blend and morph; give morphing pieces `.glassEffectID(_:in:)`.
- **Primary action:** `.buttonStyle(.glassProminent)` with `.tint(Color("thread"))`. Secondary: `.buttonStyle(.glass)`.
- **Hero art:** on playlist and seam detail, let the cover run under the navigation bar with `.backgroundExtensionEffect()`, and use `.scrollEdgeEffectStyle(.soft, for: .top)`.
- **Sheets:** partial-height sheets are glass automatically; don't set a background. Full-height sheets go opaque.
- Never stack glass on glass. Never tint glass with a status color; put a status pill inside it instead.
- Respect Reduce Transparency (glass goes frosted automatically) and Increase Contrast (add a 1pt `hairline` outline to custom glass).

## Motion

- The stitch moves only while a seam is being monitored: dashes drift along the seam at one stitch per second in the sync direction. Two-way seams drift both halves toward the middle. Paused seams stand still.
- Glass morphs between states with the default spring (`.smooth`). The direction picker morphs the arrow; it never cross-fades.
- Track rows insert from the leading edge during a sync, 40ms apart, max 12 animated.
- With Reduce Motion, the stitch is static and a small pulse dot replaces the drift.

## App icon

Two voices face each other across a golden stitch: the call, the answer, and the thread that keeps them together. Files are in the **App icon** asset group.

- Default appearance: `antiphon-icon-default.png` (voices in `ink` on a `canvas` radial ground, stitch in `thread`).
- Light and tinted appearances: `antiphon-icon-light.png`, `antiphon-icon-tinted.png`.
- For Icon Composer, import the three layers in order: `layer-1-background.svg`, `layer-2-voices.svg`, `layer-3-stitch.svg`. Give the voices and stitch layers Liquid Glass; keep the background flat.
- `antiphon-mark.svg` is the mark alone, for the onboarding hero and the About screen. Never place it on a thread fill.
- Don't add platform colors, a wordmark or a music note to the icon.

## Iconography

SF Symbols only, rendered `.hierarchical`, weight matched to adjacent text. Core set: `arrow.right` (one way), `arrow.left.arrow.right` (both ways), `link` (link existing), `plus.rectangle.on.rectangle` (create new), `eye` / `eye.slash` (monitoring on/off), `checkmark.circle.fill`, `questionmark.circle.fill`, `exclamationmark.triangle.fill`, `circle.slash`, `clock.arrow.circlepath` (history), `arrow.triangle.2.circlepath` (sync now).

Platform marks: this system ships **no Spotify or Apple Music logos.** Previews use a colored dot plus the platform's name. In the app, use each company's official badge assets under their brand guidelines for sign-in buttons and attribution; everywhere else, the dot.

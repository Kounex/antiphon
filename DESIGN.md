# Antiphon Design System

This document specifies the visual theme, color palette, typography, status states, and UI components of the Antiphon application. It serves as a standard `DESIGN.md` reference for developers and agent-based design generators.

---

## 1. Color Palette

All colors are designed for a high-fidelity, premium dark mode aesthetic.

### Brand Colors
| Token | SwiftUI Color | Hex / RGB Representation | Description |
| :--- | :--- | :--- | :--- |
| `spotifyGreen` | `Color.spotifyGreen` | `#1CBA54` / RGB(28, 186, 84) | Official Spotify green accent |
| `appleMusicPink` | `Color.appleMusicPink` | `#FA3866` / RGB(250, 56, 102) | Core Apple Music pink/rose accent |
| `appleMusicRed` | `Color.appleMusicRed` | `#E31745` / RGB(227, 23, 69) | Deep Apple Music brand red gradient stop |

### App Primary Palette
| Token | SwiftUI Color | Hex / RGB Representation | Usage / Role |
| :--- | :--- | :--- | :--- |
| `appBackground` | `Color.appBackground` | `#11111F` / RGB(17, 17, 31) | Base screen background (Deep navy-purple) |
| `cardBackground` | `Color.cardBackground` | `#1C1C2E` / RGB(28, 28, 46) | Background for cards, lists, list rows |
| `surfaceElevated` | `Color.surfaceElevated` | `#262638` / RGB(38, 38, 56) | Background for modals, menus, sheets |
| `subtleBorder` | `Color.subtleBorder` | `white.opacity(0.08)` | Thin separators, glass-card boundaries |

### Text Colors
| Token | SwiftUI Color | Opacity | Role |
| :--- | :--- | :--- | :--- |
| `textPrimary` | `Color.textPrimary` | `100%` (`#FFFFFF`) | Primary copy, titles, interactive text |
| `textSecondary` | `Color.textSecondary` | `60%` (`#FFFFFF` @ 0.6) | Subtitles, helper text, inline details |
| `textTertiary` | `Color.textTertiary` | `50%` (`#FFFFFF` @ 0.5) | Timestamps, micro badges, disabled states |

---

## 2. Gradients

Gradients are used to blend the platform identities and create visual depth.

### Brand Gradient (`AppGradients.brand`)
- **Type**: Linear
- **Colors**: `RGB(22, 130, 60)` → `RGB(58, 96, 196)` → `RGB(206, 40, 86)`
- **Direction**: `.topLeading` to `.bottomTrailing`
- **Usage**: Primary Action buttons, brand headers, dashboard accent stripes.
- **Accessibility note**: Stops are deliberately darkened so white text on the gradient meets the WCAG AA 4.5:1 contrast ratio at every stop. (The middle stop was previously documented as RGB(51, 80, 230); the pre-darkening code value was RGB(76, 128, 230).)

---

## 3. Typography

Font tokens are mapped to semantic SwiftUI text styles so all 189 call sites scale with Dynamic Type automatically. Visual sizes match the original fixed-size spec at the default (Large) content size.

| Font Token | SwiftUI Font | Semantic Mapping (default size) | Core Usage |
| :--- | :--- | :--- | :--- |
| `appLargeTitle` | `Font.appLargeTitle` | `.largeTitle.rounded()` (34, Bold) | Navigation Titles |
| `appTitle` | `Font.appTitle` | `.title2.rounded().weight(.bold)` (22, Bold) | Section Headers |
| `appTitle2` | `Font.appTitle2` | `.title3.rounded().weight(.semibold)` (20, Semibold) | Dashboard list headers |
| `appTitle3` | `Font.appTitle3` | `.headline.rounded()` (17, Semibold) | Card headers, primary badges |
| `appBody` | `Font.appBody` | `.body` (16, Regular) | Main copy, track titles |
| `appBodyBold` | `Font.appBodyBold` | `.body.weight(.semibold)` (16, Semibold) | Button text, emphasized copy |
| `appCaption` | `Font.appCaption` | `.footnote` (13, Regular) | Subtitle text, relative times |
| `appCaptionBold` | `Font.appCaptionBold` | `.footnote.weight(.semibold)` (13, Semibold) | Segment controls, tab headers |
| `appMicro` | `Font.appMicro` | `.caption2.weight(.medium)` (11, Medium) | Monitored badges, platform labels |
| `appMono` | `Font.appMono` | `.footnote.monospaced()` (13, Monospaced) | ISRCs, technical identifiers |

---

## 4. Status Indicator States

Used by `SyncStatusIndicator` to visually represent the status of a sync pair in cards and history logs.

| State / Token | Color Accent | SF Symbol Icon | Display Logic |
| :--- | :--- | :--- | :--- |
| **Synced / Success** | `Color.syncSuccess` (`#33C759` / Green) | `checkmark.circle.fill` | All tracks matched, 100% in sync |
| **Flagged / Warning** | `Color.syncWarning` (`#FFC207` / Yellow) | `flag.fill` | Tracks flagged for deletion or review |
| **Missing / Failed** | `Color.syncError` (`#FF4545` / Red) | `exclamationmark.circle.fill` | Match failure / track not found |
| **Syncing / In Progress** | `Color.syncProgress` (`#5996FF` / Blue) | `arrow.triangle.2.circlepath` | Active sync operation (rotating) |
| **Not Synced / Unknown** | `Color.textTertiary` (Gray) | `circle` | Stale or never synchronized |

> **Icon canonical source**: `exclamationmark.circle.fill` is the canonical failed icon. `SyncStatusIndicator` uses it. ⚠️ Known drift: `SyncResultStatus.icon` in `SyncPair.swift` still returns `xmark.circle.fill` for `.failed` — that model file is outside the design-system area; update it to `exclamationmark.circle.fill` when editing it.

---

## 5. UI Elements & Components

### Glass Card
Frosted-glass background style applied via `.glassCard()`.
- **Backdrop**: `.ultraThinMaterial` (real iOS material, dark-mode correct)
- **Tint Overlay**: `Color.cardBackground` at 50% opacity over the material
- **Border**: 1pt stroke of `Color.subtleBorder`
- **Corner Radius**: Default is `16pt`

### Primary Button (`AntiphonButtonStyle`)
Primary call-to-action button styled via `.buttonStyle(.antiphon)`.
- **Text Font**: `.appBodyBold` in White
- **Background**: `AppGradients.brand` linear gradient
- **Corner Radius**: `14pt`
- **Interactive Micro-Animation**: Pressing scales the button down to `0.97` size and drops opacity to `0.9` (duration: `0.15s`).

### Secondary Button (`SecondaryButtonStyle`)
Subdued secondary button styled via `.buttonStyle(.secondary)`.
- **Text Font**: `.appBodyBold` in `Color.textPrimary`
- **Background**: `Color.surfaceElevated` with 1pt subtle border
- **Corner Radius**: `14pt`
- **Interactive Micro-Animation**: Matches primary button scaling and opacity transitions.

### Shimmer Loading Modifier (`.shimmer()`)
Applies a repeating white shimmer highlight rotationally offset by 30° moving across loading placeholder states (linear duration: `2.0s`).
- **Reduce Motion**: When `accessibilityReduceMotion` is enabled the shimmer renders as a static sheen at 50% opacity with no animation. The modifier re-evaluates the setting via `.task(id:)`, so toggling it takes effect live. `PulsingDot` shows a static halo and `SyncStatusIndicator` stops rotating under the same setting.

---

## 6. Theme Extension Bindings

The theme code resides in the following implementation files:
- [AppColors.swift](file:///Users/kounex/development/swiftui/antiphon/Antiphon/UI/Theme/AppColors.swift)
- [AppFonts.swift](file:///Users/kounex/development/swiftui/antiphon/Antiphon/UI/Theme/AppFonts.swift)
- [AppStyles.swift](file:///Users/kounex/development/swiftui/antiphon/Antiphon/UI/Theme/AppStyles.swift)

To update the theme deterministically:
1. Edit hex values / RGB constants in `AppColors.swift`.
2. Adjust base scaling parameters in `AppFonts.swift`.
3. Add custom shapes or hover state scale animations in `AppStyles.swift`.

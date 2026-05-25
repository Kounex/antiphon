# Antiphon Design System

This document specifies the visual theme, color palette, typography, status states, and UI components of the Antiphon application. It serves as a standard `DESIGN.md` reference for developers and agent-based design generators.

---

## 1. Color Palette

All colors are designed for a high-fidelity, premium dark mode aesthetic.

### Brand Colors
| Token | SwiftUI Color | Hex / RGB Representation | Description |
| :--- | :--- | :--- | :--- |
| `spotifyGreen` | `Color.spotifyGreen` | `#1CDB54` / RGB(28, 219, 84) | Official Spotify green accent |
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
| `textTertiary` | `Color.textTertiary` | `35%` (`#FFFFFF` @ 0.35) | Timestamps, micro badges, disabled states |

---

## 2. Gradients

Gradients are used to blend the platform identities and create visual depth.

### Brand Gradient (`AppGradients.brand`)
- **Type**: Linear
- **Colors**: `[.spotifyGreen, RGB(51, 80, 230), .appleMusicPink]`
- **Direction**: `.topLeading` to `.bottomTrailing`
- **Usage**: Primary Action buttons, brand headers, dashboard accent stripes.

### Glass Card Gradient (`AppGradients.glass`)
- **Type**: Linear
- **Colors**: `[white.opacity(0.12), white.opacity(0.04)]`
- **Direction**: `.topLeading` to `.bottomTrailing`
- **Usage**: Frosted glass card overlay fill.

---

## 3. Typography

All custom fonts utilize System Fonts with `.rounded` design where appropriate to maintain a modern, friendly style.

| Font Token | SwiftUI Font | Configuration | Core Usage |
| :--- | :--- | :--- | :--- |
| `appLargeTitle` | `Font.appLargeTitle` | Size 34, Bold, System Rounded | Navigation Titles |
| `appTitle` | `Font.appTitle` | Size 22, Bold, System Rounded | Section Headers |
| `appTitle2` | `Font.appTitle2` | Size 20, Semibold, System Rounded | Dashboard list headers |
| `appTitle3` | `Font.appTitle3` | Size 17, Semibold, System Rounded | Card headers, primary badges |
| `appBody` | `Font.appBody` | Size 16, Regular | Main copy, track titles |
| `appBodyBold` | `Font.appBodyBold` | Size 16, Semibold | Button text, emphasized copy |
| `appCaption` | `Font.appCaption` | Size 13, Regular | Subtitle text, relative times |
| `appCaptionBold` | `Font.appCaptionBold` | Size 13, Semibold | Segment controls, tab headers |
| `appMicro` | `Font.appMicro` | Size 11, Medium | Monitored badges, platform labels |
| `appMono` | `Font.appMono` | Size 13, Regular, Monospaced | ISRCs, technical identifiers |

---

## 4. Status Indicator States

Used by `SyncStatusIndicator` to visually represent the status of a sync pair in cards and history logs.

| State / Token | Color Accent | SF Symbol Icon | Display Logic |
| :--- | :--- | :--- | :--- |
| **Synced / Success** | `Color.syncSuccess` (`#33C759` / Green) | `checkmark.circle.fill` | All tracks matched, 100% in sync |
| **Flagged / Warning** | `Color.syncWarning` (`#FFC207` / Yellow) | `exclamationmark.triangle.fill` | Tracks flagged for deletion or review |
| **Missing / Failed** | `Color.syncError` (`#FF4545` / Red) | `exclamationmark.circle.fill` | Match failure / track not found |
| **Syncing / In Progress** | `Color.syncProgress` (`#5996FF` / Blue) | `arrow.triangle.2.circlepath` | Active sync operation (rotating) |
| **Not Synced / Unknown** | `Color.textTertiary` (Gray) | `circle` | Stale or never synchronized |

---

## 5. UI Elements & Components

### Glass Card
Frosted-glass background style applied via `.glassCard()` modifier.
- **Backdrop**: `Color.cardBackground`
- **Inner Overlay Gradient**: `AppGradients.glass`
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

# Antiphon: notes for agents

Antiphon keeps playlists in sync between Spotify and Apple Music (iOS 26, SwiftUI, SwiftData, Liquid Glass). It runs on the device only: no server, and Spotify sign-in uses the person's own client ID (BYOK).

Read this first, then `docs/redesign-plan.md` (decisions D1–D7, the screen map, and a "done" section per milestone with what was verified and what differs from the storyboard).

## Where things stand (2026-10-11)

- **Branch `redesign/ios26`** has the whole iOS 26 redesign, M0–M8, all done and pushed. `main` is the old shipping app. The branch can fast-forward onto main. **Merge only when the user says "merge"**, because TestFlight builds are cut from main.
- **Next milestone: M9.** App Group, widgets with "Sync all" (`LiveActivityIntent`), Live Activity, actionable notifications, share extension (plan rows 9.01–9.03). Wait for the user to start it.
- **Open follow-ups** (not started):
  - "Moved" changes aren't recorded, so undo doesn't restore order.
  - The Spotify saved-track total isn't shown in onboarding.
  - Search has no "Add to a seam" for single tracks.
- **Design sources:** the design system artifact `TXKAkq1pkYhFFF593kxH63` and the storyboard `BF77MNwKAG2ZbZNv6mL15Q` (boards 1–9). Read them with the Artifact tool if needed.

## Commands

All scripts live in `scripts/`. Logs go to `build/logs/`, screenshots to `build/shots/`.

| What | Command |
|---|---|
| Regenerate the project (after adding or removing files) | `xcodegen generate` |
| Unit tests (Swift Testing, ~300) | `scripts/test.sh` or `scripts/test.sh -only-testing:AntiphonTests/<Suite>` |
| Simulator build and install | `scripts/screenshot.sh --install` |
| Screenshot a debug route | `scripts/screenshot.sh shell/library light library` (`WAIT=6` for slow screens) |
| Dev build for the phone | `scripts/build-dev.sh` (bundle `com.kounex.antiphon.dev`, installed next to the real app) |
| On-device self-test, real accounts | `scripts/selftest.sh [scenario]` |

- The scheme is **"Antiphon (Debug)"**, not "Antiphon".
- The simulator is the iPhone 17 Pro, `SIM_ID` D6F98034-F7A7-4574-967C-A9E182A7ED3A. The user's phone is `DEVICE_ID` E027CD50-71A3-550D-B5FA-24BA79C6EA30. Both can be overridden with environment variables.
- For the device build, override `ANTIPHON_BUNDLE_ID`, never `PRODUCT_BUNDLE_IDENTIFIER`. The latter renames the design package's resource bundle and its colors stop resolving.

### Debug routes (`-AntiphonScreen <route>`, DEBUG only, `Antiphon/Debug/DebugRouter.swift`)

- **Shell on preview data:**
  - `shell`, `shell/library`, `shell/library-playlist`, `shell/library-stitch`
  - `shell/search-<query>`, `shell/activity`, `shell/activity-new`, `shell/activity-run`
  - `shell/detail`, `shell/rules`, `shell/review`, `shell/review-removal`, `shell/match`, `shell/conflict`, `shell/problems`
  - `shell/preview|syncing|synced`, `shell/newseam/<step>`
  - `shell/settings`, `shell/settings/<spotify|appleMusic|defaults|matching|monitoring|notifications|help>`
  - `shell/settings-flip-<from>-<to>`: switches the theme with the Settings sheet open.
- **Onboarding:** `onboarding`, `onboarding/connect|defaults|twins`
- **Component catalog:** `catalog`, `catalog/<Component>`
- **Self-test:** `selftest`, `selftest/<scenario>`, real accounts and its own throwaway store.

### Self-test on real accounts (`Antiphon/Debug/SelfTest/SelfTestRunner.swift`)

- **Scenarios:**
  - `twoway`, `sameorder`, `album` (read only), `library` (read only, includes the onboarding twin scan), `undo`, `recheck`, `monitor` (the background run, called directly).
  - Only when named: `ownam` (writes to the user's own Apple Music "Antiphon Test"), `realpreview` (dry run of the user's real seam), `icon` (switches the Home Screen icon).
- Last full run: **102 of 102**.
- **Rules from the user:**
  - Only touch playlists whose names start with "Antiphon". "Antiphon Test" (made by the user, used by their real two-way seam) and "Antiphon Test 2" (Antiphon-made) may be used.
  - The phone must be unlocked; auto-lock is at most 5 minutes. If the device connection drops ("CoreDeviceError … invalidated"), just rerun.

## How the user wants work done

- **Verify sync and playlist-write changes on the real services before presenting** (self-test or a new scenario). Fakes only encode assumptions; a fake that assumed Apple Music returns catalog IDs once hid a real bug.
- **Write the test first:** watch it fail, then implement. Keep pure logic (planning, copy, policy) in testable enums or structs; views stay thin.
- **Every milestone:** build, unit tests, simulator screenshots compared with the board (light, dark, AX5 where relevant), docs updated in `docs/redesign-plan.md`, then commit and push to `redesign/ios26`.
- **Commits** end with `Assisted-by: Claude Code` and a `Co-Authored-By: Claude …` line. Push after every finished unit of work.
- **User-facing copy is plain and honest.** Each choice states its consequence ("Removing a track on Spotify won't touch Apple Music."). No promises iOS doesn't keep ("about every 15 min when iOS allows").
- **Hero screens work like Apple Music:** no navigation title over the art, glass buttons, soft scroll edge, cover colours bleeding under the toolbar.
- **Remind the user to review** non-trivial changes, especially anything that writes to their playlists.

## Architecture (redesign layer)

```
Antiphon/
  App/            AntiphonApp (onboarding gate, appearance, background registration), AppConstants
  Core/
    Sync/Planning/ Pure planning: CatalogTrack, MatchFinder, ConfidenceScorer + VersionTag (versions),
                   ReleasePreference/ReleaseResolver (which album), PlanBuilder → SyncPlan, DryRunStageA,
                   OperationRunner (restore/accept/decide/undo), UndoPlanner, ConflictResolver,
                   TrackOrder + PlacementStep (where new tracks go, "Same order"), PlaylistEntryEdit, PlanCopy
    Sync/Live/     SyncPlanner (preview = dry run), LivePlaylistEditor (writes), CatalogAdapters
    Sync/          SyncEngine (applies a plan or runs monitoring; records SyncChange per write), CacheAligner,
                   DeltaEngine, LibraryAnchor (Apple Music library IDs), RemovalSafety, SyncCoordinator
    Background/    BackgroundTaskManager + MonitorRun (due seams, gates, notifications), MonitorPolicy
                   (MonitorSchedule, MonitorGates, MonitorNotifications, RecheckCadence), SyncPlaylistsIntent
    Storage/       SwiftData models (SyncPair, CachedTrack, SyncLog, SyncChange, SyncProblem), AppPreferences
                   (UserDefaults), AppAppearance (+ AppearanceApplier, AppIconSwitcher), Keychain
    Networking/    SpotifyAPI (client, auth, models, endpoints), AppleMusic (MusicKit manager, editing)
  Services/        Protocols the screens use, each with a live and a Preview implementation:
                   SeamRepository (SwiftDataSeamRepository also conforms to ReviewRepository, ProblemsRepository,
                   TrackIndex, ActivityRepository, SettingsStore), SyncService, LibraryService,
                   AvailabilityService, CatalogSearchService, AccountsService; PreviewServices = fixtures
  Features/        Shell (tabs, sheets) · Syncs (home, seam detail, rules) · NewSeam · SyncFlow (preview →
                   syncing → synced) · Review (queue, match detail, conflicts, problems) · Library (grid,
                   playlist detail, search) · Activity (history, new tracks, run detail + undo) · Settings ·
                   Onboarding (TwinSuggester)
  Debug/           DebugRouter, ComponentCatalogView, SelfTest
Packages/AntiphonDesign  Tokens (colors from tokens.json, type, spacing) and components (SeamLine, TrackRow,
                         CoverArt, ChipBar, Banner, StatTile, GlassButton, DirectionPicker, SyncAccessory…)
Tests/AntiphonTests      Swift Testing suites per area; in-memory SwiftData via SharedModelContainer.make(inMemory:)
```

**Sync flow.** A manual sync previews first: `SyncPlanner.plan` gives a `PlannedSync`. The person approves it, `SyncService.apply` hands it to `SyncEngine.syncPair(planned:)`, and that writes, records a `SyncChange` per write, then places new tracks in order. Monitoring runs the engine without a preview: close matches wait in Review, and removals in two-way seams become questions. Single actions (put back, accept a match, undo) go through `OperationRunner`.

## Gotchas learned the hard way

- **Apple Music IDs and timing:**
  - Playlist reads return library IDs (`i.…`), but adds take catalog IDs. An added song is listed about 3 s later, sometimes under an equivalent catalog ID. `LibraryAnchor` maps adds to library IDs (by ID, then title/artist/length), and `DeltaEngine` gives catalog-ID rows a 15-minute read grace.
  - Apps can only remove or reorder tracks in Apple Music playlists **they created** (D1). In the person's own playlists Antiphon can only append, and removals are "guided" (the person does them in the Music app).
- **Spotify:**
  - Since February 2026 the API uses `/items` (it accepts both `item` and `track` keys).
  - Development-mode apps get at most 10 search results and can't read Spotify-made playlists.
  - Local files have `album.id == null`.
- **SwiftData:**
  - Batch `delete(model:)` fails on the run → change relationship. Delete object by object (`resetAll`).
  - Enum comparisons don't work in `#Predicate`; filter in memory.
- **SwiftUI:**
  - `lazy var` in an `@Observable` class needs `@ObservationIgnored`.
  - `preferredColorScheme` doesn't reach a sheet that's already open, so the theme is set on the windows instead (`AppearanceApplier`).
  - iOS cancels `setAlternateIconName` at launch, so `AppIconSwitcher` waits until the app is active.
- **Tests:**
  - Pin the locale when formatting numbers ("1.284" in the German simulator).
  - The legacy `Inspector` is gone; don't reintroduce `HistorySection`-style name clashes.
- **Simulator:** if a stale system alert (such as the notification prompt) covers screenshots, reboot the simulator: `xcrun simctl shutdown/boot`.

## Other docs

- `docs/redesign-plan.md`: the plan and the per-milestone record. Keep adding to it.
- `docs/SYNC_ENGINE.md`: Stage A/B engine internals.
- `docs/ARCHITECTURE.md`: concurrency and SwiftData schema.
- `DESIGN.md`: design system notes.
- Release flow (version bump, archive, fastlane beta) is in the user's agent memory; TestFlight only when asked.

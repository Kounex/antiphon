# Antiphon: notes for agents

Antiphon keeps playlists in sync between Spotify and Apple Music (iOS 26, SwiftUI, SwiftData, Liquid Glass). It runs on the device only: no server, and Spotify sign-in uses the person's own client ID (BYOK).

Read this first, then `docs/redesign-plan.md` (decisions D1–D7, the screen map, and a "done" section per milestone with what was verified and what differs from the storyboard).

## Where things stand (2026-10-14)

- **Work happens on `main`.** The iOS 26 redesign (M0–M8 plus the review fixes) was merged on 2026-10-11 and `redesign/ios26` is deleted. Commit and push to `main` after each unit of work. TestFlight builds are cut from `main`, but only when the user asks.
- **M9 in progress.** Steps 1–3 are done: App Group and snapshot, answering questions from the notification, widgets with "Sync all", Live Activity, and syncs that keep running in the background. Step 4, the share extension (9.03), is next. Opening the app checks every seam (`SeamChecks`).
- **1.4.0 shipped to TestFlight 2026-10-14** (unattended overnight session): the sync sheet now caches its `SyncFlowModel` per seam so hiding and reopening it — from anywhere — shows the same content instead of restarting; several running syncs browse in one sheet via a cover strip; an iPad pass fixed Library's column count and three screens (Onboarding, Review's match card, MatchDetailView) that stretched edge to edge with no system sheet to size them. Track matching was investigated against a tester's "wrong album" report and found solid (see `docs/redesign-plan.md`'s last entry) — no code change there. Not verified on a real device tonight; re-check the sync-sheet hide/reopen behavior on your phone.
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
| App Store screenshot captures (preview data, both Store simulators) | `scripts/store_screenshots.sh [phone\|tablet\|all] [slot …]` → `build/store_screenshots/` |

- The scheme is **"Antiphon (Debug)"**, not "Antiphon".
- The simulator is the iPhone 17 Pro, `SIM_ID` D6F98034-F7A7-4574-967C-A9E182A7ED3A. The user's phone is `DEVICE_ID` E027CD50-71A3-550D-B5FA-24BA79C6EA30. Both can be overridden with environment variables.
- For the device build, override `ANTIPHON_BUNDLE_ID`, never `PRODUCT_BUNDLE_IDENTIFIER`. The latter renames the design package's resource bundle and its colors stop resolving.

### Debug routes (`-AntiphonScreen <route>`, DEBUG only, `Antiphon/Debug/DebugRouter.swift`)

- **Shell on preview data:**
  - `shell`, `shell/library`, `shell/library-playlist`, `shell/library-stitch`
  - `shell/search-<query>`, `shell/activity`, `shell/activity-new`, `shell/activity-run`
  - `shell/detail`, `shell/rules`, `shell/review`, `shell/review-removal`, `shell/match`, `shell/conflict`, `shell/problems`
  - `shell/preview|syncing|synced`, `shell/syncing-several` (the list the accessory opens), `shell/checking` (cards while opening the app checks), `shell/newseam/<step>`
  - `shell/settings`, `shell/settings/<spotify|appleMusic|defaults|matching|monitoring|notifications|help>`
  - `shell/settings-flip-<from>-<to>`: switches the theme with the Settings sheet open.
  - `shell/store`: the App Store home (7 seams, nothing broken, Run Club syncing). `-AntiphonStoreData YES` gives any shell route that data.
- **Onboarding:** `onboarding`, `onboarding/connect|defaults|twins`, `onboarding/connect-spotify` (Spotify signed in, Apple Music not asked yet)
- **Component catalog:** `catalog`, `catalog/<Component>`
- **Self-test:** `selftest`, `selftest/<scenario>`, real accounts and its own throwaway store.

### Self-test on real accounts (`Antiphon/Debug/SelfTest/SelfTestRunner.swift`)

- **Scenarios:**
  - `twoway`, `sameorder`, `album` (read only), `library` (read only, includes the onboarding twin scan), `undo`, `recheck`, `monitor` (the background run, called directly), `opencheck` (what opening the app checks).
  - Only when named: `ownam` (writes to the user's own Apple Music "Antiphon Test"), `realpreview` (dry run of the user's real seam), `icon` (switches the Home Screen icon), `ask` (posts a question notification; the person taps its button from Notification Centre, then reopens the app).
- Last full run: **105 of 105** (2026-10-11).
- **Rules from the user:**
  - Only touch playlists whose names start with "Antiphon". "Antiphon Test" (made by the user, used by their real two-way seam) and "Antiphon Test 2" (Antiphon-made) may be used.
  - The phone must be unlocked and the dev app on screen (a suspended app stalls mid-run); auto-lock is at most 5 minutes. If the device connection drops ("CoreDeviceError … invalidated"), just rerun.

## How the user wants work done

- **Verify sync and playlist-write changes on the real services before presenting** (self-test or a new scenario). Fakes only encode assumptions; a fake that assumed Apple Music returns catalog IDs once hid a real bug.
- **Write the test first:** watch it fail, then implement. Keep pure logic (planning, copy, policy) in testable enums or structs; views stay thin.
- **Every milestone:** build, unit tests, simulator screenshots compared with the board (light, dark, AX5 where relevant), docs updated in `docs/redesign-plan.md`, then commit and push to `main`.
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

**Sync flow.** A manual sync previews first: `SyncPlanner.plan` gives a `PlannedSync`. The person approves it, `SyncService.apply` hands it to `SyncEngine.syncPair(planned:)`, and that writes, records a `SyncChange` per write, then places new tracks in order. Monitoring (`SyncEngine.syncAllMonitored` → `monitorSync`) builds the same plan unattended and applies it approving nothing: strong matches are added, close matches wait in Review, Mirror removals (one- and two-way) are carried out unless Settings › Monitoring › "Removals in the background" is off (D2 as revised, `PlanBuilder.unattendedPolicy`), and Ask seams' removals become questions. It plans for at most `backgroundLookupTime` (12 s, `LookupBudget`, at least one track) and applies what it has; the rest stay pending for the next run. Single actions (put back, accept a match, undo) go through `OperationRunner`.

## Gotchas learned the hard way

- **Apple Music IDs and timing:**
  - Playlist reads return library IDs (`i.…`), but adds take catalog IDs. An added song is listed about 3 s later, sometimes under an equivalent catalog ID. `LibraryAnchor` maps adds to library IDs (by ID, then title/artist/length), and `DeltaEngine` gives catalog-ID rows a 15-minute read grace.
  - Apps can only remove or reorder tracks in Apple Music playlists **they created** (D1). In the person's own playlists Antiphon can only append, and removals are "guided" (the person does them in the Music app).
- **Spotify:**
  - Since February 2026 the API uses `/items` (it accepts both `item` and `track` keys).
  - Development-mode apps get at most 10 search results and can't read Spotify-made playlists.
  - Local files have `album.id == null`.
- **Background execution** (what works, verified on device 2026-10-12: two syncs of 19 and 25 tracks at once finished while the person used other apps and with the phone locked):
  - A sync the person starts asks for a `BGContinuedProcessingTask` (iOS 26) at once, while the app is still on screen (`ContinuedSync.start`). Each run uses its own identifier `<bundle id>.sync.<uuid>`, covered by the wildcard `$(PRODUCT_BUNDLE_IDENTIFIER).sync.*` in `BGTaskSchedulerPermittedIdentifiers`. `strategy = .fail`: run now or not at all.
  - Register the handler with `using: .main` and treat the closure as main-actor code (`MainActor.assumeIsolated`). If it's delivered on another queue, Swift's isolation check crashes the app.
  - The expiration handler runs on iOS's queue. Call `setTaskCompleted(success: false)` right there, exactly once (`CompletionFlag`), and only then cancel the sync. If the app doesn't complete promptly, iOS ends it.
  - Feed the task's `Progress` all the time, on one 0–1000 scale for the whole sync (checking is the first 30%, adding the next 69%), never backwards, and set 1000 only at the end. A phase that reaches 100% and starts again from 0 can look to iOS like a finished task, and stalled progress looks like a hung one.
  - While continued processing runs, iOS shows its own progress, so the Live Activity is suppressed (it still feeds that progress).
  - `beginBackgroundTask` (`BackgroundTime`) is still taken for the ordinary few seconds, and handed back when the work ends or when its expiration fires. Holding it past its time gets the app ended.
  - Live Activities can't be started from the background. They start when the scene goes `.inactive` (`startLiveActivitiesBeforeLeaving`), and ones left over are ended at launch.
  - Expect a sync to be stopped mid-write anyway:
    - At launch `SyncRecovery` puts "syncing" tracks back to pending, and Stage A plans them as pending.
    - `DeltaEngine.requeueNeverArrived` requeues Apple Music adds that never showed up.
    - Spotify's batched add throws `partialAdd` with the batches that landed.
  - If it regresses: DEBUG builds log the grant, progress, lock state and expiry to `Documents/sync-diagnostics.log` (`SyncDiagnostics`).
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

## App Store screenshots

Composed in the store-shots repo (`github.com/Kounex/store-shots`, `projects/antiphon/`, its README has the loop), in the style of the screenshot canvas (claude.ai artifact `Nz2fhRTSzhDHWAifDBTL1i`). Review gallery: https://antiphon-gallery.kounex.com (Cloudflare Access). iPhone 6.9″ and iPad 13″ (the app runs on iPad, so App Store Connect needs both). Captures come from `scripts/store_screenshots.sh`.

## Other docs

- `docs/redesign-plan.md`: the plan and the per-milestone record. Keep adding to it.
- `docs/SYNC_ENGINE.md`: Stage A/B engine internals.
- `docs/ARCHITECTURE.md`: concurrency and SwiftData schema.
- `DESIGN.md`: design system notes.
- Release flow (version bump, archive, fastlane beta) is in the user's agent memory; TestFlight only when asked.

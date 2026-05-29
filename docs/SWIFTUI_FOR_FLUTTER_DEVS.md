# SwiftUI for Flutter Developers

A concept-mapping guide grounded in the Antiphon codebase. If you know Flutter's state management, routing, and widget tree mechanics, this document bridges you to SwiftUI.

---

## 1. View Lifecycle and Rebuilds

### Flutter mental model
- `StatelessWidget.build()` returns a widget tree every time the parent rebuilds.
- `StatefulWidget` + `State` persists mutable state across rebuilds.
- Flutter's framework diffs the widget tree and updates the underlying `Element` tree.

### SwiftUI equivalent
- **Every view is a value-type struct** (no `StatelessWidget` vs `StatefulWidget` distinction).
- The framework calls `var body: some View` whenever a dependency changes.
- SwiftUI diffs by **structural identity** (position in the view tree) and **explicit identity** (`id()` modifier or `ForEach` identity).
- If a view's inputs haven't changed, SwiftUI skips re-evaluating its body entirely.

### Key difference
In Flutter, `build()` is called top-down from the dirty widget. In SwiftUI, the framework tracks which specific properties a view's `body` actually *reads* (via `@Observable` tracking) and only re-evaluates views that depend on changed data.

### Project example

```swift
// SyncPairRow in DashboardView.swift
// This is a struct with injected data — like a StatelessWidget
struct SyncPairRow: View {
    let syncPair: SyncPair  // Immutable input — like a constructor param

    var body: some View {
        HStack { /* ... */ }
    }
}
```

Flutter equivalent:
```dart
class SyncPairRow extends StatelessWidget {
  final SyncPair syncPair;
  const SyncPairRow({required this.syncPair});

  @override
  Widget build(BuildContext context) => Row(children: [/* ... */]);
}
```

---

## 2. State Management

### Concept Map

| Flutter | SwiftUI | When to use |
|---------|---------|-------------|
| Local `setState()` / `ValueNotifier` | `@State private var` | View-owned ephemeral state (toggle, text field, animation flag) |
| `ChangeNotifier` / Riverpod `StateNotifier` | `@Observable` class | Shared business logic that multiple views observe |
| `ref.watch(provider)` / `context.watch<T>()` | `@Environment(T.self)` | Reading a shared object from the tree |
| Passing a `ValueNotifier` to child for writes | `@Binding var` | Child needs to modify parent's state |
| `ref.read(provider)` (one-shot read) | `let value: T` | Read-only value passed to child |

### @State — local ephemeral state

Like calling `setState()` in a `StatefulWidget`, but without the ceremony:

```swift
// DashboardView.swift
struct DashboardView: View {
    @State private var showingSettings = false  // Like: bool _showingSettings = false;

    var body: some View {
        Button("Settings") { showingSettings = true }  // Like: setState(() => _showingSettings = true)
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }
}
```

Rules:
- Always `private` — only the view that owns it can mutate it.
- Survives view re-creation (SwiftUI preserves it by structural identity, like Flutter's `State` object surviving widget rebuilds).

### @Observable — shared observable state

The `@Observable` macro is like a `ChangeNotifier` that automatically notifies only the views reading changed properties (no manual `notifyListeners()` needed):

```swift
// SyncCoordinator.swift
@Observable
final class SyncCoordinator {
    private(set) var syncingPairIds: Set<UUID> = []  // Like a @published field
    private(set) var lastResults: [UUID: SyncResult] = [:]

    func isSyncing(_ pairId: UUID) -> Bool {
        syncingPairIds.contains(pairId)  // Views reading this auto-subscribe
    }
}
```

Flutter equivalent:
```dart
class SyncCoordinator extends ChangeNotifier {
  final Set<String> _syncingPairIds = {};

  bool isSyncing(String pairId) => _syncingPairIds.contains(pairId);

  void startSync(String pairId) {
    _syncingPairIds.add(pairId);
    notifyListeners();  // <-- SwiftUI does this automatically
  }
}
```

The key upgrade: with `@Observable`, SwiftUI tracks *which properties* each view accesses in its `body`. If `SyncCoordinator.lastResults` changes but a view only reads `syncingPairIds`, that view does NOT rebuild. This is finer-grained than `ChangeNotifier` (which triggers all listeners on any change).

### @Binding and the $ prefix — two-way data flow

The `$` prefix is the most confusing syntax for Flutter devs. Here's the mental model:

**`$` never goes on the left side of an assignment.** You never write `$var = newValue`.
- To **mutate**, just assign directly: `x = newValue` (no `$`).
- To **pass a writable reference** to another view, use `$x`.

```swift
@State private var showingSettings = false
@State private var selectedItems: [UUID] = []
@State private var viewModel = LinkWizardViewModel()

// WRITING — direct assignment, no $ needed, works for any type
showingSettings = true
selectedItems.append(someId)
viewModel.currentStep = .confirm

// PASSING A BINDING — $ creates a Binding<T> so the receiver can write back
Toggle("Settings", isOn: $showingSettings)
TextField("Name", text: $viewModel.newTargetName)
```

`@Binding` is the **receiving side** — a child declares it to say "I expect a writable reference":

```swift
// Parent
@State private var volume: Double = 0.5
VolumeSlider(volume: $volume)  // Passes Binding<Double>

// Child
struct VolumeSlider: View {
    @Binding var volume: Double  // Receives the writable reference

    var body: some View {
        Slider(value: $volume)            // Can pass it further down
        Button("Reset") { volume = 0.5 } // Writes directly — no $ needed
    }
}
```

The Dart/Flutter analogy:

| Swift | Dart equivalent |
|-------|-----------------|
| `@State private var x = false` | `final x = ValueNotifier(false);` |
| `x = true` (mutating) | `x.value = true;` |
| `$x` (projecting a Binding) | Passing the `ValueNotifier` object itself (not `.value`) |
| `@Binding var x: Bool` (in child) | Receiving a `ValueNotifier<bool>` parameter |
| `x = true` (in child with @Binding) | `widget.x.value = true;` |

The `$` prefix works on multiple property wrappers:

| Source | `$` produces | Example |
|--------|-------------|---------|
| `@State private var x` | `Binding<T>` | `$showingSettings` |
| `@Bindable var model` | `Binding<T>` to any property | `$model.name` |
| `@FocusState private var focused` | `Binding<Bool>` | `.focused($focused)` |

### Decision Flowchart

```
Who creates this data?
├─ This view creates it → @State private var
│
└─ Passed from outside
    ├─ Child needs to WRITE it? → @Binding var
    ├─ Child only READS it? → let (immutable prop)
    └─ It's a shared service/manager? → @Environment(T.self)
```

---

## 3. Dependency Injection: Environment

### Flutter mental model
- `InheritedWidget` propagates data down the tree.
- `Provider` / `ProviderScope` wraps the tree; descendants call `context.read<T>()` or `context.watch<T>()`.

### SwiftUI equivalent
- `.environment(object)` modifier on a parent view injects an `@Observable` object.
- `@Environment(T.self)` in a descendant reads it.
- Propagation is automatic down the view tree (including into `.sheet()` and `.navigationDestination()`).

### Project example

```swift
// AntiphonApp.swift — the "ProviderScope"
@main
struct AntiphonApp: App {
    let spotifyAuth = SpotifyAuthManager()
    let syncCoordinator = SyncCoordinator(modelContainer: modelContainer)

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environment(spotifyAuth)        // Like: Provider<SpotifyAuth>(create: (_) => auth)
                .environment(syncCoordinator)    // Like: Provider<SyncCoordinator>(create: (_) => coord)
        }
    }
}

// Any descendant view — the "Consumer"
struct DashboardView: View {
    @Environment(SpotifyAuthManager.self) private var spotifyAuth  // Like: context.watch<SpotifyAuth>()
    // ...
}
```

### System-provided environment values

SwiftUI also provides built-in values (like `MediaQuery` in Flutter):

```swift
@Environment(\.colorScheme) private var colorScheme  // Like: Theme.of(context).brightness
@Environment(\.dismiss) private var dismiss          // Like: Navigator.of(context).pop()
@Environment(\.modelContext) private var modelContext // The database context (see section 5)
```

### The backslash (key path) vs type syntax

You'll see two forms of `@Environment` — here's when each is used:

```swift
// Backslash form — for system-provided values (key paths into EnvironmentValues)
@Environment(\.colorScheme) private var colorScheme
@Environment(\.dismiss) private var dismiss
@Environment(\.modelContext) private var modelContext

// Type form — for your own @Observable objects
@Environment(SpotifyAuthManager.self) private var spotifyAuth
@Environment(SyncCoordinator.self) private var syncCoordinator
```

**Why two forms?**

`\.colorScheme` reads from `EnvironmentValues` — a struct Apple provides with dozens of built-in properties. The backslash key path tells SwiftUI *which property* on that struct you want:

```swift
// Under the hood, EnvironmentValues is like:
struct EnvironmentValues {
    var colorScheme: ColorScheme
    var dismiss: DismissAction
    var modelContext: ModelContext
    var locale: Locale
    // ... dozens more built-in values
}

// \.colorScheme is a KeyPath<EnvironmentValues, ColorScheme>
// It says: "from the EnvironmentValues bag, give me the colorScheme property"
```

`SpotifyAuthManager.self` reads a whole `@Observable` object you injected with `.environment(spotifyAuth)`. No key path needed — you're asking for the entire object by type.

| Pattern | Swift | When |
|---------|-------|------|
| System values (appearance, locale, sizing) | `@Environment(\.propertyName)` | Reading built-in platform state |
| Your own services/managers | `@Environment(MyType.self)` | Reading injected `@Observable` objects |
| SwiftData context | `@Environment(\.modelContext)` | Database ops (injected by `.modelContainer()`) |

Dart analogy:
```dart
// \.colorScheme is like:
MediaQuery.of(context).platformBrightness   // system-provided, accessed by property name

// SpotifyAuthManager.self is like:
context.read<SpotifyAuthManager>()          // your own DI-injected object, accessed by type
```

### Key paths in general (the backslash syntax)

The `\` appears elsewhere in Swift — it's not specific to `@Environment`. It means "a reference to a property itself, not its current value":

```swift
// Sorting by a property
// Dart: items.sort((a, b) => a.name.compareTo(b.name))
items.sorted(by: \.name)

// SwiftData query sorting
@Query(sort: \SyncPair.createdAt, order: .reverse)

// Map using a key path (like: people.map((p) => p.name))
let names = people.map(\.name)
```

Used anywhere the framework needs to know *which* property you mean rather than reading its value immediately.

---

## 4. Concurrency: @MainActor, actors, async/await

### Flutter mental model
- Dart is **single-threaded** with an event loop. UI never blocks because everything is async.
- Heavy compute uses `Isolate.run()` (separate memory, message passing).
- You never worry about "which thread" because there's only one.

### Swift mental model
- Swift is **multi-threaded by default**. Any `Task {}` can run on any thread.
- UI updates MUST happen on the main thread (like Android's `runOnUiThread`).
- Swift 6 with strict concurrency makes this a **compile-time guarantee**, not a runtime crash.

### @MainActor — "UI thread only"

```swift
// This annotation means: this function can only run on the main thread.
// If called from a background thread, Swift automatically hops to main first.
@MainActor
func startSync(pairId: UUID, action: SyncAction, spotifyAuth: SpotifyAuthManager) {
    syncingPairIds.insert(pairId)  // Safe — we're guaranteed to be on main thread
}
```

Flutter doesn't need this because Dart is single-threaded. In Swift, without `@MainActor`, mutating a published property from a background thread would be a data race.

You can annotate an entire class:
```swift
@Observable
@MainActor
final class LinkWizardViewModel {  // ALL properties and methods are main-thread-only
    var currentStep: LinkWizardStep = .pickPlatform
}
```

### actor — like an Isolate with shared memory

An `actor` serializes all access to its internal state (like a single-threaded queue). Unlike Dart Isolates, actors share memory — no message serialization needed:

```swift
// SyncEngine.swift
actor SyncEngine {
    private let modelContainer: ModelContainer
    private var lastSyncTimestamp: Date?

    // Only one caller can execute inside this actor at a time
    func syncPair(_ pairId: UUID, action: SyncAction) async -> SyncResult {
        let context = ModelContext(modelContainer)  // Safe — actor-isolated
        // ... heavy work runs off the main thread automatically
    }
}
```

Flutter equivalent pattern:
```dart
// You'd use Isolate.run() or a compute function
final result = await Isolate.run(() => heavySyncWork(data));
```

The difference: Swift actors are persistent objects with state, not one-shot compute calls.

### Task — structured concurrency

```swift
// Like Future(() async { ... }) but with cancellation built in
let task = Task {
    let result = await engine.syncPair(pairId, action: .manualSync)
    // This closure runs on a background thread by default
    await MainActor.run {
        // Hop to main thread for UI updates (like WidgetsBinding.instance.addPostFrameCallback)
        self.lastResults[pairId] = result
    }
}

// Cancel later (the engine checks Task.isCancelled at checkpoints)
task.cancel()
```

### When to use @MainActor — decision framework

In Flutter you never think about this because Dart is single-threaded. In Swift, here's how to decide:

```
Does this code mutate properties that SwiftUI views observe?
├─ YES → @MainActor
│   - ViewModel driving a screen
│   - Any @Observable class injected via .environment()
│   - A function that writes to view-observed state
│
└─ NO → No @MainActor needed
    ├─ Pure computation (sorting, filtering, parsing)
    ├─ Network requests (URLSession calls)
    ├─ Database operations on a background ModelContext
    └─ Actor-isolated code (already has its own serial queue)
```

How this plays out in the project:

| Type | @MainActor? | Reasoning |
|------|-------------|-----------|
| `LinkWizardViewModel` | Class-level | ALL its state drives UI (step, playlists, loading flags) |
| `SyncCoordinator` | Per-method | Public methods mutate `syncingPairIds` (views read it), but also stores background `Task` refs |
| `SpotifyAuthManager` | Per-method | `startLogin()`/`logout()` mutate `isAuthenticated` (views read it), but `validAccessToken()` is called from background sync |
| `SyncEngine` | No — it's an `actor` | Runs off main thread, never touches view state directly |
| `SpotifyAPIClient` | No — it's an `actor` | Pure networking, no UI state |
| `TrackMatcher`, `CacheAligner` | No | Pure logic structs — no state, no side effects |

Rules of thumb:

1. **Entire class `@MainActor`** — when ALL its state is UI-facing and no methods do heavy async work (e.g., `LinkWizardViewModel`).
2. **Per-method `@MainActor`** — when the class mixes UI-mutating methods and background-callable methods (e.g., `SpotifyAuthManager`).
3. **No `@MainActor`** — actors, pure structs, anything that never touches view state.
4. **`@unchecked Sendable`** — escape hatch saying "trust me, I handle thread safety manually." Used on `SyncCoordinator` because it stores `Task` references but guarantees mutations go through `@MainActor` methods.

The Dart equivalent of the mistake `@MainActor` prevents:
```swift
// WRONG — without @MainActor this runs on a random thread
Task {
    syncCoordinator.syncingPairIds.insert(pairId)  // Data race! View reads this on main thread
}

// CORRECT — @MainActor guarantees main thread
@MainActor
func startSync(pairId: UUID) {
    syncingPairIds.insert(pairId)  // Compiler-enforced safe
}
```

### Summary

| Dart/Flutter | Swift |
|-------------|-------|
| Single-threaded event loop | Multi-threaded runtime |
| `Future<T>` | `async throws -> T` |
| `Stream<T>` | `AsyncSequence` / `AsyncStream` |
| `Isolate.run()` | `actor` or `Task.detached {}` |
| "Just works" (no thread bugs) | `@MainActor` + `Sendable` + `actor` (compiler-enforced thread safety) |
| `await Future.delayed(...)` | `try await Task.sleep(for: .seconds(1))` |

---

## 5. Persistence: SwiftData

### Flutter mental model
- `drift` / `sqflite`: Define tables, write queries, get `Stream<List<T>>` for reactive UI.
- `Hive`: Key-value box with type adapters.
- Manual serialization with `json_serializable` / `freezed`.

### SwiftData equivalent
SwiftData is an Apple-provided ORM built into SwiftUI. No codegen, no packages. Think: drift but fully integrated into the view layer.

### @Model — entity definition

```swift
// SyncPair.swift — like a drift Table class, but it's just a regular class
@Model
final class SyncPair {
    @Attribute(.unique) var id: UUID
    var spotifyPlaylistName: String
    var isMonitored: Bool
    var lastSyncedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \CachedTrack.syncPair)
    var cachedTracks: [CachedTrack] = []
}
```

Flutter/drift equivalent:
```dart
class SyncPairs extends Table {
  TextColumn get id => text()();
  TextColumn get spotifyPlaylistName => text()();
  BoolColumn get isMonitored => boolean()();
  DateTimeColumn get lastSyncedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
```

Key differences:
- No codegen step — the `@Model` macro does everything at compile time.
- Relationships are expressed as regular Swift properties, not separate join tables.
- The class is mutable — you modify properties directly and call `context.save()`.

### ModelContainer — the database connection

```swift
// AntiphonApp.swift — created once, like opening a drift database
let modelContainer = try ModelContainer(
    for: SyncPair.self, CachedTrack.self, SyncLog.self,
    configurations: ModelConfiguration(isStoredInMemoryOnly: false)
)

// Injected into the tree (like providing a drift database)
WindowGroup { DashboardView() }
    .modelContainer(modelContainer)
```

### ModelContext — the transaction scope

```swift
// Read from environment (like: final db = context.read<AppDatabase>())
@Environment(\.modelContext) private var modelContext

// Insert (like: db.into(syncPairs).insert(...))
let pair = SyncPair(spotifyPlaylistId: "abc", ...)
modelContext.insert(pair)
try modelContext.save()

// Delete (like: db.delete(syncPairs).where((t) => t.id.equals(id)))
modelContext.delete(syncPair)
try modelContext.save()
```

### @Query — live-updating reactive queries

This is the killer feature. `@Query` is like a `StreamBuilder` watching a drift query, but declarative:

```swift
// DashboardView.swift
@Query(sort: \SyncPair.createdAt, order: .reverse)
private var syncPairs: [SyncPair]

// The view automatically re-evaluates body when the query results change.
// No StreamBuilder, no AsyncSnapshot, no loading states to manage.
var body: some View {
    ForEach(syncPairs) { pair in
        SyncPairRow(syncPair: pair)
    }
}
```

With filtering (like drift's `.where()`):

```swift
// SyncPairRow.swift — filtered query for tracks belonging to this pair
init(syncPair: SyncPair) {
    let pairId = syncPair.id
    let predicate = #Predicate<CachedTrack> { $0.syncPair?.id == pairId }
    _tracks = Query(filter: predicate)
}
```

### No serialization boilerplate

- No `toJson()` / `fromJson()`.
- No `TypeAdapter` (Hive).
- No `json_serializable` + `build_runner`.
- SwiftData handles all persistence automatically. Enums just need `Codable` conformance:

```swift
enum SyncDirection: String, Codable {  // That's it — stored as a string in the DB
    case bidirectional
    case spotifyToApple
    case appleToSpotify
}
```

---

## 6. Navigation

### WindowGroup — the app's root container

`WindowGroup` is SwiftUI's equivalent of `MaterialApp` — the root scene that creates your app's window:

```swift
// AntiphonApp.swift
var body: some Scene {
    WindowGroup {
        DashboardView()  // The root — like MaterialApp(home: DashboardView())
            .environment(spotifyAuth)
            .environment(syncCoordinator)
            .preferredColorScheme(.dark)
    }
    .modelContainer(modelContainer)
}
```

Only `DashboardView` is listed here — same reason Flutter's `MaterialApp` only specifies one `home:`. All other screens are presented **from within** via navigation (push, sheet, etc.):

```
WindowGroup (= MaterialApp + runApp)
 └─ DashboardView (= home screen)
     ├─ NavigationLink → PlaylistInspectorView (push)
     ├─ .sheet → SettingsView (modal)
     └─ .sheet → LinkWizardView (modal)
```

| WindowGroup responsibility | Flutter equivalent |
|---------------------------|-------------------|
| Creates the app window | `runApp()` + `MaterialApp` |
| Multi-window on iPad/Mac | No Flutter equivalent (single-window) |
| Scene lifecycle (`scenePhase`) | `WidgetsBindingObserver.didChangeAppLifecycleState` |
| Propagates environment to all children | `ProviderScope` wrapping `MaterialApp` |

On iOS there's always one window. On macOS/iPadOS, the system can spawn multiple independent windows from the same `WindowGroup`.

### Flutter mental model
- `GoRouter`: Declarative routing with path-based URLs.
- `Navigator 2.0`: Imperative push/pop with `Router` + `RouterDelegate`.
- `context.push('/playlist/123')` or `Navigator.of(context).push(MaterialPageRoute(...))`.

### SwiftUI equivalent
- **`NavigationStack`**: The navigation container (like `MaterialApp` with router).
- **`NavigationLink`**: A tappable element that pushes a destination (like `ListTile` + `onTap: () => context.push(...)`).
- **`.sheet()`**: Modal presentation (like `showModalBottomSheet` or `showDialog`).
- **No external package needed** — navigation is built into SwiftUI.

### Project example — push navigation

```swift
// DashboardView.swift
NavigationStack {
    ScrollView {
        ForEach(syncPairs) { pair in
            NavigationLink {
                // Destination view — like GoRoute's builder
                PlaylistInspectorView(syncPair: pair)
            } label: {
                // The tappable row — like the ListTile
                SyncPairRow(syncPair: pair)
            }
        }
    }
}
```

Flutter equivalent:
```dart
// GoRouter
GoRoute(
  path: '/playlist/:id',
  builder: (context, state) => PlaylistInspectorScreen(id: state.params['id']!),
)

// Navigating
context.push('/playlist/${pair.id}');
```

Key difference: SwiftUI passes the actual object, not a serialized route parameter. No string-based routing.

### Modal presentation (sheets)

```swift
@State private var showingSettings = false

Button("Settings") { showingSettings = true }
.sheet(isPresented: $showingSettings) {
    SettingsView()  // Presented as a modal sheet
}
```

Flutter equivalent:
```dart
showModalBottomSheet(
  context: context,
  builder: (_) => SettingsView(),
);
```

### Dismissing

```swift
@Environment(\.dismiss) private var dismiss

Button("Done") { dismiss() }  // Like Navigator.of(context).pop()
```

### Tab-based navigation (custom)

Antiphon uses `TabView` with `.tabViewStyle(.page)` for swipeable tabs in the Inspector — this is like a `PageView` in Flutter, not a `BottomNavigationBar`.

---

## 7. Theming and Styling

### Flutter mental model
- `ThemeData` defines colors, typography, shapes globally.
- `Theme.of(context).colorScheme.primary` reads from the tree.
- Custom widgets wrap `DecoratedBox`, `Container`, etc.

### SwiftUI approach
There's no single `ThemeData` class. Instead, the pattern is:
1. **Static `Color` extensions** — named tokens like `Color.appBackground`
2. **Static `Font` extensions** — tokens like `Font.appTitle3`
3. **Custom `ViewModifier`s** — reusable styling bundles (like a `DecoratedBox` widget)
4. **Custom `ButtonStyle`s** — control button appearance globally

### Project implementation

**Colors** (`AppColors.swift`):
```swift
extension Color {
    static let appBackground = Color(red: 0.07, green: 0.07, blue: 0.12)
    static let spotifyGreen = Color(red: 0.11, green: 0.73, blue: 0.33)
    static let syncSuccess = Color(red: 0.20, green: 0.78, blue: 0.35)
}
```

Flutter equivalent:
```dart
abstract class AppColors {
  static const appBackground = Color(0xFF11111F);
  static const spotifyGreen = Color(0xFF1CDB54);
}
```

**Fonts** (`AppFonts.swift`):
```swift
extension Font {
    static let appTitle3 = Font.system(size: 17, weight: .semibold, design: .rounded)
    static let appBody = Font.system(size: 16)
}
```

**ViewModifiers** — the SwiftUI equivalent of reusable decoration widgets:
```swift
// AppStyles.swift — Step 1: Define the modifier logic
struct GlassCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.subtleBorder))
    }
}

// Step 2: Create a View extension to give it a dot-syntax name
extension View {
    func glassCard(cornerRadius: CGFloat = 16, padding: CGFloat = 16) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

// Step 3: Use it — the method name comes from YOUR extension, not the struct name
Text("Hello").glassCard()
```

The connection: `ViewModifier` struct = reusable logic, `View` extension = the dot-syntax shorthand. Without the extension, you'd write the verbose `Text("Hello").modifier(GlassCardModifier())`. You choose the method name freely — it could be `.frostyBox()` or anything.

Flutter equivalent:
```dart
class GlassCard extends StatelessWidget {
  final Widget child;
  const GlassCard({required this.child});

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.cardBackground,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.subtleBorder),
    ),
    child: child,
  );
}
```

**ButtonStyles** — like Flutter's `ButtonStyle` but applied via `.buttonStyle()`:
```swift
// AntiphonButtonStyle in AppStyles.swift
struct AntiphonButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.appBodyBold)
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14).fill(AppGradients.brand))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
    }
}

// Usage
Button("Link Playlist") { /* ... */ }
    .buttonStyle(.antiphon)
```

---

## 8. Quick Reference Table

| Flutter Concept | SwiftUI Equivalent | Notes |
|----------------|-------------------|-------|
| `StatelessWidget` | `struct MyView: View` | All SwiftUI views are structs |
| `StatefulWidget` + `State` | `@State private var` | State preserved by structural identity |
| `setState(() { })` | Direct mutation of `@State` var | SwiftUI auto-detects the change |
| `ChangeNotifier` | `@Observable` class | Property-level granularity (no `notifyListeners()`) |
| `Provider<T>` / `InheritedWidget` | `.environment(object)` | Propagates down the tree |
| `context.watch<T>()` | `@Environment(T.self)` | Subscribes to changes |
| `context.read<T>()` | `let` property (no wrapper) | One-shot read, no subscription |
| `ValueNotifier` passed to child | `@Binding var` | Two-way data flow |
| `StreamBuilder` | `@Query` or `.task { }` | Declarative async data |
| `FutureBuilder` | `.task { }` modifier | Auto-cancelled on disappear |
| `Navigator.push()` | `NavigationLink { }` | Declarative push |
| `GoRouter` path routing | `NavigationStack` + `.navigationDestination(for:)` | Type-based, not string-based |
| `showModalBottomSheet` | `.sheet(isPresented:)` | Modal presentation |
| `Navigator.pop()` | `@Environment(\.dismiss)` | Call `dismiss()` |
| `ThemeData` | `Color`/`Font` extensions + `ViewModifier` | No single theme object |
| `Theme.of(context)` | `@Environment(\.colorScheme)` | System appearance |
| `Container` / `DecoratedBox` | `.modifier(MyModifier())` or `.background()` | Chained modifiers |
| `Padding` widget | `.padding()` modifier | Modifier, not a wrapper widget |
| `GestureDetector` + `onTap` | `Button { }` or `.onTapGesture` | Prefer `Button` for accessibility |
| `ListView.builder` | `LazyVStack { ForEach }` | Lazy = on-demand creation |
| `sqflite` / `drift` | SwiftData (`@Model`, `@Query`) | Built into the framework |
| `shared_preferences` | `@AppStorage("key")` | One-line persistent key-value |
| `Isolate.run()` | `actor` or `Task.detached {}` | Shared memory, no serialization |
| `compute()` | `Task { }` | Runs on a background thread |
| `WidgetsBinding...addPostFrameCallback` | `MainActor.run { }` | Hop to main thread |
| `json_serializable` | `Codable` protocol | Built into Swift, no codegen |
| `freezed` (immutable data class) | `struct` with `let` properties | Structs are value types by default |
| `Equatable` (package) | `Equatable` protocol | Built into Swift |

---

## Key Mental Model Shifts

1. **No `build_runner` / codegen**: Swift macros (`@Observable`, `@Model`, `@Entry`) do at compile time what Dart packages do with codegen. No `part` files, no `*.g.dart`.

2. **Modifiers, not wrapper widgets**: In Flutter you nest `Padding(child: Container(child: ...))`. In SwiftUI you chain: `Text("hi").padding().background(...)`. The view tree is flatter.

3. **Thread safety is the compiler's job**: In Dart you don't think about threads. In Swift 6, you MUST annotate concurrency boundaries (`@MainActor`, `Sendable`, `actor`). The payoff: the compiler catches data races that would be silent bugs in Dart.

4. **No route strings**: Navigation is type-safe. You pass actual objects to destinations, not string paths with parameters.

5. **Persistence is a framework feature**: SwiftData is to SwiftUI what `drift` would be if it were built into Flutter itself with zero setup — just annotate a class with `@Model` and query it with `@Query`.

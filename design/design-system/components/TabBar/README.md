# TabBar

The floating Liquid Glass tab bar: Syncs, Library, Activity, and Search as its own glass circle.

```swift
TabView {
    Tab("Syncs", systemImage: "rectangle.split.2x1") { SyncsView() }
        .badge(reviewCount)
    Tab("Library", systemImage: "books.vertical") { LibraryView() }
    Tab("Activity", systemImage: "clock.arrow.circlepath") { ActivityView() }
    Tab(role: .search) { SearchView() }
}
.tabBarMinimizeBehavior(.onScrollDown)
.tabViewBottomAccessory { if sync.isRunning { SyncAccessory() } }
.tint(Color("thread"))
```

- Settings lives behind the account button in each root's toolbar, not in a tab.
- Badge Syncs with the number of tracks waiting for review; never badge for routine syncs.

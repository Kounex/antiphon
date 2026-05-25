# Playlist Sync Engine Guide

This document explains the delta synchronization logic, track-matching pipelines, and override mechanisms in the Antiphon sync engine. It serves as a technical source of truth for developers and AI agents.

---

## 🔄 The Two-Stage Sync Pipeline

To maximize speed and prevent UI freezes, the synchronization engine is split into a fast, non-blocking phase (Stage A) followed by a slower, progress-reporting match phase (Stage B).

```
[Start Sync]
     │
     ▼
[Stage A: Fast Scan]
  ├── Fetch Spotify & Apple Music Tracklists
  ├── Cache Seeding (Spotify by default, AM if Spotify is empty)
  ├── Aligner: Detect source removals & additions
  └── DeltaEngine: Match target tracks & identify target changes
     │
     ▼
[Stage B: Sequential Resolve]
  ├── Chunked AM Catalog Resolution (Batches of 25 by ISRC)
  ├── Sequential Track Matching Fallbacks
  └── Commit Batch Writes (Adds tracks to Spotify & Apple Music)
     │
     ▼
  [Complete]
```

---

## 🛠 Stage A: Cache Alignment & Delta calculations

Stage A executes quick list alignments in memory using optimized dictionary lookups ($O(N)$ matching instead of $O(N^2)$ arrays).

### 1. Source Alignment (`CacheAligner.swift`)
* It fetches the source playlist tracks (Spotify by default, or Apple Music if Spotify is empty).
* **Source Removals**: Checks all cached tracks. If a track exists in the cache but is missing in the live source, it flags the track as `.removedFromSource` with a timestamp.
* **Source Additions**: Any new track in the source that is not in the cache is inserted as `.pending` with `removalFlag = nil`.

### 2. Target Alignment & Matching (`DeltaEngine.swift`)
* The engine fetches the target/destination playlist tracks. It runs two matching passes to match cached tracks against target items:
  * **Pass 1 (Exact ISRC)**: Matches target tracks with cached tracks having the exact same ISRC code.
  * **Pass 2 (Fuzzy Title/Artist)**: Fallback match evaluating normalized title/artist strings and durations. A match score of $\ge 0.75$ is required.
* **Target Removals**: If the sync is *not* initial, any track present on both sides in the cache but missing from the live target is flagged as removed from the target platform.
* **Target Additions (Destination-Only Tracks)**: 
  * If a track exists on the target but is absent from both the source and the cache, it is classified as a target addition.
  * **Unidirectional Sync**: The track is flagged as `.extraOnDestination` (e.g. *"Only on Apple Music — not on Spotify"*) and marked `.synced`.
  * **Bidirectional Sync**: The track is inserted as `.pending` (with `removalFlag = nil`) and has its source set to the target platform. It will be synced back to the source during Stage B.
  * **Ordering**: To prevent newly added tracks from sorting near the top of the playlist, their `addedAt` timestamp is calculated as `max(existingTrack.addedAt) + 1.0` seconds, placing them at the bottom.

---

## ⚡ Stage B: Resolution & Batch Writes

Stage B resolves the matching details on the target platforms and commits writes in batches:

### 1. Batch ISRC Catalog Pre-Resolution
Before resolving tracks one by one, the engine batches all Apple Music catalog lookups by grouping up to 25 ISRCs inside a single `MusicCatalogResourceRequest`. This avoids making serial, individual network requests, saving significant sync overhead.

### 2. Target Matching Fallback Rules
For each pending track, `TrackMatcher` searches the opposite platform:
1. **ISRC Search**: Queries the target platform directory for the track's specific ISRC code.
2. **Fuzzy Search**: If ISRC search fails, it searches using the track's normalized title and primary artist name, selecting the candidate with the highest similarity score.

### 3. String Normalization Rules
To handle differences in title formatting, string titles are normalized inside `String+Extensions.swift` prior to fuzzy scoring:
* Strips promotional junk tags (e.g. `[Official Video]`, `(Explicit)`) but retains music-specific edits in brackets (e.g. `[YDG Remix]`).
* Converts all hyphens `-`, slashes `/`, and backslashes `\` to spaces.
* Strips parenthesis `( )`, bracket `[ ]`, and brace `{ }` characters entirely while keeping their internal contents.
* Normalizes whitespace and converts the string to lowercase.

This guarantees that `Edge (Blanke Remix)`, `Edge - Blanke Remix`, and `Edge [Blanke Remix]` normalize to `"edge blanke remix"` and match cleanly.

### 4. Batch Writes
Tracks queued for addition are collected inside `spotifyUrisToAdd` and `appleMusicSongsToAdd` arrays. They are committed to Spotify and Apple Music using batch API requests at the very end of Stage B, minimizing HTTP API write latency.

---

## 🛡 Override & Conflict Resolution UI

When tracks are flagged or fail to match, users can override states using two safe actions:

### 1. Keep Action (Resolving Deletions)
* **What it does**: Clears the `removalFlag` and marks the track as in-sync.
* **Why it needs confirmation**: Clears the flag in-memory. If done by accident, the engine will assume the track is in-sync and won't flag it again. Reversing this requires a **Full Rebuild** to clean the cache.

### 2. Dismiss Action (Overriding Matches)
* **What it does**: Clears the `unmatchedPlatform` property and marks `syncState = .synced` (or `.skipped`).
* **Why it is useful**: Useful when a song cannot be found on the opposite platform (e.g., local mixes, greyed-out licenses) but the user wants to clear the red error badge and restore the sync card to green.
* **Why it needs confirmation**: Bypasses platform matching. Reversing it requires a **Full Rebuild**.

---

## 🛑 Sync Safeguards

* **Safety Threshold**: If more than 30% of your playlist's tracks are flagged for deletion in a single delta sync run, the engine triggers a safeguard abort. This protects against corrupted playlist fetches or API errors clearing your music collections.

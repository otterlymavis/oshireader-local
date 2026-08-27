# OshiReader — Code Review Findings

Whole-project review of the iOS app (`ios-swift/`). Findings are grouped by
severity. Line numbers are from the state of the tree at review time; the
build and test suite were **not** run, so severities are best-effort from
reading.

> **Status:** all **High** and **Medium** findings below were fixed on this
> branch. Each carries a **✅ Fixed** note with the change made. Low /
> optimization / tooling items are left as-is.
>
> **Verification:** `xcodebuild build` green; `xcodebuild test` → **393 / 393
> unit tests pass** (incl. `FeedMergingTests`, `FeedQueryingTests`,
> `PaidPushTests`, `QuietHoursTests`, `SavedBookmarksTests`, `OPMLExportTests`,
> `ThemeMetadataTests`). 8 of 20 **UI** tests fail — **proven pre-existing**:
> stashing only this fix's 12 files (leaving the tree's other uncommitted
> changes) and re-running still fails the same tests identically. The cause is
> the tree's separate uncommitted change enabling paid push by default
> (`config/paid-catalog.json` `repository_default_enabled: true`, populated
> `PUSH_SUBSCRIPTION_PRODUCT_IDS` in `project.yml` / `project.pbxproj`,
> `PlusStore.swift` — none touched here): `testPaidPushControlsFollowCatalogConfiguration`
> asserts the guaranteed-push Settings section is *absent* under plain
> `--uitesting`, and it is now present, which shifts every Settings /
> add-keyword element lookup below it. All fixes here are inert under
> `--uitesting` (paid sync disabled, `FeedView.refreshFeed()` returns early).

**Severity key**
- **High** — data loss / integrity, security, or user-visible wrong behavior that occurs in normal use.
- **Medium** — wrong behavior in a specific or less-common path, a main-thread stall, or a bug needing an uncommon trigger.
- **Low** — edge cases, robustness gaps, cosmetic issues, or code that is fragile but currently correct.
- **Optimization** — no correctness impact.
- **Concurrency (unverified)** — plausible races found by reading; not reproduced.

---

## High

### H1. Concurrent watch-term sync has no single-flight guard → duplicate backend terms
**Files:** `OshiReader/PaidBackendFeedCoordinator.swift:365‑411`, `OshiReader/AppDelegate.swift:21‑28, 49‑59`, `OshiReader/PushSyncCoordinator.swift:167‑179`

`synchronizeActiveProfileTerms()` does `fetchPushTerms()` → per-term `createBackendTerm` / `updateBackendTerm` / `deletePushTerm`, with `await` points in the middle and no in-flight lock. It is reachable concurrently from:
- `PaidBackendFeedCoordinator.refresh()` via `async let paidBackendResult` in `LocalRefreshCoordinator`,
- `scheduleSynchronization()`'s debounced `Task`,
- `AppDelegate.didFinishLaunching` **and** `applicationDidBecomeActive` (fires every foreground).

Two overlapping runs both see "no backend row for keyword X" and both call `createBackendTerm`, producing duplicate server rows. `PushSyncCoordinator.retryPendingOperations()` has the same interleaving (double `deletePushTerm` for one id). Backgrounding + foregrounding quickly, or launch + immediate activate, is enough to hit it.

**Fix:** guard `synchronizeActiveProfileTerms` / `retryPendingOperations` with an `isSyncing` flag or a single-flight `Task`, the way `PaidBackendFeedCoordinator` already does for `hostedMutesInFlight`.

**✅ Fixed.** `PaidBackendFeedCoordinator` now keeps `activeTermSync: (profileID, Task<[Int], Error>)?`; `synchronizeActiveProfileTerms` coalesces concurrent callers onto that task (keyed by profile so a run started before a profile switch is never reused) and the body moved to `performActiveProfileTermSync(profileID:)`. `PushSyncCoordinator.retryPendingOperations` got the same treatment via `pendingRetryTask` + `performRetryPendingOperations`.

---

## Medium

### M1. No per-refresh cap on local notifications → notification burst
**Files:** `OshiReader/LocalDB.swift:892‑929`, `OshiReader/NotificationManager.swift:407‑452`

`notifyForNewItems` schedules one `UNNotificationRequest` per surviving item, uncapped. `wasFirstLoad` is only true when the *entire* feed is empty (`currentMap.isEmpty`, `LocalDB.swift:795`), so enabling "notify on new" for an existing term, or re-subscribing a platform, can make one refresh emit 20–25 notifications at once (bounded only by the 3-day `maxNotifiableItemAge` filter). iOS silently drops past 64 pending.

**Fix:** when a merge yields more than ~3 notifiable items for one keyword, collapse to a single "N new items for X" (reuse the quiet-hours digest machinery).

**✅ Fixed.** `notifyForNewItems` now computes `countsByKeyword`; any keyword above `maxIndividualNotificationsPerKeyword` (3) gets one summary notification (`notificationDigestBodyFmt`, carrying the newest item's `userInfo` so a tap still opens something) and is excluded from the per-item delivery loop.

### M2. `LocalProfileStore` is read off the main thread while mutated on it
**Files:** `OshiReader/LocalProfileStore.swift:104‑111, 217‑220`, `OshiReader/IngestionService.swift:1135`

Plain `ObservableObject`, no isolation/lock. `activeProfileID` (`@Published var`) is written on `@MainActor` (`activateProfile`/`deleteProfile` via `LocalDB.switchProfile`) but read from background ingestion — `IngestionService.fetchFiveChDirect` re-reads `LocalProfileStore.shared.activeProfileID`, and `LocalProfileStore.defaultsKey(_:profileID:)` reads it whenever `profileID` is `nil` (used across `QuietHoursSettings`, `RecentTermUsageStore`, `RefreshDiagnostics`, `PaidBackendFeedCoordinator`). A profile switch during an in-flight background refresh is a data race; SwiftUI will also flag publishing from a background thread.

**Fix:** make it `@MainActor`, or guard `activeProfileID` with `os_unfair_lock`. Ingestion should use the `profileID` that `LocalRefreshCoordinator` already captures and threads through, not re-read the global.

**✅ Fixed.** `LocalProfileStore` now keeps an `NSLock`-guarded mirror of the id and exposes `currentProfileIDThreadSafe`; `activeProfileID`'s `didSet` updates it. The two confirmed background readers — `LocalProfileStore.defaultsKey(_:profileID:)` and `IngestionService.fetchFiveChDirect` — use the thread-safe accessor. The remaining reads are all inside `@MainActor` types/`init`.

### M3. iCloud sync freshness check is clock-skew sensitive; conflict "retry" still clobbers
**File:** `OshiReader/CloudSyncManager.swift:157‑196`

`pullIfNewer` decides "is remote newer?" with `remoteUpdatedAt <= lastSyncedAt` — comparing device B's wall clock (`record["updatedAt"]`) against device A's wall clock (`lastSyncedAt`). If A's clock runs ahead, A silently skips importing B's genuinely newer snapshot. Separately, the `.serverRecordChanged` handler re-applies the local asset onto the freshest record and saves unconditionally — the comment claims it avoids "clobbering the remote," but it overwrites the concurrent change with no `updatedAt` comparison.

**Fix:** compare record versions/timestamps explicitly on the retry path; document that LWW is skew-sensitive or switch the freshness gate to a stored copy of the last-seen `record["updatedAt"]`.

**✅ Fixed.** Freshness is now judged against a persisted `lastSeenRemoteUpdatedAt` (the `updatedAt` of the newest remote snapshot this device has imported or written), not the local `lastSyncedAt` wall clock. On `.serverRecordChanged`, if the latest remote `updatedAt` is newer than anything we've seen, the conflict winner is imported and the local push is left pending for the next cycle instead of being overwritten.

### M4. Silent-push preview items get a permanent fake "just now" timestamp
**File:** `OshiReader/NotificationNavigationManager.swift:55‑70, 108‑154`

`mergeNotificationItem` calls `LocalDB.mergeItems(newItems:[item])`, and when the APNs payload omits `item_published_at`, `notificationPayload` synthesizes `published_at = now` (`:142`). When the real hosted feed later delivers the same item with its true (older) date, `LocalDB.mergedPublishedAt` keeps `incomingDate >= existingDate ? incoming : existing` — the genuine date loses to the synthetic `now`, so the item is stuck sorted to the top showing "just now".

**Fix:** don't fabricate `now` for a missing publish date — skip the merge, or tag the item so a later real date always replaces it.

**✅ Fixed.** `mergeNotificationItem` now returns early (`guard payload.hasPublishedAt`) when the payload has no real publish date. Those items are still picked up by the `refreshNow()` that follows the silent push, with their genuine date.

### M5. Widget snapshot rebuild runs `computeQueryFeed` per term on the main thread
**File:** `OshiReader/LocalDB.swift:162‑187`

`scheduleWidgetSnapshotRefresh` schedules `writeWidgetSnapshotNow` on `DispatchQueue.main`, and it loops every watch term calling `computeQueryFeed(keyword:days:0)` — a full filter + sort + dedup over up to 600 `feedItems` **each**, cache deliberately bypassed. Fires on every debounced (400 ms) data-change burst. Cost is `O(terms × feedItems·log)` on the main thread.

**Fix:** snapshot `terms`/`feedItems` on main, then build `itemsByTermID` on `queue`.

**✅ Fixed.** `computeQueryFeed` was split into an instance wrapper and a pure `static` implementation taking `feedItems` / `hiddenItems` / `subscribedPlatforms` / `terms` as parameters (`matchesKeyword` and `normalizedPlatformKey` are now `static` too). `writeWidgetSnapshotNow` snapshots those four `@Published` values on the main thread, then runs the per-term loop and the file write inside a single `queue.async`.

### M6. Backup / profile import blocks the main thread
**File:** `OshiReader/Views/SettingsView.swift:619‑640, 702‑713`; `OshiReader/LocalDB.swift:1737‑1899`

The `.fileImporter` handlers call `db.importBackupData(data)` / `db.importProfileTransferData(...)` synchronously on the main actor: JSON decode of up to 20 MB, normalization, encode of 9 files, staged synchronous writes + `replaceItemAt`, plus (profile transfer) two `switchProfile` calls that each run `loadAll()` synchronously. The encrypted variants offload PBKDF2 to `Task.detached` but still finish with `importBackupData` on main (`SettingsView.swift:1108‑1112` — `decrypt` is detached, `db.importBackupData(plaintext)` is not). `CloudSyncManager.pullIfNewer` (`CloudSyncManager.swift:167`) has the same issue.

**Fix:** run decode/normalize/write in a detached task; touch `@Published` state back on main.

**✅ Fixed.** `importBackupData` is split into `prepareBackupImport(_:) -> PreparedBackupImport` (pure: decode + validate + normalize + re-encode nine files — `Sendable`) and `@MainActor applyPreparedImport(_:)` (staged swap + `@Published` assignment). New `importBackupDataOffMain(_:) async` runs `prepareBackupImport` in `Task.detached`. The plain-backup `.fileImporter` (now reads eagerly and imports in a `Task`), the encrypted import, and both `CloudSyncManager` import sites use it. **Residual now closed:** `importProfileTransferData` is `async` and uses `importBackupDataOffMain` too; its `.fileImporter` reads eagerly + runs in a `Task`, and the two `SavedBookmarksTests` cases were updated to `async` (`assertImportProfileThrows` helper). The package-wrapper parse (`JSONSerialization` + `JSONDecoder` of the ≤22 MB transfer) still runs on the main actor — one decode, far less than the 9-file normalize pipeline that now moved off.

### M7. Cold-launch share-drain can dismiss its own failure alert
**File:** `OshiReader/ContentView.swift:120‑133, 176‑178`

Both `.onAppear` and `.onChange(of: scenePhase)` (`phase == .active`) call `handlePendingShareDrain(db.processPendingShares())`. On cold launch both fire. The first drain surfaces a failure (`pendingShareFailure = .invalidURL`); the second drain returns an empty summary (queue already drained) and `handlePendingShareDrain` unconditionally sets `pendingShareFailure = summary.failures.first` → `nil`, tearing down the alert before the user sees it.

**Fix:** only overwrite `pendingShareFailure` when `!summary.failures.isEmpty`, or drain from a single lifecycle hook.

**✅ Fixed.** `handlePendingShareDrain` now `guard`s on `summary.failures.first` and only ever *sets* a failure — it never clears one.

### M8. `WallpaperRenderer.render` downloads layer images with no timeout or size cap
**File:** `OshiReader/WallpaperRenderer.swift:23‑37`

Each layer is fetched via `URLSession.shared.data(from: url)` — no `timeoutInterval`, no `expectedContentLength`/byte check. `AvatarEditorView.applyAsWallpaper` / `OshiView.setCurrentAvatarAsWallpaper` await it behind only a `settingWallpaper` bool, so a slow/dead sticker host leaves the "Set as wallpaper" button stuck on `"..."` indefinitely and an oversized image is decoded unbounded. `ReaderView.downloadBulkImageData` (`ReaderView.swift:702‑719`) already has the right pattern (8 s timeout, 20 MB cap).

**✅ Fixed.** Each layer download now uses a `URLRequest` with a 10 s `timeoutInterval`, verifies the HTTP status, and rejects bodies over 12 MB (both `expectedContentLength` and actual `data.count`).

### M9. `.platform` refresh silently coalesces onto an unrelated active refresh
**File:** `OshiReader/LocalRefreshCoordinator.swift:203‑211`

If a `.foreground` (or `.platform("youtube")`) refresh is in flight and the user taps a different source chip, `refresh(.platform("tver"))` returns `await activeTask.value` — the other request's result. The tapped source is never fetched, and `FeedView.platformFilterButton` (`FeedView.swift:743‑749`) only triggers the ingest once, so the chip shows nothing until a full refresh.

**✅ Fixed.** `refresh` now: `if case .platform = request, activeRequest != request` → `await` the active task, then recurse. A single-source tap waits its turn and runs its own pass instead of coalescing onto unrelated work. (`.foreground` coalescing is unchanged — that path is already guarded by `isRefreshing` at the call site.)

**Fix:** queue `.platform` requests instead of coalescing them onto a non-matching active task.

---

## Low

### L1. `decodeJavaScriptEscapedString` corrupts non-BMP characters
**File:** `OshiReader/IngestionService.swift:2410‑2459`
`\uXXXX` is decoded one escape at a time. YouTube's string-form `ytInitialData` encodes emoji / CJK-ext as surrogate pairs (`😀`); `UnicodeScalar(0xD83D)` returns `nil`, the code falls to `else`, appends the literal `u`, and advances 2 — producing garbage. Scrape-fallback path only; cosmetic. Fix: combine a high surrogate (`0xD800…0xDBFF`) with a following `\uDCxx`.

### L2. `cappedFeedItems` can return more than `maxFeedItems` on import
**File:** `OshiReader/LocalDB.swift:973‑1025, 1778`
The final fallback pass counts `selectedKeys.count`, but the return filters `sortedItems` by key membership. `importBackupData` passes items not deduped by `feedItemKey`, so duplicate keys let both rows through and the result exceeds the cap.

### L3. Temp files leak on failed atomic replace
**File:** `OshiReader/IngestionService.swift:67‑70` (`FiveChIndexStore.commit`)
`replaceItemAt`/`moveItem` failures leave `.fivech-index-<uuid>.tmp` in the profile directory with no cleanup. Wrap in `do/catch` + `try? removeItem(at: temp)`.

### L4. `RecentTermUsageStore.markUsed` writes unconditionally
**File:** `OshiReader/RecentTermUsageStore.swift:32‑37`
(Correction to an earlier draft: this is **not** called per feed-row appearance — only on article open / keyword-filter change, `FeedView.swift:260, 630, 697`.) Residual: `timestamps[termID] = Date()` always changes the value, so re-opening the same article triggers a full `UserDefaults` dictionary write + `@Published` mutation. Add a "skip if updated within ~60 s" guard.

### L5. `styleInjectionJS()` interpolates CSS into a JS template literal
**File:** `OshiReader/Views/ReaderView.swift:1006‑1014`
`style.innerHTML = \`\(readerCSS)\``, and `readerCSS` embeds `fontFamilyCSS` (from `AppearanceManager`). A backtick or `${…}` breaks the literal or executes in the page's JS context. Fixed enum today; still, assign via a `<style>` element's `textContent` or strip `` ` `` / `\` / `$`.

### L6. `ShareViewController` only inspects the first attachment
**File:** `OshiReaderShare/ShareViewController.swift:44‑62`
`item.attachments?.first` misses the URL when a share carries multiple providers (text + `public.url`) and the URL isn't first; the plain-text branch forwards raw text as a URL with no validation (becomes a silent `.invalidURL` later). Iterate attachments and prefer `public.url`.

### L7. Import size guards use the wrong API and fail open
**File:** `OshiReader/Views/SettingsView.swift:626‑633, 662‑667, 707‑710`
`FileManager.attributesOfItem(atPath: url.path)` on a document-picker / iCloud URL isn't reliable; `(attributes[.size] as? NSNumber)?.int64Value ?? 0` yields size `0` on failure, passing every `<= maximumBytes` check, and `Data(contentsOf:)` then loads the whole file. Use `url.resourceValues(forKeys: [.fileSizeKey]).fileSize` and treat "unknown size" as a hard failure.

### L8. `PendingShareStore.enqueue` does an unsynchronized read-modify-write
**File:** `OshiReader/PendingShare.swift:24‑35`
`readAll()` + append + `write(atomic)` on the shared App Group file. Two rapid Share Extension invocations, or an `enqueue` mid-`drain`, can drop a share. `drain()` is race-hardened; `enqueue` isn't. Use `NSFileCoordinator` or an append-only format.

### L9. `KeychainHelper.save` delete-then-add is not atomic
**File:** `OshiReader/KeychainHelper.swift:97‑108`
`readRawData` → `SecItemDelete` → `SecItemAdd` for the same key can interleave across two concurrent saves to lose a write or resurrect the old value via the restore path. Rare (manual token entry).

### L10. `PlusStore.refreshStatus` failure keeps stale entitlement
**File:** `OshiReader/PlusStore.swift:179‑187, 225‑236`
On a backend error the `catch` only logs, so `hasActiveEntitlement` retains its last value. `expiresAt` is tracked but never used to downgrade locally. Add an `expiresAt < now` client-side check.

### L11. `NotificationService` (NSE) mutates instance state on two threads
**File:** `OshiReaderNotificationService/NotificationService.swift:14‑36` vs. the `DispatchQueue.main.async` completion blocks
`contentWorkFinished` / `receiptWorkFinished` / `activeRequestID` are set directly in `didReceive` and also from download/receipt completions hopping to main. Works if `didReceive` is always main-thread (it is, in practice) but nothing enforces it.

### L12. `fetchAllBackendFeed` has no absolute page cap
**File:** `OshiReader/BackendClient.swift:627‑672`
The loop guards (`seenCursors`, `nextCursor.matchID < cursor.matchID`, `nextCursor != cursor`) are solid, but a backend returning full pages with a slowly-decreasing `matchID` grows `seenCursors` unbounded. Add `while allItems.count < N`.

### L13. AvatarEditor drag state is shared across all layers
**File:** `OshiReader/Views/AvatarEditorView.swift:27‑32, 128‑165`
`isDragging`, `startX/startY`, `startCropX/startCropY` are view-level `@State` but every layer's `DragGesture.onChanged` reads/writes them. Two fingers dragging two stickers at once → the second gesture skips its own start capture and applies layer A's origin to layer B. Single-touch is fine. Use per-layer state (`[String: CGPoint]`) or `@GestureState`.

### L14. AvatarEditor sticker fetches have no race guard
**File:** `OshiReader/Views/AvatarEditorView.swift:521‑553`
`selectCategory` / `performSearch` set `searchingStickers = true`, `await`, then assign `stickers = result`. Tapping category A then B quickly → whichever response lands last wins, so A's stickers can show while `activeCategory == B`. `.onAppear` also fires `selectCategory(nil)` unconditionally, racing a category tap. Capture a generation token before the `await`.

### L15. AvatarEditor `bringForward` / `sendBack` seed `reduce` with `0`
**File:** `OshiReader/Views/AvatarEditorView.swift:447‑459`
`layers.reduce(0) { max/min }` is only correct because `addLayer` always assigns positive `zIndex`. A composition whose layers are all negative `zIndex` (reachable via repeated `sendBack` + save/reload, or backup import) makes `sendBack` compute `minZ = 0` and stop moving layers behind each other. Seed with `layers.map(\.zIndex).min()`.

### L16. AvatarEditor `onAppear` re-runs `loadComposition()`
**File:** `OshiReader/Views/AvatarEditorView.swift:373‑394`
Re-appearing (nav pop-back) reloads layers from `db.compositions[keyword]`, silently discarding unsaved edits, and refetches stickers.

### L17. Avatar / wallpaper are built from the thumbnail, not the full image
**File:** `OshiReader/Views/AvatarEditorView.swift:332`
`addLayer(url: sticker.thumb)` uses the ~400px upscaled Blogger thumb; `saveComposition`/`WallpaperRenderer` render from it. `sticker.url` is the full-res source.

### L18. Unknown platform IDs pass through `normalizeID` and are then silently dropped
**File:** `OshiReader/PlatformRegistry.swift:132‑148`; `OshiReader/LocalDB.swift:1124`
`normalizeID` returns unknown ids unchanged; `computeQueryFeed`'s `subscribedPlatforms.contains(platformKey)` then drops the item. An item merged with `platform: "web"` (the `NotificationNavigationManager` fallback, `NotificationNavigationManager.swift:135`) is invisible in the feed.

### L19. `OshiView` pages the `TabView` by array index
**File:** `OshiReader/Views/OshiView.swift:65‑76, 134‑136`
`ForEach(cachedSortedTerms.indices, id: \.self)` bound to `$activePage` — deleting/reordering a term leaves `activePage` on an index that now maps to a different oshi; `rebuildOshiCache` only clamps the out-of-range case.

### L20. `FeedView` "Delete" and "Hide Post" swipe actions are identical
**File:** `OshiReader/Views/FeedView.swift:781‑785, 809‑813, 851‑858, 872‑884`
`deleteFeedItem` and `confirmHidePost` both call `db.deleteFeedItem` + `PaidBackendFeedCoordinator.muteHiddenItem`. Two differently-labelled destructive buttons doing the same thing (one with a confirm dialog). UX smell.

### L21. `FeedView.isFilteredEmptyState` thrashes the single-slot `queryFeed` cache
**File:** `OshiReader/Views/FeedView.swift:614‑618`; `OshiReader/LocalDB.swift:1055‑1069`
It calls `queryFeed(keyword: nil, days: 30)` — the full dedup path (`keyword != nil` short-circuits earlier). `LocalDB.queryFeedCache` is one slot, so evaluating this while a keyword filter is active evicts the entry `cachedFilteredItems` just populated → the next `rebuildFeedCache` is a guaranteed cache miss. Only when the filtered list is empty.

### L22. `OPMLExporter.xmlEscape` doesn't strip XML-1.0-illegal control characters
**File:** `OshiReader/OPMLExporter.swift:105‑112`
Handles the 5 predefined entities but not `\u{00}`–`\u{1F}` (except tab/LF/CR); a keyword or custom-URL title with a control char produces an OPML file strict readers reject.

### L23. `didReceiveRemoteNotification` / background refresh report `.failed` when the coordinator is busy
**File:** `OshiReader/AppDelegate.swift:95‑104`; `OshiReader/BackgroundRefreshManager.swift:76‑103`
When a foreground refresh is running, `refreshIfIdle(.background)` returns `nil` → `.failed` → `completionHandler(.failed)` / `task.setTaskCompleted(success: false)`. Repeated spurious failures can make iOS throttle silent pushes and BG runs. Treat "coordinator busy" as `.noData`/success.

### L24. Assorted minor issues
- `PlatformRegistry` has no guard against two definitions sharing a `rawPlatformValues` entry (first match wins); the explicit `"news:mdpr"` / `"news:yahoo_ent"` switch cases (`PlatformRegistry.swift:137‑140`) duplicate what `rawPlatformValues` already handles.
- `SavedPage.toFeedItem()` flattens `media_type` to `"article"` (`SavedView.swift:3‑20`) — a saved YouTube video opens in reader mode. Fidelity, not a defect.
- `parseBroadcastLabel` uses `TimeZone(identifier: "UTC")` for Japanese broadcast dates (`IngestionService.swift:2233‑2235`) — off by up to a day at boundaries; should be `Asia/Tokyo`.
- `cleanDisplayText` (`Models.swift:86‑97`) decodes only 7 named HTML entities; numeric entities (`&#8230;`, `&#x2019;`) pass through, and `&amp;quot;` double-decodes.
- `ReaderView` coordinator marks `.loaded` on `didCommit` (`ReaderView.swift:1117‑1121`), before first paint — brief "loaded" flash over a blank page on slow redirects.
- `QuietHoursDigestState` is never explicitly cleared after the digest fires (`QuietHours.swift`); self-heals on window change.
- **"Playful" font is inconsistent between native UI and reader** — `AppearanceManager.font()` maps `.playful` to `.system(design: .rounded)` (`Theme.swift:339‑348`) while `AppFontChoice.cssFamily` returns Chalkboard / Comic Sans (`Theme.swift:44‑45`). The reader webview and the app UI render "Playful" differently. Also `font(size:relativeTo:)`'s `relativeTo` parameter is declared but never used (dead).
- **`ThemeManager` / `AppearanceManager` are plain `ObservableObject`, not `@MainActor`** (`Theme.swift:164, 286`) — same unenforced-main-thread pattern as M2; `private init()` reads `LocalProfileStore.shared.activeProfileID` off any thread on first `.shared` access.
- **Encrypted-backup import success doesn't clear `encryptedBackupConfirmation`** (`SettingsView.swift:1113‑1116`) — leaves stale `@State` that can pre-fill a mismatched confirmation field on the next export flow.
- `RefreshFeedIntent.perform()` (`AppShortcuts.swift:11‑18`) awaits a full foreground refresh (10–30 s); Siri/Shortcuts may kill `perform` before the dialog returns, though the refresh Task keeps running on the shared coordinator. Accepted trade-off, noted.

---

## Concurrency (unverified)

- **`RequestLimiter.acquire()` cancellation vs. direct hand-off** — `OshiReader/IngestionService.swift:3097‑3139`. `release()` resumes `waiters.first` with `true` while `active` stays put; the "resumed `true` while the task was cancelled" case relies on every call site re-checking `Task.isCancelled` after `acquire()` and calling `release()`. Most do; the 5ch index maintenance paths are worth an audit for a leaked slot.
- **`JSONDecoder` shared across the concurrent `loadAll()` fan-out** — `OshiReader/LocalDB.swift:252‑297`. Concurrent `decode` on one instance is undocumented as safe. Give each parallel closure its own decoder.
- **`LocalDB.queryFeedGeneration` bumped from `objectWillChange.sink`** — `OshiReader/LocalDB.swift:146‑149`. `objectWillChange` fires *before* the property write; a `queryFeed` call landing between the sink and the write caches a stale result under the new generation and won't be invalidated until the next mutation.
- **`PushSyncCoordinator.retryPendingOperations()` re-entrancy** — `OshiReader/PushSyncCoordinator.swift:167‑179`. Called from many `@MainActor` paths with `await` points mid-loop; two invocations can interleave and double-`deletePushTerm` the same id. (Related to H1.)

---

## Optimizations

> **Status:** O1–O6, O8–O10 applied plus the M6 residual and the
> `collectDictionaries` / `SearchView` micro-items (build green, 393/393 unit
> tests pass). Only O7 (acceptable as-is) is left — see the per-item notes.

### O1. `PlatformRegistry.normalizeID` is O(n) with two string allocations, in every hot path
**File:** `OshiReader/PlatformRegistry.swift:132‑148`
`trimmingCharacters` + `lowercased` (two allocations even for an already-canonical id), a `switch`, then `all.first(where: { $0.rawPlatformValues.contains(id) })` over 27 definitions. Called per feed item in `LocalDB.computeQueryFeed` (twice per item), per item in `mergeItemsBatchedResult` and `cappedFeedItems.map`, and on every feed/saved row render via `theme.metadata(for:)`. Order of 10k+ scans per query/merge.
**Fix:** build `static let aliasToCanonical: [String: String]` once and make `normalizeID` `trim → lowercase → dictionary lookup → hasPrefix("news:") fallback`.

**✅ Done.** `aliasToCanonical` (+ `byID`, `knownIDs`) built once; `normalizeID` is now the dict lookup; `definition(for:)` and `normalizeIDs` use `byID`/`knownIDs`; the redundant `"x"` / `"news:*"` switch cases were dropped (already covered by `rawPlatformValues`).

### O2. `PlatformRegistry` derived collections are `static var` (recomputed on every access)
**File:** `OshiReader/PlatformRegistry.swift:98‑120`
`strictKeywordPlatformIDs`, `mediaPlatformIDs`, `activityDateWindowPlatformIDs`, `dateCutoffExemptPlatformIDs`, `defaultSubscribedIDs`, `googleNewsSources` each rebuild a `Set`/array from `filter` + `map` over `all` every read. `dateCutoffExemptPlatformIDs` is rebuilt once per subscribed platform per feed-cap pass via `LocalDB.minRetainedFeedItems` (`LocalDB.swift:1027‑1031`). Make them `static let`.

**✅ Done.** All six are now `static let`.

### O3. `ISO8601DateFormatter()` allocated per call in hot paths
**Files:** `OshiReader/PaidBackendFeedCoordinator.swift:308, 320, 331`; `OshiReader/PlusStore.swift:231`; `OshiReader/BackendClient.swift:333` (`JSONDecoder()` per request). Hoist to `static let`.

**✅ Done** for the `ISO8601DateFormatter` sites in `PaidBackendFeedCoordinator` and `PlusStore` (both `@MainActor`, so a shared static is safe). **Skipped** the `BackendClient` `JSONDecoder`: it's hit concurrently from non-isolated code, and a shared `JSONDecoder` there trades a cheap allocation for the same "concurrent `decode` on one instance" question flagged under *Concurrency (unverified)*.

### O4. `fetchTVer` creates an anonymous platform token per keyword *and* per alias, per refresh
**File:** `OshiReader/IngestionService.swift:1985‑2008`
Up to 5 `create` POSTs per term per refresh. Cache `{uid, token}` in an actor with a TTL.

**✅ Done.** New `TVerTokenCache` actor holds `(uid, token)` with a 30-min TTL; `fetchTVer` reuses it and only calls the extracted `createTVerToken` on a miss. A search response that fails to parse invalidates the cache so a rejected stale token can't wedge every TVer keyword for the TTL. Concurrent cold-cache misses may still each mint one (unchanged for that first burst); every later refresh reuses.

### O5. `_ISO8601Cache` eviction is a full flush
**File:** `OshiReader/Models.swift:36‑55`
`removeAll(keepingCapacity:)` at 4096 entries — a burst of unique timestamps causes repeated cold starts of the parse cache that `feedItemSortPrecedes` / `computeQueryFeed` lean on. Use a small ring buffer or 2-generation map.

**✅ Done.** Two-generation cache: an overflow demotes `parsedDates` to `previousParsedDates` (still consulted, entries promoted back on hit) instead of discarding everything.

### O6. `RefreshDiagnostics` re-encodes + persists `healthRecords` per refresh unit
**File:** `OshiReader/RefreshDiagnostics.swift:161‑178, 285‑313`
`recordCompletedSourceStatuses` / `rebuildHealthSummaries` JSON-encode and write to `UserDefaults` on every call; in background mode `performBackground` calls it per unit. Batch to once per refresh.

**✅ Done.** Two steps: (1) `rebuildHealthSummaries(now:persist:)` no longer re-writes the identical bytes `recordCompletedSourceStatuses` just persisted. (2) `recordCompletedSourceStatuses` now takes `persist:` — the background loop in `LocalRefreshCoordinator.performBackground` records each unit with `persist: false` and calls the new `flushPendingHealthRecords()` once when the loop ends (covering normal completion and an early `break`). Because each per-unit call already rewrites this refresh's records via `replacingRecordsSince: startedAt`, the single end-of-loop encode + `UserDefaults` write is equivalent to the last per-unit write, minus the N−1 intermediate ones. Foreground `perform` still persists per completed pass (one write, unchanged).

### O7. `flushPendingWrites()` / `queue.sync {}` on the main actor during `switchProfile`
**File:** `OshiReader/LocalDB.swift:197‑213, 447‑452`
Blocks the main thread on a full `feed_items` re-encode (up to 600 items). Acceptable now; will get janky if the cap grows.

### O8. Dead code / redundant recompute
- **✅ Done:** `RSSDateFormatterPool` (`OshiReader/NetworkManager.swift:15‑34`) deleted — `date(from:format:)` was never called.
- **✅ Done:** `computeQueryFeed`'s strict-keyword filter now builds the lowercased haystack once per item (`LocalDB.keywordHaystack(for:)`) instead of once per candidate keyword/alias inside `matchesKeyword`.
- **✅ Done:** `SavedPageCard` computes `cleanDisplayText(page.title)` and `formattedDate` once per render, not 2–3×.
- **✅ Done:** `collectDictionaries` no longer re-walks a matched renderer subtree (a `videoRenderer` never nests another one), skipping a large chunk of the YouTube response tree.
- **✅ Done:** `SearchView` caches `selectedLinks.map(feedItem(for:))` in `@State`, rebuilt only on group / keyword / custom-URL change — `feedItem(for:)` stamps a fresh timestamp per call, so the inline map was handing `ReaderView` a never-equal `siblingItems` every render.

### O9. `WallpaperCanvas` renders a 1:1 300pt canvas shown `.aspectRatio(.fit)` full-screen
**File:** `OshiReader/WallpaperRenderer.swift:97‑120`
The wallpaper appears small / letterboxed versus the editor preview. Design mismatch, not a crash.

**✅ Done:** `WallpaperBackground` now displays the composition with
`.aspectRatio(contentMode: .fill)` + `.clipped()` instead of `.fit`, so the
square render covers the full screen (centre-cropping the horizontal edges)
rather than letterboxing. The 300×300 `WallpaperCanvas` itself is unchanged —
it still matches the editor.

### O10. `ThemeManager.metadata(for:)` — 27-case switch + `Color` allocations per card render, no caching
**File:** `OshiReader/Theme.swift:220‑283`
Called for every feed card, saved card, and platform chip on every render. It calls `PlatformRegistry.normalizeID` once, then again via `PlatformRegistry.definition(for:)` in the `default` branch, and allocates a fresh `PlatformMetadata` (several `Color`s) each time with no memoization. Pairs with O1/O2.
**Fix:** build a `static let [String: PlatformMetadata]` keyed by canonical id once, with the primary-color default as fallback.

**✅ Done** (variant): rather than transcribe the 27-case switch into a literal, `metadata(for:)` is now a cache wrapper (`[AppThemeMode: [String: PlatformMetadata]]`, `NSLock`-guarded) around an unchanged `uncachedMetadata(for:normalizedPlatform:)`. Keyed by `(mode, normalized id)` so a theme switch never serves stale colors; unknown raw platforms are computed fresh (not cached).

---

## Non-app code (tooling / legacy)

### T1. `mobile/` is an orphaned React Native fragment that cannot compile
`mobile/` still contains an Expo `package.json` (RN 0.81, React 19) and a single source file, `mobile/src/scraper/youtube.ts`, which imports `../localDb`, `../connectors/youtube`, and `./utils` — none of which exist in the tree (the rest of the RN app was removed in the on-device Swift migration). `tsc` on this directory fails. Delete `mobile/` or restore the missing modules; as-is it's dead weight and a misleading second "mobile app".

### T2. `scripts/paid_catalog_cost_gate.py` — minor robustness
- `nonnegative_decimal` calls `Decimal(raw)`, which raises `decimal.InvalidOperation` (an `ArithmeticError`, **not** a `ValueError`/`ArgumentTypeError`) on non-numeric input — argparse doesn't catch it, so `--compute abc` prints an uncaught traceback instead of a clean usage error. Wrap in `try/except (InvalidOperation, ValueError)` and re-raise `argparse.ArgumentTypeError`.
- With no cost arguments (all default to `0`), `minimum_gross_monthly_price` is `0.00` and **any** proposed price passes the gate (exit 0). A CI job that forgets the cost flags silently passes. Add a guard that `seven_day_cost > 0`.
- Flat 30% Apple commission (`APPLE_NET_SHARE = 0.70`) ignores the 15% Small Business / post-year-1 subscription rate — intentionally conservative for a price floor, not a bug; worth a comment.

## Coverage

**Reviewed in depth:** `IngestionService`, `LocalDB`, `LocalRefreshCoordinator`, `NetworkManager`, `Models`, `PaidBackendFeedCoordinator`, `PushSyncCoordinator`, `PushTermRegistry`, `BackgroundRefreshManager`, `NotificationManager`, `NotificationNavigationManager`, `ReaderView`, `EncryptedBackup`, `CloudSyncManager`, `QuietHours`, `RecentTermUsageStore`, `LocalProfileStore`, `RefreshDiagnostics`, `BackendClient`, `PlusStore`, `AppDelegate`, `KeychainHelper`, `PendingShare`, `WidgetSnapshot`, `ShareViewController`, `NotificationService`, `NotificationViewController` (content extension), `AvatarEditorView`, `PlatformRegistry`, `WallpaperRenderer`, `OPMLExporter`, `ContentView`, `SearchView`, `OshiView`, `SavedView`, `FeedView`, `OshiReaderApp`, `Theme` (`ThemeManager` / `AppearanceManager`), `AppShortcuts`, `AppIntentNavigation`, `OshiReaderWidget` + `SelectWatchTermIntent`; `SettingsView` I/O + encrypted-backup paths; `scripts/paid_catalog_cost_gate.py`.

**Skimmed only:** `SettingsView` presentational UI body, `I18n` (translation tables), `ExtensionStrings`, `AppGroup`, `ShareConfirmationView`. `mobile/` covered as legacy (see T1).

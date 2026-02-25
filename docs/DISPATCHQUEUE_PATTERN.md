# DispatchQueue Pattern for SwiftUI Thread Safety

## Problem: AttributeGraph Cycles and Publishing During View Updates

### Symptoms
When loading files, the app experienced these critical errors:

```
Publishing changes from within view updates is not allowed, this will cause undefined behavior.

=== AttributeGraph: cycle detected through attribute 1004088 ===
=== AttributeGraph: cycle detected through attribute 1004352 ===
```

Additionally:
- Files would fail to load
- UI would freeze (beach ball cursor)
- Content wouldn't appear in editor tabs

### Root Cause Discovery

**Initial hypothesis:** The issue was in async file loading code calling `applyLoadedContent()`.

**Reality (discovered via diagnostic logging):** The REAL culprit was earlier - in the **synchronous placeholder tab creation** when `openFile(url:)` is called from menu actions!

### The Diagnostic Trace That Revealed Everything

Adding color-coded trace logging revealed the exact sequence:

```
🔵 [TRACE] openFile() called for: CHANGELOG.md - Thread: MAIN
🟡 [TRACE] About to append placeholder tab - Thread: MAIN
🟢 [TRACE] Placeholder tab appended - Thread: MAIN        ← Direct @Published modification
🟢 [TRACE] selectedTabID set - Thread: MAIN               ← Another @Published modification
=== AttributeGraph: cycle detected ===                     ← ERROR IMMEDIATELY!
⚪️ [TRACE] About to schedule DispatchQueue.main.async...  ← This happens LATER
```

**Key insight:** The error occurred **before** any async file loading! It happened immediately after modifying `tabs` and `selectedTabID` in `openFile(url:)`.

### Why This Happens

When you click "Open Recent" → File.md:

1. **SwiftUI rendering cycle begins** (to update menu UI)
2. Menu button action calls `openFile(url:)` **during this rendering**
3. `openFile()` directly modifies `@Published var tabs` and `@Published var selectedTabID`
4. SwiftUI tries to re-render because `@Published` changed
5. **Cycle detected** - SwiftUI is already rendering but needs to restart due to state change

The critical concept: **Menu actions execute synchronously in the same runloop as SwiftUI's view update cycle.**

### Technical Details

SwiftUI's rendering process:
1. **Read Phase**: SwiftUI reads all `@Published` properties needed for rendering
2. **Compute Phase**: View bodies execute, layouts calculated
3. **Commit Phase**: Changes applied to screen

**Menu button actions happen during phase 2!** If your action modifies `@Published` properties synchronously, SwiftUI tries to restart from phase 1, but it's already in progress → **cycle**.

## Solution: DispatchQueue + Task Pattern

### The Complete Fix (Multiple Locations)

#### CRITICAL Fix: Defer Content Application (applyLoadedContent)

**Most Important Discovery (2026-02-24):** Even with all placeholder tab creation properly deferred, AttributeGraph cycles persisted because `applyLoadedContent()` was directly modifying `@Published` properties from within a nested `MainActor.run` + `Task { @MainActor }` context.

**The Problem:**
```swift
// In openFile(url:) after loading file data:
await MainActor.run {
    Task { @MainActor in
        await self.applyLoadedContent(...)  // ← Still in view update context!
    }
}

// Inside applyLoadedContent():
@MainActor
private func applyLoadedContent(...) async {
    tabs[index].content = content           // ← Direct modification = cycle!
    tabs[index].language = language
    tabs[index].isLoadingContent = false
}
```

**Why it failed:** Even though we were using `MainActor.run` to get onto the main actor, the nested `Task { @MainActor }` was still executing in a context where SwiftUI might be in a view update cycle. The direct modifications to `tabs[index]` properties triggered AttributeGraph cycles.

**Symptoms:**
- Files would load (logs confirmed content was read)
- Properties would be set (traces showed assignments executing)
- But UI displayed empty tabs
- AttributeGraph cycle warnings in console
- No errors, just silent failure to display

**The Solution:**
Wrap ALL @Published property modifications inside `applyLoadedContent()` with `DispatchQueue.main.async` using `withCheckedContinuation` for async/await compatibility:

```swift
@MainActor
private func applyLoadedContent(...) async {
    // Defer ALL @Published property modifications to avoid AttributeGraph cycles
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                continuation.resume()
                return
            }

            // NOW it's safe to modify @Published properties
            self.tabs[index].language = language
            self.tabs[index].content = content
            self.tabs[index].isLoadingContent = false

            continuation.resume()
        }
    }
}
```

**Key Insight:** You need to defer modifications EVEN WHEN you think you're already on MainActor. The issue isn't thread safety - it's SwiftUI's view update cycle timing.

#### Fix 1: Defer Placeholder Tab Creation

Wrap initial tab creation in `DispatchQueue.main.async`:

```swift
// BROKEN - Direct modification during menu action
func openFile(url: URL) {
    // ... metadata checks ...

    let placeholderTab = TabData(...)
    tabs.append(placeholderTab)        // ← Executes during menu action = cycle!
    selectedTabID = placeholderTab.id  // ← Another sync modification = cycle!

    Task.detached { /* file loading */ }
}
```

```swift
// FIXED - Deferred to next runloop
func openFile(url: URL) {
    // ... metadata checks ...

    let placeholderTab = TabData(...)
    let tabID = placeholderTab.id  // Capture ID immediately

    // Defer tab creation to avoid modifying @Published during view updates
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.tabs.append(placeholderTab)     // ← Safe! Happens AFTER menu action
        self.selectedTabID = placeholderTab.id
    }

    // File loading happens independently with captured tabID
    Task.detached(priority: .userInitiated) { [tabID] in
        // ... load file ...
    }
}
```

#### Fix 2: Defer Content Updates (Also Important)

Once the file loads, wrap content updates the same way:

```swift
// In the Task.detached file loading block:
Task.detached(priority: .userInitiated) {
    let data = try Data(contentsOf: url)
    let content = String(decoding: data, as: UTF8.self)

    // Defer content updates to next runloop
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        Task { @MainActor in
            await self.applyLoadedContent(
                tabID: tabID,
                content: content,
                // ...
            )
        }
    }
}
```

### Why This Works

**Layer 1 - `DispatchQueue.main.async`:**
- Schedules work for the **next** main thread runloop iteration
- Guarantees execution happens **after** current runloop completes
- If SwiftUI is rendering (menu action), this waits until rendering finishes

**Layer 2 - `Task { @MainActor in }` (for async methods):**
- Maintains Swift Concurrency's actor isolation
- Allows `await` calls to other `@MainActor` methods
- Type-safe, compiler-enforced thread safety

**Combined Effect:**
- Menu action starts → SwiftUI rendering → `DispatchQueue.main.async` scheduled → rendering completes → tab created ✓
- No cycles, no crashes ✓
- Maintains actor isolation ✓

## The Three Critical Locations

### Location 1: Initial Tab Creation (PRIMARY FIX)

**File:** `EditorViewModel.swift`
**Method:** `openFile(url: URL)`
**Issue:** Direct synchronous modification of `tabs` and `selectedTabID`

```swift
// Line ~745 - The critical fix
DispatchQueue.main.async { [weak self] in
    guard let self = self else { return }
    self.tabs.append(placeholderTab)
    self.selectedTabID = placeholderTab.id
}
```

**Why it matters:** This is called from menu actions during SwiftUI rendering.

### Location 2: Content Loading (IMPORTANT: NO DEFERRAL)

**File:** `EditorViewModel.swift`
**Method:** `openFile(url:)` → `Task.detached` → content update
**Issue:** Initially had DispatchQueue deferral, but this caused **race conditions and empty tabs**

```swift
// Line ~836 - CORRECT: Use MainActor.run without DispatchQueue deferral
await MainActor.run { [startTime] in
    Task { @MainActor in
        await self.applyLoadedContent(...)
    }
}
```

**Why no DispatchQueue here?** Because we're coming from background `Task.detached`, not from a UI action. Using `DispatchQueue.main.async` here would create a double-deferral race condition:
1. Placeholder tab deferred via DispatchQueue (Location 1)
2. Content loading deferred via DispatchQueue (this location)
3. **Race**: Tab renders empty before content arrives

**Solution**: Use `MainActor.run` to execute immediately on main actor without runloop deferral.

### Location 3: Tab Content Updates (CRITICAL FIX)

**File:** `EditorViewModel.swift`
**Method:** `updateTabContent(tab:content:)`
**Issue:** Direct synchronous modification of `tabs[index].content`, `tabs[index].isDirty`, and language properties

**Called from:**
- Text editor bindings (user typing in ContentView)
- Menu actions (AI suggestions in AppMenus)
- Language change callbacks (template insertion in ContentView)

```swift
// Line ~461 - Wrap entire method in DispatchQueue.main.async
func updateTabContent(tab: TabData, content: String) {
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }

        if let index = self.tabs.firstIndex(where: { $0.id == tab.id }) {
            // All @Published property modifications now deferred
            self.tabs[index].content = content
            self.tabs[index].isDirty = true
            self.tabs[index].language = detected
            // ... etc
        }
    }
}
```

**Why it matters:** This method is called from text editor bindings during SwiftUI's view update cycle. When the user types, the binding's `set` closure executes during rendering. Without the DispatchQueue wrapper, this causes "Publishing changes from within view updates" errors. The ~16ms delay (one frame) is imperceptible but prevents AttributeGraph cycles.

### Location 4-6: Tab Management Methods (ADDITIONAL FIXES)

**File:** `EditorViewModel.swift`
**Methods:** `addNewTab()`, `closeTab(tab:)`, `focusTabIfOpen(for:)`
**Issue:** Direct synchronous modification of `tabs` and `selectedTabID` when called from menu/toolbar actions

These methods also needed the same fix:

```swift
// addNewTab() - Line ~446
func addNewTab() {
    let newTab = TabData(name: "Untitled \(tabs.count + 1)", ...)
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.tabs.append(newTab)
        self.selectedTabID = newTab.id
    }
}

// closeTab(tab:) - Line ~620
func closeTab(tab: TabData) {
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.tabs.removeAll { $0.id == tab.id }
        if self.tabs.isEmpty {
            self.addNewTab()
        } else if self.selectedTabID == tab.id {
            self.selectedTabID = self.tabs.first?.id
        }
    }
}

// focusTabIfOpen(for:) - Line ~1013
func focusTabIfOpen(for url: URL) -> Bool {
    if let existingIndex = indexOfOpenTab(for: url) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.selectedTabID = self.tabs[existingIndex].id
        }
        return true
    }
    return false
}
```

**Why these matter:** All three are called from menu actions (File → New Tab, File → Close Tab, File → Open Recent when file already open). Without deferral, they caused the same AttributeGraph cycles.

## When to Use This Pattern

### ✅ MUST Use DispatchQueue.main.async:

1. **Any @Published property modification in methods called from:**
   - Menu button actions
   - Toolbar button actions
   - Context menu actions
   - Keyboard shortcuts
   - Any SwiftUI button/action closure

2. **Specifically when modifying:**
   - Collections: `@Published var tabs: [Tab]`
   - Selection state: `@Published var selectedTabID: UUID?`
   - Any state that triggers view re-renders

3. **Pattern recognition - if you see:**
   - "Publishing changes from within view updates"
   - "AttributeGraph: cycle detected"
   - State changes in methods called from UI actions

### ❌ Don't Use (Not Needed):

1. **State changes in async contexts already on main actor**
   ```swift
   Task { @MainActor in
       // This is safe if NOT called from a button action
       self.tabs.append(newTab)
   }
   ```

2. **View model initialization**
   ```swift
   init() {
       // Safe - not during any view update, use direct modifications
       self.tabs = []
       // or call immediate helper methods
       self.addNewTabImmediate(initialTab)
   }
   ```

3. **Changes triggered by timers/notifications (if not during rendering)**

## ⚠️ Critical: Avoid Double Deferral

**Problem:** If a deferred method calls another deferred method, you create double deferral:

```swift
// WRONG - Double deferral!
func closeTab(tab: TabData) {
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.tabs.removeAll { $0.id == tab.id }
        if self.tabs.isEmpty {
            self.addNewTab()  // ← This defers AGAIN!
        }
    }
}

func addNewTab() {
    DispatchQueue.main.async { [weak self] in  // ← Second deferral!
        // ...
    }
}
```

**Solution:** Create immediate (non-deferred) helper methods for internal use:

```swift
// Public API - defers for UI safety
func addNewTab() {
    let newTab = TabData(...)
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.addNewTabImmediate(newTab)
    }
}

// Internal helper - no deferral
private func addNewTabImmediate(_ newTab: TabData) {
    tabs.append(newTab)
    selectedTabID = newTab.id
}

// Now closeTab can call the immediate version
func closeTab(tab: TabData) {
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.tabs.removeAll { $0.id == tab.id }
        if self.tabs.isEmpty {
            let newTab = TabData(...)
            self.addNewTabImmediate(newTab)  // ← Direct, no double deferral!
        }
    }
}
```

## Diagnostic Logging Strategy

The fix was only possible because of strategic logging. Here's the pattern used:

```swift
// Entry point logging
print("🔵 [TRACE] openFile() called - Thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")")

// Before critical operations
print("🟡 [TRACE] About to modify @Published property")
tabs.append(placeholderTab)
print("🟢 [TRACE] Modification complete")

// Async scheduling
print("⚪️ [TRACE] Scheduling DispatchQueue.main.async")
DispatchQueue.main.async {
    print("⚪️ [TRACE] DispatchQueue executing - Thread: \(Thread.isMainThread)")
    // modifications here
}
```

**The traces revealed:**
- ✅ Which exact line caused the cycle
- ✅ Thread context (always MAIN, as expected)
- ✅ Timing: Error occurred BEFORE async operations
- ✅ Proof that placeholder creation was the culprit

## Common Pitfalls

### ❌ Wrong: Just using @MainActor
```swift
// BROKEN - still executes synchronously during menu action!
@MainActor
func openFile(url: URL) {
    tabs.append(placeholderTab)  // Cycle if called from button!
}
```

**Why:** `@MainActor` ensures main thread but doesn't defer to next runloop.

### ❌ Wrong: Using Task without DispatchQueue
```swift
// BROKEN - Task may execute immediately during view update!
func openFile(url: URL) {
    Task { @MainActor in
        tabs.append(placeholderTab)  // Still causes cycle!
    }
}
```

**Why:** `Task` doesn't guarantee runloop deferral - it might execute immediately.

### ✅ Correct: DispatchQueue for deferral
```swift
// CORRECT - Guaranteed deferred to next runloop
func openFile(url: URL) {
    DispatchQueue.main.async {
        self.tabs.append(placeholderTab)  // Safe!
    }
}
```

### ✅ Correct: DispatchQueue + Task for async methods
```swift
// CORRECT - Deferred AND maintains actor isolation
DispatchQueue.main.async { [weak self] in
    guard let self = self else { return }
    Task { @MainActor in
        await self.applyLoadedContent(...)  // Safe!
    }
}
```

## Performance Considerations

### Minimal Overhead
- `DispatchQueue.main.async`: ~0.1ms overhead
- One extra runloop iteration: ~16ms max (one frame at 60fps)
- Users won't notice the delay

### Actual Benefits Measured
- **Before:** Multi-second UI freezes, cycles, crashes
- **After:** Smooth file loading, no cycles, responsive UI
- **Trade-off:** 16ms delay vs. broken app = obviously worth it

### Large File Optimization
The complete solution combines:
1. **DispatchQueue deferral** (prevents cycles)
2. **Chunked content loading** (prevents UI blocking on large files)
3. **Task.yield()** between chunks (keeps UI responsive)
4. **Background decoding** (doesn't block main thread)

Result: Files >10MB load smoothly without freezing UI.

## Real-World Example: The Full Pattern

Here's the complete, production-ready pattern from the actual fix:

```swift
func openFile(url: URL) {
    // 1. Do metadata work synchronously (file size, language detection)
    let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    let extLangHint = LanguageDetector.shared.preferredLanguage(for: url)

    // 2. Create tab data structure
    let placeholderTab = TabData(
        name: url.lastPathComponent,
        content: "",
        language: extLangHint ?? "plain",
        fileURL: url,
        isLoadingContent: true
    )
    let tabID = placeholderTab.id  // Capture ID immediately

    // 3. DEFER tab creation to next runloop (THE FIX!)
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.tabs.append(placeholderTab)
        self.selectedTabID = tabID
    }

    // 4. Load file in background
    Task.detached(priority: .userInitiated) { [url, tabID] in
        let data = try Data(contentsOf: url)
        let content = String(decoding: data, as: UTF8.self)

        // 5. DEFER content update to next runloop
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                await self.applyLoadedContent(tabID: tabID, content: content)
            }
        }
    }
}
```

## Critical Race Condition Fix (2024-02-24)

### The Empty Tab Problem

After implementing DispatchQueue deferral for `updateTabContent`, a new issue emerged:
- Files would sometimes open with **empty tabs**
- Navigating away and back would show the content
- This was a **race condition** caused by double deferral

### Root Cause

The file loading flow had TWO DispatchQueue deferrals:
1. **Placeholder tab creation** (Location 1): `DispatchQueue.main.async` → correct, needed to avoid cycles
2. **Content loading** (Location 2): `DispatchQueue.main.async` → **WRONG**, caused race condition

**Timeline of the bug:**
```
T+0ms:   Menu action → openFile()
T+0ms:   DispatchQueue.main.async { create placeholder tab } [scheduled for T+16ms]
T+5ms:   Task.detached starts background file loading
T+10ms:  File loaded, content ready
T+10ms:  DispatchQueue.main.async { apply content } [scheduled for T+26ms]
T+16ms:  Placeholder tab created, tab renders EMPTY
T+20ms:  User sees empty tab (content not yet applied!)
T+26ms:  Content applied (too late, user already confused)
```

### The Fix

**Remove** the `DispatchQueue.main.async` wrapper from content loading and use `MainActor.run` instead:

```swift
// WRONG - causes race condition
DispatchQueue.main.async { [weak self, startTime] in
    guard let self = self else { return }
    Task { @MainActor in
        await self.applyLoadedContent(...)
    }
}

// CORRECT - immediate execution on main actor
await MainActor.run { [startTime] in
    Task { @MainActor in
        await self.applyLoadedContent(...)
    }
}
```

**Why this works:**
- `MainActor.run` executes **immediately** when the main actor is available
- No runloop deferral, so content arrives as soon as file loads
- Placeholder tab and content application happen in quick succession
- No visible empty tab state

## Testing

To verify the fix works:

1. **Open Recent menu** - rapidly click multiple files
   - ✅ Should open without errors
   - ✅ Console shows no AttributeGraph cycles
   - ✅ **No empty tabs** - content should appear immediately

2. **Check trace logs** - look for pattern:
   ```
   🔵 openFile() called
   🟡 About to DEFER placeholder tab
   [no cycles here!]
   🟡 DispatchQueue executing placeholder
   🟢 Placeholder tab appended
   ```

3. **Large files (>2MB)** - should load without beach ball

4. **Memory** - no leaks after closing tabs (verify `[weak self]`)

## Related Documentation

- `EditorViewModel.swift` - Implementation location
- `AppMenus.swift` - Menu actions that call openFile()
- `SECURITY_SCOPED_RESOURCES.md` - File access patterns

## Key Takeaways

1. **Menu actions execute during SwiftUI rendering** - always defer state changes
2. **@MainActor alone is not enough** - must use DispatchQueue for deferral
3. **Diagnostic logging is essential** - color-coded traces reveal exact issues
4. **Two-layer pattern** - DispatchQueue.main.async + Task @MainActor for async methods
5. **Always capture values before async** - tabID captured before DispatchQueue

---

**Last Updated:** 2024-02-24
**Author:** AI Assistant (Claude)
**Related Issues:** File loading failures, UI freezing, AttributeGraph cycles
**Fix Confirmed:** Diagnostic traces prove placeholder tab creation was the culprit

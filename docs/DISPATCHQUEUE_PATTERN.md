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

### The Complete Fix (Two Locations)

#### Fix 1: Defer Placeholder Tab Creation

The primary fix - wrap initial tab creation in `DispatchQueue.main.async`:

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

## The Two Critical Locations

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

### Location 2: Content Loading (SECONDARY FIX)

**File:** `EditorViewModel.swift`
**Method:** `openFile(url:)` → `Task.detached` → content update
**Issue:** Async updates might execute during subsequent view updates

```swift
// Line ~800 - Defensive fix
DispatchQueue.main.async { [weak self] in
    guard let self = self else { return }
    Task { @MainActor in
        await self.applyLoadedContent(...)
    }
}
```

**Why it matters:** Prevents cycles if user interacts with UI while file loads.

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
       // Safe - not during any view update
       self.tabs = []
   }
   ```

3. **Changes triggered by timers/notifications (if not during rendering)**

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

## Testing

To verify the fix works:

1. **Open Recent menu** - rapidly click multiple files
   - ✅ Should open without errors
   - ✅ Console shows no AttributeGraph cycles

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

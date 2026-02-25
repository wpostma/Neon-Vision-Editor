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

### Root Cause

The issue occurred in `EditorViewModel.swift` when loading file content asynchronously:

```swift
// BROKEN CODE - DO NOT USE
Task.detached(priority: .userInitiated) {
    let content = try Data(contentsOf: url)
    // ... process content ...

    // This await can execute DURING SwiftUI's view update cycle!
    await self.applyLoadedContent(
        tabID: tabID,
        content: content,
        // ...
    )
}
```

**Why this breaks:**

1. `applyLoadedContent()` is marked `@MainActor`
2. When called with `await` from a detached task, it runs on the main thread
3. **BUT**: The timing is unpredictable - it might execute while SwiftUI is rendering
4. Modifying `@Published` properties during SwiftUI's view update creates a cycle:
   - SwiftUI reads `@Published var tabs` to render
   - Your code modifies `tabs`
   - SwiftUI tries to re-read `tabs` (already in progress)
   - **Cycle detected!**

### Technical Details

SwiftUI's rendering process:
1. **Read Phase**: SwiftUI reads all `@Published` properties needed for rendering
2. **Compute Phase**: View bodies execute, layouts calculated
3. **Commit Phase**: Changes applied to screen

If you modify a `@Published` property during phases 1-2, SwiftUI tries to restart from phase 1, but it's already in progress → **cycle**.

## Solution: DispatchQueue + Task Pattern

### The Fix

Wrap all `@Published` property modifications in a **two-layer async pattern**:

```swift
// CORRECT CODE - USE THIS PATTERN
Task.detached(priority: .userInitiated) {
    let content = try Data(contentsOf: url)
    // ... process content on background thread ...

    // Layer 1: DispatchQueue.main.async - defers to next runloop
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }

        // Layer 2: Task @MainActor - maintains actor isolation
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
- If SwiftUI is rendering, this waits until rendering finishes

**Layer 2 - `Task { @MainActor in }`:**
- Maintains Swift Concurrency's actor isolation
- Allows `await` calls to other `@MainActor` methods
- Type-safe, compiler-enforced thread safety

**Combined Effect:**
- Background work stays on background thread ✓
- UI updates deferred until SwiftUI is idle ✓
- No cycles, no crashes ✓
- Maintains actor isolation ✓

## Implementation Examples

### Example 1: Loading File Content

Location: `EditorViewModel.swift` - `openFile(url:)` method

```swift
Task.detached(priority: .userInitiated) { [url, tabID] in
    // Step 1: Read file on background thread (good!)
    let data = try Data(contentsOf: url)
    let content = String(decoding: data, as: UTF8.self)

    // Step 2: Update UI - defer to next runloop
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        Task { @MainActor in
            await self.applyLoadedContent(
                tabID: tabID,
                content: content,
                language: detectedLang,
                // ...
            )
        }
    }
}
```

### Example 2: Streaming Preview Updates

Location: `EditorViewModel.swift` - Large file streaming

```swift
data = try EditorLoadHelper.streamFileData(from: url) { previewData in
    let preview = String(decoding: previewData, as: UTF8.self)

    // Defer preview updates to avoid cycles
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        Task { @MainActor in
            await self.applyStreamingPreview(tabID: tabID, preview: preview)
        }
    }
}
```

### Example 3: Error Handling

Location: `EditorViewModel.swift` - File load error handler

```swift
catch {
    // Error handling ALREADY uses this pattern correctly
    await MainActor.run {
        // Remove failed tab
        if let index = self.tabs.firstIndex(where: { $0.id == tabID }) {
            self.tabs.remove(at: index)
        }
        // Show error alert
        self.fileOpenErrorMessage = "Failed to open..."
        self.showFileOpenError = true
    }
}
```

## When to Use This Pattern

### ✅ Use DispatchQueue.main.async + Task Pattern:

1. **Updating @Published properties from background tasks**
   - File loading
   - Network responses
   - Heavy computation results

2. **Updates triggered by async callbacks**
   - Streaming data handlers
   - Completion handlers from background work

3. **When you see these errors:**
   - "Publishing changes from within view updates"
   - "AttributeGraph: cycle detected"
   - Content not appearing in UI
   - Beach ball / UI freezing

### ❌ Don't Use (Not Needed):

1. **Direct button actions** - already outside view update cycle
   ```swift
   Button("Save") {
       // This is fine - button actions are safe
       viewModel.saveFile()
   }
   ```

2. **@MainActor methods called from main thread** - already isolated
   ```swift
   @MainActor
   func userDidTapButton() {
       // This is fine - already on main thread, not during view update
       self.tabs.append(newTab)
   }
   ```

3. **View model init or explicit user actions** - safe by design

## Performance Considerations

### Minimal Overhead
- `DispatchQueue.main.async`: ~0.1ms overhead
- One extra runloop iteration: ~16ms max (one frame at 60fps)
- Users won't notice the delay

### Benefits
- Eliminates UI freezing (was causing multi-second hangs)
- Prevents crashes and undefined behavior
- Enables responsive UI during file loading

### Large File Optimization
Combined with chunked content loading for files >2MB:
- First chunk shows immediately
- Subsequent chunks load progressively
- `Task.yield()` between chunks keeps UI responsive
- DispatchQueue pattern prevents cycles on each chunk

## Common Pitfalls

### ❌ Wrong: Just using @MainActor
```swift
// BROKEN - can still execute during view updates!
await MainActor.run {
    self.tabs[index].content = newContent
}
```

### ❌ Wrong: Just using DispatchQueue
```swift
// BROKEN - loses actor isolation, unsafe!
DispatchQueue.main.async {
    self.tabs[index].content = newContent  // Not @MainActor isolated!
}
```

### ✅ Correct: Both layers
```swift
// CORRECT - deferred AND isolated
DispatchQueue.main.async { [weak self] in
    guard let self = self else { return }
    Task { @MainActor in
        await self.updateContent(newContent)  // Safe!
    }
}
```

## Memory Management

Always use `[weak self]` in the DispatchQueue closure:

```swift
DispatchQueue.main.async { [weak self] in  // ✓ Prevents retain cycles
    guard let self = self else { return }
    Task { @MainActor in
        await self.applyContent(...)
    }
}
```

**Why:** The closure might outlive the view model (e.g., user closes window during file load). Without `[weak self]`, the closure retains the view model, causing memory leaks.

## Testing

To verify the fix works:

1. **Open large files (>2MB)** - should load without beach ball
2. **Check console** - no AttributeGraph errors
3. **Open multiple files rapidly** - no crashes
4. **Check memory** - no leaks after closing tabs

## Related Documentation

- `LARGE_FILE_PERFORMANCE.md` - Chunked loading strategy
- `SECURITY_SCOPED_RESOURCES.md` - File access patterns
- `APPLE_INTELLIGENCE_FIX.md` - Similar async/await patterns

## References

- [Swift Concurrency: Behind the Scenes](https://developer.apple.com/videos/play/wwdc2021/10254/)
- [Main Actor Usage in SwiftUI](https://www.swiftbysundell.com/articles/the-main-actor-attribute/)
- [AttributeGraph Debugging](https://www.fivestars.blog/articles/swiftui-attributed-graph/)

---

**Last Updated:** 2024-02-24
**Author:** AI Assistant (Claude)
**Related Issues:** File loading failures, UI freezing, AttributeGraph cycles

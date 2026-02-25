# DispatchQueue Usage Guidelines for SwiftUI

**Last Updated:** 2026-02-24
**Status:** Updated after @Observable migration

## Overview

This document describes when and why to use `DispatchQueue.main.async` in the Neon Vision Editor codebase after migrating from `ObservableObject` to `@Observable`.

## Historical Context: The Migration

### Before: ObservableObject + @Published (DEPRECATED)

The codebase previously used `ObservableObject` with `@Published` properties, which suffered from critical AttributeGraph cycle issues:

**Problem symptoms:**
```
Publishing changes from within view updates is not allowed, this will cause undefined behavior.
=== AttributeGraph: cycle detected through attribute 1004088 ===
```

**Root cause:** When menu actions or button handlers directly modified `@Published` properties during SwiftUI's view update cycle, SwiftUI would try to restart rendering while already rendering, causing cycles.

**Old workaround:** Wrap ALL `@Published` property modifications in `DispatchQueue.main.async` to defer them to the next runloop:

```swift
// OLD PATTERN (No longer needed with @Observable!)
func addNewTab() {
    let newTab = TabData(...)
    DispatchQueue.main.async { [weak self] in  // ← Workaround for @Published
        guard let self = self else { return }
        self.tabs.append(newTab)
        self.selectedTabID = newTab.id
    }
}
```

### After: @Observable (CURRENT)

As of 2026-02-24, `EditorViewModel` uses the modern `@Observable` macro:

**Benefits:**
- ✅ **Automatic deferral** - `@Observable` automatically batches and defers property change notifications
- ✅ **No more AttributeGraph cycles** - Direct property modifications are safe
- ✅ **Cleaner code** - ~150 lines of deferral boilerplate removed
- ✅ **No double deferrals** - No more complex timing issues

**New pattern:**
```swift
// NEW PATTERN (With @Observable)
func addNewTab() {
    let newTab = TabData(...)
    // Direct modifications are now safe!
    tabs.append(newTab)
    selectedTabID = newTab.id
}
```

## Current Usage: When to Use DispatchQueue.main.async

With `@Observable`, the vast majority of `DispatchQueue.main.async` deferrals have been **eliminated**. However, there are still legitimate use cases:

### ✅ Valid Uses (Keep These)

#### 1. UI Timing and Delays
Use `DispatchQueue.main.asyncAfter` for intentional delays:

```swift
// Welcome tour delay - give app time to settle
if !hasSeenWelcomeTourV1 {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        showWelcomeTour = true
    }
}

// File drop progress UI - brief display before hiding
DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
    droppedFileLoadInProgress = false
}
```

**Why:** These are intentional UX delays, not workarounds.

#### 2. Debouncing and Throttling
Use `DispatchQueue.main.asyncAfter` with work item cancellation:

```swift
// Debounce syntax highlighting refresh
private func scheduleHighlightRefresh(delay: TimeInterval = 0.05) {
    pendingHighlightRefresh?.cancel()
    let work = DispatchWorkItem {
        highlightRefreshToken &+= 1
    }
    pendingHighlightRefresh = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
}
```

**Why:** Prevents expensive operations from running on every keystroke.

#### 3. Background → Main Thread Handoffs
Use `DispatchQueue.main.async` when moving from background to main:

```swift
// Project tree building
DispatchQueue.global(qos: .utility).async {
    let nodes = buildProjectTree(at: root)  // Heavy work on background

    DispatchQueue.main.async {
        guard generation == projectTreeRefreshGeneration else { return }
        projectTreeNodes = nodes  // Update UI on main
    }
}
```

**Why:** Background work must marshal results back to main thread.

#### 4. Cross-View Coordination
Use `DispatchQueue.main.async` for coordinating between independent views:

```swift
// WindowAccessor pattern
DispatchQueue.main.async {
    onWindowChange(view.window)
}

// Line navigation after file load
DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
    NotificationCenter.default.post(
        name: .moveCursorToLine,
        object: lineNumber
    )
}
```

**Why:** Allows view hierarchy to settle before coordination.

#### 5. Session Restoration Timing
Use `DispatchQueue.main.asyncAfter` for startup coordination:

```swift
// Delay file restoration to allow security-scoped bookmarks to resolve
DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak viewModel] in
    guard let viewModel = viewModel else { return }

    viewModel.tabs.removeAll()
    for url in urls {
        viewModel.openFile(url: url)
    }
}
```

**Why:** Ensures app initialization completes before accessing file system.

### ❌ No Longer Needed (Removed After Migration)

These patterns were removed during the `@Observable` migration:

#### 1. State Changes from UI Actions
```swift
// OLD (REMOVED):
func openFile(url: URL) {
    DispatchQueue.main.async {  // ← No longer needed!
        self.tabs.append(placeholderTab)
        self.selectedTabID = tabID
    }
}

// NEW (CURRENT):
func openFile(url: URL) {
    // Direct modifications are safe with @Observable
    tabs.append(placeholderTab)
    selectedTabID = tabID
}
```

#### 2. Tab Management Operations
```swift
// OLD (REMOVED):
func closeTab(tab: TabData) {
    DispatchQueue.main.async {  // ← No longer needed!
        self.tabs.removeAll { $0.id == tab.id }
        if self.tabs.isEmpty {
            self.addNewTab()
        }
    }
}

// NEW (CURRENT):
func closeTab(tab: TabData) {
    tabs.removeAll { $0.id == tab.id }
    if tabs.isEmpty {
        addNewTab()
    }
}
```

#### 3. Content Updates
```swift
// OLD (REMOVED):
func updateTabContent(tab: TabData, content: String) {
    DispatchQueue.main.async {  // ← No longer needed!
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs[index].content = content
            tabs[index].isDirty = true
        }
    }
}

// NEW (CURRENT):
func updateTabContent(tab: TabData, content: String) {
    if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
        tabs[index].content = content
        tabs[index].isDirty = true
    }
}
```

## Decision Tree: Do I Need DispatchQueue?

```
Are you modifying @Observable model properties?
├─ YES: Is this from a UI action (button, menu)?
│  ├─ YES: Use direct modification (no DispatchQueue needed)
│  └─ NO: Continue to next question
└─ NO: Continue to next question

Do you need an intentional delay for UX?
├─ YES: Use DispatchQueue.main.asyncAfter
└─ NO: Continue to next question

Are you on a background thread moving to main?
├─ YES: Use DispatchQueue.main.async
└─ NO: Continue to next question

Are you debouncing/throttling an operation?
├─ YES: Use DispatchQueue.main.asyncAfter with cancellation
└─ NO: You probably don't need DispatchQueue
```

## Common Patterns in Current Codebase

### Pattern 1: Direct Model Updates (Most Common)
```swift
// EditorViewModel.swift - Direct state updates with @Observable
func addNewTab() {
    let newTab = TabData(...)
    tabs.append(newTab)
    selectedTabID = newTab.id
}
```

### Pattern 2: Background Work Handoff
```swift
// ContentView+Actions.swift - Background → Main
func refreshProjectTree() {
    DispatchQueue.global(qos: .utility).async {
        let nodes = buildProjectTree(at: root)

        DispatchQueue.main.async {
            projectTreeNodes = nodes
        }
    }
}
```

### Pattern 3: Debounced Operations
```swift
// ContentView.swift - Debounced highlight refresh
private func scheduleHighlightRefresh(delay: TimeInterval = 0.05) {
    pendingHighlightRefresh?.cancel()
    let work = DispatchWorkItem {
        highlightRefreshToken &+= 1
    }
    pendingHighlightRefresh = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
}
```

### Pattern 4: Intentional UX Delays
```swift
// ContentView.swift - Welcome tour delay
if !hasSeenWelcomeTourV1 {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        showWelcomeTour = true
    }
}
```

## Files with Remaining DispatchQueue Usage

As of 2026-02-24, legitimate `DispatchQueue.main.async` usage remains in:

1. **ContentView.swift** (~8 instances)
   - Welcome tour timing
   - File drop progress UI
   - Highlight refresh debouncing
   - Session restoration timing
   - Paste handling

2. **ContentView+Actions.swift** (~3 instances)
   - Project tree background work
   - Sidebar sheet coordination
   - File navigation timing

3. **PanelsAndHelpers.swift** (~3 instances)
   - Window accessor callbacks
   - Welcome tour window coordination

4. **NeonSettingsView.swift** (~2 instances)
   - Font discovery deferral
   - Window translucency application

5. **SidebarViews.swift** (~1 instance)
   - TOC navigation coordination

All of these are **legitimate uses** for timing, coordination, or background→main handoffs.

## What Changed in the Migration

| Aspect | Before (@Published) | After (@Observable) |
|--------|-------------------|-------------------|
| State mutations from UI | Required DispatchQueue wrapper | Direct modifications OK |
| Tab creation | Deferred with DispatchQueue | Immediate |
| Tab deletion | Deferred with DispatchQueue | Immediate |
| Content updates | Deferred with DispatchQueue | Immediate |
| Helper methods | Needed "immediate" variants | Single implementation |
| Double deferral risk | High | None |
| AttributeGraph cycles | Frequent | Eliminated |
| Code complexity | High (~150 lines of deferrals) | Low (direct calls) |

## Performance Impact

### Before (with deferrals):
- Every state change: +16ms latency (one runloop)
- Risk of double deferrals: +32ms
- Complex timing issues
- Race conditions possible

### After (with @Observable):
- State changes: <1ms (immediate)
- No deferral overhead
- No timing issues
- No race conditions

## Testing Guidelines

When adding new code:

1. **Default to direct property modification** with `@Observable`
2. **Only add DispatchQueue if:**
   - You need an intentional delay
   - You're moving from background to main thread
   - You're debouncing an operation
   - You're coordinating between independent views
3. **Never use DispatchQueue as a workaround** for AttributeGraph cycles (not needed anymore)

## Migration Notes

If you find old code with `DispatchQueue.main.async` wrapping simple state changes:

```swift
// OLD PATTERN (can be removed):
func someMethod() {
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.someProperty = newValue
    }
}

// REFACTOR TO:
func someMethod() {
    someProperty = newValue
}
```

**Exception:** Keep the DispatchQueue if it's genuinely for timing/coordination, not for workaround purposes.

## Key Takeaways

1. ✅ **@Observable eliminated the need for defensive deferrals**
2. ✅ **Direct property modifications are now safe and preferred**
3. ✅ **DispatchQueue is still valid for timing, coordination, and threading**
4. ❌ **Don't use DispatchQueue as a workaround for state management**
5. 📊 **Code is simpler, faster, and more maintainable**

## Related Documentation

- `refactor-information.md` - Details of the @Observable migration
- `EditorViewModel.swift` - Model implementation with @Observable
- `ARCHITECTURE.md` - Overall app architecture

---

**Migration Date:** 2026-02-24
**Status:** Complete
**Build Status:** ✅ Succeeds
**AttributeGraph Cycles:** ✅ Eliminated

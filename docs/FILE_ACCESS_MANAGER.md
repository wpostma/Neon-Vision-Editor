# FileAccessManager - Security-Scoped Resource Management

**Created:** 2026-02-24
**Status:** ✅ IMPLEMENTED

## Overview

`FileAccessManager` is a centralized manager for security-scoped file access in the sandboxed macOS app. It maintains persistent access to files throughout the app's lifetime, eliminating the need for repeated `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` calls.

## The Problem

Previously, the app was calling `startAccessingSecurityScopedResource()` and `stopAccessingSecurityScopedResource()` every time it accessed a file:

```swift
// OLD PATTERN - inefficient and error-prone
func openFile(url: URL) {
    let didStart = url.startAccessingSecurityScopedResource()
    defer {
        if didStart {
            url.stopAccessingSecurityScopedResource()
        }
    }
    // ... use file
}
```

This approach had several problems:
- **Inefficient**: Starting/stopping access on every read/write
- **Error-prone**: Easy to forget defer blocks
- **Access denied errors**: When opening files from Recent Files menu, access would be released after initial load, causing subsequent operations to fail

## The Solution

`FileAccessManager` provides **pooled, persistent security-scoped access**:

```swift
// NEW PATTERN - efficient and reliable
func openFile(url: URL) {
    FileAccessManager.shared.requestAccess(to: url)
    // ... file access maintained for app lifetime
}
```

### Key Features

1. **Singleton Pattern**: One manager for the entire app
2. **Persistent Access**: Once started, access stays active until tab closes or app terminates
3. **Automatic Cleanup**: Releases all resources on app termination
4. **Reference Counting**: Tracks multiple tabs using the same file
5. **Thread-Safe**: `@MainActor` ensures all operations on main thread

## Implementation

### Core Methods

```swift
@MainActor
final class FileAccessManager {
    static let shared = FileAccessManager()

    // Request access - starts if needed, otherwise returns immediately
    func requestAccess(to url: URL) -> Bool

    // Release access when file is no longer needed
    func releaseAccess(to url: URL)

    // Release all on app termination
    func releaseAll()

    // Check if we have access
    func hasAccess(to url: URL) -> Bool
}
```

### Integration Points

**EditorViewModel.openFile()**
```swift
func openFile(url: URL) {
    // Request persistent access
    FileAccessManager.shared.requestAccess(to: url)

    // ... create tab and load file
    // Access stays active - no defer needed!
}
```

**EditorViewModel.saveFile()**
```swift
func saveFile(tab: TabData) {
    if let url = tabs[index].fileURL {
        // Ensure access (usually already active)
        FileAccessManager.shared.requestAccess(to: url)
        // ... save file
    }
}
```

**EditorViewModel.closeTab()**
```swift
func closeTab(tab: TabData) {
    if let url = tab.fileURL {
        // Only release if no other tabs use this file
        let stillInUse = tabs.contains { $0.id != tab.id && $0.fileURL == url }
        if !stillInUse {
            FileAccessManager.shared.releaseAccess(to: url)
        }
    }
    // ... close tab
}
```

## Entitlements Changes

Changed from app-scoped to document-scoped bookmarks:

```xml
<!-- BEFORE -->
<key>com.apple.security.files.bookmarks.app-scope</key>
<true/>

<!-- AFTER -->
<key>com.apple.security.files.bookmarks.document-scope</key>
<true/>
```

Document-scoped bookmarks provide proper security-scoped access across app launches.

## How It Works

### Opening a File from NSOpenPanel

1. User selects file via `NSOpenPanel`
2. `EditorViewModel.openFile(url:)` called
3. `FileAccessManager.requestAccess(to: url)` starts security-scoped access
4. File loaded into tab
5. **Access stays active for app lifetime**
6. Saves/reloads work without re-requesting access

### Opening from Recent Files

1. `RecentFilesManager.loadRecentFiles()` resolves security-scoped bookmark
2. URL passed to `EditorViewModel.openFile(url:)`
3. `FileAccessManager.requestAccess(to: url)` starts access from resolved bookmark
4. File loaded and **access persists**
5. No more "access denied" errors!

### Closing a Tab

1. `closeTab()` checks if other tabs use same file
2. If not, calls `FileAccessManager.shared.releaseAccess(to: url)`
3. Security-scoped access released
4. Memory and resources freed

### App Termination

1. `NSApplication.willTerminateNotification` received
2. `FileAccessManager.releaseAll()` called
3. All security-scoped resources released cleanly

## Benefits

### Before (Start/Stop Pattern)
- ❌ Repeated start/stop calls on every file operation
- ❌ Easy to forget defer blocks
- ❌ Access denied errors when loading from Recent Files
- ❌ Complex error handling

### After (Persistent Pool Pattern)
- ✅ Single start call per file, released on close
- ✅ No defer blocks needed
- ✅ Recent Files work reliably
- ✅ Simpler, cleaner code
- ✅ Better performance
- ✅ Automatic cleanup

## Files Modified

| File | Changes |
|------|---------|
| `FileAccessManager.swift` | **NEW** - Central security-scoped access manager |
| `EditorViewModel.swift` | Updated `openFile()`, `saveFile()`, `closeTab()` to use FileAccessManager |
| `Neon Vision Editor.entitlements` | Changed to document-scoped bookmarks |

## Testing Checklist

- [ ] Open file via File → Open menu (NSOpenPanel)
- [ ] Save file (Cmd+S)
- [ ] Close tab
- [ ] Reopen from Recent Files menu
- [ ] Save again
- [ ] Open multiple tabs with same file
- [ ] Close one tab (access should stay active)
- [ ] Close all tabs (access should release)
- [ ] Restore session on app launch
- [ ] Quit app (verify no leaks/warnings)

## Related Documentation

- `RECENT_FILES_FEATURE.md` - Recent Files implementation
- `refactor-information.md` - @Observable migration details
- Apple Docs: [Security-Scoped Bookmarks](https://developer.apple.com/documentation/foundation/url/2143023-startaccessingsecurityscopedreso)

---

**Status:** ✅ Implemented and building successfully
**Build Status:** ✅ SUCCESS
**Runtime Testing:** ⚠️ PENDING

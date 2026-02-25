import Foundation
#if os(macOS)
import AppKit
#endif

/// Manages security-scoped access to files throughout the app's lifetime.
/// This ensures files opened via NSOpenPanel or bookmarks remain accessible
/// without needing to repeatedly call startAccessingSecurityScopedResource.
@MainActor
final class FileAccessManager {
    static let shared = FileAccessManager()
    
    /// Tracks URLs that currently have active security-scoped access
    private var accessedURLs: Set<URL> = []
    
    private init() {
        // Register for app termination to clean up all resources
        #if os(macOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        #endif
    }
    
    /// Request access to a file URL. If this is the first access, starts security-scoped access.
    /// - Parameter url: The file URL to access
    /// - Returns: True if access was granted or already active
    @discardableResult
    func requestAccess(to url: URL) -> Bool {
        print("🔷 [FileAccess] requestAccess() called for: \(url.lastPathComponent)")
        print("🔷 [FileAccess] - Original path: \(url.path)")
        
        // Normalize URL to avoid duplicates with different representations
        let normalizedURL = url.standardizedFileURL
        print("🔷 [FileAccess] - Normalized path: \(normalizedURL.path)")
        
        // If we already have access, just return true
        if accessedURLs.contains(normalizedURL) {
            print("🔷 [FileAccess] - Already have access, returning true")
            return true
        }
        
        // Try to start security-scoped access
        print("🔷 [FileAccess] - Calling startAccessingSecurityScopedResource()...")
        let didStart = normalizedURL.startAccessingSecurityScopedResource()
        print("🔷 [FileAccess] - startAccessingSecurityScopedResource() returned: \(didStart)")
        
        if didStart {
            accessedURLs.insert(normalizedURL)
            print("🔐 [FileAccess] ✅ Started security-scoped access for: \(normalizedURL.lastPathComponent)")
        } else {
            // Even if startAccessingSecurityScopedResource returns false,
            // the file might still be accessible (e.g., user-selected files
            // from NSOpenPanel have implicit access). Track it anyway.
            accessedURLs.insert(normalizedURL)
            print("🔓 [FileAccess] ⚠️ Tracking access for: \(normalizedURL.lastPathComponent) (no scoped access needed)")
        }
        
        print("🔷 [FileAccess] - Total files tracked: \(accessedURLs.count)")
        return true
    }
    
    /// Release security-scoped access to a specific file URL
    /// - Parameter url: The file URL to release
    func releaseAccess(to url: URL) {
        let normalizedURL = url.standardizedFileURL
        
        guard accessedURLs.contains(normalizedURL) else {
            return
        }
        
        normalizedURL.stopAccessingSecurityScopedResource()
        accessedURLs.remove(normalizedURL)
        print("🔒 [FileAccess] Released security-scoped access for: \(normalizedURL.lastPathComponent)")
    }
    
    /// Release all security-scoped access. Called on app termination.
    func releaseAll() {
        print("🔒 [FileAccess] Releasing all security-scoped access (\(accessedURLs.count) files)")
        
        for url in accessedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        
        accessedURLs.removeAll()
    }
    
    /// Check if we currently have access to a URL
    /// - Parameter url: The file URL to check
    /// - Returns: True if we're tracking access to this URL
    func hasAccess(to url: URL) -> Bool {
        return accessedURLs.contains(url.standardizedFileURL)
    }
    
    /// Get the number of files currently being accessed
    var accessedFileCount: Int {
        return accessedURLs.count
    }
    
    @objc private func applicationWillTerminate(_ notification: Notification) {
        releaseAll()
    }
}

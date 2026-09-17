import AppKit

/// Whether the app's main (document) window is actually on screen. Closing it only orders it
/// out (see `AppLifecycleDelegate.windowShouldClose`), so SwiftUI's `onDisappear` never fires
/// for its content; pollers that drive UI-only state check this as well as their view's
/// own appear/disappear flag.
@MainActor
enum MainWindowVisibility {
    static var isVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
    }
}

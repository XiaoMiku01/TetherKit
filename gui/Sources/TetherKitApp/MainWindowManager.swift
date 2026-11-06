import AppKit
import SwiftUI
import TetherKitIPC

/// Owns the main window.
///
/// Why not SwiftUI's `Window` scene: it creates the window with its
/// own compact chrome — small, flat traffic lights (measured: 12pt
/// circles in 14×16pt frames at 20pt spacing, versus the stock
/// full-size ones every ordinary window on this machine paints:
/// 14pt circles in 14×14pt frames at 23pt spacing). Even
/// `hiddenTitleBar` plus a bare unified toolbar never flips the
/// rendering (tested). The fix is to make the window like every
/// other window on the machine: a plain `NSWindow` with
/// `fullSizeContentView` and a transparent, title-hidden bar hosting
/// the SwiftUI content via `NSHostingView`. The bar still drags the
/// window; the three lights behave as usual (zoom is disabled since
/// the window is intentionally fixed-size and fullscreen is unneeded).
///
/// One window object, reused forever: the menu bar's "Open Main
/// Window" re-shows it, the red close button hides it, and closing it
/// drops the app back to menu-bar-only mode.
@MainActor
final class MainWindowManager: NSObject {
    static let shared = MainWindowManager()

    /// Held strongly so closing the window does not destroy it.
    private var window: NSWindow?
    private weak var model: AppModel?

    /// Creates the window on first use, then brings it to the front.
    func present(_ model: AppModel) {
        self.model = model
        if window == nil {
            window = makeWindow(model)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        model.windowDidAppear()
    }

    /// Hides the window — File ▸ Close (⌘W) and the red close button
    /// both go through performClose, so both end in the same
    /// hide-and-menu-bar-mode path. Deliberately targets the main
    /// window even when the menu-bar panel is key; a no-op when the
    /// window is already hidden.
    func closeMainWindow() {
        window?.performClose(nil)
    }

    private func makeWindow(_ model: AppModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                  width: Design.Window.width,
                                                  height: Design.Window.height),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // Zoom does nothing on a fixed-size window; disable it
        // explicitly rather than leave a live-looking gray button.
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.minSize = NSSize(width: Design.Window.width, height: Design.Window.height)
        window.maxSize = window.minSize
        window.contentView = NSHostingView(rootView: MainWindowRoot(model: model))
        window.delegate = self
        window.center()
        return window
    }
}

extension MainWindowManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model?.windowDidDisappear()
        model = nil
    }
}

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
        // Hosting sizing propagation OFF: the hosting view must not drive
        // the window size from page content. Default sizing options push
        // min/intrinsic/max into the window as pages swap (page heights
        // differ), and on macOS 26 content-size changes synchronize with
        // window-frame animation (WWDC25-256) — the click's "bulge". The
        // window is fixed-size forever: propagation off, min/max asserted
        // after hosting is attached so it cannot override them.
        let hosting = NSHostingView(rootView: MainWindowRoot(model: model))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.minSize = NSSize(width: Design.Window.width, height: Design.Window.height)
        window.maxSize = window.minSize
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

    // The window has no `.resizable` style bit, so min/max only guard
    // programmatic resizes. Observed on macOS 26: AppKit resets both
    // shortly after presentation (a one-time +32pt chrome settle via
    // `_setFrameCommon` — this is also what changes the recorded
    // frame), so the pin is reasserted on these two delegate hooks.
    // A SwiftUI-facing redundancy: the hosting view runs with
    // `sizingOptions = []`, so page swaps cannot resize the window in
    // either direction.
    func windowDidBecomeMain(_ notification: Notification) {
        pinFixedSize()
    }

    func windowDidResize(_ notification: Notification) {
        pinFixedSize()
    }

    private func pinFixedSize() {
        let fixed = NSSize(width: Design.Window.width, height: Design.Window.height)
        // Idempotent writes: setting min/max must never itself post a
        // resize event (windowDidResize hand-off → infinite loop).
        if window?.minSize != fixed { window?.minSize = fixed }
        if window?.maxSize != fixed { window?.maxSize = fixed }
    }
}

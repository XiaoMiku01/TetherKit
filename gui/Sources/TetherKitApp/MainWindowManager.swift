import AppKit
import SwiftUI
import TetherKitIPC

/// Owns the main window.
///
/// Why not SwiftUI's `Window` scene: it defers the first window and
/// rebuilds it when the app drops to menu-bar mode; owning one window
/// object from the app delegate is deterministic and exposes the
/// reopen hook. Chrome (traffic-light size and spacing) is decided by
/// the executable's LC_BUILD_VERSION `sdk` stamp, not by the layer
/// owning the window; see the linker settings in Package.swift.
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

    /// Hides the main window (File ▸ Close / ⌘W and the red close
    /// button land on the same path), even when the menu-bar panel is
    /// key; a no-op when the window is already hidden.
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
        // explicitly rather than leave a live-looking button.
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        // Hosting sizing propagation OFF: the hosting view must not
        // drive the window size from page content. Default sizing
        // options push min/intrinsic/max into the window as pages swap
        // (page heights differ), and on macOS 26 content-size changes
        // synchronize with window-frame animation (WWDC25-256), the
        // click's "bulge".
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

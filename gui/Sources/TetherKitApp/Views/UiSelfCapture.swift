import AppKit
import SwiftUI

// Dev tool for the visual iteration loop: window self-capture.
//
// Background: screenshotting the app window requires the macOS Screen
// Recording permission, which is unavailable in headless / CI / agent
// sessions. An app capturing ITS OWN window needs no such permission:
// the window's frame view rasterizes itself into a bitmap (the title
// bar with the traffic lights included). CGWindowListCreateImage is
// gone in macOS 15+, so the frame view is the capture path.
//
// Invocation (debug launch arguments):
//
//     ./TetherKit -SelfCapture /tmp/out.png -TetherKitLanguagePreference chinese
//
//   * -SelfCapture <path>: after the window settles, capture it to PNG
//     and terminate.
//   * Language is forced through the argument domain of UserDefaults
//     (-TetherKitLanguagePreference <chinese|english>); the argument
//     domain outranks normal storage.
//
// A few dozen lines here buy the "edit UI, auto-capture, view PNG"
// loop without any screen permission. Retire it when CI grows a real
// replacement.

/// Driver logic for the self-capture.
enum UiSelfCapture {

    /// Output path parsed from the launch arguments; nil when absent
    /// (normal launch).
    static func requestedOutputPath() -> String? {
        let arguments = CommandLine.arguments
        return arguments.firstIndex(of: "-SelfCapture")
            .flatMap { index in index + 1 < arguments.count ? arguments[index + 1] : nil }
    }

    /// Schedules one capture + quit once the window is ready.
    static func schedule(_ window: NSWindow, outputPath: String) {
        // Leave time for layout, language restore, and the first status
        // poll: after 1.5 seconds the picture is fully settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            capture(window, to: outputPath)
            NSApp.terminate(nil)
        }
    }

    private static func capture(_ window: NSWindow, to path: String) {
        // Rasterize the window's frame view hierarchy, which includes
        // the title bar and the traffic lights — unlike the old
        // CGWindowListCreateImage path, this needs no screen
        // recording permission and works on macOS 15+.
        guard let frame = window.contentView?.superview,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// Checks and schedules the self-capture when the view lands in a
/// window.
///
/// Only a view actually placed into a window can reach the NSWindow;
/// the zero-size probe does not affect layout. Attach once as
/// `.background(SelfCaptureProbe())` on the main window's root view.
struct SelfCaptureProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !Self.scheduled else { return }
            Self.scheduled = true
            guard let path = UiSelfCapture.requestedOutputPath() else { return }
            UiSelfCapture.schedule(window!, outputPath: path)
        }

        /// SwiftUI repeatedly mounts and unmounts views (a language
        /// switch rebuilds the whole tree), so the capture is scheduled
        /// exactly once.
        private static var scheduled = false
    }
}

extension View {

    /// In self-capture mode (-SelfCapture launch argument), the window
    /// writes one PNG after it settles.
    func handleSelfCaptureRequest() -> some View {
        background(SelfCaptureProbe())
    }
}

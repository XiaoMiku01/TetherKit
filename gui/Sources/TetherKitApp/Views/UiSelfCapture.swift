import AppKit
import SwiftUI

// Dev tool for the visual iteration loop: window self-capture.
//
// Background: screenshotting the app window requires the macOS Screen
// Recording permission, which is unavailable in headless / CI / agent
// sessions. An app capturing ITS OWN window is not gated by that
// permission. Drawing the window by its window number into a bitmap
// (CGWindowListCreateImage with "own window" selection) does the job.
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
        // First choice: a full-window bitmap by window number with
        // `boundsIgnoreFraming`, which trims the shadow margin outside
        // the rounded corners and makes pixel-level comparison possible.
        let id = CGWindowID(window.windowNumber)
        if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, id,
                                            [.boundsIgnoreFraming, .bestResolution]) {
            let rep = NSBitmapImageRep(cgImage: cg)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                return
            }
        }
        // Fallback: cached display render of the content view tree.
        // SwiftUI hosting views support this; blur materials end up as
        // an approximation of the base color, which is enough to judge
        // layout.
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
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

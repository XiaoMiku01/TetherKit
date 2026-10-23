import AppKit
import Observation
import SwiftUI

/// 原生 NSStatusItem 不属于 SwiftUI 场景，最后一个主窗口关闭后仍须常驻。
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// App 持有菜单栏生命周期；模型和面板仍由 SwiftUI 管理。
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var windowCloseObserver: Any?

    init(model: AppModel, openMainWindow: @escaping () -> Void) {
        self.model = model
        super.init()

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let hosting = NSHostingController(rootView: MenuBarPanel(model: model) { [weak self] in
            self?.popover.close()
            openMainWindow()
        })
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.contentSize = hosting.view.fittingSize
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  window.title == "TetherKit" else { return }
            MainActor.assumeIsolated {
                self?.model.windowDidDisappear()
                NSApp.setActivationPolicy(.accessory)
            }
        }
        observeModel()
    }

    deinit {
        let item = statusItem
        let panel = popover
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
        Task { @MainActor in
            panel.close()
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    private func observeModel() {
        withObservationTracking {
            let _ = model.languageRevision
            MenuBarAppearance.apply(
                to: statusItem, status: model.status,
                receiveBitsPerSecond: model.throughput.receiveBitsPerSecond,
                transmitBitsPerSecond: model.throughput.transmitBitsPerSecond
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeModel() }
        }
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.close()
        } else if let button = statusItem.button {
            button.highlight(true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
    }
}

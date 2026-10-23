import AppKit
import TetherKitIPC
import XCTest
@testable import TetherKitApp

final class MenuBarAppearanceTests: XCTestCase {
    func testClosingTheLastWindowKeepsTheMenuBarAppRunning() async {
        await MainActor.run {
            XCTAssertFalse(MenuBarAppDelegate().applicationShouldTerminateAfterLastWindowClosed(.shared))
        }
    }

    func testNativeButtonKeepsTheSameWidthAcrossRates() async {
        await MainActor.run {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            defer { NSStatusBar.system.removeStatusItem(item) }
            guard let button = item.button else {
                XCTFail("无法创建原生菜单栏按钮")
                return
            }
            var status = SessionStatus.idle
            status.runState = .running
            let rates: [Double] = [0, 9_000, 19_000, 999_999, 6_800_000,
                                   999_999_999, 1_000_000_000, 10_000_000_000]
            for receive in rates {
                for transmit in rates {
                    MenuBarAppearance.apply(to: item, status: status,
                                             receiveBitsPerSecond: receive,
                                             transmitBitsPerSecond: transmit)
                    XCTAssertEqual(item.length, MenuBarAppearance.runningLength)
                    XCTAssertEqual(item.button?.imagePosition, .imageLeft)
                    XCTAssertEqual(item.button?.image?.size, NSSize(width: 18, height: 18))
                    XCTAssertLessThanOrEqual(button.attributedTitle.size().width,
                                             MenuBarAppearance.valueWidth)
                }
            }
            XCTAssertLessThanOrEqual(item.length, 70, "图标与系统内边距应保持紧凑")

            MenuBarAppearance.apply(to: item, status: .idle,
                                     receiveBitsPerSecond: 0, transmitBitsPerSecond: 0)
            XCTAssertEqual(item.length, NSStatusItem.variableLength)
            XCTAssertEqual(item.button?.attributedTitle.string, "")
            XCTAssertEqual(item.button?.imagePosition, .imageOnly)
        }
    }

    func testNativeTitleMetricsLineOrderAndBaseline() async {
        await MainActor.run {
            for height: CGFloat in [22, 24, 30] {
                let text = MenuBarAppearance.title(receiveBitsPerSecond: 38 * 1_024 * 8,
                                                    transmitBitsPerSecond: 2_867 * 8,
                                                    buttonHeight: height)
                XCTAssertEqual(text.string, "2.8K/s\n 38K/s")
                let attributes = text.attributes(at: 0, effectiveRange: nil)
                let font = attributes[.font] as? NSFont
                XCTAssertEqual(font?.fontName, NSFont.monospacedSystemFont(ofSize: 9.5,
                                                                          weight: .regular).fontName)
                XCTAssertEqual(font?.pointSize, 9.5)
                XCTAssertEqual(attributes[.foregroundColor] as? NSColor, .controlTextColor)
                let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
                XCTAssertEqual(paragraph?.alignment, .right)
                XCTAssertEqual(paragraph?.minimumLineHeight, 10)
                XCTAssertEqual(paragraph?.maximumLineHeight, 10)
                XCTAssertEqual(paragraph?.lineSpacing, 0)
                let offset = attributes[.baselineOffset] as? CGFloat
                let expected = -(MenuBarAppearance.font.ascender - MenuBarAppearance.font.descender) / 3
                    + (20 - height) / 2
                XCTAssertEqual(offset, expected)
            }
        }
    }

    func testControllerCanReleaseItsStatusItem() async {
        await MainActor.run {
            weak var weakController: MenuBarController?
            var controller: MenuBarController? = MenuBarController(model: AppModel(), openMainWindow: {})
            weakController = controller
            XCTAssertNotNil(weakController)
            controller = nil
            XCTAssertNil(weakController, "面板与观察回调不能把控制器循环持有")
        }
    }

    func testByteRateFormattingAndRoundedUnitPromotion() {
        let cases: [(Double, String)] = [
            (0, "0B/s"), (-1, "0B/s"), (.nan, "0B/s"), (.infinity, "0B/s"),
            (999, "999B/s"), (1_000, "1.0K/s"), (2_867, "2.8K/s"),
            (10_188, "9.9K/s"), (10_189, "10K/s"), (38 * 1_024, "38K/s"),
            (1_023_487, "999K/s"), (1_023_488, "1.0M/s"),
            (1_024 * 1_024, "1.0M/s"), (1_024 * 1_024 * 1_024, "1.0G/s")
        ]
        for (bytes, expected) in cases {
            XCTAssertEqual(Format.compactByteRate(bytes * 8), expected)
        }
    }
}

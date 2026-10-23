import AppKit
import TetherKitIPC

/// 使用原生 attributedTitle，避免把小字号文字栅格化后再缩放。
@MainActor
enum MenuBarAppearance {
    static let font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
    static let lineHeight: CGFloat = 10
    static let valueWidth = ceil(("999B/s" as NSString).size(withAttributes: [.font: font]).width)
    // 与 Clash 的原生按钮相同：18pt 图标和系统内边距共预留 30pt。
    static let runningLength = max(58, valueWidth + 30)

    static func title(receiveBitsPerSecond: Double, transmitBitsPerSecond: Double,
                      buttonHeight: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byClipping
        paragraph.lineSpacing = 0
        paragraph.lineHeightMultiple = 1
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.paragraphSpacingBefore = 0

        // NSStatusBarButton 的文字基线取决于实际菜单栏高度，不能用图片顶部代替。
        let baseline = -(font.ascender - font.descender) / 3
            + (lineHeight * 2 - buttonHeight) / 2
        func padded(_ bitsPerSecond: Double) -> String {
            let value = Format.compactByteRate(bitsPerSecond)
            return String(repeating: " ", count: max(0, 6 - value.count)) + value
        }
        return NSAttributedString(
            string: padded(transmitBitsPerSecond) + "\n" + padded(receiveBitsPerSecond),
            attributes: [.font: font, .foregroundColor: NSColor.controlTextColor,
                         .paragraphStyle: paragraph, .baselineOffset: baseline]
        )
    }

    static func apply(to item: NSStatusItem, status: SessionStatus,
                      receiveBitsPerSecond: Double, transmitBitsPerSecond: Double) {
        guard let button = item.button else { return }
        let running = status.runState == .running
        item.length = running ? runningLength : NSStatusItem.variableLength
        button.image = icon(for: status)
        button.attributedTitle = running
            ? title(receiveBitsPerSecond: receiveBitsPerSecond,
                    transmitBitsPerSecond: transmitBitsPerSecond,
                    buttonHeight: button.bounds.height)
            : NSAttributedString(string: "")
        button.imagePosition = running ? .imageLeft : .imageOnly
        let description = "\(Design.statusLabel(for: status)), "
            + "\(L(.upstreamShort)) \(Format.bitrate(transmitBitsPerSecond)), "
            + "\(L(.downstreamShort)) \(Format.bitrate(receiveBitsPerSecond))"
        button.setAccessibilityLabel(description)
        button.toolTip = description
    }

    private static func icon(for status: SessionStatus) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: Design.statusSymbol(for: status),
                                   accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) else { return nil }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            let scale = min(bounds.width / symbol.size.width, bounds.height / symbol.size.height)
            let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            symbol.draw(in: NSRect(x: (bounds.width - size.width) / 2,
                                   y: (bounds.height - size.height) / 2,
                                   width: size.width, height: size.height))
            return true
        }
        image.isTemplate = true
        return image
    }
}

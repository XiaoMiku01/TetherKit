import SwiftUI
import TetherKitIPC

/// 日志面板。
///
/// 布局这支笔有两档：
///
///   * 旧 Dashboard 时代它常驻右栏底部，吃掉两栏剩下的高度；（弹性层钉死
///     `idealHeight` 的原因见 `logList` —— 外层兜底 ScrollView 用理想尺寸
///     测内容，而内嵌 ScrollView 的理想高度 = 全部日志展开的高度。）
///   * 侧边栏改版后它独占一页（`fillsAvailableHeight`）：不再有外层滚动，
///     列表随窗口一起长高，`minHeight` 只作为极端窗口下的下限保底。
///
/// 出问题时它是唯一有用的东西，所以做了三件事：可按级别过滤、自动滚到底、
/// 一键复制全部（用户报 issue 时能直接贴过来）。
struct LogCard: View {
    @Bindable var model: AppModel
    @State private var autoScroll = true

    /// 独占整页时置 true：列表撑满页面剩余高度。
    /// 为 false 时维持旧右栏底部形态（钉死的 90pt 弹性层）。
    var fillsAvailableHeight: Bool = false

    var body: some View {
        Card(title: L(.logSectionTitle), systemImage: "text.alignleft") {
            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                toolbar
                // 高度两档的分岔点。卡片圈住的这一层是 flex 的吸收层：
                // 页面化时随窗口长高；旧两栏形态下钉死理想高度（原因见 logList）。
                if fillsAvailableHeight {
                    logList.frame(minHeight: 288, maxHeight: .infinity)
                } else {
                    logList.frame(minHeight: 90, idealHeight: 90, maxHeight: .infinity)
                }
                if model.droppedLogCount > 0 {
                    Label(L(.logDroppedNotice, Int(model.droppedLogCount)),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: Design.Spacing.small) {
            Picker(L(.logLevelLabel), selection: $model.logLevelFilter) {
                Text(L(.logLevelAll)).tag(LogLevel.trace)
                Text(L(.logLevelDebug)).tag(LogLevel.debug)
                Text(L(.logLevelInfo)).tag(LogLevel.info)
                Text(L(.logLevelWarning)).tag(LogLevel.warning)
                Text(L(.logLevelError)).tag(LogLevel.error)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)

            Spacer()

            Toggle(L(.logAutoScroll), isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .font(.callout)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(plainText, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(L(.logCopyAll))

            Button {
                model.clearLogs()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L(.logClear))
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            listBody
                .background(.quaternary.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: Design.Radius.control))
            .onChange(of: model.filteredLogs.last?.id) { _, newValue in
                guard autoScroll, let newValue else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newValue, anchor: .bottom)
                }
            }
        }
    }

    /// 列表本体：不带高度语义（由调用点的两档 frame 决定）。
    private var listBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.filteredLogs) { entry in
                    LogRow(entry: entry)
                        .id(entry.id)
                }
            }
            .padding(Design.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var plainText: String {
        model.filteredLogs
            .map { item in
                var line = "\(Format.time(item.latest.timestamp)) [\(item.latest.level.label)] "
                    + "[\(item.latest.thread)] \(item.latest.message)"
                if item.count > 1 {
                    line += L(.logRepeatSuffix, item.count, Format.time(item.first.timestamp))
                }
                return line
            }
            .joined(separator: "\n")
    }
}

private struct LogRow: View {
    let entry: CollapsedLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: Design.Spacing.small) {
            Text(Format.time(entry.latest.timestamp))
                .foregroundStyle(.tertiary)
            Text(entry.latest.level.label)
                .foregroundStyle(Design.logColor(for: entry.latest.level))
                // 固定宽度让级别列对齐，扫读时眼睛不用横向找。
                .frame(width: 46, alignment: .leading)
            Text(entry.latest.message)
                .foregroundStyle(Design.logColor(for: entry.latest.level))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if entry.count > 1 {
                Text("×\(entry.count)")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help(L(.logRepeatTooltip, entry.count,
                            Format.time(entry.first.timestamp)))
            }
        }
        .font(.system(size: 11, design: .monospaced))
    }
}

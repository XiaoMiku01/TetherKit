import SwiftUI
import TetherKitIPC

/// Log panel.
///
/// When something breaks, this is the only tool that helps, so it does
/// three things: filter by level, auto-scroll to the newest line,
/// copy everything in one tap (users paste it straight into an issue).
///
/// The card owns the Log page: no outer scroll, the list grows with
/// the window, and `minHeight` is only a floor for extreme window
/// sizes. (It used to sit in the two-column dashboard's right column
/// with a pinned 90pt height; that path is gone.)
///
/// The card carries no title row — the page header already says
/// "Log".
struct LogCard: View {
    @Bindable var model: AppModel
    @State private var autoScroll = true

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                toolbar
                logList.frame(minHeight: 288, maxHeight: .infinity)
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

    /// The list body itself: no height semantics of its own (the page
    /// supplies the frame).
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

import Charts
import SwiftUI
import TetherKitIPC

/// 吞吐与计数器。
///
/// 图表刻意只画**速率**而不画累计量：累计曲线永远单调上升，看不出任何东西；
/// 而速率能一眼看出卡顿、抖动和被限速。累计量放在下面的指标格里，需要时能读到。
///
/// The card carries no title row: it is the body of the "Throughput"
/// page and the page header already says it (with the LIVE badge).
struct ThroughputCard: View {
    @Bindable var model: AppModel

    private var hasData: Bool { !model.throughputHistory.isEmpty }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                rateRow
                chart
                Divider()
                counterRow
                if hasDrops {
                    dropHint
                }
            }
        }
    }

    // The four rate tiles form a 2x2 grid, not one row. In the
    // two-column era this card had half a window column; the Throughput
    // page is now its own page with the full content width, so a row
    // would fit. Kept as 2x2 for the next visual pass.
    private var rateRow: some View {
        Grid(alignment: .leading,
             horizontalSpacing: Design.Spacing.medium,
             verticalSpacing: Design.Spacing.small) {
            GridRow {
                MetricTile(caption: L(.throughputDownstream),
                           value: Format.bitrate(model.throughput.receiveBitsPerSecond),
                           systemImage: "arrow.down",
                           tint: .blue)
                MetricTile(caption: L(.throughputUpstream),
                           value: Format.bitrate(model.throughput.transmitBitsPerSecond),
                           systemImage: "arrow.up",
                           tint: .purple)
            }
            GridRow {
                MetricTile(caption: L(.throughputDownstreamFPS),
                           value: "\(Format.packetsPerSecond(model.throughput.receivePacketsPerSecond)) pps",
                           systemImage: "square.stack.3d.up")
                MetricTile(caption: L(.throughputUpstreamFPS),
                           value: "\(Format.packetsPerSecond(model.throughput.transmitPacketsPerSecond)) pps",
                           systemImage: "square.stack.3d.up")
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        if hasData {
            Chart {
                ForEach(model.throughputHistory) { sample in
                    AreaMark(x: .value(L(.chartTime), sample.timestamp),
                             y: .value(L(.chartRate), sample.receiveBitsPerSecond))
                        .foregroundStyle(
                            .linearGradient(colors: [.blue.opacity(0.35), .blue.opacity(0.02)],
                                            startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)

                    LineMark(x: .value(L(.chartTime), sample.timestamp),
                             y: .value(L(.chartRate), sample.receiveBitsPerSecond),
                             series: .value(L(.chartDirection), L(.downstreamShort)))
                        .foregroundStyle(.blue)
                        .interpolationMethod(.monotone)

                    LineMark(x: .value(L(.chartTime), sample.timestamp),
                             y: .value(L(.chartRate), sample.transmitBitsPerSecond),
                             series: .value(L(.chartDirection), L(.upstreamShort)))
                        .foregroundStyle(.purple)
                        .interpolationMethod(.monotone)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let bits = value.as(Double.self) {
                            Text(Format.bitrate(bits)).font(.caption2)
                        }
                    }
                }
            }
            // 横轴不画刻度：这是一条「最近 60 秒」的滚动曲线，具体时刻没有意义，
            // 画上去只会挤占本来就不高的绘图区。
            .chartXAxis(.hidden)
            .frame(height: 120)
        } else {
            RoundedRectangle(cornerRadius: Design.Radius.control)
                .fill(.quaternary.opacity(0.35))
                .frame(height: 120)
                .overlay(
                    Text(L(model.status.runState == .running ? .throughputCollecting : .throughputPlaceholder))
                        .font(.callout)
                        .foregroundStyle(.secondary))
        }
    }

    private var counterRow: some View {
        HStack(spacing: Design.Spacing.medium) {
            MetricTile(caption: L(.totalDownstream), value: Format.bytes(model.status.rxBytes))
            MetricTile(caption: L(.totalUpstream), value: Format.bytes(model.status.txBytes))
            MetricTile(caption: L(.downstreamFrames), value: Format.count(model.status.rxFrames))
            MetricTile(caption: L(.upstreamFrames), value: Format.count(model.status.txFrames))
        }
    }

    private var hasDrops: Bool {
        model.status.rxDropped > 0 || model.status.txDropped > 0
            || model.status.linkKernelDrops > 0 || model.status.txBackpressure > 0
    }

    /// 丢包提示。
    ///
    /// 分开列四个数字而不是合成一个「丢包率」：它们指向完全不同的瓶颈 ——
    /// 队列满是下游写不过来，内核丢是我们读得不够快，背压是 USB 侧发不出去。
    /// 合并之后就分不清该调哪个参数了。
    private var dropHint: some View {
        HStack(spacing: Design.Spacing.medium) {
            MetricTile(caption: L(.downstreamDropped), value: Format.count(model.status.rxDropped), tint: .orange)
            MetricTile(caption: L(.upstreamDropped), value: Format.count(model.status.txDropped), tint: .orange)
            MetricTile(caption: L(.kernelDrops), value: Format.count(model.status.linkKernelDrops), tint: .orange)
            MetricTile(caption: L(.transmitBackpressure), value: Format.count(model.status.txBackpressure), tint: .orange)
        }
    }
}

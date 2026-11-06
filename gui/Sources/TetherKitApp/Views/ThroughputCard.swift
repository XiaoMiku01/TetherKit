import Charts
import SwiftUI
import TetherKitIPC

/// 吞吐与计数器。
///
/// 图表刻意只画**速率**而不画累计量：累计曲线永远单调上升，看不出任何东西；
/// 而速率能一眼看出卡顿、抖动和被限速。累计量放在下面的指标格里，需要时能读到。
struct ThroughputCard: View {
    @Bindable var model: AppModel

    /// 页面化开关。吞吐卡现在是「吞吐」页的主体 —— 页头本身写着「吞吐」，
    /// 卡片自我介绍的标题行要能关掉，避免同一层级出现两次。
    /// 「实时」徽标随标题行一起走：页面化时由页面头负责渲染它
    /// （见 ThroughputPage）。
    var showsTitleRow: Bool = true

    private var hasData: Bool { !model.throughputHistory.isEmpty }

    var body: some View {
        Card(title: showsTitleRow ? L(.throughputSectionTitle) : nil,
             systemImage: showsTitleRow ? "chart.line.uptrend.xyaxis" : nil,
             accessory: showsTitleRow ? AnyView(liveBadge) : nil) {
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

    @ViewBuilder
    private var liveBadge: some View {
        if model.status.runState == .running {
            StatusBadge(text: L(.throughputLive), color: .green)
        }
    }

    // 速率四格排成 2×2 而不是一行：旧两栏时代这卡只占半栏，一行四格会把
    // 「下行（设备 → 本机）」这类说明挤到截断。现在卡住了「吞吐」页的 640pt
    // 全宽，一行放得下 —— 但本轮改版只动布局不动卡内排版，先保留 2×2，
    // 留到下次视觉迭代再评估（见 ThroughputPage）。
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

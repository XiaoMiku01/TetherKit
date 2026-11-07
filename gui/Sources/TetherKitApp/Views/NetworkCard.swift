import SwiftUI
import TetherKitCore
import TetherKitIPC

/// 上网方式配置：DHCP 或静态 IP。
///
/// ★ 「当前生效」一栏为什么单独存在 ★
///   它显示的是**从系统回读**的状态，不是我们下发的值。两者可能不同 ——
///   最典型的是静态模式下的 DNS：IPConfiguration 只在 DHCP 模式发布 DNS，
///   静态模式我们只能尽力而为地补一个键，能不能被系统采纳取决于 IPMonitor。
///   与其向用户承诺一个可能不成立的结果，不如把真实状态摆出来。
///
/// This card lives on the "Network" page with the full content width
/// to itself. The two-column grid works on a full-width page: a single
/// column would stretch the form sparse and tall (IPv4 values are
/// short), and long explanations stay in tooltips.
struct NetworkCard: View {
    @Bindable var model: AppModel

    /// 网卡还没创建时整块禁用 —— 没有网卡可配，让用户填完再报错是最糟的顺序。
    private var interfaceReady: Bool { !model.status.systemInterface.isEmpty }

    private var canAddDNS: Bool {
        // 上限与 C ABI 的 TK_DNS_MAX 一致，多填的会被丢弃，不如直接不让加。
        model.networkConfiguration.dnsServers.count < 4
    }

    /// 静态 DNS 的悬停说明。它属于「什么时候需要在意」级别的信息，
    /// 不值得常驻一行。
    /// 计算属性而非 `static let`：后者只求值一次，切换语言后就不再更新了。
    private static var dnsHint: String { L(.dnsEffectivenessTooltip) }

    var body: some View {
        Card(title: L(.ipModeLabel), systemImage: "network", accessory: AnyView(interfaceBadge)) {
            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                // The "connect first" hint sits inline above the form
                // instead of floating over it; at full width the old
                // centered capsule covered the DHCP explanation.
                if !interfaceReady {
                    Label(L(.connectBeforeConfiguring), systemImage: "cable.connector")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Group {
                    modePicker

                    switch model.networkConfiguration.mode {
                    case .dhcp:
                        dhcpExplanation
                    case .manual:
                        manualForm
                    case .none:
                        EmptyView()
                    }

                    defaultRouteToggle
                    actionRow

                    if interfaceReady {
                        Divider()
                        EffectiveStateView(state: model.networkState,
                                           interface: model.status.systemInterface)
                    }
                }
                .disabled(!interfaceReady)
                .opacity(interfaceReady ? 1 : 0.55)
            }
        }
    }

    @ViewBuilder
    private var interfaceBadge: some View {
        if interfaceReady {
            StatusBadge(text: model.status.systemInterface, color: .accentColor)
        }
    }

    private var modePicker: some View {
        Picker(L(.ipModeLabel), selection: $model.networkConfiguration.mode) {
            // 刻意不把「不配置」放进选择器：它是一个动作（撤销），不是一种上网
            // 方式。混在一起会让人以为选中它就已经生效了。
            Text(IPMode.dhcp.displayName).tag(IPMode.dhcp)
            Text(IPMode.manual.displayName).tag(IPMode.manual)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var dhcpExplanation: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.tight) {
            Label(L(.dhcpHelp), systemImage: "wand.and.stars")
                .font(.callout)
            Text(L(.dhcpTooltip))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var manualForm: some View {
        Grid(alignment: .leading,
             horizontalSpacing: Design.Spacing.medium,
             verticalSpacing: Design.Spacing.small) {
            GridRow {
                AddressField(label: L(.ipAddress),
                             placeholder: "192.168.42.100",
                             text: $model.networkConfiguration.address,
                             isValid: NetworkValidator.isValidIPv4(model.networkConfiguration.address))
                AddressField(label: L(.netmask),
                             placeholder: "255.255.255.0",
                             text: $model.networkConfiguration.netmask,
                             isValid: NetworkValidator.isValidNetmask(model.networkConfiguration.netmask))
            }
            GridRow {
                AddressField(label: L(.router),
                             placeholder: L(.routerOptional),
                             text: $model.networkConfiguration.router,
                             isValid: model.networkConfiguration.router.isEmpty
                                 || NetworkValidator.isValidIPv4(model.networkConfiguration.router))
                if model.networkConfiguration.dnsServers.isEmpty {
                    emptyDNSCell
                } else {
                    dnsField(at: 0)
                }
            }
            // 第 2 条起的 DNS 各占一行的右格，左格空着 —— 和上面的 DNS 对齐。
            ForEach(Array(model.networkConfiguration.dnsServers.indices.dropFirst()),
                    id: \.self) { index in
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    dnsField(at: index)
                }
            }
        }
    }

    /// 一条 DNS：输入格 + 删除，最后一条再带一个「添加」。
    private func dnsField(at index: Int) -> some View {
        HStack(spacing: Design.Spacing.tight) {
            AddressField(label: index == 0 ? "DNS" : "",
                         placeholder: "223.5.5.5",
                         text: $model.networkConfiguration.dnsServers[index],
                         isValid: model.networkConfiguration.dnsServers[index].isEmpty
                             || NetworkValidator.isValidIPv4(model.networkConfiguration.dnsServers[index]))

            Button {
                model.networkConfiguration.dnsServers.remove(at: index)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(L(.deleteThisEntry))

            if index == model.networkConfiguration.dnsServers.count - 1, canAddDNS {
                Button {
                    model.networkConfiguration.dnsServers.append("")
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help(L(.addDNSServer))
            }
        }
        .help(Self.dnsHint)
    }

    /// 一条 DNS 都没有时占住格子的「添加」。
    private var emptyDNSCell: some View {
        HStack(spacing: Design.Spacing.tight) {
            Text("DNS")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: AddressField.labelWidth, alignment: .leading)
            Button {
                model.networkConfiguration.dnsServers.append("")
            } label: {
                Label(L(.add), systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .font(.callout)
            Spacer(minLength: 0)
        }
        .help(Self.dnsHint)
    }

    private var defaultRouteToggle: some View {
        Toggle(isOn: $model.networkConfiguration.setDefaultRoute) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L(.setDefaultRoute))
                Text(L(.setDefaultRouteHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help(L(.setDefaultRouteTooltip))
    }

    private var actionRow: some View {
        HStack(spacing: Design.Spacing.small) {
            Button {
                Task { await model.applyNetworkConfiguration() }
            } label: {
                HStack(spacing: Design.Spacing.tight) {
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Text(L(.apply))
                }
                .frame(minWidth: 56)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy)

            Button(L(.clearConfiguration)) {
                Task { await model.clearNetworkConfiguration() }
            }
            .disabled(model.isBusy || !model.networkState.hasAddress)
            .help(L(.clearConfigurationTooltip))

            Spacer()
        }
    }
}

/// 一个带即时校验反馈的紧凑地址输入框：标签在左，校验图标叠在输入框内侧
/// （两列布局里每一点宽度都金贵）。
///
/// 校验放在输入时而不是提交时：地址填错是最常见的操作失误，等点了「应用」再报错
/// 会让用户来回猜是哪一格错了。
private struct AddressField: View {
    /// 标签列宽。回读区的标签也用它，两块的竖向对齐线才是同一条。
    static let labelWidth: CGFloat = 56

    let label: String
    let placeholder: String
    @Binding var text: String
    let isValid: Bool

    var body: some View {
        HStack(spacing: Design.Spacing.tight) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)

            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .overlay(alignment: .trailing) {
                    // 空输入不标红：还没填完不算错。
                    if !text.isEmpty {
                        Image(systemName: isValid ? "checkmark.circle.fill"
                                                  : "exclamationmark.circle.fill")
                            .foregroundStyle(isValid ? Color.green : Color.orange)
                            .font(.caption)
                            .padding(.trailing, 4)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

/// 从系统回读的真实生效状态。
private struct EffectiveStateView: View {
    let state: NetworkState
    let interface: String

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.tight) {
            HStack(spacing: Design.Spacing.small) {
                Text(L(.currentlyEffective))
                    .font(.subheadline.weight(.medium))
                if !state.method.isEmpty {
                    StatusBadge(text: state.method, color: .accentColor)
                }
                if !state.serviceState.isEmpty {
                    StatusBadge(text: state.serviceState,
                                color: state.serviceState == "BOUND" ? .green : .orange)
                }
                if state.isPrimaryDefaultRoute {
                    StatusBadge(text: L(.primaryDefaultRoute), color: .green)
                }
            }

            if state.hasAddress {
                // 两列四格而不是四行：这是纯展示区，紧凑优先。放不下的值
                // （多条 DNS）中截显示，悬停能看全，也能选中复制。
                Grid(alignment: .leading,
                     horizontalSpacing: Design.Spacing.medium,
                     verticalSpacing: Design.Spacing.tight) {
                    GridRow {
                        readbackCell(L(.ipAddress), state.address)
                        readbackCell(L(.netmask), state.netmask)
                    }
                    GridRow {
                        readbackCell(L(.router), state.router)
                        readbackCell("DNS", state.dnsServers.isEmpty
                                     ? L(.notEffective)
                                     : state.dnsServers.joined(separator: L(.listSeparator)))
                    }
                }
            } else {
                Text(L(.noAddressYet, interface))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func readbackCell(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.tight) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: AddressField.labelWidth, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(value)
    }
}

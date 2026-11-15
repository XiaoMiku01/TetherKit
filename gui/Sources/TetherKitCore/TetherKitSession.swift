import CTetherKit
import Foundation
import TetherKitIPC

/// 一个 RNDIS 会话。**需要 root**，因此只在 helper 进程里使用。
///
/// 线程安全：C 侧的会话本身是线程安全的（状态快照与事件队列都有锁），但
/// `start` / `stop` 的调用顺序需要调用方自己保证不并发。helper 用一个串行
/// 队列串起所有生命周期调用来满足这一点。
public final class TetherKitSession {
    private let handle: OpaquePointer

    /// 一次最多取走多少条事件，与 C 侧环形缓冲容量（128）一致。
    private static let eventCapacity = 128

    public init(configuration: SessionConfiguration) throws {
        var raw = tk_session_config_t()
        // 必须先 init 再改：结构体里有一堆调优旋钮，全零初始化会得到无效配置。
        tk_session_config_init(&raw)
        raw.vendor_id = configuration.vendorID
        raw.product_id = configuration.productID
        raw.bus_number = configuration.busNumber
        raw.device_address = configuration.deviceAddress
        raw.mtu = configuration.mtu
        raw.adopt_device_mac = configuration.adoptDeviceMAC

        var error = tk_error_t()
        guard let created = tk_session_create(&raw, &error) else {
            throw TetherKitError(result: TK_ERR_FAILED.rawValue, error: error)
        }
        handle = created
    }

    deinit {
        // tk_session_destroy 内部会先停机（幂等），所以这里不用先 stop。
        tk_session_destroy(handle)
    }

    /// 启动。**非阻塞** —— 返回只表示请求已受理，成败要看后续的 status。
    public func start() throws {
        var error = tk_error_t()
        let result = tk_session_start(handle, &error)
        try check(result, error)
    }

    /// 停机并等待全部拆除完成。幂等。
    public func stop() {
        _ = tk_session_stop(handle)
    }

    /// 取一份状态快照。任意线程可调。
    public func status() -> SessionStatus {
        var raw = tk_session_status_t()
        guard tk_session_status_get(handle, &raw) == TK_OK else {
            return .idle
        }
        return SessionStatus(
            runState: RunState(rawValue: raw.run_state) ?? .idle,
            rndisState: RndisState(rawValue: raw.rndis_state) ?? .uninitialized,
            linkUp: raw.link_up,
            paused: raw.paused,
            systemInterface: String(fixedCArray: raw.system_interface),
            driverInterface: String(fixedCArray: raw.driver_interface),
            deviceMAC: formatMAC(raw.device_mac),
            mtu: raw.mtu,
            linkSpeedMbps: raw.link_speed_mbps,
            vendorDescription: String(fixedCArray: raw.vendor_description),
            deviceDescription: String(fixedCArray: raw.device_description),
            rxFrames: raw.rx_frames,
            rxBytes: raw.rx_bytes,
            rxDropped: raw.rx_dropped,
            txFrames: raw.tx_frames,
            txBytes: raw.tx_bytes,
            txDropped: raw.tx_dropped,
            rxQueueDepth: raw.rx_queue_depth,
            linkKernelDrops: raw.link_kernel_drops,
            txBackpressure: raw.tx_backpressure,
            monotonicNanos: raw.monotonic_nanos,
            fatalMessage: String(fixedCArray: raw.fatal))
    }

    /// 当前系统网卡名（如 feth0）。
    public var systemInterface: String {
        status().systemInterface
    }

    /// 取走已排队的事件，渲染成给用户看的一句话。
    ///
    /// 只保留「用户会关心」的那几类：链路变化、设备复位、致命错误。RNDIS 内部
    /// 的状态迁移与生命周期迁移界面已经通过 status 展示了，再刷成通知只是噪音。
    public func drainNotices() -> [String] {
        var buffer = [tk_event_t](repeating: tk_event_t(), count: Self.eventCapacity)
        let taken = tk_session_poll_events(handle, &buffer, Self.eventCapacity)

        return buffer.prefix(taken).compactMap { event -> String? in
            // C 侧的 tk_event_kind 全是非负值，被 Swift 导入成 UInt32，而结构体
            // 字段是 int32_t —— 两者不能直接比较，必须显式转一次。
            switch event.kind {
            case Int32(TK_EVENT_LINK.rawValue):
                return L(event.a == 1 ? .eventLinkUp : .eventLinkDown)
            case Int32(TK_EVENT_DEVICE_RESET.rawValue):
                return L(event.a == 1 ? .eventDeviceResetReplayed : .eventDeviceReset)
            case Int32(TK_EVENT_FATAL.rawValue):
                return String(fixedCArray: event.text)
            case Int32(TK_EVENT_NEGOTIATED.rawValue):
                return L(.eventNegotiated, Int(event.a), Int(event.b))
            default:
                return nil
            }
        }
    }
}

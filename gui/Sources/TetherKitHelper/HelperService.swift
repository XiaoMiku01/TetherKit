import Foundation
import TetherKitCore
import TetherKitIPC

/// helper 的 XPC 服务实现。
///
/// ★ 线程模型 ★
///
///   XPC 的方法在连接自己的队列上被调用。凡是可能耗时的操作（启动会话要做 USB
///   握手、DHCP 要等租约）都**立刻派发到自己的串行队列并异步回复**，绝不在
///   XPC 队列上阻塞 —— 否则同一条连接上后续的状态轮询会被一起卡住，界面表现
///   成「整个卡死」。
///
///   会话生命周期与网卡配置各用一条串行队列：两者互不阻塞，但各自内部严格串行
///   （并发的 start/stop 或并发的 ipconfig 都是灾难）。状态查询不排队，直接打到
///   C 层 —— 那边的快照本来就是线程安全的。
final class HelperService: NSObject, TetherKitHelperProtocol {
    private let lifecycleQueue = DispatchQueue(label: "com.tetherkit.helper.lifecycle")
    private let networkQueue = DispatchQueue(label: "com.tetherkit.helper.network")

    /// 保护 session 与 notices。持有时间都极短，用普通锁足够。
    private let stateLock = NSLock()
    private var session: TetherKitSession?
    /// startSession 正在构造 / 握手中。这段窗口里 session 还没登记，但设备
    /// **已经**被本进程打开了 —— 枚举的占用判定必须把它算进去，否则字符串
    /// 读取会往握手中的控制端点再插一笔传输。
    private var sessionStarting = false
    /// 尚未被 App 取走的提示。
    private var pendingNotices: [String] = []

    // MARK: - 不需要授权的探测接口

    func helperVersion(reply: @escaping (String) -> Void) {
        // 带上 XPC 接口修订号，让 App 能发现「helper 是升级前的旧版本」。
        reply(HelperConstants.encodeVersion(TetherKitLibrary.versionInfo.version))
    }

    func environment(reply: @escaping (Data?, String?) -> Void) {
        respond(with: TetherKitLibrary.checkEnvironment(), reply: reply)
    }

    func listDevices(reply: @escaping (Data?, String?) -> Void) {
        // 设备被本进程持有期间不读字符串描述符：读要 libusb_open，白白失败一遍，
        // 还会往正在握手的控制端点插传输。判定用「真的持有」而不是「session
        // 非 nil」—— failed / stopped 的死会话早就把 USB 拆干净了，把它们也算
        // 「占用」会让设备拔掉重插后一直读不到名字。
        // 跳过不会丢名字：C 层会回填上次成功读到的值（见 environment.cc）。
        let deviceHeld = stateLock.withLock { () -> Bool in
            if sessionStarting { return true }
            guard let session else { return false }
            switch session.status().runState {
            case .starting, .running, .stopping: return true
            case .idle, .stopped, .failed: return false
            }
        }
        do {
            let devices = try TetherKitLibrary.listDevices(readStrings: !deviceHeld)
            respond(with: devices, reply: reply)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func sessionStatus(reply: @escaping (Data?, String?) -> Void) {
        let status = withState { $0?.status() } ?? .idle
        // 顺带把会话事件收进提示队列 —— 状态轮询本来就是每个刷新周期一次，
        // 搭车过来不用多一次 XPC 往返。
        if let notices = withState({ $0?.drainNotices() }), !notices.isEmpty {
            appendNotices(notices)
        }
        respond(with: status, reply: reply)
    }

    func queryNetwork(interface: String, reply: @escaping (Data?, String?) -> Void) {
        do {
            respond(with: try NetworkConfigurator.query(interface: interface), reply: reply)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func drainFeed(reply: @escaping (Data?) -> Void) {
        let drained = TetherKitLibrary.drainLogs()
        let notices = takeNotices()
        let feed = HelperFeed(logs: drained.entries, droppedLogs: drained.dropped, notices: notices)
        reply(try? JSONEncoder().encode(feed))
    }

    func setLanguage(_ rawValue: String, reply: @escaping () -> Void) {
        // 认不出来就保持原样。宁可继续用上一种语言，也不要因为 App 传了个新值
        // 就退回默认 —— 那会表现成「切了个语言，helper 的日志反而变回英文」。
        if let language = Language(rawValue: rawValue) {
            L10n.apply(language == .chinese ? .chinese : .english)
            TetherKitLibrary.setLanguage(language)
        }
        reply()
    }

    // MARK: - 需要授权的特权接口

    func startSession(authorization: Data, configuration: Data,
                      reply: @escaping (String?, Bool) -> Void) {
        guard let configuration = decode(SessionConfiguration.self, from: configuration, reply: reply),
              authorize(authorization, reply: reply) else {
            return
        }

        lifecycleQueue.async { [weak self] in
            guard let self else { return }

            // 已经彻底死掉（失败 / 已停）的旧会话不能挡住新的连接。
            //
            // 典型场景：设备被拔掉 → 保活连续失败 → 会话进入 failed。C++ 侧
            // 此时已经把 USB、网卡全部拆干净了，Swift 这层只剩一个壳 —— 但它
            // 非 nil。若只按「session != nil 就拒绝」，用户重插设备后永远
            // 连不上，只能重装 helper。这个坑真实踩过。
            if let existing = self.withState({ $0 }) {
                let state = existing.status().runState
                guard state == .failed || state == .stopped else {
                    reply(L(.helperSessionAlreadyRunning), false)
                    return
                }
                existing.stop()  // 幂等，只是保险
                self.stateLock.withLock { self.session = nil }
            }

            // 从构造到 start() 返回的整个握手期间把「设备已被持有」亮出来，
            // 让并发到来的 listDevices 跳过字符串读取（见那边的说明）。
            self.stateLock.withLock { self.sessionStarting = true }
            defer { self.stateLock.withLock { self.sessionStarting = false } }
            do {
                let session = try TetherKitSession(configuration: configuration)
                try session.start()
                self.stateLock.withLock { self.session = session }
                reply(nil, false)
            } catch {
                reply(error.localizedDescription, false)
            }
        }
    }

    func stopSession(authorization: Data, reply: @escaping (String?, Bool) -> Void) {
        guard authorize(authorization, reply: reply) else { return }

        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            // 先把 session 从状态里摘出来再停：停机要 join 控制线程、可能耗时
            // 数百毫秒，期间不该继续对外声称「会话在运行」。
            let session = self.stateLock.withLock { () -> TetherKitSession? in
                defer { self.session = nil }
                return self.session
            }
            if let iface = session?.systemInterface, !iface.isEmpty {
                try? NetworkConfigurator.clear(interface: iface)
            }
            session?.stop()
            self.appendNotices([L(.helperSessionStopped)])
            reply(nil, false)
        }
    }

    func applyNetwork(authorization: Data, interface: String, configuration: Data,
                      reply: @escaping (String?, Bool) -> Void) {
        guard let configuration = decode(NetworkConfiguration.self, from: configuration, reply: reply),
              authorize(authorization, reply: reply) else {
            return
        }
        // 界面已经校验过一遍，但 XPC 是任何本机进程都能连的，helper 必须自己再挡
        // 一道 —— 而且用的是同一份规则，不会出现两边判断不一致。
        if let message = NetworkValidator.validationMessage(for: configuration) {
            reply(message, false)
            return
        }

        // DHCP 会阻塞到拿到租约（库内部上限 10 秒），所以必须异步回复。
        networkQueue.async { [weak self] in
            do {
                try NetworkConfigurator.apply(configuration, to: interface)
                self?.appendNotices([L(.helperNetworkApplied, configuration.mode.displayName)])
                reply(nil, false)
            } catch {
                reply(error.localizedDescription, false)
            }
        }
    }

    // MARK: - 停机清理

    /// 收到 SIGTERM（`launchctl bootout`）时调用。
    ///
    /// Swift 的 deinit 在进程被终止时不会跑，不主动停一下就会把 feth 网卡漏在
    /// 内核里。落盘登记能兜住 SIGKILL，但能优雅退出时还是该优雅退出 ——
    /// 那样连「下次启动清理」这一步都省了。
    func shutdown() {
        let session = stateLock.withLock { () -> TetherKitSession? in
            defer { self.session = nil }
            return self.session
        }
        if let iface = session?.systemInterface, !iface.isEmpty {
            try? NetworkConfigurator.clear(interface: iface)
        }
        session?.stop()
    }

    // MARK: - 内部工具

    /// 复核授权；不通过时回复错误并把第二个参数置为 true，告诉 App
    /// 「这是授权问题，重新弹框再来一次也许就成了」。
    private func authorize(_ data: Data, reply: @escaping (String?, Bool) -> Void) -> Bool {
        do {
            try AuthorizationVerifier.verify(externalForm: data)
            return true
        } catch {
            reply(error.localizedDescription, true)
            return false
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data,
                                      reply: @escaping (String?, Bool) -> Void) -> T? {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            reply(L(.helperRequestDecodeFailed, error.localizedDescription), false)
            return nil
        }
    }

    private func respond<T: Encodable>(with value: T, reply: (Data?, String?) -> Void) {
        do {
            reply(try JSONEncoder().encode(value), nil)
        } catch {
            reply(nil, L(.helperReplyEncodeFailed, error.localizedDescription))
        }
    }

    private func withState<T>(_ body: (TetherKitSession?) -> T) -> T {
        stateLock.withLock { body(session) }
    }

    private func appendNotices(_ notices: [String]) {
        guard !notices.isEmpty else { return }
        stateLock.withLock {
            pendingNotices.append(contentsOf: notices)
            // 上限 200：App 若长时间不来取（比如被挂起），不该让它无限增长。
            if pendingNotices.count > 200 {
                pendingNotices.removeFirst(pendingNotices.count - 200)
            }
        }
    }

    private func takeNotices() -> [String] {
        stateLock.withLock {
            defer { pendingNotices.removeAll() }
            return pendingNotices
        }
    }
}

/// XPC 监听器代理。
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: HelperService

    init(service: HelperService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // ★ 为什么这里无条件接受 ★
        //
        //   安全性不建立在「谁能连上」，而建立在「每次特权调用都要附带一份用户刚
        //   确认过的授权凭据」。这是刻意的选择：另一条路是校验调用方的代码签名
        //   （SMJobBless 的做法），但那依赖证书的 designated requirement，而源码
        //   分发下每台机器编出的 cdhash 都不同，写死的 DR 必然对不上。
        //
        //   对开源、源码分发的工具，凭据复核是更合适的模型：谁编译的都一样安全。
        connection.exportedInterface = NSXPCInterface(with: TetherKitHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

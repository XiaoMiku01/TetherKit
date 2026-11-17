#include "tetherkit/core/runtime.h"

#include <algorithm>
#include <chrono>
#include <format>
#include <string>
#include <utility>

#include "tetherkit/common/i18n.h"
#include "tetherkit/common/logging.h"
#include "tetherkit/common/scheduling.h"
#include "tetherkit/common/time.h"

namespace tetherkit::core {

std::string_view RunStateName(RunState state) noexcept {
  switch (state) {
    case RunState::kIdle:
      return Text(Msg::kCoreRunStateIdle);
    case RunState::kStarting:
      return Text(Msg::kCoreRunStateStarting);
    case RunState::kRunning:
      return Text(Msg::kCoreRunStateRunning);
    case RunState::kStopping:
      return Text(Msg::kCoreRunStateStopping);
    case RunState::kStopped:
      return Text(Msg::kCoreRunStateStopped);
    case RunState::kFailed:
      return Text(Msg::kCoreRunStateFailed);
  }
  return Text(Msg::kCoreRunStateUnknown);
}

Result<std::unique_ptr<Runtime>> Runtime::Create(const RuntimeConfig& config) {
  auto runtime = std::unique_ptr<Runtime>(new Runtime());
  runtime->config_ = config;
  return runtime;
}

Runtime::~Runtime() {
  Stop();
}

// =============================================================================
// 宿主线程接口
// =============================================================================

Status Runtime::Start() {
  if (started_) {
    return std::unexpected(Error::Generic(Tr(Msg::kCoreRuntimeAlreadyStarted)));
  }

  // root 检查刻意留在**同步**路径上。
  //
  // 它不需要任何 I/O，而「忘了 sudo」是最常见的失败，提前同步报出来，命令行
  // 才能在返回码里体现，也不用让用户盯着一个转圈的界面等异步事件。
  // 注意 libusb 声明 RNDIS 接口**不需要** root（macOS 没有 RNDIS 内核驱动），
  // 需要 root 的是 feth 创建与 /dev/bpf* 打开。
  if (!net::IsRunningAsRoot()) {
    return std::unexpected(Error::Generic(Tr(Msg::kCoreNeedsRoot)));
  }

  started_ = true;
  SetRunState(RunState::kStarting);
  control_thread_ = std::thread([this] { RunControlThread(); });
  return Ok();
}

void Runtime::WaitUntilStopped() {
  if (control_thread_.joinable()) {
    control_thread_.join();
  }
}

void Runtime::Stop() {
  if (stopped_) {
    return;
  }
  stopped_ = true;
  if (!started_) {
    return;
  }

  // 置停机标志并唤醒可能正在睡的控制线程。
  //
  // 标志必须在持锁时写：控制线程的 wait_for 用它当谓词，不持锁写会有
  // 「检查完谓词、还没睡下」的丢失唤醒窗口。RequestStop() 不持锁是刻意的
  // 取舍（它要保持异步信号安全），代价是最多晚一个循环周期被看到。
  {
    const std::lock_guard<std::mutex> guard(stop_mutex_);
    stop_requested_.store(true, std::memory_order_release);
  }
  stop_condition_.notify_all();

  if (control_thread_.joinable()) {
    control_thread_.join();
  }
}

RuntimeSnapshot Runtime::Snapshot() const {
  const std::lock_guard<std::mutex> guard(snapshot_mutex_);
  return snapshot_;
}

std::string Runtime::SystemInterfaceName() const {
  const std::lock_guard<std::mutex> guard(snapshot_mutex_);
  return snapshot_.system_interface;
}

// =============================================================================
// 控制线程
// =============================================================================

void Runtime::RunControlThread() noexcept {
  // 控制线程用 kControl 而非 kDataPath 的 QoS：它每几秒才干一点活，
  // 抢性能核对它没意义，反而可能挤占三个真正的数据路径线程。
  ConfigureCurrentThread("rndis-ctl", ThreadRole::kControl);

  if (const auto status = RunStartSequence(); !status) {
    RecordFatal(status.error());
  } else {
    SetRunState(RunState::kRunning);
    RunControlLoop();
    SetRunState(RunState::kStopping);
  }

  // 无论启动成功与否都要拆除：启动序列可能已经建了半套东西（比如 feth 建好了
  // 但 BPF 打不开），漏掉就会把网卡留在内核里。
  Teardown();

  SetRunState(fatal_error_.load(std::memory_order_acquire) ? RunState::kFailed
                                                           : RunState::kStopped);
}

Status Runtime::RunStartSequence() {
  // ---- 第 1 步：libusb 上下文与事件线程 ----
  //
  // （root 检查已在 Start() 里同步做过。）
  TETHERKIT_ASSIGN_OR_RETURN(usb_context_, usb::Context::Create());

  // ---- 第 2 步：发现并打开设备 ----
  TETHERKIT_ASSIGN_OR_RETURN(const auto candidates,
                             usb::FindRndisDevices(*usb_context_, config_.device_filter));
  if (candidates.empty()) {
    return std::unexpected(Error::Generic(Tr(Msg::kCoreNoDeviceFound)));
  }
  if (candidates.size() > 1) {
    TETHERKIT_INFO_TR(Msg::kCoreMultipleDevices, candidates.size());
  }
  TETHERKIT_ASSIGN_OR_RETURN(device_, usb::Device::Open(*usb_context_, candidates.front()));
  RefreshSnapshot();

  // ---- 第 3 步：RNDIS 控制通道与状态机 ----
  //
  // 控制通道用同步 libusb API，因此必须跑在**非事件线程**上 —— 本函数就在
  // Runtime 自己的控制线程上，满足要求。
  control_channel_ =
      std::make_unique<usb::UsbControlChannel>(*device_, config_.rndis.control_timeout_millis);

  // 中断通知必须走异步传输，否则控制线程会永久卡死 —— 详见
  // include/tetherkit/usb/device.h 里 UsbControlChannel 的说明。
  // 必须在状态机 Start() **之前**启动，因为初始化握手本身就要等通知。
  TETHERKIT_RETURN_IF_ERROR(control_channel_->StartNotificationListener());

  // 让 RNDIS 协商用上真实的端点最大包长（影响 MaxTransferSize 的推导）。
  rndis::StateMachineConfig rndis_config = config_.rndis;
  rndis_config.requested_mtu = config_.mtu;
  state_machine_ = std::make_unique<rndis::StateMachine>(*control_channel_, *this, rndis_config);

  TETHERKIT_RETURN_IF_ERROR(state_machine_->Start());

  // 到这里才拿到了协商结果：设备 MAC、最终 MTU、聚合上限、对齐要求。
  const rndis::NegotiatedParameters& parameters = state_machine_->Parameters();
  const rndis::DeviceInfo& info = state_machine_->Info();

  // ---- 第 4 步：创建 feth 网卡对 ----
  //
  // 必须在协商之后：系统侧 MAC 要设成设备汇报的地址，MTU 要用协商结果，
  // 而 MAC 又必须在接口 IFF_UP 之前设好。
  {
    const net::MacAddress* system_mac = nullptr;
    net::MacAddress adopted{};
    if (config_.adopt_device_mac && info.has_permanent_address) {
      std::ranges::copy(info.permanent_address, adopted.begin());
      system_mac = &adopted;
    }
    TETHERKIT_ASSIGN_OR_RETURN(auto pair, net::FethPair::Create(parameters.mtu, system_mac));
    feth_pair_ = std::make_unique<net::FethPair>(std::move(pair));
  }
  // 网卡一建好就刷进快照：后面任何一步失败时，GUI 也该能看到网卡名，
  // 否则用户连「刚才建了哪张卡」都不知道。
  RefreshSnapshot();

  // ---- 第 5 步：在**驱动侧**接口上打开 BPF ----
  //
  // 挂驱动侧而不是系统侧，是因为主机从系统侧发出的帧在驱动侧表现为 input 方向，
  // 而我们 write 进驱动侧的帧会进入系统侧的 input —— 一个描述符同时完成收发。
  {
    net::BpfConfig bpf_config = config_.bpf;
    // 单帧上限 = MTU + 以太头。注意内核 bpfwrite 的硬上限是 MTU + 18，
    // 所以这里绝不能超过它。
    bpf_config.max_frame_bytes = parameters.mtu + rndis::kEthernetHeaderBytes;
    TETHERKIT_ASSIGN_OR_RETURN(bpf_link_,
                               net::BpfLink::Open(feth_pair_->DriverSide().Name(), bpf_config));
  }

  // ---- 第 6 步：创建 USB 数据通道 ----
  {
    usb::DataChannelConfig data_config = config_.data_channel;
    // bulk IN 缓冲必须 >= 我们在 INITIALIZE_MSG 里宣称的 MaxTransferSize，
    // 否则设备聚合出来的大传输会溢出/被截断。
    data_config.rx_transfer_bytes =
        std::max(data_config.rx_transfer_bytes, config_.rndis.host_max_transfer_size);
    TETHERKIT_ASSIGN_OR_RETURN(data_channel_,
                               usb::UsbDataChannel::Create(*device_, parameters, data_config));
  }

  // ---- 第 7 步：启动桥接层 ----
  {
    BridgeConfig bridge_config = config_.bridge;
    bridge_config.max_frame_bytes = parameters.mtu + rndis::kEthernetHeaderBytes;
    bridge_ = std::make_unique<Bridge>(*data_channel_, *bpf_link_, bridge_config);
    TETHERKIT_RETURN_IF_ERROR(bridge_->Start());
  }

  RefreshSnapshot();
  PrintNextSteps();
  return Ok();
}

void Runtime::RunControlLoop() {
  BridgeStats previous = bridge_->Snapshot();
  Nanos last_stats_nanos = MonotonicNanos();
  std::uint32_t consecutive_idle_reports = 0;

  const Nanos stats_interval_nanos =
      static_cast<Nanos>(config_.stats_interval_millis) * kNanosPerMilli;

  while (!stop_requested_.load(std::memory_order_acquire) &&
         !fatal_error_.load(std::memory_order_acquire)) {
    // ---- 状态机的周期性工作：保活 + 排空设备推送的消息 ----
    if (const auto status = state_machine_->Poll(); !status) {
      RecordFatal(std::move(status).error());
      break;
    }

    // ---- 刷新快照 ----
    //
    // 放在每一轮循环里而不是只在事件发生时刷：统计计数器是持续变化的，
    // GUI 要靠两次快照做差算速率。循环周期上限 250 ms，足够 2 Hz 的界面刷新。
    RefreshSnapshot();

    // ---- 周期性统计 ----
    const Nanos now = MonotonicNanos();
    if (stats_interval_nanos != 0 && now - last_stats_nanos >= stats_interval_nanos) {
      const BridgeStats current = bridge_->Snapshot();
      const double seconds =
          static_cast<double>(now - last_stats_nanos) / static_cast<double>(kNanosPerSecond);
      const DirectionSnapshot rx_delta = current.rx - previous.rx;
      const DirectionSnapshot tx_delta = current.tx - previous.tx;
      const bool is_idle = (rx_delta.frames == 0 && tx_delta.frames == 0 &&
                            rx_delta.TotalDropped() == 0 && tx_delta.TotalDropped() == 0 &&
                            current.link_kernel_drops == previous.link_kernel_drops &&
                            current.tx_backpressure_events == previous.tx_backpressure_events);
      if (is_idle) {
        // 空闲期抑制高频刷屏：只在刚进入空闲时报告一次，之后每 12 个周期（约 60 秒）打一次心跳。
        ++consecutive_idle_reports;
        if (consecutive_idle_reports == 1 || consecutive_idle_reports % 12 == 0) {
          TETHERKIT_INFO("{}", FormatStatsLine(previous, current, seconds));
        }
      } else {
        consecutive_idle_reports = 0;
        TETHERKIT_INFO("{}", FormatStatsLine(previous, current, seconds));
      }
      previous = current;
      last_stats_nanos = now;
    }

    // ---- 睡到下一个该醒的时刻 ----
    //
    // 取「下次保活」与「下次统计」两个期限里更近的那个，避免无谓的唤醒。
    // 上限 250 ms 是为了让只写原子的 RequestStop() 也能被及时看到。
    std::uint32_t sleep_millis =
        std::min<std::uint32_t>(state_machine_->MillisUntilNextPoll(), 250);
    if (stats_interval_nanos != 0) {
      const Nanos elapsed = now - last_stats_nanos;
      const Nanos remaining = elapsed >= stats_interval_nanos ? 0 : stats_interval_nanos - elapsed;
      sleep_millis = std::min<std::uint32_t>(sleep_millis,
                                             static_cast<std::uint32_t>(remaining / kNanosPerMilli));
    }
    // 至少睡 10 ms：避免在保活刚好到期的边界上忙转。
    sleep_millis = std::max<std::uint32_t>(sleep_millis, 10);

    // 用条件变量而不是 sleep_for：Stop() 能立刻把我们叫醒，用户按下「停止」
    // 不用等最多 250 ms 才有反应。
    std::unique_lock<std::mutex> lock(stop_mutex_);
    stop_condition_.wait_for(lock, std::chrono::milliseconds(sleep_millis),
                             [this] { return stop_requested_.load(std::memory_order_acquire); });
  }

  if (fatal_error_.load(std::memory_order_acquire)) {
    TETHERKIT_ERROR_TR(Msg::kCoreExitingOnFatal);
  }
}

void Runtime::PrintNextSteps() const {
  const std::string_view name = feth_pair_->SystemSide().Name();
  TETHERKIT_INFO("");
  TETHERKIT_INFO_TR(Msg::kCoreInterfaceReady, name);
  TETHERKIT_INFO_TR(Msg::kCoreNextStepsAssignIp);
  TETHERKIT_INFO("    sudo ipconfig set {} DHCP", name);
  TETHERKIT_INFO_TR(Msg::kCoreNextStepsVerify);
  TETHERKIT_INFO("    ipconfig getifaddr {}", name);
  TETHERKIT_INFO("    ipconfig getsummary {}", name);
  TETHERKIT_INFO_TR(Msg::kCoreNextStepsDefaultRoute);
  TETHERKIT_INFO("    sudo route -n change default $(ipconfig getoption {} router)", name);
  TETHERKIT_INFO_TR(Msg::kCoreNextStepsTemporaryNote1);
  TETHERKIT_INFO_TR(Msg::kCoreNextStepsTemporaryNote2);
  TETHERKIT_INFO("");
}

// =============================================================================
// 停机
// =============================================================================

void Runtime::Teardown() {
  TETHERKIT_INFO_TR(Msg::kCoreStopping);

  // 严格按启动顺序的**逆序**拆除。
  //
  // 1. 先停桥接层：它内部会 join 两个数据路径线程，然后调
  //    DataChannel::Shutdown() 等在飞 USB 传输全部回收。这一步必须在销毁
  //    device_ 之前完成 —— libusb_close 不会帮我们回收在飞 transfer，
  //    先关句柄再释放 transfer 就是 use-after-free。
  if (bridge_ != nullptr) {
    bridge_->Stop();
    bridge_.reset();
  }
  data_channel_.reset();

  // 2. 关 BPF（此时已经没人在读写它了）。
  bpf_link_.reset();

  // 3. 销毁 feth 网卡对。内核的 feth_clone_destroy 会自动先解绑 peer。
  feth_pair_.reset();

  // 4. 让设备退出 RNDIS：先 SET filter = 0 让它停止发数据，再发 HALT。
  //    必须在关闭 USB 句柄之前做 —— 否则设备会一直以为主机还在，
  //    下次插上时状态不干净。
  //
  //    这一步会发同步控制消息，因此必须在控制线程上 —— 本函数正是。
  if (state_machine_ != nullptr) {
    state_machine_->Stop();
    state_machine_.reset();
  }
  // 先停中断监听（它会等在飞的异步 transfer 回收完），再销毁通道对象。
  if (control_channel_ != nullptr) {
    control_channel_->StopNotificationListener();
    control_channel_.reset();
  }

  // 5. 释放接口并关闭设备句柄。
  device_.reset();

  // 6. 最后停 libusb 事件线程并释放上下文。
  usb_context_.reset();

  // 拆完再刷一次：网卡名、统计都该归零，GUI 不该继续显示已经不存在的网卡。
  // link_up 由事件维护、RefreshSnapshot 不会动它，所以在这里显式清掉 ——
  // 停机后界面上还亮着「链路已连接」会误导人。
  {
    const std::lock_guard<std::mutex> guard(snapshot_mutex_);
    snapshot_.link_up = false;
  }
  RefreshSnapshot();
  TETHERKIT_INFO_TR(Msg::kCoreStopped);
}

// =============================================================================
// 快照与事件
// =============================================================================

void Runtime::RefreshSnapshot() {
  // 先在锁外把各组件的状况读出来 —— 这些读取会走 ioctl / 原子加载，
  // 不该占着 snapshot_mutex_。
  RuntimeSnapshot fresh;
  if (device_ != nullptr) {
    fresh.device_description = std::string{device_->Describe()};
  }
  if (state_machine_ != nullptr) {
    fresh.rndis_state = state_machine_->CurrentState();
    fresh.device_info = state_machine_->Info();
    fresh.parameters = state_machine_->Parameters();
  }
  if (feth_pair_ != nullptr) {
    fresh.system_interface = std::string{feth_pair_->SystemSide().Name()};
    fresh.driver_interface = std::string{feth_pair_->DriverSide().Name()};
  }
  if (bridge_ != nullptr) {
    fresh.bridge = bridge_->Snapshot();
    fresh.paused = bridge_->Paused();
  }

  const std::lock_guard<std::mutex> guard(snapshot_mutex_);
  // run_state、link_up 与 fatal_message 由各自的迁移点维护，这里不能覆盖。
  fresh.run_state = snapshot_.run_state;
  fresh.link_up = snapshot_.link_up;
  fresh.fatal_message = snapshot_.fatal_message;
  snapshot_ = std::move(fresh);
}

void Runtime::SetRunState(RunState next) {
  RunState previous = RunState::kIdle;
  {
    const std::lock_guard<std::mutex> guard(snapshot_mutex_);
    previous = snapshot_.run_state;
    if (previous == next) {
      return;
    }
    snapshot_.run_state = next;
  }
  Emit(RuntimeEvent{.kind = RuntimeEvent::Kind::kRunState,
                    .a = static_cast<std::int64_t>(previous),
                    .b = static_cast<std::int64_t>(next),
                    .text = std::string{RunStateName(next)}});
}

void Runtime::RecordFatal(const Error& error) {
  const std::string message = error.ToString();
  TETHERKIT_ERROR("{}", message);

  {
    const std::lock_guard<std::mutex> guard(snapshot_mutex_);
    // 只记**第一个**致命错误：后续的多半是它引发的连锁反应，覆盖掉反而丢了根因。
    if (snapshot_.fatal_message.empty()) {
      snapshot_.fatal_message = message;
    }
  }
  fatal_error_.store(true, std::memory_order_release);
  Emit(RuntimeEvent{.kind = RuntimeEvent::Kind::kFatal, .text = message});
}

void Runtime::Emit(const RuntimeEvent& event) const {
  if (config_.event_sink != nullptr) {
    config_.event_sink->OnRuntimeEvent(event);
  }
}

// =============================================================================
// StateMachineObserver（均在控制线程上被调用）
// =============================================================================

void Runtime::OnStateChanged(rndis::State from, rndis::State to) {
  // 状态机自己已经打了日志，这里不重复，只把迁移转发给宿主。
  Emit(RuntimeEvent{.kind = RuntimeEvent::Kind::kRndisState,
                    .a = static_cast<std::int64_t>(from),
                    .b = static_cast<std::int64_t>(to),
                    .text = std::string{rndis::StateName(to)}});
}

void Runtime::OnNegotiated(const rndis::NegotiatedParameters& parameters,
                           const rndis::DeviceInfo& info) {
  TETHERKIT_INFO_TR(Msg::kCoreRndisReady, rndis::FormatMac(info.permanent_address).data(),
                    parameters.mtu, info.LinkSpeedMbps());

  Emit(RuntimeEvent{.kind = RuntimeEvent::Kind::kNegotiated,
                    .a = static_cast<std::int64_t>(parameters.mtu),
                    .b = static_cast<std::int64_t>(info.LinkSpeedMbps()),
                    .text = info.vendor_description});
}

void Runtime::OnLinkStateChanged(bool connected) {
  TETHERKIT_INFO_TR(Msg::kCoreLinkState,
                    Text(connected ? Msg::kCoreLinkConnected : Msg::kCoreLinkDisconnected));

  {
    const std::lock_guard<std::mutex> guard(snapshot_mutex_);
    snapshot_.link_up = connected;
  }

  // 链路 down 时暂停数据搬运。继续往断开的链路发帧只是浪费，而且会把队列填满
  // 导致真正恢复时先送出一堆过期的帧。
  if (bridge_ != nullptr) {
    bridge_->SetPaused(!connected);
  }

  Emit(RuntimeEvent{.kind = RuntimeEvent::Kind::kLink, .a = connected ? 1 : 0});
}

void Runtime::OnDeviceReset(bool addressing_lost) {
  TETHERKIT_WARN_TR(Msg::kCoreDeviceReset,
                    Text(addressing_lost ? Msg::kCoreAddressingLost : Msg::kCoreAddressingKept));

  // 复位期间设备丢弃了所有未完成的数据包。短暂暂停让状态机把包过滤重放完，
  // 避免在设备重建内部状态的窗口里继续灌数据。
  if (bridge_ != nullptr) {
    bridge_->SetPaused(true);
    bridge_->SetPaused(false);
  }

  Emit(RuntimeEvent{.kind = RuntimeEvent::Kind::kDeviceReset, .a = addressing_lost ? 1 : 0});
}

void Runtime::OnFatalError(const Error& error) {
  // WithContext 是 &&-限定的，而这里拿到的是 const 引用，必须先拷一份。
  Error annotated = error;
  RecordFatal(std::move(annotated).WithContext(Tr(Msg::kCoreLinkUnrecoverable)));
}

}  // namespace tetherkit::core

// 数据路径桥接：把 RNDIS 数据通道与 feth/BPF 链路对接起来。
//
// ★ 线程模型（本文件最重要的设计决定）★
//
//   ┌─────────────────────────────────────────────────────────────────────┐
//   │ RX 方向（设备 → 主机）                                               │
//   │                                                                     │
//   │  libusb 事件线程                        RX 注入线程                  │
//   │  ───────────────                        ───────────                  │
//   │  handle_events()                        BatchRead 取一批帧            │
//   │   └→ bulk IN 回调                  ┌──►  └→ LinkBackend::WriteFrames │
//   │       ├ 拆 RNDIS 包               │        （一次系统调用发整批）     │
//   │       ├ BatchWrite 进 FrameRing ──┘                                  │
//   │       └ 立刻 resubmit                                                │
//   └─────────────────────────────────────────────────────────────────────┘
//   ┌─────────────────────────────────────────────────────────────────────┐
//   │ TX 方向（主机 → 设备）                                               │
//   │                                                                     │
//   │  TX 抽取线程                                                         │
//   │  ───────────                                                         │
//   │  LinkBackend::ReadFrames()（阻塞，内核自动聚合成批）                  │
//   │   └→ DataChannel::SendFrames（聚合成 RNDIS 多包，异步提交 bulk OUT）  │
//   └─────────────────────────────────────────────────────────────────────┘
//
//   一共三个数据路径线程（外加 libusb 自己的 IOKit runloop 线程与状态机的控制
//   线程）。本机是 4 性能核 + 6 效率核，三个热线程 + libusb 的 runloop 线程刚好
//   占满性能核集群且不过订阅。
//
//   为什么 RX 必须拆成两个线程？
//     libusb 的 transfer 回调持有 ctx->event_waiters_lock，回调里做阻塞 I/O 会
//     把所有等同步传输的线程（包括跑控制通道的状态机线程）一起拖住。而 BPF 的
//     write() 是系统调用（macOS 上约 660 ns 起，批量写更久）。所以回调只做
//     「拆包 + memcpy 进无锁队列 + 立刻 resubmit」，真正的写出交给注入线程。
//
//   为什么 TX 只需要一个线程？
//     BPF 的 read() 本身就是阻塞并自动聚合的（BIOCIMMEDIATE=1 下每来一包就唤醒，
//     醒来时一次性交付期间累积的全部包），而 SendFrames 是**异步**提交，不阻塞。
//     所以「读一批 → 提交一批」在同一个线程里就是最优形态，多一个线程只会多一次
//     跨核队列传递。
//
//   为什么不用单个 kqueue 事件循环把三件事合起来？
//     实测 macOS 上一次空的 kevent()（timeout={0,0}、无事件）要 13.4~13.7 µs，
//     比普通系统调用贵 20 倍。25 kpps 下光探测就要花掉 34% 的单核。kqueue 只能
//     用于真正的阻塞等待，绝不能用于轮询 —— 而我们的三条路径各自都已经有天然的
//     阻塞点，合并没有收益。
#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <thread>
#include <vector>

#include "tetherkit/common/error.h"
#include "tetherkit/common/frame_ring.h"
#include "tetherkit/common/stats.h"
#include "tetherkit/net/link_backend.h"
#include "tetherkit/usb/data_channel.h"

namespace tetherkit::core {

/// 桥接层配置。
struct BridgeConfig {
  /// RX 队列容量（帧数）。
  ///
  /// 容量推导：要缓冲住「libusb 回调突发」与「BPF 写线程被调度延迟」之间的错配。
  /// 按最坏 10 ms 调度延迟、1 Gbps 满速（82 k pps）计需要约 820 帧；取 2048 留
  /// 2.5 倍余量。每槽 2048+128 字节，2048 槽约 4.25 MiB。
  std::size_t rx_ring_frames = 2048;

  /// 单帧上限（含以太头）。应与 feth 的 MTU + 14 一致。
  std::uint32_t max_frame_bytes = 1518;

  /// RX 注入线程一次最多攒多少帧再写出。
  ///
  /// 批量写能把「一次 write() 的系统调用成本」摊薄到每帧；实测收益在 batch≥8
  /// 就基本饱和，但更大的批在突发时能进一步降低系统调用次数。取 64 兼顾两者：
  /// 空闲时批很小（延迟低），突发时自动变大（吞吐高）。
  std::uint32_t rx_write_batch = 64;

  /// RX 队列空时自旋多少次再让出 CPU。
  ///
  /// 纯自旋会白烧一个核；直接 yield 又会在高吞吐下增加延迟。少量自旋能覆盖
  /// 「生产者正在写下一帧」这种极短的空窗。
  std::uint32_t rx_spin_before_yield = 64;

  /// RX 队列空时让出 CPU（yield）的轮数，之后转入微秒级睡眠，避免在 Darwin/POSIX
  /// 上因 sched_yield 立即返回而导致空闲时单核 100% 忙轮询。
  std::uint32_t rx_yield_before_sleep = 16;

  /// RX 队列持续为空时的睡眠微秒数。默认 250 微秒，兼顾零 CPU 消耗与亚毫秒级唤醒延迟。
  std::uint32_t rx_idle_sleep_micros = 250;

  /// TX 方向单批最多提交多少帧给 USB。
  std::uint32_t tx_submit_batch = 256;

  /// 统计报告周期（毫秒）；0 表示不周期性报告。
  std::uint32_t stats_interval_millis = 0;
};

/// 桥接层运行时的可观测快照。
struct BridgeStats {
  DirectionSnapshot rx;
  DirectionSnapshot tx;
  /// RX 队列当前深度，用于判断哪一侧是瓶颈。
  std::size_t rx_queue_depth = 0;
  /// 内核 BPF 侧累计丢包（bs_drop）。
  std::uint64_t link_kernel_drops = 0;
  /// TX 因传输池没有空闲槽位而进入等待的次数。
  ///
  /// 这是**事件**计数不是帧数：每次 SendFrames 一帧都没能提交、TX 线程转入
  /// 等待就 +1（持续压力下每约 50 ms 至多再 +1）。它衡量「TX 侧顶到池上限的
  /// 频繁程度」；出现它不代表丢帧 —— 等待期间帧安然留在批次里，上游突发由
  /// 内核 BPF 缓冲吸收，真溢出会体现在 link_kernel_drops。
  std::uint64_t tx_backpressure_events = 0;
};

/// 数据路径桥接。
///
/// 生命周期：Create → Start → （运行）→ Stop。Stop 是幂等的，析构会兜底调用。
class Bridge {
 public:
  Bridge(usb::DataChannel& data_channel, net::LinkBackend& link, const BridgeConfig& config);

  Bridge(const Bridge&) = delete;
  Bridge& operator=(const Bridge&) = delete;
  Bridge(Bridge&&) = delete;
  Bridge& operator=(Bridge&&) = delete;

  ~Bridge();

  /// 启动数据路径。
  [[nodiscard]] Status Start();

  /// 停止数据路径。
  ///
  /// 拆除顺序是刻意安排的，见实现里的注释 —— 顺序错了会漏帧或者死锁。
  void Stop();

  [[nodiscard]] bool Running() const noexcept {
    return running_.load(std::memory_order_acquire);
  }

  [[nodiscard]] BridgeStats Snapshot() const;

  /// RX 方向的计数器。数据通道的接收回调直接写它。
  [[nodiscard]] DirectionCounters& RxCounters() noexcept { return counters_.rx; }

  /// 暂停 / 恢复数据搬运。
  ///
  /// 用于 RNDIS 软复位期间：设备会丢弃所有未完成的数据包，这期间继续往它发帧
  /// 只是浪费，而且可能撞上设备重建内部状态的窗口。
  ///
  /// `SetPaused(true)` 是**同步**的：返回后保证 RX 注入线程已经停在暂停分支上，
  /// 既不会再碰 rx_ring_、也不会再往链路写帧。
  ///
  /// 这个同步是必需的，光靠标志位给不了保证：worker 可能刚过完标志检查、正准备
  /// 把一批取出的帧写出去，调用方却以为已经停了。曾经就是这样漏过一个
  /// rx_write_batch（16 帧）出去。
  ///
  /// TX 方向拿不到同样强的保证 —— 它必须持续把 BPF 读空，否则内核缓冲会堆满
  /// 转成内核侧丢包。暂停期间它改为读出即丢弃，并在每个提交分片前重新检查，
  /// 因此本函数返回后最多只可能有一个已在途的分片继续提交完。
  ///
  /// ⚠️ 不可从 RX/TX 工作线程内部调用 —— 会自等死锁。现有调用方都在控制路径上
  /// （链路状态变化、设备软复位），满足这个前提。
  void SetPaused(bool paused) noexcept;

  [[nodiscard]] bool Paused() const noexcept { return paused_.load(std::memory_order_acquire); }

 private:
  /// RX 注入线程：从 FrameRing 取帧批量写入链路。
  void RunReceiveInjector() noexcept;

  /// TX 抽取线程：从链路读帧批量提交给 USB。
  void RunTransmitExtractor() noexcept;

  usb::DataChannel* data_channel_;
  net::LinkBackend* link_;
  BridgeConfig config_;

  /// RX 队列：libusb 事件线程（生产者）→ RX 注入线程（消费者）。
  std::unique_ptr<FrameRing> rx_ring_;

  PathCounters counters_;
  std::atomic<std::uint64_t> tx_backpressure_events_{0};
  std::atomic<std::uint64_t> link_kernel_drops_{0};

  std::thread receive_injector_;
  std::thread transmit_extractor_;

  std::atomic<bool> running_{false};
  std::atomic<bool> stop_requested_{false};
  std::atomic<bool> paused_{false};

  /// RX 注入线程对 paused_ 的确认位，SetPaused(true) 等的就是它。
  ///
  /// 由 RX 注入线程**独占写入**：每轮循环开头先清零、确认停住后再置位。
  /// 每轮都清零是关键 —— 否则 SetPaused(false) 紧接 SetPaused(true) 时，
  /// 后者可能读到上一轮残留的 true 就直接返回，保证当场失效。
  std::atomic<bool> rx_paused_ack_{false};

  /// RX 注入线程复用的帧视图数组，避免每批都分配。
  std::vector<FrameView> rx_batch_;
};

/// 把统计快照渲染成一行人类可读的文本。
[[nodiscard]] std::string FormatStatsLine(const BridgeStats& previous, const BridgeStats& current,
                                          double seconds);

}  // namespace tetherkit::core

#include "tetherkit/core/bridge.h"

#include <algorithm>
#include <chrono>
#include <format>
#include <thread>

#include "tetherkit/common/i18n.h"
#include "tetherkit/common/logging.h"
#include "tetherkit/common/scheduling.h"

namespace tetherkit::core {
namespace {

/// TX 背压时单次等待空闲传输槽位的上限（毫秒）。
///
/// 取值只影响两件事的权衡：停机/暂停的响应延迟上界（每次醒来都会重查标志），
/// 与等待期间的无谓唤醒频率。槽位实际的释放周期是几百微秒（一次 bulk OUT 的
/// 完成时间），绝大多数等待都由完成回调的 notify 提前唤醒，几乎不会等满。
constexpr std::uint32_t kTxCapacityWaitMillis = 50;

/// 把字节数换算成 Mbps。
[[nodiscard]] double ToMegabitsPerSecond(std::uint64_t bytes, double seconds) {
  if (seconds <= 0.0) {
    return 0.0;
  }
  return static_cast<double>(bytes) * 8.0 / 1'000'000.0 / seconds;
}

[[nodiscard]] double ToPacketsPerSecond(std::uint64_t frames, double seconds) {
  if (seconds <= 0.0) {
    return 0.0;
  }
  return static_cast<double>(frames) / seconds;
}

}  // namespace

Bridge::Bridge(usb::DataChannel& data_channel, net::LinkBackend& link,
               const BridgeConfig& config)
    : data_channel_(&data_channel), link_(&link), config_(config) {
  rx_ring_ = std::make_unique<FrameRing>(config_.rx_ring_frames, config_.max_frame_bytes);
  rx_batch_.reserve(config_.rx_write_batch);
}

Bridge::~Bridge() {
  Stop();
}

Status Bridge::Start() {
  if (running_.load(std::memory_order_acquire)) {
    return std::unexpected(Error::Generic(Tr(Msg::kCoreBridgeAlreadyRunning)));
  }
  stop_requested_.store(false, std::memory_order_release);

  // 先让数据通道开始接收 —— 它会把帧推进 rx_ring_。
  // 顺序上必须在启动注入线程**之前**还是之后都可以（队列是有界的，满了会丢弃
  // 并计数），但先开接收能让链路一就绪就开始收，少丢几帧。
  TETHERKIT_RETURN_IF_ERROR(data_channel_->StartReceiving(*rx_ring_, counters_.rx));

  running_.store(true, std::memory_order_release);
  receive_injector_ = std::thread([this] { RunReceiveInjector(); });
  transmit_extractor_ = std::thread([this] { RunTransmitExtractor(); });

  TETHERKIT_INFO_TR(Msg::kCoreDataPathStarted, rx_ring_->Capacity(),
                    rx_ring_->StorageBytes() / 1024, config_.rx_write_batch,
                    config_.tx_submit_batch,
                    Text(link_->SupportsBatchWrite() ? Msg::kCoreBatchWriteAvailable
                                                     : Msg::kCoreBatchWriteUnavailable));
  return Ok();
}

void Bridge::Stop() {
  if (!running_.exchange(false, std::memory_order_acq_rel)) {
    return;  // 没在跑或已经停过
  }

  // ---------------------------------------------------------------------------
  // 拆除顺序（顺序错了会漏帧或死锁）
  //
  //  1. 置停机标志 —— 两个线程的循环条件都看它；
  //  2. 打断链路的阻塞 read() —— 否则 TX 抽取线程会一直卡在里面；
  //  3. join 两个数据路径线程；
  //  4. **最后**才停数据通道。
  //
  // 第 4 步必须最后做，原因有两个：
  //   * DataChannel::Shutdown() 要等在飞 USB 传输的回调全部回来，而那些回调会
  //     往 rx_ring_ 里写 —— 如果先停通道再 join，倒也没错；但反过来若先销毁了
  //     rx_ring_ 就是 use-after-free。这里的顺序保证 rx_ring_ 一直活着。
  //   * Shutdown() 绝不能在 libusb 事件线程上调用（会自己等自己死锁），
  //     而这里是调用 Stop() 的那个线程（主线程或控制线程），安全。
  // ---------------------------------------------------------------------------
  stop_requested_.store(true, std::memory_order_release);
  rx_ring_->WakeConsumer();

  link_->Interrupt();

  if (receive_injector_.joinable()) {
    receive_injector_.join();
  }
  if (transmit_extractor_.joinable()) {
    transmit_extractor_.join();
  }

  data_channel_->Shutdown();

  TETHERKIT_INFO_TR(Msg::kCoreDataPathStopped);
}

// =============================================================================
// RX 注入线程：FrameRing → 链路
// =============================================================================

void Bridge::SetPaused(bool paused) noexcept {
  paused_.store(paused, std::memory_order_release);
  rx_ring_->WakeConsumer();
  if (!paused) {
    return;
  }

  // 等 RX 注入线程确认它确实停住了。没有这一步，本函数返回之后 worker 仍可能
  // 把一批已经取出的帧写到链路上：它可能刚过完上面那个标志检查。
  //
  // 只在线程确实在跑的时候等 —— Start() 之前或 Stop() 之后没人会来置位，
  // 无条件等会永远不返回。
  while (running_.load(std::memory_order_acquire) &&
         !stop_requested_.load(std::memory_order_acquire) &&
         !rx_paused_ack_.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }
}

void Bridge::RunReceiveInjector() noexcept {
  ConfigureCurrentThread("rx-inject", ThreadRole::kDataPath);
  TETHERKIT_DEBUG_TR(Msg::kCoreRxInjectorStarted);

  std::uint32_t idle_spins = 0;

  while (!stop_requested_.load(std::memory_order_acquire)) {
    // 先撤销确认位，再判断是否暂停。顺序不能反 —— 留着上一轮的 true 会让
    // SetPaused(true) 误以为本线程已经停住，而它其实正要去取帧。
    rx_paused_ack_.store(false, std::memory_order_release);

    if (paused_.load(std::memory_order_acquire)) {
      // 复位期间：不搬运，但也不丢弃 —— 队列里的帧等恢复后继续发。
      //
      // 置确认位是给 SetPaused(true) 看的：从这里到下一轮看见 paused_ 变回
      // false 之前，本线程不会碰 rx_ring_，所以这个确认是可信的。
      rx_paused_ack_.store(true, std::memory_order_release);
      const std::uint64_t ticket = rx_ring_->ConsumerTicket();
      if (paused_.load(std::memory_order_acquire) &&
          !stop_requested_.load(std::memory_order_acquire)) {
        rx_ring_->WaitForConsumerChange(ticket);
      }
      continue;
    }

    // 攒一批再写。批量会话在作用域结束时才一次性释放槽位，因此期间取出的
    // 全部视图都保持有效 —— 这正是「零拷贝交给一次批量 write()」的前提。
    rx_batch_.clear();
    const std::uint64_t idle_ticket = rx_ring_->ConsumerTicket();
    {
      auto batch = rx_ring_->BeginBatchRead();
      while (rx_batch_.size() < config_.rx_write_batch) {
        const FrameView view = batch.Next();
        if (view.Empty()) {
          break;
        }
        rx_batch_.push_back(view);
      }

      if (rx_batch_.empty()) {
        // 队列空时只短暂自旋以覆盖相邻帧的间隙；长期空闲就原子等待生产者通知。
        if (++idle_spins < config_.rx_spin_before_yield) {
          continue;
        }
        idle_spins = 0;
        if (!stop_requested_.load(std::memory_order_acquire) &&
            !paused_.load(std::memory_order_acquire)) {
          rx_ring_->WaitForConsumerChange(idle_ticket);
        }
        continue;
      }
      idle_spins = 0;

      const auto result = link_->WriteFrames(rx_batch_);
      if (!result) {
        counters_.rx.AddIoError();
        TETHERKIT_WARN_TR(Msg::kCoreLinkWriteFailed, rx_batch_.size(),
                          result.error().ToString());
        // 写失败不退出线程 —— 可能只是接口暂时 down。批量会话照常释放槽位
        // （帧已经没法送出去了，留着只会堵住队列）。
      } else {
        if (result->frames_skipped != 0) {
          counters_.rx.AddDroppedOversize(result->frames_skipped);
        }
        const auto written = result->frames_written;
        if (written < rx_batch_.size()) {
          // 链路没吃下整批（内核发送队列满）。剩下的帧已经从队列里取出来了，
          // 只能丢弃并计数 —— 这是真实的丢包，必须让运维看得见。
          counters_.rx.AddDroppedFull(rx_batch_.size() - written);
        }
        // 注意：内核侧的 bs_drop 是**读**方向的统计，由 TX 抽取线程从
        // ReadFrames 的结果里更新，这里不碰它。
      }
    }  // 批量会话析构 → 一次 PublishRead(n)
  }

  TETHERKIT_DEBUG_TR(Msg::kCoreRxInjectorExited);
}

// =============================================================================
// TX 抽取线程：链路 → USB
// =============================================================================

void Bridge::RunTransmitExtractor() noexcept {
  ConfigureCurrentThread("tx-extract", ThreadRole::kDataPath);
  TETHERKIT_DEBUG_TR(Msg::kCoreTxExtractorStarted);

  while (!stop_requested_.load(std::memory_order_acquire)) {
    // 阻塞读。BPF 在 BIOCIMMEDIATE=1 下会自动把期间累积的包整批交付，
    // 所以这里天然就是「低速低延迟、高速大批量」，不需要我们自己攒批。
    const auto batch = link_->ReadFrames();
    if (!batch) {
      counters_.tx.AddIoError();
      TETHERKIT_WARN_TR(Msg::kCoreLinkReadFailed, batch.error().ToString());
      // 读失败可能是接口被拆了。稍等再试，避免忙循环刷日志。
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
      continue;
    }

    link_kernel_drops_.store(batch->kernel_drops, std::memory_order_relaxed);

    if (batch->frames.empty()) {
      continue;  // 读超时到期且期间无包，正常
    }
    if (paused_.load(std::memory_order_acquire)) {
      // 复位期间设备会丢弃所有未完成的数据包，往它发只是浪费。
      counters_.tx.AddDroppedFull(batch->frames.size());
      continue;
    }

    // 分批提交给 USB。
    std::size_t offset = 0;
    while (offset < batch->frames.size()) {
      // 每个分片前重新查一次停机与暂停：下面的背压等待让这个循环可能长时间
      // 驻留，不能只依赖外层的检查。暂停时丢弃剩余帧是刻意的（RNDIS 复位期间
      // 设备会丢弃所有未完成的数据包）；TX 拿不到 RX 那样的强保证（它必须持续
      // 把 BPF 读空，没法真的停下），但把漏发窗口收窄到「一个分片」是免费的。
      if (stop_requested_.load(std::memory_order_acquire) ||
          paused_.load(std::memory_order_acquire)) {
        counters_.tx.AddDroppedFull(batch->frames.size() - offset);
        break;
      }

      const std::size_t chunk =
          std::min<std::size_t>(config_.tx_submit_batch, batch->frames.size() - offset);
      const std::span<const FrameView> slice = batch->frames.subspan(offset, chunk);

      const auto sent = data_channel_->SendFrames(slice);
      if (!sent) {
        counters_.tx.AddIoError();
        // 放弃的剩余帧必须计入丢弃 —— 曾经这里只 +1 个 io_error 就 break，
        // 剩余帧不进任何计数器，统计上凭空消失。
        counters_.tx.AddDroppedFull(batch->frames.size() - offset);
        TETHERKIT_WARN_TR(Msg::kCoreUsbSubmitFailed, chunk, sent.error().ToString());
        break;
      }

      // 桥接层是 TX 计数器的**唯一写者**（DirectionCounters 用 relaxed
      // load+store，靠单写者才安全）。数据通道那侧只统计异步完成回调里的错误，
      // 由 Snapshot() 在读取时合并进来。发出帧数与字节数直接取自 SendOutcome，
      // 被跳过的非法长度帧计入 oversize 丢弃而不是「已发出」。
      if (sent->sent_frames != 0) {
        counters_.tx.AddBatch(sent->sent_frames, sent->sent_bytes);
      }
      if (sent->skipped != 0) {
        counters_.tx.AddDroppedOversize(sent->skipped);
      }

      if (sent->consumed == 0) {
        // 传输池没有空闲槽位 —— 这就是背压。**等待，不丢弃。**
        //
        // 旧实现在这里立即丢弃剩余帧，理由是「等待会让 BPF 内核缓冲堆积成
        // 不可见的内核丢包」。这个前提是错的：内核缓冲默认 4 MiB（250 Mbps
        // 下约 130 ms 的弹性），而且它的溢出计数 bs_drop 每次 ReadFrames 都
        // 带回来、就显示在统计行的「内核丢包」里 —— 根本不是不可见的。
        // 真机实测的后果：一个满帧分片需要约 26 个传输槽而池里只有 4 个，
        // 槽位在几百微秒内就会释放，旧代码却一微秒都不等，高负载下把
        // 30%+ 的 TX 流量丢在了这里（docs/BENCHMARKS.md「真机端到端实测」）。
        //
        // 等待用有限超时：每次醒来回到循环顶部重查停机/暂停标志，停机延迟
        // 因此有上界。真正的溢出兜底仍然在内核缓冲 —— 它满了才该丢，
        // 且丢在统计上可见。
        tx_backpressure_events_.fetch_add(1, std::memory_order_relaxed);
        (void)data_channel_->WaitForSendCapacity(kTxCapacityWaitMillis);
        continue;
      }
      offset += sent->consumed;
    }
  }

  TETHERKIT_DEBUG_TR(Msg::kCoreTxExtractorExited);
}

// =============================================================================
// 观测
// =============================================================================

BridgeStats Bridge::Snapshot() const {
  DirectionSnapshot tx = tetherkit::Snapshot(counters_.tx);
  // 合并数据通道在异步完成回调里累计的错误 —— 那部分由 libusb 事件线程递增，
  // 刻意与桥接层的计数器分开以维持「每个计数器只有一个写者」的不变式。
  tx.io_errors += data_channel_->AsyncSendErrors();

  return BridgeStats{
      .rx = tetherkit::Snapshot(counters_.rx),
      .tx = tx,
      .rx_queue_depth = rx_ring_->SizeSnapshot(),
      .link_kernel_drops = link_kernel_drops_.load(std::memory_order_relaxed),
      .tx_backpressure_events = tx_backpressure_events_.load(std::memory_order_relaxed),
  };
}

std::string FormatStatsLine(const BridgeStats& previous, const BridgeStats& current,
                            double seconds) {
  const DirectionSnapshot rx_delta = current.rx - previous.rx;
  const DirectionSnapshot tx_delta = current.tx - previous.tx;

  return Tr(
      Msg::kCoreStatsLine,
      ToPacketsPerSecond(rx_delta.frames, seconds),
      ToMegabitsPerSecond(rx_delta.bytes, seconds), rx_delta.TotalDropped(),
      ToPacketsPerSecond(tx_delta.frames, seconds),
      ToMegabitsPerSecond(tx_delta.bytes, seconds), tx_delta.TotalDropped(),
      current.rx_queue_depth, current.link_kernel_drops - previous.link_kernel_drops,
      current.tx_backpressure_events - previous.tx_backpressure_events);
}

}  // namespace tetherkit::core

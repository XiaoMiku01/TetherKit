#include "tetherkit/usb/data_channel.h"

#include <sys/sysctl.h>

#include <cstdlib>
#include <format>

#include "tetherkit/common/i18n.h"
#include "tetherkit/common/logging.h"
#include "tetherkit/rndis/packet_codec.h"

namespace tetherkit::usb {
namespace {

/// 传输缓冲的对齐字节数。
///
/// darwin 后端不提供零拷贝 DMA 缓冲（libusb_dev_mem_alloc 返回 NULL），
/// 只能自己分配。按系统页大小对齐能减少 IOKit 为该缓冲建立 DMA 描述符时的
/// 内存分段数量。Apple Silicon 上 hw.pagesize 是 16384。
[[nodiscard]] std::size_t QueryPageSize() {
  std::int64_t value = 0;
  std::size_t size = sizeof(value);
  if (::sysctlbyname("hw.pagesize", &value, &size, nullptr, 0) != 0 || value <= 0) {
    return 16384;  // Apple Silicon 的实际值，作为兜底
  }
  return static_cast<std::size_t>(value);
}

}  // namespace

// =============================================================================
// 构造与析构
// =============================================================================

Result<std::unique_ptr<UsbDataChannel>> UsbDataChannel::Create(
    Device& device, const rndis::NegotiatedParameters& parameters,
    const DataChannelConfig& config) {
  auto channel = std::unique_ptr<UsbDataChannel>(new UsbDataChannel());
  channel->device_ = &device;
  channel->parameters_ = parameters;
  channel->config_ = config;

  // TX 缓冲不能超过设备宣称的 MaxTransferSize —— 超了设备会拒收或截断。
  channel->tx_transfer_bytes_ =
      std::min(config.tx_transfer_bytes, parameters.device_max_transfer_size);
  if (channel->tx_transfer_bytes_ < rndis::kPacketMsgHeaderBytes + parameters.mtu +
                                        rndis::kEthernetHeaderBytes) {
    return std::unexpected(Error::Generic(Tr(
        Msg::kUsbTxBufferTooSmall, channel->tx_transfer_bytes_,
        rndis::kPacketMsgHeaderBytes + parameters.mtu + rndis::kEthernetHeaderBytes)));
  }

  TETHERKIT_RETURN_IF_ERROR(channel->AllocatePool(channel->rx_pool_, config.rx_transfer_count,
                                                  config.rx_transfer_bytes));
  TETHERKIT_RETURN_IF_ERROR(channel->AllocatePool(channel->tx_pool_, config.tx_transfer_count,
                                                  channel->tx_transfer_bytes_));

  // TX 空闲槽位队列：初始全部空闲。
  channel->tx_free_slots_ = std::make_unique<SpscRing<std::uint32_t>>(config.tx_transfer_count);
  for (std::uint32_t i = 0; i < config.tx_transfer_count; ++i) {
    if (!channel->tx_free_slots_->TryPush(i)) {
      return std::unexpected(Error::Generic(Tr(Msg::kUsbTxSlotQueueInitFailed)));
    }
  }

  TETHERKIT_INFO_TR(
      Msg::kUsbDataChannelReady,
      config.rx_transfer_count, config.rx_transfer_bytes / 1024,
      config.rx_transfer_count * config.rx_transfer_bytes / 1024, config.tx_transfer_count,
      channel->tx_transfer_bytes_ / 1024, parameters.device_max_transfer_size,
      parameters.max_packets_per_message, parameters.tx_alignment_bytes);

  return channel;
}

UsbDataChannel::~UsbDataChannel() {
  // Shutdown 是幂等的；这里兜底一次，防止调用方忘了。
  Shutdown();
  FreePool(rx_pool_);
  FreePool(tx_pool_);
}

Status UsbDataChannel::AllocatePool(std::vector<Slot>& pool, std::uint32_t count,
                                    std::uint32_t buffer_bytes) {
  const std::size_t alignment = QueryPageSize();
  pool.resize(count);

  for (std::uint32_t i = 0; i < count; ++i) {
    Slot& slot = pool[i];
    slot.owner = this;
    slot.index = i;
    slot.buffer_bytes = buffer_bytes;

    void* raw = nullptr;
    // 长度也向上取整到对齐边界，避免尾部跨页。
    const std::size_t allocation =
        ((buffer_bytes + alignment - 1) / alignment) * alignment;
    if (::posix_memalign(&raw, alignment, allocation) != 0 || raw == nullptr) {
      return std::unexpected(
          Error::Generic(Tr(Msg::kUsbTransferAllocFailed, allocation, alignment)));
    }
    slot.buffer = static_cast<std::byte*>(raw);

    slot.transfer = ::libusb_alloc_transfer(0);
    if (slot.transfer == nullptr) {
      return std::unexpected(Error::Generic(Tr(Msg::kUsbAllocTransferFailed)));
    }
  }
  return Ok();
}

void UsbDataChannel::FreePool(std::vector<Slot>& pool) noexcept {
  for (Slot& slot : pool) {
    if (slot.transfer != nullptr) {
      ::libusb_free_transfer(slot.transfer);
      slot.transfer = nullptr;
    }
    // posix_memalign 分配的内存必须用 free 释放（不能用 delete）。
    // NOLINTNEXTLINE(cppcoreguidelines-no-malloc,cppcoreguidelines-owning-memory)
    std::free(slot.buffer);
    slot.buffer = nullptr;
  }
  pool.clear();
}

// =============================================================================
// 接收路径（设备 → 主机）
// =============================================================================

Status UsbDataChannel::StartReceiving(FrameRing& rx_ring, DirectionCounters& rx_counters) {
  rx_ring_ = &rx_ring;
  rx_counters_ = &rx_counters;

  for (Slot& slot : rx_pool_) {
    TETHERKIT_RETURN_IF_ERROR(SubmitReceive(slot));
  }
  TETHERKIT_DEBUG_TR(Msg::kUsbBulkInSubmitted, rx_pool_.size());
  return Ok();
}

Status UsbDataChannel::SubmitReceive(Slot& slot) {
  ::libusb_fill_bulk_transfer(
      slot.transfer, device_->Handle(), device_->BulkInEndpoint(),
      reinterpret_cast<unsigned char*>(slot.buffer), static_cast<int>(slot.buffer_bytes),
      &UsbDataChannel::ReceiveCallbackTrampoline, &slot,
      static_cast<unsigned int>(config_.rx_timeout_millis));

  // **刻意不设 LIBUSB_TRANSFER_SHORT_NOT_OK。**
  // 短包在 bulk IN 上是完全正常的语义（设备只有半个缓冲的数据就发短包结束传输）。
  // 设了这个标志会让 io.c 把「COMPLETED 且 actual_length != 请求长度」重判为
  // LIBUSB_TRANSFER_ERROR —— 那样几乎每个传输都会「失败」。
  slot.transfer->flags = 0;

  // 先递增在飞计数再提交：否则回调可能在递增之前就跑完，导致计数下溢。
  outstanding_.fetch_add(1, std::memory_order_acq_rel);

  const int rc = ::libusb_submit_transfer(slot.transfer);
  if (rc != LIBUSB_SUCCESS) {
    outstanding_.fetch_sub(1, std::memory_order_acq_rel);
    return std::unexpected(Error::FromLibUsb(rc, Tr(Msg::kUsbSubmitBulkInFailed)));
  }
  return Ok();
}

void UsbDataChannel::ReceiveCallbackTrampoline(::libusb_transfer* transfer) {
  auto* slot = static_cast<Slot*>(transfer->user_data);
  slot->owner->OnReceiveComplete(*slot);
}

void UsbDataChannel::OnReceiveComplete(Slot& slot) noexcept {
  // ⚠️ 本函数在 libusb **事件线程**上执行，并且持有 ctx->event_waiters_lock。
  // 因此这里：
  //   * 绝不能调用同步 API（会返回 LIBUSB_ERROR_BUSY）；
  //   * 绝不能做阻塞 I/O（会拖住所有等同步传输的线程）；
  //   * 只做「解包 + memcpy 进无锁队列 + 立刻 resubmit」。
  //   真正的 BPF write() 由另一个线程负责。
  const ::libusb_transfer* transfer = slot.transfer;
  bool should_resubmit = true;

  switch (transfer->status) {
    case LIBUSB_TRANSFER_COMPLETED: {
      const auto received = static_cast<std::size_t>(transfer->actual_length);
      if (received > 0 && rx_ring_ != nullptr) {
        // 批量发布：整个传输里的所有帧只做一次 release store。
        auto batch = rx_ring_->BeginBatchWrite();
        rndis::PacketMessageReader reader(
            std::span<const std::byte>{slot.buffer, received}, rx_ring_->MaxFrameBytes());

        std::span<const std::byte> frame;
        std::uint64_t frame_bytes = 0;
        while (true) {
          const rndis::ReadOutcome outcome = reader.Next(frame);
          if (outcome == rndis::ReadOutcome::kFrame) {
            if (!batch.Push(frame)) [[unlikely]] {
              // 下游队列满 —— BPF 写线程跟不上。丢弃并计数，不能阻塞在这里。
              rx_counters_->AddDroppedFull();
              continue;
            }
            frame_bytes += frame.size();
            continue;
          }
          if (outcome == rndis::ReadOutcome::kMalformed) {
            malformed_transfers_.fetch_add(1, std::memory_order_relaxed);
            rx_counters_->AddDroppedMalformed();
            TETHERKIT_TRACE_TR(Msg::kUsbMalformedRndisMessage,
                               rndis::MalformedReasonName(reader.Reason()),
                               reader.FramesDecoded());
          }
          break;
        }
        if (batch.Staged() != 0) {
          const std::uint32_t staged = batch.Staged();
          batch.Publish();
          // NOLINTNEXTLINE(readability-suspicious-call-argument)
          rx_counters_->AddBatch(staged, frame_bytes);
        }
      }
      break;
    }

    case LIBUSB_TRANSFER_STALL:
      // 端点 halt。清掉再继续 —— libusb_clear_halt 走同步 IOKit 调用但**没有**
      // usbi_handling_events 守卫，在回调里调用是安全的（代价是阻塞事件线程
      // 几十微秒到毫秒级，所以只在真 STALL 时做）。
      rx_counters_->AddIoError();
      TETHERKIT_WARN_TR(Msg::kUsbBulkInStall);
      if (const auto status = device_->ClearHalt(device_->BulkInEndpoint()); !status) {
        TETHERKIT_ERROR_TR(Msg::kUsbBulkInClearHaltFailed, status.error().ToString());
        should_resubmit = false;
      }
      break;

    case LIBUSB_TRANSFER_CANCELLED:
      // 停机路径。**不要** resubmit。
      should_resubmit = false;
      break;

    case LIBUSB_TRANSFER_NO_DEVICE:
      // 设备拔了。停止重提交，让在飞计数收敛，由上层重连逻辑处理。
      should_resubmit = false;
      TETHERKIT_INFO_TR(Msg::kUsbBulkInDeviceGone);
      break;

    case LIBUSB_TRANSFER_TIMED_OUT:
      // rx_timeout_millis 默认 0（无限），正常不该出现。出现了就继续提交。
      rx_counters_->AddIoError();
      break;

    case LIBUSB_TRANSFER_ERROR:
    case LIBUSB_TRANSFER_OVERFLOW:
    default:
      rx_counters_->AddIoError();
      TETHERKIT_WARN_TR(Msg::kUsbBulkInFailed, static_cast<int>(transfer->status));
      break;
  }

  if (shutting_down_.load(std::memory_order_acquire)) {
    should_resubmit = false;
  }

  if (should_resubmit) {
    // 官方保证：在回调里直接 resubmit 同一个 transfer 是安全的
    // （usbi_handle_transfer_completion 在调回调前已把它移出 flying list
    //  并清了 IN_FLIGHT 标志，且不持 itransfer->lock）。
    const int rc = ::libusb_submit_transfer(slot.transfer);
    if (rc == LIBUSB_SUCCESS) {
      return;  // 在飞计数保持不变：一进一出
    }
    TETHERKIT_WARN_TR(Msg::kUsbBulkInResubmitFailed, ::libusb_error_name(rc));
  }

  // 该传输就此退出飞行。通知可能正在等待归零的 Shutdown()。
  if (outstanding_.fetch_sub(1, std::memory_order_acq_rel) == 1) {
    const std::lock_guard<std::mutex> guard(drain_mutex_);
    drain_condition_.notify_all();
  }
}

// =============================================================================
// 发送路径（主机 → 设备）
// =============================================================================

bool UsbDataChannel::CanSend() const noexcept {
  return tx_free_slots_ != nullptr && tx_free_slots_->SizeSnapshot() > 0;
}

Result<SendOutcome> UsbDataChannel::SendFrames(std::span<const FrameView> frames) {
  if (frames.empty()) {
    return SendOutcome{};
  }
  if (shutting_down_.load(std::memory_order_acquire)) {
    return std::unexpected(Error::Generic(Tr(Msg::kUsbDataChannelShuttingDown)));
  }

  SendOutcome outcome;

  while (outcome.consumed < frames.size()) {
    std::uint32_t slot_index = 0;
    if (!tx_free_slots_->TryPop(slot_index)) {
      // 没有空闲传输槽位 —— 这就是背压。如实返回已消费数，调用方应
      // WaitForSendCapacity() 后重试剩余帧，而不是丢弃。
      break;
    }
    Slot& slot = tx_pool_[slot_index];

    // 把尽可能多的帧聚合进这一个传输。
    rndis::PacketMessageWriter writer(
        std::span<std::byte>{slot.buffer, slot.buffer_bytes},
        rndis::PacketMessageWriter::Limits{
            .max_transfer_bytes = parameters_.device_max_transfer_size,
            .max_messages = parameters_.max_packets_per_message,
            .alignment_bytes = parameters_.tx_alignment_bytes,
        },
        device_->BulkMaxPacketSize());

    std::uint32_t scanned = 0;   // 从输入消费掉的帧数（含被跳过的短帧）
    std::uint32_t appended = 0;  // 真正装进本传输的帧数
    bool append_failed = false;
    while (outcome.consumed + scanned < frames.size()) {
      const FrameView& frame = frames[outcome.consumed + scanned];
      if (frame.length < kMinEthernetFrameBytes) [[unlikely]] {
        // 非法短帧：跳过并如实计入 skipped —— 它没有被发出。
        ++scanned;
        ++outcome.skipped;
        continue;
      }
      if (!writer.TryAppend(frame.Bytes())) {
        append_failed = true;
        break;  // 本批装满了（受字节数或包数上限），或单帧超长
      }
      ++scanned;
      ++appended;
    }

    if (writer.Empty()) {
      // 一帧都没装进去。要么这一段全是被跳过的短帧，要么第一个合法帧就超过了
      // 设备的 MaxTransferSize —— 后者必须跳过并前进，否则会死循环。
      outcome.consumed += scanned;
      if (append_failed && outcome.consumed < frames.size()) {
        ++outcome.consumed;
        ++outcome.skipped;
      }
      if (!tx_free_slots_->TryPush(slot_index)) {
        TETHERKIT_ERROR_TR(Msg::kUsbReturnTxSlotFailed, slot_index);
      }
      continue;
    }

    const std::uint32_t transfer_bytes = writer.Finish();
    const std::uint64_t payload_bytes = writer.PayloadBytes();
    const std::uint32_t message_count = writer.MessageCount();

    ::libusb_fill_bulk_transfer(
        slot.transfer, device_->Handle(), device_->BulkOutEndpoint(),
        reinterpret_cast<unsigned char*>(slot.buffer), static_cast<int>(transfer_bytes),
        &UsbDataChannel::SendCallbackTrampoline, &slot,
        static_cast<unsigned int>(config_.tx_timeout_millis));
    slot.transfer->flags = 0;

    outstanding_.fetch_add(1, std::memory_order_acq_rel);
    const int rc = ::libusb_submit_transfer(slot.transfer);
    if (rc != LIBUSB_SUCCESS) {
      outstanding_.fetch_sub(1, std::memory_order_acq_rel);
      if (!tx_free_slots_->TryPush(slot_index)) {
        TETHERKIT_ERROR_TR(Msg::kUsbReturnTxSlotFailed, slot_index);
      }
      async_send_errors_.fetch_add(1, std::memory_order_relaxed);
      return std::unexpected(Error::FromLibUsb(rc, Tr(Msg::kUsbSubmitBulkOutFailed)));
    }

    // 帧数与字节数由**桥接层**统计（它是 TX 计数器的唯一写者）。这里只记
    // 供诊断用的聚合效果。
    TETHERKIT_TRACE_TR(Msg::kUsbBulkOutSubmitted, message_count, payload_bytes, transfer_bytes);
    outcome.consumed += scanned;
    outcome.sent_frames += appended;
    outcome.sent_bytes += payload_bytes;
  }

  return outcome;
}

bool UsbDataChannel::WaitForSendCapacity(std::uint32_t timeout_millis) {
  std::unique_lock<std::mutex> lock(send_capacity_mutex_);
  return send_capacity_cv_.wait_for(lock, std::chrono::milliseconds(timeout_millis), [this] {
    return shutting_down_.load(std::memory_order_acquire) ||
           tx_free_slots_->SizeSnapshot() > 0;
  });
}

void UsbDataChannel::SendCallbackTrampoline(::libusb_transfer* transfer) {
  auto* slot = static_cast<Slot*>(transfer->user_data);
  slot->owner->OnSendComplete(*slot);
}

void UsbDataChannel::OnSendComplete(Slot& slot) noexcept {
  // 同样在 libusb 事件线程上，同样不能阻塞。
  switch (slot.transfer->status) {
    case LIBUSB_TRANSFER_COMPLETED:
      break;

    case LIBUSB_TRANSFER_STALL:
      async_send_errors_.fetch_add(1, std::memory_order_relaxed);
      TETHERKIT_WARN_TR(Msg::kUsbBulkOutStall);
      if (const auto status = device_->ClearHalt(device_->BulkOutEndpoint()); !status) {
        TETHERKIT_ERROR_TR(Msg::kUsbBulkOutClearHaltFailed, status.error().ToString());
      }
      break;

    case LIBUSB_TRANSFER_CANCELLED:
    case LIBUSB_TRANSFER_NO_DEVICE:
      break;

    case LIBUSB_TRANSFER_TIMED_OUT:
      // 超时多因设备侧在空闲时未读取非单播广播包（如 mDNS/SSDP），
      // 记录丢包并打 DEBUG，避免在空闲期每 5 秒在日志面板疯狂刷 WARN 警告。
      async_send_errors_.fetch_add(1, std::memory_order_relaxed);
      TETHERKIT_DEBUG_TR(Msg::kUsbBulkOutFailed, static_cast<int>(slot.transfer->status));
      break;

    default:
      async_send_errors_.fetch_add(1, std::memory_order_relaxed);
      TETHERKIT_WARN_TR(Msg::kUsbBulkOutFailed, static_cast<int>(slot.transfer->status));
      break;
  }

  // 归还槽位。停机时不归还也无所谓 —— 反正不会再有人取。
  if (!shutting_down_.load(std::memory_order_acquire)) {
    if (!tx_free_slots_->TryPush(slot.index)) {
      TETHERKIT_ERROR_TR(Msg::kUsbReturnTxSlotFailed, slot.index);
    }
    // 唤醒可能在 WaitForSendCapacity 里等槽位的 TX 线程。空临界区惯用法：
    // 取一下锁保证等待方不会在「查完谓词、还没睡下」的窗口里漏掉这次通知。
    { const std::lock_guard<std::mutex> guard(send_capacity_mutex_); }
    send_capacity_cv_.notify_one();
  }

  if (outstanding_.fetch_sub(1, std::memory_order_acq_rel) == 1) {
    const std::lock_guard<std::mutex> guard(drain_mutex_);
    drain_condition_.notify_all();
  }
}

// =============================================================================
// 拆除
// =============================================================================

void UsbDataChannel::Shutdown() {
  if (shutdown_complete_) {
    return;
  }
  // ⚠️ 本函数**绝对不能**从 libusb 事件线程调用：下面要等在飞计数归零，
  // 而递减它的回调正是在事件线程上跑的 —— 在那里等就是自己等自己，必然死锁。
  // 正确的调用者是控制线程或主线程。

  // 1. 置停机标志。回调看到它就不再 resubmit，在飞数开始自然收敛。
  //    同时唤醒可能还在 WaitForSendCapacity 里等槽位的线程（正常拆除顺序下
  //    TX 线程此时已被 join，这里是防御性兜底 —— 比如测试直接驱动通道时）。
  shutting_down_.store(true, std::memory_order_release);
  { const std::lock_guard<std::mutex> guard(send_capacity_mutex_); }
  send_capacity_cv_.notify_all();

  // 2. 取消在飞传输。
  //
  // darwin 上 libusb_cancel_transfer 是 AbortPipe，会取消**该端点上所有**在飞
  // 传输，所以每个端点其实只需调一次；这里逐个调是幂等且更清晰的写法。
  // LIBUSB_ERROR_NOT_FOUND 表示它本来就不在飞，属于正常情况。
  for (Slot& slot : rx_pool_) {
    if (slot.transfer != nullptr) {
      const int rc = ::libusb_cancel_transfer(slot.transfer);
      if (rc != LIBUSB_SUCCESS && rc != LIBUSB_ERROR_NOT_FOUND) {
        TETHERKIT_DEBUG_TR(Msg::kUsbCancelBulkInReturned, ::libusb_error_name(rc));
      }
    }
  }
  for (Slot& slot : tx_pool_) {
    if (slot.transfer != nullptr) {
      const int rc = ::libusb_cancel_transfer(slot.transfer);
      if (rc != LIBUSB_SUCCESS && rc != LIBUSB_ERROR_NOT_FOUND) {
        TETHERKIT_DEBUG_TR(Msg::kUsbCancelBulkOutReturned, ::libusb_error_name(rc));
      }
    }
  }

  // 3. 等在飞计数归零。**这一步是避免 use-after-free 的关键** ——
  //    必须等到每个回调都跑完，才能释放 transfer 与缓冲。
  {
    constexpr auto kDrainTimeout = std::chrono::seconds(5);
    std::unique_lock<std::mutex> lock(drain_mutex_);
    const bool drained = drain_condition_.wait_for(lock, kDrainTimeout, [this] {
      return outstanding_.load(std::memory_order_acquire) == 0;
    });
    if (!drained) {
      // 超时。这时释放缓冲是危险的（回调可能还会访问），所以**故意泄漏** ——
      // 泄漏几百 KB 远好于 use-after-free 崩溃。
      const std::uint32_t stuck = outstanding_.load(std::memory_order_acquire);
      TETHERKIT_ERROR_TR(Msg::kUsbTransferReclaimTimeout, stuck,
                         (stuck * config_.rx_transfer_bytes) / 1024);
      // 把 transfer 指针清空，让 FreePool 跳过它们。
      for (Slot& slot : rx_pool_) {
        slot.transfer = nullptr;
        slot.buffer = nullptr;
      }
      for (Slot& slot : tx_pool_) {
        slot.transfer = nullptr;
        slot.buffer = nullptr;
      }
    }
  }

  shutdown_complete_ = true;
  TETHERKIT_DEBUG_TR(Msg::kUsbDataChannelStopped);
}

}  // namespace tetherkit::usb

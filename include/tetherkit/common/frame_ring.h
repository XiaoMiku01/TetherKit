// 变长以太帧的 SPSC 无锁环形队列。
//
// 与 SpscRing<T> 的区别：以太帧是变长的（14~2048 字节），而且我们希望
// **整条数据路径上只发生一次内存拷贝**。因此这里提供「预留槽位 → 直接写入 →
// 提交」的接口，而不是「先在别处组装好再入队」：
//
//   生产者（libusb 回调线程）                 消费者（BPF 写线程）
//   ------------------------------------      -----------------------------------
//   std::byte* dst = ring.BeginWrite();       auto view = ring.BeginRead();
//   memcpy(dst, usb_payload, len);   ← 唯一   ::write(bpf_fd, view.data(), ...);
//   ring.CommitWrite(len);              一次  ring.CommitRead();
//                                       拷贝
//
// 为什么必须拷贝这一次（而不是零拷贝）：
//   libusb 的 bulk IN 传输缓冲要尽快 resubmit 才能维持 USB 管道满载；如果把
//   缓冲交给下游持有，就必须准备远多于「在飞传输数」的缓冲区，并引入归还机制。
//   实测 1500 字节的 memcpy 在 Apple Silicon 上约 40~60 ns，而一次 BPF write()
//   系统调用是它的 30~50 倍 —— 拷贝根本不是瓶颈，为它做零拷贝是错误的优化方向。
//
// 存储布局：容量个定长槽位，每槽 = 缓存行对齐的 header(长度) + 帧数据区。
// 定长槽位而非紧凑 arena 的理由：arena 需要处理跨越环尾的回绕拼接，会让
// 「一次 write() 发一帧」变成两次，反而更慢。
#pragma once

#include <cassert>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <span>

#include "tetherkit/common/cache.h"
#include "tetherkit/common/spsc_ring.h"

namespace tetherkit {

/// 以太帧的最大字节数（不含 FCS）。
///
/// 取 2048 的理由：feth 的 `net.link.fake.max_mtu` 是 2048，因此 MTU 上限
/// 就是 2048，加上 14 字节以太头本应是 2062；但 RNDIS 设备可能协商出更大的
/// `OID_GEN_MAXIMUM_FRAME_SIZE`，且槽位按 2 的幂对齐更利于地址计算，
/// 故直接取 2048 作为帧数据区容量，超长帧在入队前就被丢弃并计数。
inline constexpr std::uint32_t kMaxEthernetFrameBytes = 2048;

/// 最小合法以太帧（目的 MAC 6 + 源 MAC 6 + EtherType 2）。
inline constexpr std::uint32_t kMinEthernetFrameBytes = 14;

/// 只读的帧视图，指向环形队列内部存储，在 CommitRead 之前有效。
struct FrameView {
  const std::byte* data = nullptr;
  std::uint32_t length = 0;

  [[nodiscard]] std::span<const std::byte> Bytes() const noexcept { return {data, length}; }

  [[nodiscard]] bool Empty() const noexcept { return length == 0; }
};

/// 变长帧的 SPSC 无锁有界队列。
class FrameRing {
 public:
  /// `capacity_frames` 会被向上取整到 2 的幂。
  /// `max_frame_bytes` 为单帧上限，默认 kMaxEthernetFrameBytes。
  explicit FrameRing(std::size_t capacity_frames,
                     std::uint32_t max_frame_bytes = kMaxEthernetFrameBytes)
      : cursor_(RoundUpToPowerOfTwo(capacity_frames)),
        max_frame_bytes_(max_frame_bytes),
        slot_stride_(ComputeSlotStride(max_frame_bytes)),
        storage_(AllocateStorage(RoundUpToPowerOfTwo(capacity_frames),
                                 ComputeSlotStride(max_frame_bytes))) {
    // 存储起点对齐到缓存行后缓存下来，避免每次访问槽位都重算一遍对齐。
    // 用 std::align 而非整数取模：后者需要 uintptr_t ↔ 指针互转，会削弱
    // 编译器的别名分析（clang-tidy performance-no-int-to-ptr 就在提示这点）。
    void* base = storage_.get();
    std::size_t space = cursor_.Capacity() * slot_stride_ + kCacheLineSize;
    void* aligned = std::align(kCacheLineSize, cursor_.Capacity() * slot_stride_, base, space);
    assert(aligned != nullptr);
    aligned_base_ = static_cast<std::byte*>(aligned);
  }

  FrameRing(const FrameRing&) = delete;
  FrameRing& operator=(const FrameRing&) = delete;
  FrameRing(FrameRing&&) = delete;
  FrameRing& operator=(FrameRing&&) = delete;
  ~FrameRing() = default;

  [[nodiscard]] std::size_t Capacity() const noexcept { return cursor_.Capacity(); }

  [[nodiscard]] std::uint32_t MaxFrameBytes() const noexcept { return max_frame_bytes_; }

  /// 队列占用的总字节数，用于启动时打印内存预算。
  [[nodiscard]] std::size_t StorageBytes() const noexcept {
    return cursor_.Capacity() * slot_stride_;
  }

  // ---------------------------------------------------------------------------
  // 生产者侧
  // ---------------------------------------------------------------------------

  /// 预留一个槽位，返回可写入 `MaxFrameBytes()` 字节的缓冲区；队列满返回空 span。
  ///
  /// 必须与 CommitWrite 配对；两次调用之间不得再调用 BeginWrite。
  [[nodiscard]] std::span<std::byte> BeginWrite() noexcept {
    if (!cursor_.TryAcquireWrite(pending_write_index_)) [[unlikely]] {
      return {};
    }
    return {FrameDataAt(pending_write_index_), max_frame_bytes_};
  }

  /// 提交刚写入的帧。`length` 必须 <= MaxFrameBytes()。
  void CommitWrite(std::uint32_t length) noexcept {
    assert(length <= max_frame_bytes_);
    StoreLength(pending_write_index_, length);
    cursor_.PublishWrite();
    WakeConsumer();
  }

  /// 便捷入口：拷贝一整帧进队列。成功返回 true，队列满或帧超长返回 false。
  [[nodiscard]] bool TryPush(std::span<const std::byte> frame) noexcept {
    if (frame.size() > max_frame_bytes_) [[unlikely]] {
      return false;
    }
    const std::span<std::byte> dst = BeginWrite();
    if (dst.empty()) [[unlikely]] {
      return false;
    }
    std::memcpy(dst.data(), frame.data(), frame.size());
    CommitWrite(static_cast<std::uint32_t>(frame.size()));
    return true;
  }

  /// 生产者视角的空闲槽数。用于在拆包前判断能否容纳整批，避免半批丢弃。
  [[nodiscard]] std::size_t WritableApprox() noexcept { return cursor_.WritableApprox(); }

  /// 批量写入会话。**数据路径上应当一律用它，而不是逐帧 TryPush。**
  ///
  /// 一次 release store 会让写位置所在的缓存行跨核弹一次（实测约 60 ns）。
  /// 逐帧发布时那就是每帧的固定成本；批量发布则摊薄成 60/N：
  ///     batch=1 约 63 ns/帧、batch=8 约 5.5 ns/帧、batch=32 约 1.9 ns/帧。
  ///
  /// 用法（libusb 回调里拆一个传输的多个 RNDIS 包）：
  /// ```
  /// auto batch = ring.BeginBatchWrite();
  /// while (reader.Next(frame) == ReadOutcome::kFrame) {
  ///   const std::span<std::byte> dst = batch.Begin();
  ///   if (dst.empty()) { break; }          // 队列满
  ///   std::memcpy(dst.data(), frame.data(), frame.size());
  ///   batch.Commit(frame.size());
  /// }
  /// // batch 析构时一次性发布全部帧
  /// ```
  class BatchWrite {
   public:
    explicit BatchWrite(FrameRing& ring) noexcept : ring_(&ring) {}

    BatchWrite(const BatchWrite&) = delete;
    BatchWrite& operator=(const BatchWrite&) = delete;
    BatchWrite(BatchWrite&&) = delete;
    BatchWrite& operator=(BatchWrite&&) = delete;

    /// 析构时自动发布。忘记显式 Publish 也不会丢数据。
    ~BatchWrite() { Publish(); }

    /// 预留下一个槽位，返回可写缓冲；队列满返回空 span。
    [[nodiscard]] std::span<std::byte> Begin() noexcept {
      if (!ring_->cursor_.TryAcquireWriteAt(staged_, staged_index_)) [[unlikely]] {
        return {};
      }
      return {ring_->FrameDataAt(staged_index_), ring_->max_frame_bytes_};
    }

    /// 记录刚写入的帧长。**不做任何原子操作** —— 这是批量化的关键。
    void Commit(std::uint32_t length) noexcept {
      assert(length <= ring_->max_frame_bytes_);
      ring_->StoreLength(staged_index_, length);
      ++staged_;
    }

    /// 便捷入口：拷贝一整帧。成功返回 true。
    [[nodiscard]] bool Push(std::span<const std::byte> frame) noexcept {
      if (frame.size() > ring_->max_frame_bytes_) [[unlikely]] {
        return false;
      }
      const std::span<std::byte> dst = Begin();
      if (dst.empty()) [[unlikely]] {
        return false;
      }
      std::memcpy(dst.data(), frame.data(), frame.size());
      Commit(static_cast<std::uint32_t>(frame.size()));
      return true;
    }

    /// 立即发布已暂存的全部帧。可提前调用；之后本会话可继续暂存新帧。
    void Publish() noexcept {
      if (staged_ != 0) {
        ring_->cursor_.PublishWrite(staged_);
        ring_->WakeConsumer();
        published_ += staged_;
        staged_ = 0;
      }
    }

    /// 本会话已暂存但未发布的帧数。
    [[nodiscard]] std::uint32_t Staged() const noexcept { return staged_; }

    /// 本会话累计已发布的帧数。
    [[nodiscard]] std::uint32_t Published() const noexcept { return published_; }

   private:
    FrameRing* ring_;
    std::uint32_t staged_ = 0;
    std::uint32_t published_ = 0;
    std::size_t staged_index_ = 0;
  };

  [[nodiscard]] BatchWrite BeginBatchWrite() noexcept { return BatchWrite{*this}; }

  // ---------------------------------------------------------------------------
  // 消费者侧
  // ---------------------------------------------------------------------------

  /// 取出队首帧的只读视图；队列空时返回 length == 0 的视图。
  ///
  /// 视图在下一次 CommitRead 之前有效。必须与 CommitRead 配对。
  [[nodiscard]] FrameView BeginRead() noexcept {
    if (!cursor_.TryAcquireRead(pending_read_index_)) [[unlikely]] {
      return FrameView{.data = nullptr, .length = 0};
    }
    return FrameView{.data = FrameDataAt(pending_read_index_),
                     .length = LoadLength(pending_read_index_)};
  }

  /// 释放队首帧。
  void CommitRead() noexcept { cursor_.PublishRead(); }

  /// 消费者视角的可读帧数。批量消费时用它一次拿到批大小。
  [[nodiscard]] std::size_t ReadableApprox() noexcept { return cursor_.ReadableApprox(); }

  /// 批量读取会话。与 BatchWrite 对称，只在批次结束时做一次 release store。
  ///
  /// 这正是 BPF 写线程要的形态：一次取出几十帧，攒成一个 BIOCSBATCHWRITE
  /// 批量写出去，然后一次性释放全部槽位。
  ///
  /// 用法：
  /// ```
  /// auto batch = ring.BeginBatchRead();
  /// std::vector<FrameView> views;
  /// while (views.size() < kMaxBatch) {
  ///   const FrameView view = batch.Next();
  ///   if (view.Empty()) { break; }
  ///   views.push_back(view);              // 视图在 batch 析构前有效
  /// }
  /// link.WriteFrames(views);
  /// // batch 析构时一次性释放全部槽位
  /// ```
  class BatchRead {
   public:
    explicit BatchRead(FrameRing& ring) noexcept : ring_(&ring) {}

    BatchRead(const BatchRead&) = delete;
    BatchRead& operator=(const BatchRead&) = delete;
    BatchRead(BatchRead&&) = delete;
    BatchRead& operator=(BatchRead&&) = delete;

    /// 析构时自动释放已取出的槽位。
    ~BatchRead() { Release(); }

    /// 取下一帧的只读视图；无更多帧时返回 length == 0 的视图。
    ///
    /// 返回的视图在本会话 Release()（或析构）**之前**有效 —— 因为槽位尚未
    /// 归还给生产者，内容不会被覆写。这正是零拷贝批量写出的前提。
    [[nodiscard]] FrameView Next() noexcept {
      std::size_t index = 0;
      if (!ring_->cursor_.TryAcquireReadAt(staged_, index)) [[unlikely]] {
        return FrameView{};
      }
      ++staged_;
      return FrameView{.data = ring_->FrameDataAt(index),
                       .length = ring_->LoadLength(index)};
    }

    /// 立即释放已取出的槽位。调用后之前返回的视图全部失效。
    void Release() noexcept {
      if (staged_ != 0) {
        ring_->cursor_.PublishRead(staged_);
        released_ += staged_;
        staged_ = 0;
      }
    }

    /// 已取出但未释放的帧数。
    [[nodiscard]] std::uint32_t Staged() const noexcept { return staged_; }

    /// 本会话累计已释放的帧数。
    [[nodiscard]] std::uint32_t Released() const noexcept { return released_; }

   private:
    FrameRing* ring_;
    std::uint32_t staged_ = 0;
    std::uint32_t released_ = 0;
  };

  [[nodiscard]] BatchRead BeginBatchRead() noexcept { return BatchRead{*this}; }

  /// Snapshot a producer notification generation before checking the queue.
  /// Waiting against this ticket avoids losing a publish between the empty check
  /// and parking the consumer.
  [[nodiscard]] std::uint64_t ConsumerTicket() const noexcept {
    return consumer_epoch_.load(std::memory_order_acquire);
  }

  void WaitForConsumerChange(std::uint64_t ticket) const noexcept {
    consumer_epoch_.wait(ticket, std::memory_order_acquire);
  }

  void WakeConsumer() noexcept {
    consumer_epoch_.fetch_add(1, std::memory_order_release);
    consumer_epoch_.notify_all();
  }

  // ---------------------------------------------------------------------------
  // 观测
  // ---------------------------------------------------------------------------

  [[nodiscard]] std::size_t SizeSnapshot() const noexcept { return cursor_.SizeSnapshot(); }

  [[nodiscard]] std::uint64_t TotalEnqueued() const noexcept { return cursor_.TotalEnqueued(); }

  [[nodiscard]] std::uint64_t TotalDequeued() const noexcept { return cursor_.TotalDequeued(); }

 private:
  // 两个批量会话类需要直接访问游标与槽位寻址，避免在热路径上多一层转发。
  friend class BatchWrite;
  friend class BatchRead;

  /// 槽位内布局：[0, 4) 存长度，[kSlotHeaderBytes, ...) 存帧数据。
  ///
  /// 帧数据从 kCacheLineSize 偏移开始，保证每帧的起始地址都是缓存行对齐的 ——
  /// memcpy 与后续 write() 都能走最优路径。
  static constexpr std::size_t kSlotHeaderBytes = kCacheLineSize;

  static std::size_t RoundUpToPowerOfTwo(std::size_t requested) noexcept {
    std::size_t value = 1;
    while (value < requested) {
      value <<= 1U;
    }
    return value;
  }

  /// 槽位步长：header + 帧数据区，再向上对齐到缓存行，使每个槽都独占若干整行。
  static std::size_t ComputeSlotStride(std::uint32_t max_frame_bytes) noexcept {
    const std::size_t raw = kSlotHeaderBytes + max_frame_bytes;
    return ((raw + kCacheLineSize - 1) / kCacheLineSize) * kCacheLineSize;
  }

  static std::unique_ptr<std::byte[]> AllocateStorage(std::size_t capacity, std::size_t stride) {
    // 用 new[] 而非 aligned_alloc：整块起始地址的对齐由下面的 AlignedBase 处理，
    // 这样析构仍然是简单的 unique_ptr，不需要自定义 deleter。
    return std::make_unique<std::byte[]>(capacity * stride + kCacheLineSize);
  }

  [[nodiscard]] std::byte* SlotAt(std::size_t index) const noexcept {
    return aligned_base_ + index * slot_stride_;
  }

  [[nodiscard]] std::byte* FrameDataAt(std::size_t index) const noexcept {
    return SlotAt(index) + kSlotHeaderBytes;
  }

  void StoreLength(std::size_t index, std::uint32_t length) noexcept {
    std::memcpy(SlotAt(index), &length, sizeof(length));
  }

  [[nodiscard]] std::uint32_t LoadLength(std::size_t index) const noexcept {
    std::uint32_t length = 0;
    std::memcpy(&length, SlotAt(index), sizeof(length));
    return length;
  }

  SpscCursor cursor_;
  mutable std::atomic<std::uint64_t> consumer_epoch_{0};

  // 构造后只读，两侧线程都只做读取，可以安全共享同一条缓存行。
  std::uint32_t max_frame_bytes_;
  std::size_t slot_stride_;
  std::unique_ptr<std::byte[]> storage_;
  std::byte* aligned_base_ = nullptr;

  // 「已预留但未提交」的槽位下标：生产者与消费者各自私有，**必须**分处不同
  // 缓存行 —— 否则每帧的 BeginWrite/BeginRead 都会互相 invalidate，
  // 前面为 SpscCursor 做的缓存行隔离就全白费了。
  TETHERKIT_CACHE_ALIGNED std::size_t pending_write_index_ = 0;
  TETHERKIT_CACHE_ALIGNED std::size_t pending_read_index_ = 0;
};

}  // namespace tetherkit

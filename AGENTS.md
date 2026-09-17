# AGENTS.md —— TetherKit 实现备忘

> 本文件是给 AI agent（以及接手的人类）看的**工作记忆**。
> 每完成一个提交都要更新对应章节。开始任何工作前先读一遍本文件，避免重复踩坑。

---

## 1. 项目一句话

macOS **用户态** RNDIS 驱动：USB 侧用 libusb 与 RNDIS 设备（Android 手机 USB 网络共享等）
通话，网卡侧用 `feth` 虚拟网卡对 + BPF 直接读写原始以太帧，把设备变成一张系统可见的网卡。

---

## 2. 已实测确认的环境事实（**不要重复验证，直接引用**）

实测机器：macOS 26.5.1 (Darwin 25.5.0)、Apple Silicon arm64、Apple clang 21.0.0。

### 2.1 工具链

| 事实 | 结论 | 验证方式 |
|---|---|---|
| Apple clang 21 的 C++23 | **可用**：`std::expected`、`std::byteswap`、`std::format`、`jthread`、`stop_token`、`latch`、`counting_semaphore` 全部通过编译+运行 | 实测编译运行 |
| `std::expected` / `std::byteswap` 在 `-std=c++20` 下 | **不可用**，是 C++23 库特性。项目因此定为 C++23 | 实测编译报错 |
| `std::format` 浮点格式化 | 依赖 libc++ 的 `std::to_chars`，带 availability 标注，**部署目标必须 ≥ macOS 13.3**，否则编译失败 | 实测 `-mmacosx-version-min=13.0` 报 `'to_chars' is unavailable: introduced in macOS 13.3` |
| `std::hardware_destructive_interference_size` | Apple libc++ **未提供**。必须自己定义缓存行常量 | 实测编译报错 |
| **缓存行大小** | **128 字节**（不是 64！）`hw.cachelinesize: 128`。SPSC 队列的 false-sharing 填充必须按 128 对齐 | `sysctl hw.cachelinesize` |
| L1D 缓存 | 65536 字节 | `sysctl hw.l1dcachesize` |
| CPU | 10 逻辑核，其中 **4 个性能核**（`hw.perflevel0.logicalcpu = 4`）。数据路径线程需要用 QoS 争取性能核 | `sysctl hw.ncpu hw.perflevel0.logicalcpu` |
| `-mcpu=apple-m1` / `-mcpu=native` | 都可用；但默认**不开**（见 `cmake/Optimizations.cmake` 里的取舍说明） | 实测编译 |
| ninja | **未安装**，用默认 Unix Makefiles 生成器 | `which ninja` |
| CMake | 4.3.3 | `cmake --version` |

### 2.2 libusb

| 事实 | 结论 |
|---|---|
| 版本 | 1.0.30.12037，`/opt/homebrew/opt/libusb` |
| pkg-config | 可用。注意头文件目录是 `.../include/libusb-1.0`（非常规），`FindLibUSB.cmake` 已处理 |
| hotplug | `libusb_has_capability(LIBUSB_CAP_HAS_HOTPLUG)` 返回 **1**，支持 |
| 链接依赖 | darwin 后端需要 `IOKit`、`CoreFoundation`、`Security` 三个 framework |
| **本机 USB 设备** | 立项时为 **0**（`libusb_get_device_list` 与 `ioreg -c IOUSBHostDevice` 都是 0 条），架构因此按「USB 逻辑必须能用 mock 后端离线测试」来设计。后来接上过真实 RNDIS 设备做验证（见第 6 节），但**这个设计约束仍然有效** —— 不要假设跑测试时一定有设备 |

### 2.3 BPF（Darwin）

| 事实 | 结论 |
|---|---|
| **零拷贝 BPF** | **不存在**。SDK 的 `net/bpf.h` 里**没有** `BIOCSETZBUF` / `BIOCGETZMAX` / `BIOCROTZBUF`（FreeBSD 有，Darwin 没有）。只能用经典 BPF：大 `BIOCSBLEN` + 批量 `read()` |
| 可用 ioctl 全集 | `BIOCGBLEN`(102R) `BIOCSBLEN`(102WR) `BIOCSETF`(103) `BIOCFLUSH`(104) `BIOCPROMISC`(105) `BIOCGDLT`(106) `BIOCGETIF`(107) `BIOCSETIF`(108) `BIOCSRTIMEOUT`(109) `BIOCGRTIMEOUT`(110) `BIOCGSTATS`(111) `BIOCIMMEDIATE`(112) `BIOCVERSION`(113) `BIOCGRSIG`(114) `BIOCSRSIG`(115) `BIOCGHDRCMPLT`(116) `BIOCSHDRCMPLT`(117) `BIOCGSEESENT`(118) `BIOCSSEESENT`(119) `BIOCSDLT`(120) `BIOCGDLTLIST`(121) `BIOCSETFNR`(126) |
| `struct bpf_hdr` | `{ struct BPF_TIMEVAL bh_tstamp; bpf_u_int32 bh_caplen; bpf_u_int32 bh_datalen; u_short bh_hdrlen; }` —— 遍历时**必须**用 `bh_hdrlen` 而非 `sizeof(bpf_hdr)` |
| 对齐宏 | `BPF_ALIGNMENT = sizeof(int32_t) = 4`，`BPF_WORDALIGN(x) = ((x)+3) & ~3` |
| 设备节点 | `/dev/bpf0..3` 存在（Darwin 按需克隆更多节点） |
| **批量写** | ✅ **支持**（macOS 14+）：私有 ioctl `BIOCSBATCHWRITE = _IOW('B',143,int) = 0x8004428f`。缓冲格式与 read 对称（连续的 `bpf_hdr + 帧`，每条按 `BPF_WORDALIGN` 对齐），前置条件是 `BIOCSHDRCMPLT=1`。macOS 13 及更早**没有**此 ioctl → 必须运行时特性探测，失败回落逐帧 write |
| 私有 ioctl 编号（实测核对） | `BIOCSBATCHWRITE`=0x8004428f、`BIOCSNOTSTAMP`=0x80044291（关时间戳，省每帧一次 microtime）、`BIOCSWRITEMAX`=0x8004428c、`BIOCSDIRECTION`=0x8004428a、`BIOCSHEADDROP`=0x80044280。macOS 26 把它们从 `net/bpf.h` 挪到了 `net/bpf_private.h`（**SDK 未提供该文件**） |
| `BIOCSBLEN` 上限 | `sysctl debug.bpf_bufsize_cap` = **33554432（32 MiB）**。超限**不报错**，静默截断并通过 `_IOWR` 把实际值**写回参数** |
| `read()` 缓冲长度 | **必须精确等于** `bd_bufsize`，否则 `bpfread` 开头就返回 `EINVAL`。必须用 `BIOCSBLEN` 的写回值 |
| `BIOCSHDRCMPLT` | **必须设为 1**。=0 时 `bpfwrite` 会剥掉前 14 字节重建帧头（源 MAC 被驱动改写）；=1 才走 `DLIL_OUTPUT_FLAGS_RAW` 原样透传。批量写也硬性要求它是 1 |
| 单帧写入长度上限 | `BPF_WRITE_LEEWAY = 18`，`hdrcmplt=1` 时整帧长度必须 ≤ 接口 MTU + 18（MTU=1500 → 1518） |
| `BIOCSRTIMEOUT` 分辨率 | **10 ms**（内核存 `tvtohz(tv)-1` 个 tick，实测 `kern.clockrate hz=100`）。传 `{0,0}` 会变成**永久阻塞** |
| 最优读取模型 | `BIOCIMMEDIATE=1` + **专用线程阻塞 `read()`**，不要用 kqueue。immediate 下每来一包就唤醒，`read()` 醒来时一次性交付期间累积的全部包（低速低延迟、高速自动大批量，行为类似 NAPI），每批只一次系统调用；kqueue 的就绪判据完全一样却要多一次 `kevent()` |
| `/dev/bpf` 克隆节点 | **不存在**（实测 `ls /dev/bpf` → No such file）。必须遍历 `/dev/bpf%d`：`EBUSY` 试下一个、`ENOENT` 到上限。打开当前最后一个节点时内核会按需再造一个。上限 `sysctl debug.bpf_maxdevices` = 256 |
| `access_bpf` 组 | macOS **没有**（那是 FreeBSD 的做法，实测 `dscl . -list /Groups` 无匹配）。`/dev/bpf*` 是 `0600 root:wheel`，只能 root |

### 2.4 feth（if_fake）

| 事实 | 结论 |
|---|---|
| 是否存在 | **存在**，`sysctl net.link.fake.*` 可见 |
| 关键 sysctl | `net.link.fake.max_mtu = 2048`、`tx_headroom = 32`、`buflet_size = 512`、`qset_cnt = 4`、`link_layer_aggregation_factor = 96` |
| 创建权限 | **需要 root**：非 root 下 `ifconfig feth0 create` 返回 `SIOCIFCREATE2: Operation not permitted` |
| `struct ifdrv` | **不在**公开 SDK 的 `net/if.h` 中，必须自行声明。带 `#pragma pack(4)`，LP64 下 `sizeof == 40`（偏移 16/24/32）。**大小参与 ioctl 编号计算**，算错就得到不存在的 ioctl 号 → 已用 `static_assert` 钉死。实测 `SIOCSDRVSPEC = 0x8028697b`、`SIOCGDRVSPEC = 0xc028697b` |
| `net/if_fake_var.h` | **不在**公开 SDK 中。`struct if_fake_request` = `uint64_t reserved[4]`（32 字节，**内核校验必须全零**）+ 128 字节 union，**总 160 字节**。`IF_FAKE_S_CMD_SET_PEER = 1`、`IF_FAKE_G_CMD_GET_PEER = 1` |
| 私有 ABI 的版本风险 | **极低，无需降级到 ifconfig**：`if_fake_var.h` 在 xnu-7195(macOS 11) → xnu-12377(macOS 26) 的所有发布 tag 下文件 md5 完全相同，从未变动。Apple 自己的 `ifconfig fethN peer fethM` 走的就是这套 ABI |
| SET_PEER 的内核校验 | 五项，任一不满足返回 `EINVAL`：① `ifd_len >= 160`；② `reserved` 全零；③ peer 必须也是 feth（`ifnet_name()=="feth"` 且 `IFT_ETHER`）；④ 双方都不能已有 peer；⑤ 需要 root |
| **数据流向语义**（已对照 `feth_output_common()` 源码确认） | 主机从 feth0 发出的帧 → 在 feth1 上是 **input** 方向；我们向 feth1 的 BPF `write()` 一帧 → 走 feth1 的 output → 进入 feth0 的 **input** → 被主机 IP 栈收到，**不会** loopback 回 feth1。所以 BPF 只挂 feth1 一个描述符就能同时收发 |
| `BIOCSSEESENT=0` 的作用 | → `bd_direction = BPF_D_IN`，恰好滤掉**我们自己写进去的帧**（它们在 feth1 上是 output 方向）。**不设会形成回环** |
| `IFF_UP` 要求 | `bpfwrite` 里有硬检查 `if ((ifp->if_flags & IFF_UP) == 0) return ENETDOWN` → feth1 必须 UP；feth0 也必须 UP 才能让 IP 栈处理收到的帧 |
| **创建期 sysctl 快照** | ⚠️ `hwcsum` / `fcs` / `tso_support` / `lro` / `trailer_length` / `separate_frame_header` / `max_mtu` 等开关在 `feth_clone_create()` 那一刻被快照进接口，**创建后再改 sysctl 无效**。若 `hwcsum=1`，我们读到的帧校验和是留给硬件算的假值！本机实测默认全部为 0（正是我们要的），但代码里仍在创建前显式校验（`VerifyFethSysctls()`） |
| 内核分配的 MAC | `'f','e','t','h', unit>>8, unit&0xff` → feth0 = `66:65:74:68:00:00`（0x66 的 bit1=1 → 本地管理地址，合法） |
| MAC 设置策略 | 应把**系统侧**（feth0）的 MAC 设为设备汇报的 `OID_802_3_PERMANENT_ADDRESS`（RNDIS 语义下设备就是这块网卡，对端 ARP/DHCP 都按它建）；**驱动侧必须保留内核分配的不同 MAC**，否则两侧 IPv6 链路本地地址相同会触发 DAD 冲突。改 MAC 必须在 `IFF_UP` 之前 |
| `BIOCPROMISC` | 对 feth **不需要**：`feth_output_common` 无条件把帧投给 peer 并 tap，不做 MAC 过滤，能否读到只由方向决定 |
| DHCP | GUI 走 `SCPreferences` + `SCNetworkService` 注册**持久**服务（feth 不在 `SCNetworkInterfaceCopyAll()` 里，但可用 `_SCNetworkInterfaceCreateWithBSDName` SPI 构造接口对象）。NetworkExtension 的 VPN provider **只认这种服务**，临时服务会让它报 "No network route"。CLI 仍用 `sudo ipconfig set feth0 DHCP`（临时服务，只活到下次网络配置变更，不出现在系统设置里），拆除 `sudo ipconfig set feth0 NONE` |
| 性能上限警示 | 社区报告 feth 路径在超过约 5–8 Gbps 后会出现内核 mbuf 溢出并 panic。对本项目风险很低：RNDIS over USB 2.0 HS 实测约 200–300 Mbps，USB 3 下也难超 1–2 Gbps |
| 相关 ioctl（**在**公开 `sys/sockio.h` 中） | `SIOCSIFFLAGS`(i,16) `SIOCGIFFLAGS`(i,17) `SIOCSIFMTU`(i,52) `SIOCSIFLLADDR`(i,60) `SIOCIFCREATE`(i,120) `SIOCIFDESTROY`(i,121) `SIOCIFCREATE2`(i,122) `SIOCSDRVSPEC`(i,123) `SIOCGDRVSPEC`(i,123) |
| `IFNAMSIZ` | 16 |

### 2.5 开发环境的限制（影响测试策略）

- **无 root**：当前会话以 uid 501 运行，无法创建 feth、无法打开 `/dev/bpf*`。
  → 需要 root 的测试必须**可选、可跳过**，并在 CI/本地用 `TETHERKIT_ROOT_TESTS=1` 之类的开关控制。
- **不保证有 USB 设备**：立项时开发机上一个都没有，后来才接上过真实设备做验证。
  → USB 后端必须抽象成接口，提供内存 loopback mock，端到端测试与吞吐基准都跑在 mock 上。
  自动化测试**不得依赖设备在场**。
- 验证状态与仍未验证的事项统一记录在本文件第 6 节。

---

## 3. 目录结构

```
TetherKit/
├── AGENTS.md              本文件：agent 工作记忆
├── README.md              用户向文档（**英文，GitHub 默认展示的那份**）
├── README.zh-CN.md        同上的中文版；两份内容对等，改一份要同步另一份
├── CMakeLists.txt         顶层构建脚本
├── .clang-format          代码格式（Google 基线，100 列）
├── .clang-tidy            静态检查与命名约定
├── cmake/
│   ├── FindLibUSB.cmake        libusb-1.0 查找（pkg-config 优先 + Homebrew 回退）
│   ├── CompilerWarnings.cmake  警告选项 INTERFACE 目标
│   ├── Sanitizers.cmake        ASan/UBSan/TSan 开关
│   └── Optimizations.cmake     数据路径优化选项与取舍说明
├── include/tetherkit/     公开头文件（按模块分子目录）
│   ├── common/messages.def     **全部面向用户文案**（X-macro，中英两列）
│   └── capi/                   C ABI —— 全项目唯一的 extern "C" 边界
├── src/                   实现
│   ├── version.cc.in           CMake 注入版本号的模板
│   ├── capi/                   C ABI 实现（会话、网卡配置、日志、孤儿清理）
│   └── app/                    命令行入口
├── gui/                   SwiftUI 图形界面（SwiftPM 工程，见 docs/GUI-ARCHITECTURE.md）
│   ├── Sources/CTetherKit/     C ABI 的模块映射（头文件是符号链接）
│   ├── Sources/TetherKitIPC/   App 与 helper 共享：XPC 协议、模型、授权
│   ├── Sources/TetherKitCore/  C ABI 的 Swift 封装
│   ├── Sources/TetherKitHelper/  特权 helper（root，由 launchd 拉起）
│   ├── Sources/TetherKitApp/   SwiftUI 界面
│   ├── Resources/              Info.plist、LaunchDaemon plist
│   └── Scripts/                构建 / 安装 / 卸载脚本
├── tests/                 doctest 单元测试（单一二进制 + test-suite 过滤）
├── benchmarks/            自带轻量 harness 的性能基准
├── third_party/doctest/   vendored doctest 2.4.12 单头文件
└── docs/                  设计文档、协议笔记、性能报告
```

依赖方向**严格单向**，禁止反向或循环：

```
tk_common  ←（无依赖）
   ↑
tk_rndis / tk_net / tk_usb  ← tk_common
   ↑
tk_core    ← common + rndis + net + usb
   ↑
tetherkit（可执行）← core
tk_capi（C ABI）  ← core          → 打包成共享库 libtetherkit
   ↑
gui/（Swift）     ← libtetherkit
```

Swift 侧只能看见 `libtetherkit`，看不见任何 C++ 符号（导出符号白名单卡死在
`_tk_*`）。C++ 层的接口用了 `std::expected` / `std::span` / 抽象基类，
Swift 的 C++ 互操作吞不下，所以 C ABI 这一层不可省。

---

## 4. 代码规范（与 `.clang-tidy` 中的 CheckOptions 一致）

| 类别 | 约定 | 例 |
|---|---|---|
| 命名空间 | `lower_case` | `tetherkit`、`tetherkit::rndis` |
| 类型（class/struct/enum/别名） | `CamelCase` | `RndisStateMachine`、`BpfLink` |
| 函数与方法 | `CamelCase` | `SendEncapsulatedCommand()` |
| 局部变量与参数 | `lower_case` | `frame_len`、`max_transfer_size` |
| 私有/保护成员变量 | `lower_case_` 后缀下划线 | `handle_`、`request_id_` |
| 常量（全局/constexpr/枚举值） | `k` + `CamelCase` | `kMaxFrameSize`、`kCacheLineSize` |
| 宏 | `UPPER_CASE`（尽量不用宏） | |
| 文件名 | `snake_case`，实现用 `.cc`，头用 `.h` | `spsc_ring.h`、`bpf_link.cc` |

错误处理分层：

- **初始化 / 控制路径**：`std::expected<T, Error>`，错误可携带 errno / libusb 错误码 / 上下文串。
- **数据热路径**：**绝不**返回 `expected`、绝不抛异常、绝不分配。用返回计数 + 原子统计计数器表达失败。
- 全程 `-fno-exceptions`？**不**关异常（doctest 需要），但项目自身代码不 `throw`。

### 文案与多语言（中 / 英）

**面向用户的文字一律不写字面量**，全部走文案表。两套实现，同一个心智模型：

| | C++（库 + 命令行） | Swift（GUI + helper） |
|---|---|---|
| 文案表 | `include/tetherkit/common/messages.def`（X-macro，展开成枚举 + 两张表） | `gui/Sources/TetherKitIPC/LocalizedStrings.swift`（穷尽 switch） |
| 取文案 | `Tr(Msg::kFoo, args...)`，参数与 `std::format` 一致 | `L(.foo, args...)`，`String(format:)` 的 printf 风格 |
| 打日志 | `TETHERKIT_INFO_TR(Msg::kFoo, ...)` 等一组宏 | —— |
| 不带参数 | `Text(Msg::kFoo)` 返回 `string_view`，不分配 | `L10n.text(.foo)` |
| 漏一种语言 | 表长断言 + `common.i18n` 用例 | **编译不过**（switch 穷尽） |
| 占位符对不上 | `common.i18n` 逐条核对下标与类型 | `LocalizationTests` 逐条核对位置与类型 |

三条硬规矩：

1. **热路径禁用。** `Tr()` / `L()` 都会分配并格式化，和 `error.h` 一样只允许出现在
   初始化与控制路径上。热路径要文字时用 `Text(Msg::kFoo)`（纯查表，noexcept）。
2. **两种语言的占位符必须一一对应**（个数、下标、类型）。语序不同就用显式编号
   重排：C++ 是 `{0}`/`{1}`，Swift 是 `%1$@`/`%2$ld`。
3. **Swift 侧整数一律 `%ld` 并在调用点转 `Int`。** `%d` 只取 64 位实参的低 32 位。

语言从哪里来：

- 命令行：`--lang zh|en|auto`，缺省按 `TETHERKIT_LANG` → `LC_ALL` → `LC_MESSAGES`
  → `LANG` 依次推断。**语言在解析参数之前就定下来**，所以帮助文本与参数错误
  本身也是目标语言。⚠️ sudo 未必透传这些变量，那时要显式写 `--lang`。
- GUI：App 菜单与菜单栏面板里的语言开关（跟随系统 / 中文 / English），存
  UserDefaults 的 `TetherKitLanguagePreference`。

**切语言时必须同步三处，缺一处就会出现「界面英文、日志中文」**：Swift 文案表
（`L10n.apply`）、libtetherkit（`tk_set_language`）、helper（XPC 的 `setLanguage`
—— 它以 root 跑在 launchd 下，看不到用户偏好）。三处都在 `AppModel.applyLanguage`
里一起做，别在别处单独调其中一个。

---

## 5. 实现进度

图例：`✅ 已完成` `🚧 进行中` `⬜ 未开始`

| # | 提交 | 状态 | 备注 |
|---|---|---|---|
| 1 | `chore: 初始化项目脚手架与构建系统` | ✅ | CMake + 规范配置 + vendored doctest + 版本注入 |
| 2 | `feat(common): 基础设施层` | ✅ | 错误/日志/字节序/无锁队列/统计/线程 QoS |
| 3 | `feat(bench): 基准 harness 与微基准` | ✅ | 自带 harness，输出 Markdown 直接进 docs/ |
| 4 | `feat(rndis): RNDIS 协议层` | ✅ | 常量 + 控制消息编解码 + 数据包编解码 |
| 5 | `feat(net): feth 虚拟网卡与 BPF 链路层` | ✅ | 含私有 ABI 声明与 LoopbackLink |
| 6 | `perf(common): 无锁队列批量发布` | ✅ | 1514B 提速 2.4 倍、64B 提速 5.0 倍 |
| 7 | `feat(usb): USB 传输层` | ✅ | 设备发现/声明/控制通道/异步传输池 |
| 8 | `feat(rndis): RNDIS 状态机` + CTest 缺陷修复 | ✅ | **顺带发现测试一直在空跑，见第 7 节第 9 条** |
| 9 | `feat(core): 数据路径桥接` | ✅ | 三线程模型 + 背压 + 统计；修了 TX 统计恒为 0 的缺陷 |
| 10 | `feat(app): 运行时编排与命令行` | ✅ | 启动/停机顺序、信号处理、CLI |
| 11 | `docs: 设计文档、协议参考、性能指南` | ✅ | |
| 12 | `feat(capi): C ABI 边界与免 root 的三项能力` | ✅ | 版本/环境预检/设备枚举；日志改环形缓冲 + 轮询 |
| 13 | `refactor(core): Runtime 改为自持控制线程` | ✅ | 非阻塞 Start、一致快照、事件汇 |
| 14 | `feat(capi): 会话生命周期、状态快照与事件轮询` | ✅ | 枚举对齐用 static_assert 焊死 |
| 15 | `feat(capi): 网卡上网方式配置与孤儿网卡清理` | ✅ | DHCP / 静态 IP；feth 落盘登记 |
| 16 | `build: 输出共享库 libtetherkit` | ✅ | tk_capi 改 OBJECT 库；导出符号白名单 |
| 17 | `feat(gui): SwiftPM 工程骨架、C 互操作与 XPC 协议` | ✅ | 头文件走符号链接，永不失同步 |
| 18 | `feat(gui): 特权 helper 与授权凭据复核` | ✅ | LaunchDaemon + AuthorizationRef |
| 19 | `feat(gui): SwiftUI 设计系统与主界面` | ✅ | 状态卡/设备/吞吐/日志 |
| 20 | `feat(gui): 上网方式配置界面` | ✅ | DHCP / 静态 IP + 生效状态回读 |
| 21 | `build(gui): 打包与安装脚本、GUI 架构文档` | ✅ | |
| 22 | `feat(gui): 菜单栏实时速率与后台运行模式` | ✅ | MenuBarExtra + 仅菜单栏模式 + 自适应轮询；顺带修 helper 不清理失败态旧会话的缺陷 |
| 23 | `feat(gui): App 内一键安装与卸载特权组件` | ✅ | AEWP + helper 二进制 setuid(0)；载荷内嵌 .app，dist/helper 废除；「bash 对 euid≠ruid 掉权」的坑记入 SPIKE |
| 24 | `feat(gui): 应用图标` | ✅ | 外围白底按边缘连通泛洪抠透明（内部白色元素保留）；icns 全尺寸；Dock 实测核对 |
| 25 | `feat(gui): 检查更新（只查不换）` | ✅ | GitHub releases/latest + 语义化比较；每日静默 + 菜单手动；免证书分发下自动替换会被 Gatekeeper 拦死，故只查不换 |
| 26 | `feat!: 命令行更名 tetherkit-cli；App 自动维护 Finder 别名` | ✅ | OUTPUT_NAME 改产物名（`tetherkit` formula 名让位 GUI）；别名用 bookmark API（软链聚焦不认），首次启动自动建立 —— **brew 连 postinstall 都在沙箱里，写不了 /Applications（实测）**；本机聚焦索引损坏（mdutil unknown state），入索效果待索引重建后复核 |
| 27 | `build(ci): GUI 构建入 CI；发版附带 .app；tap 同步双 formula` | ✅ | GUI job（macos-14/26）；build-gui.sh 支持 --swift-build-flags=--disable-sandbox（SwiftPM 沙箱嵌不进 brew 沙箱） |
| 28 | `chore(release): v0.1.2 —— README 图标/截图/双 formula 安装说明` | ✅ | 中英双语；docs/assets |
| 29 | `chore(release): v0.1.3 —— 设备名不再因会话占用而丢失` | ✅ | capi 字符串记忆回填 + helper 占用判定修正（第 7 节第 17 条） |
| 30 | `feat(i18n): 全量文案外置，中英双语` | ✅ | C++ 约 390 条 + Swift 220 条；命令行 `--lang`、C ABI `tk_set_language`、GUI 语言菜单；XPC 协议号 2 → 3 |
| 31 | `chore(release): v0.1.4 —— 中英双语` | ✅ | README 英文版转正为默认（HoRNDIS 搜索意图 SEO）；**升级后用户必须在 App 内更新一次特权组件**（协议号变了） |
| 32 | `feat(gui): 特权组件与 App 版本不一致时给出更新入口` | ✅ | 比的是**库**版本而不是 Info.plist（`swift run` 没有 bundle）；只取版本号，构建配置不同不算不一致；协议号没变的版本以前完全没有提示 |
| 33 | `chore(release): v0.1.5 —— 组件版本对不上时可一键更新` | ✅ | 协议号仍是 3，旧组件照常能用；升级后管理行会提示更新，不更新也不会坏 |

### 当前状态

- **测试**：23 个 ctest 用例全部通过（新增 common.i18n 核对两种语言的占位符）；
  GUI 侧 `swift test` 17 个用例通过（含 LocalizationTests、HelperConstantsTests）
- **构建**：`-Werror` 零告警；命令行、共享库、GUI 三套产物均可构建
- **可运行**：`--version` / `--help` / `--list` 均正常；非 root 启动给出清晰提示
  并返回退出码 1；`TetherKit.app` 与 `tetherkit-helper` 打包后均可启动；
  特权组件可在 App 内一键安装 / 卸载（安装路径已真机走通）；
  组件版本与 App 对不上时管理行点亮「更新特权组件」（`brew upgrade` 只换 .app，
  装在 /Library 的那份不会跟着变 —— 协议号没变时以前完全没有提示，
  用户唯一能察觉的迹象是「更新说明里写着修好的毛病还在」；两种语言各截窗口核对过）；
  中英双语已实测：命令行两种语言的 `--help` / `--list` / 参数错误均正确，
  GUI 在菜单里切换语言后主窗口与 App 菜单**立即**变（不需重启，截窗口核对过）
- **已验证**：USB 侧在真实 RNDIS 设备上跑通（枚举、声明接口、RNDIS 握手），
  且 USB 这一侧**不需要 root**；feth 私有 ABI、两个私有 BPF ioctl、
  以及「BPF 写入能让对侧 IP 栈收到帧」这个核心前提都已实测确认。详见第 6 节
- **已压测**（2026-07-28，Android 手机 USB 网络共享）：端到端 iperf3 实测
  **RX 324~327 Mbps / TX 234~241 Mbps**（USB 2.0 高速，理论上限 426 Mbps）；
  GUI 与真实设备的完整链路走通（插上 → 连接 → DHCP 拿到地址 → 双向 ping）。
  详见第 6.4 节与 [docs/BENCHMARKS.md](docs/BENCHMARKS.md)
- **已修复**：TX 高负载丢帧的根因已查明 —— 桥接层在 bulk OUT 传输池占满时立即
  丢弃批次剩余帧，而槽位只需等几百微秒。改为等待后 TX 丢帧 1889 → 0、
  TCP TX 重传 3829 → 0、双向并发 TX 4.8 → 87 Mbps；Ctrl-C 优雅停机在修复后
  也复核过（打出「已停机」、feth 无残留）。见第 6.5 节
- **已修复**（2026-07-28）：连接后 GUI 设备列表把「vivo iQOO Z10x + 序列号」
  退化成「USB 设备 2d95:600b」并挂满整个会话 —— 启动竞态窗口里的一次枚举
  读不到字符串描述符，空串覆盖了好数据。修法是回填而不是堵窗口：capi 记住
  每台设备上次成功读到的字符串，读不到就回填；helper 的占用判定同步修正
  （握手窗口算占用、failed/stopped 死会话不算）。真机复核过（read_strings
  =false 时名字完整）。见第 7 节第 17 条
- **仍未查清**：TCP TX 呈双峰（约 240 / 约 300 Mbps，两态都零重传）；
  双向并发时 RTT 仍从 0.4 ms 膨胀到 16.6 ms（已不再造成吞吐塌陷）

### GUI 相关

**改 GUI、C ABI 或 Runtime 线程模型之前，先读 `docs/GUI-ARCHITECTURE.md`。**
那里记着一批「写错了不会当场报错、但会以很难查的方式出问题」的约束：UTF-8
边界截断、枚举顺序耦合、`cp -a` 与软链、install_name_tool 后必须重签、
授权复核的三个标志位、pipe 死锁的读写顺序等。

## 6. 验证清单（需要 root 或真实 RNDIS 设备）

### 6.1 已验证：USB 侧（**无需 root**）

已在一台真实 RNDIS 设备上实测。结论按平台事实记录 —— 它们是 macOS/libusb 的行为，
不依赖具体设备型号。

**① 非 root 下 `libusb_open` 不会返回 `LIBUSB_ERROR_ACCESS`，而是直接成功。**

原先的假设是错的。macOS 打开 USB 设备**不需要 root**（不同于 Linux 的 udev 权限
模型）。整个 USB 侧 —— 枚举、`libusb_open`、声明接口、收发传输 —— 都能以普通用户
运行；root **只**为创建 feth 与打开 `/dev/bpf*` 而需要。`--list` 因此明确标注了
「不需要 root」。

**② ⚠️ `libusb_kernel_driver_active() == 1` 在 macOS 上并不预示 `claim` 会失败。**

这是本节最容易踩错的一条。同一台复合设备上实测：

| 接口签名 | 匹配到的驱动 | `kernel_driver_active` | `libusb_claim_interface` |
|---|---|---|---|
| `02/02/ff` RNDIS 通信 | **无** | 0 | ✅ 成功 |
| `0a/00/00` RNDIS 数据 | `AppleUserECMData`（DriverKit dext） | **1** | ✅ **仍然成功** |
| `02/02/01` CDC-ACM 控制 | `AppleUSBACMControl`（kext） | 1 | ❌ `LIBUSB_ERROR_ACCESS` |
| `03/00/00` HID | `AppleUserUSBHostHIDDevice` | 1 | ❌ `LIBUSB_ERROR_ACCESS` |
| `ff/42/01` 厂商自定义 | 有 | 1 | ❌ `LIBUSB_ERROR_ACCESS` |

`kernel_driver_active` 只反映 IOKit 里有驱动**匹配（matched）**，**不**反映该驱动是否
**独占持有**接口。DriverKit dext（`com.apple.DriverKit.AppleUserECM`）匹配上 `0a/00/00`
数据接口后并不独占，claim 照样成功；而 kext（ACM/HID）是真独占。

**所以：不要拿 `kernel_driver_active` 做预检并提前报错**，那会把本来能用的设备误判成
不可用。唯一可靠的判定是直接 claim 看返回值。又因为 macOS 上没有
`libusb_detach_kernel_driver`（见第 7 节第 7 条），claim 失败就确实无解。

好消息是 RNDIS **通信**接口（`02/02/ff`）压根没有驱动匹配 —— 印证了「macOS 没有
RNDIS 内核驱动」这个立项前提。

复现方法：`--list` 看识别结果；接口级细节用 `ioreg -c IOUSBHostInterface -r -l`
查驱动匹配，再用一段十几行的 libusb 程序逐接口 `claim` 看返回值。

### 6.2 已验证：feth / BPF 侧（**需 root**）

③④⑦ 的复现方法：`sudo TETHERKIT_ROOT_TESTS=1 build/bin/tetherkit_tests --test-suite=net.feth`
（不设该环境变量时这些用例**跳过而非失败**，跳过原因会打印出来），以及直接
`sudo build/bin/tetherkit-cli` 跑一次。⑤⑥ 目前**没有**进测试套件，是用一次性探针测的
（做法写在各条里，⑥ 的缺口已记进 6.3）。

**③ `feth` 配对的私有 ABI 在 macOS 26 上可用。**

`SIOCSDRVSPEC` + `struct if_fake_request` 这条路径完全成立：创建、配对、设 MTU/MAC、
UP、销毁全流程通过。第 2 节里用 `static_assert` 钉死的那些 ioctl 编号和结构体大小
是对的 —— 编号算错的话这里会直接失败。

**④ 两个私有 BPF ioctl 在 macOS 26 上都可用。**

- `BIOCSBATCHWRITE`（一次 `write()` 发多帧）→ 生效，运行日志里显示「批量写 已启用」。
  这坐实了第 7 节第 4b 条的更正：「Darwin BPF 不支持批量写」确实是错的。
- `BIOCSNOTSTAMP`（关每帧时间戳）→ 生效，日志显示「时间戳 已关闭」。

**⑤ `BIOCSBLEN` 的实际上限是 32 MiB，`debug.bpf_maxbufsize` 不是它的约束值。**

按 `BIOCSBLEN` → `BIOCSETIF` → `BIOCGBLEN` 的顺序实测（即挂上接口后读回**有效**值）：

| 请求 | 挂接口后的有效值 |
|---|---|
| 4 KiB / 1 / 4 / 8 / 16 / 32 MiB | 原样生效，一字不改 |
| 64 MiB、2 GiB | 都被钳到 **32 MiB**（`0x2000000`） |

⚠️ 反直觉的一点：`sysctl debug.bpf_maxbufsize` 在本机报的是 **512 KiB**，
比实际能设的小 64 倍 —— **别拿这个 sysctl 去推 `BIOCSBLEN` 的上限**，对不上。
（`debug.bpf_bufsize` 报的 4 KiB 倒确实是默认值。）
另外 32 MiB 只是「设得进去」，不等于「值得设这么大」：默认的 4 MiB 已经够用。

**⑥ BPF `write()` 确实能让对侧 feth 的 IP 栈收到帧 —— 整个方案的核心前提成立。**

用 ARP 往返闭环验证：系统侧 feth 配 `10.99.99.1`，从**驱动侧** feth 的 BPF 写一个
问 `10.99.99.1` 的 ARP 请求，随即在同一个 BPF 上读到了系统侧 IP 栈发回的
**ARP reply**（源 MAC 正是系统侧 feth 的 MAC，宣称拥有该 IP）。

这一个实验同时证明了两件事：

- `write()` 到驱动侧 → 帧穿过 feth 对 → **对侧 IP 栈真的收到并处理了**（否则不会应答）；
- `BIOCSSEESENT=0` 的回环抑制正确 —— 读回来的只有 input 方向的 reply，
  没有我们自己刚写进去的那个 request。

⚠️ 但这条路有个前置条件，见第 7 节第 14 条（`BIOCSHDRCMPLT`）。

**⑦ 端到端：RNDIS 握手 → feth 建对 → BPF 挂载 → 优雅停机，全程跑通。**

一次完整启动的关键节点：声明接口拿到 bulk IN/OUT（`wMaxPacketSize` 512）与中断 IN →
RNDIS 协商完成（版本 1.0、MTU 1500）→ 查到设备 MAC 与链路速率 → 状态机进入
「数据已就绪」→ feth 对创建并配对、系统侧 MAC 改为设备 MAC → BPF 挂上驱动侧。

`SIGTERM` 后拆除顺序正确，**feth 接口无残留，默认路由全程未被改动**。

### 6.3 待验证

原先的三项**已全部完成**，结论并入 6.4：

- [x] 端到端吞吐 → RX 324~327 Mbps / TX 234~241 Mbps，见 6.4。
- [x] `net.feth` 套件缺 ARP 往返闭环 → 已补成 root 用例
      「ARP 往返闭环：BPF 写入的帧确实进了对侧 feth 的 IP 栈」，真机上通过。
      第 6.2 节 ⑥ 的结论不再只活在文档里。
- [x] Android 的 RNDIS quirk → 见 6.4「设备汇报的参数」。

- [x] TX 丢帧的**根因** —— 已查明并修复，见 6.5。
- [x] 修复后的优雅停机 —— 在真正的终端里 `sudo build/bin/tetherkit-cli` 再 Ctrl-C
      （SIGINT，与 SIGTERM / SIGHUP 共用同一个处理器）：打出「已停机」，
      `ifconfig` 无 feth 残留。**新增的背压等待没有卡住停机路径。**
      注意这一条只能在真终端里验证，走提权脚本会被吞掉信号，见第 7 节第 15 条。

仍然待查：

- [ ] TCP TX 的双峰行为（约 240 vs 约 300 Mbps 两个稳定态，都是零重传）。
- [ ] 双向并发下 RTT 从 0.4 ms 膨胀到 16.6 ms；已不再造成吞吐塌陷，
      但缩小 RX 排队深度能改善多少未测。
- [ ] 静态 IP 模式下 DNS 是否真的被 IPMonitor 采纳（见 docs/GUI-ARCHITECTURE.md）——
      本轮只验证了 DHCP 路径。

### 6.4 已验证：真机端到端（Android USB 网络共享）

**设备**：vivo iQOO Z10x（V2445A / PD2445M），Android 15（SDK 35），
USB `2d95:600b`，接口签名 `e0/01/03`（无线类 RNDIS 变体），协商 USB 2.0 高速。
macOS **没有**为它创建任何网络接口 —— 再次印证「macOS 无 RNDIS 驱动」这个立项前提。

**设备汇报的参数**（这就是原先想验证的 Android quirk）：

```
RNDIS 协商完成：版本 1.0，MTU 1500，设备聚合上限 15800 字节 / 10 包，TX 对齐 1 字节
```

即 `MaxPacketsPerMessage=10`、`MaxTransferSize=15800`、`PacketAlignmentFactor=0`。
**与主线 Linux gadget 的 `1 包 / 1580 字节` 差了 10 倍** —— messages.cc 里
「打了聚合补丁的 Android 内核报 3 或更多」那条注释得到了真机证实。
没有出现异常值，现有的钳位逻辑全程没有触发。

⚠️ 顺带一条：**设备每次会话汇报的 MAC 都不同**（Android 随机化 RNDIS MAC），
所以别把设备 MAC 当作稳定标识来缓存。

**吞吐**：RX 326~327 Mbps（0 重传）/ TX 239~302 Mbps（0 重传，修复后）。
完整证据链、A/B 数据与机理分析都在
[docs/BENCHMARKS.md](docs/BENCHMARKS.md) 的「真机端到端实测」一节。

⚠️ **排查陷阱**：手机侧 `/proc/net/dev` 的 `rndis0` `rx_errs` 计数器**不可信** ——
它会给每一帧都记一次错误（50 个 ping 全部得到回应，`rx_pkts` 和 `rx_errs` 却同时 +51）。
排查 TX 问题请以 iperf3 的实际丢包率和 TetherKit 自己的统计为准。

### 6.5 已修复：TX 高负载丢帧

**根因一行话**：`Bridge::RunTransmitExtractor` 在 USB 传输池占满时**立即丢弃**
本批剩余帧，而槽位只需等几百微秒就会释放。

旧代码在 `SendFrames` 返回 0 时 `AddDroppedFull(剩余) + break`，理由是
「等待会让 BPF 内核缓冲堆积成**看不见的**内核丢包，不如在用户态丢并计数」。
两个前提都不成立：`bs_drop` 每批都被 `ReadFrames` 读回来、就显示在统计行的
「内核丢包」列里；而 4 MiB 的内核缓冲（250 Mbps 下约 130 ms 弹性）**正是**
该吸收突发的那一级。量级更能说明问题：设备汇报 15800 字节 / 10 包，一个 256 帧
的提交分片需要约 **26 个槽**，池里只有 **4 个** —— 每个分片必然在第 4 个槽之后
撞上背压，剩下 200 多帧当场丢弃。

**修复**：`SendFrames` 返回 `SendOutcome{consumed, sent_frames, sent_bytes, skipped}`；
桥接层在 `consumed == 0` 时 `WaitForSendCapacity(50ms)` 等槽位（完成回调用条件
变量唤醒），醒来回到循环顶部重查停机/暂停再重试，一帧不丢。

| 指标 | 修复前 | 修复后 |
|---|---:|---:|
| TetherKit 自己的 TX 丢帧 | 1889 | **0** |
| TCP TX 重传 | 3829 | **0** |
| 双向并发 TX | 4.8 Mbps | **87 Mbps** |
| 单向 TCP RX（回归） | 324~327 | 326~327 |

两点诚实说明：双向 RX 从 320 降到 240 —— 那不是退步而是公平性恢复（修复前 TX
被饿死，RX 独占链路；合计仍是约 327 Mbps）。另外原先归因于「bufferbloat」的
双向塌陷，其实 bufferbloat 只是次要因素：RTT 膨胀依然存在，但把丢帧修掉后
TX 就从 4.8 回到了 87 Mbps。

**顺带否掉一条旧调优建议**：修复前把 `--tx-transfers` 提到 16 能把丢帧降到约
1/4，那是在拿池深度补偿「不肯等待」。修复后 4 / 8 / 16 三档重复三次实测**无可
分辨差异**，默认值保持 4。

⚠️ 同时修掉的两个统计错账：超长帧与短于以太头的帧原先被计入「已发出」
（`SendFrames` 只返回一个数，注释声称调用方能推断出丢弃，实际推断不出来）；
`SendFrames` 返回错误时批次剩余帧不进任何计数器，凭空消失。

---

## 7. 已知坑与规避（**踩过的坑写在这里，不要重复踩**）

1. **缓存行是 128 字节**，不是习惯性的 64。SPSC 队列若按 64 对齐，生产者/消费者索引仍会
   落在同一缓存行上，false sharing 依旧存在。项目统一用 `kCacheLineSize = 128`。
2. **`std::format` 需要部署目标 ≥ 13.3**，否则报 `to_chars unavailable`。CMake 已强制。
3. **`std::hardware_destructive_interference_size` 在 Apple libc++ 上不存在**，别用。
4. **BPF 没有零拷贝**，别去找 `BIOCSETZBUF`。但**有批量写** —— 见下一条。
4b. ~~「Darwin BPF 不支持批量写」是错的~~。第 2 节最初记录的这条结论已更正：
   macOS 14+ 有私有 ioctl `BIOCSBATCHWRITE`，一次 `write()` 能发多帧。
   本项目已实现并做特性探测（`BpfLink::WriteFramesBatched`），
   macOS 13 及更早自动回落到逐帧 write。
5. **BPF `BIOCSBLEN` 必须在 `BIOCSETIF` 之前设置**，顺序错了缓冲区大小不生效。
6. **BPF 遍历必须用 `bh_hdrlen`**，不能用 `sizeof(struct bpf_hdr)` —— 头部后面有对齐填充。
7. **libusb 在 macOS 上没有 `detach_kernel_driver`**。若接口被内核驱动占用，只能走
   codeless kext / dext 或 re-enumerate，不能靠 libusb 解决。
8. **别默认跑测试时有设备、有 root**，所以「跑不起来」不等于「代码错了」；
   离线可验证的部分必须全部覆盖到 mock 测试里，需要 root 的用例要能干净跳过。
9. **CTest 的 `add_test` 里绝不能给参数加引号。** 写
   `COMMAND tetherkit_tests --test-suite="${_suite}"` 时，CMake 会把引号当作参数
   内容原样传下去（`ctest -V` 可见传的是 `"--test-suite="foo""`），doctest 匹配不到
   任何用例 → 跑 0 个用例 → doctest 对零匹配返回退出码 0 → ctest 报 Passed。
   **整套测试静默失效却全绿**，实际掩盖了 4 个真实失败。
   正确写法是 `--test-suite=${_suite}`（无引号）。
10. **给 ctest 用例加「至少跑到一条断言」的保险时，必须用
   `FAIL_REGULAR_EXPRESSION` 而不是 `PASS_REGULAR_EXPRESSION`。** 后者会
   **取代**退出码判定（CMake 的文档行为），一旦设上，真实的断言失败反而被忽略 ——
   等于把上一条刚修好的坑又挖回来。`FAIL_` 是叠加在退出码之上的。
11. 时间相关的类**不要在构造函数里自己读时钟**。`PeriodicTimer` 原来那样写，
   导致构造函数读到的时刻比调用方手里的 `now` 略晚，「now + period」反而还没到期，
   单元测试随机失败且不可复现。改成显式传入计时起点（默认值保留便利写法）。
12. **⚠️ macOS 上的同步 libusb 中断传输会永久阻塞，timeout 参数根本不被遵守。**
   一旦踩上，症状是控制线程卡死、统计不再输出、连 SIGTERM 都响应不了、
   退出时 feth 接口残留。栈长这样：
   ```
   Poll → WaitForNotification → do_sync_bulk_transfer
        → sync_transfer_wait_for_completion → handle_events → poll(∞)
   ```
   原因链两层（均可在 libusb 源码里核对）：① darwin 后端给所有 transfer 打
   `USBI_TRANSFER_OS_HANDLES_TIMEOUT`，于是 `libusb_get_next_timeout` 跳过它们、
   返回「无超时」，同步等待里的 `poll()` 无限期阻塞；② 而 IOKit 侧 darwin 的
   `submit_interrupt_transfer` 用的是 **`ReadPipeAsync`（无超时变体）**，
   不是 bulk 用的 `ReadPipeAsyncTO` —— 所以中断传输的 timeout **压根不生效**。
   **把 timeout 从 0 改成 1 ms 并不能解决**：第 ② 条决定了它对中断端点自始至终无效。
   唯一正确解法：提交常驻的**异步**中断传输，让它在事件线程上完成，
   `WaitForNotification` 只查一个原子标志，永不进入 libusb 的等待路径。
   → 已如此实现，见 `UsbControlChannel::StartNotificationListener`。
13. 顺带记住：`timeout = 0` 在 libusb/darwin 上表示**无限等待**，不是「不等待」。
   想「只探一下」要用非零的最小值（`kProbeOnlyTimeoutMillis`），
   而且如上所述对中断端点连这个都不管用。
14. **不设 `BIOCSHDRCMPLT = 1` 的话，往 feth 上的 BPF `write()` 直接返回 `ENXIO`
   （"Device not configured"），根本不是「帧头被改写」这么轻。** 做过对照实验：
   同一段代码、同一个接口，唯一差别就是设不设这个 ioctl —— 不设必 `ENXIO`，
   设了 `write` 立刻成功。
   `bpf_link.cc` 里原来的注释只说了 `hdrcmplt=0` 会「剥掉前 14 字节重建帧头」，
   那是 `hdrcmplt` 的**语义**；在 feth 上的**实际后果**是写操作压根不成立
   （`if_fake` 的输出路径处理不了 `AF_UNSPEC` 那条重建分支）。
   排查 `ENXIO` 时很容易误以为是接口没起来或名字写错 —— 先查这个 ioctl。
   顺序上它必须在 `BIOCSETIF` 之前，且批量写（`BIOCSBATCHWRITE`）硬性要求它是 1。

15. **⚠️ `osascript ... with administrator privileges` 会吞掉进程间的 SIGTERM 投递。**
   用它做提权测试时，脚本里 `kill -TERM $pid` 返回 0、目标进程的 `blocked` 与
   `pending` 掩码都是 0、`sigaction` 装的 handler 也确实在位（`sample` 能看到
   handler 地址不是 `SIG_IGN`），但**信号永远不会到达**，进程只能 `kill -9`。
   用一个 15 行的 C 程序做过对照：普通 shell ✅、普通 `osascript` ✅、
   加 `with administrator privileges` ❌。
   → 后果：**别用这条提权链去验证优雅停机**，会得到「停机卡死」的假故障，
   而且它跟被测代码毫无关系（修复前后的运行日志里都是清一色的 `Killed: 9`，
   一度被误当成新引入的回归）。要验证端到端停机，得在真正的终端里
   `sudo build/bin/tetherkit-cli` 再 Ctrl-C —— 这样验证过，正常打出「已停机」
   且 feth 无残留。

16. **「刻意这样做」的注释也可能是错的 —— 尤其是当它读起来很有说服力时。**
   TX 丢帧的根因（第 6.5 节）藏了整整一个版本，就因为那段丢弃逻辑配了一条
   自信的注释：「等待会让内核缓冲堆积成看不见的丢包」。两个前提都不成立：
   `bs_drop` 每批都被读回来并显示在统计行里；而 4 MiB 内核缓冲正是该吸收突发
   的那一级。
   → 教训：**写「刻意」时要能说出量级**。这里只要算一下「一个 256 帧的分片需要
   约 26 个传输槽，而池里只有 4 个」就会立刻发现不对。审查时看到
   「刻意 / deliberately / on purpose」，先去核它的数量级假设。

17. **「尽力而为」的字段，空值不能覆盖已知的好值。** 连接后设备名退化成
   VID:PID 的缺陷是三层叠加：字符串描述符在设备被占用时读不到（空串）、
   GUI 在「已点连接但状态还没轮询到 running」的窗口里恰好刷了一次设备列表
   （空串覆盖好数据）、running 后列表冻结（退化名固化到会话结束）。
   修复不去堵竞态窗口 —— XPC 往返之间天然有间隙，堵不完 —— 而是让空串不再
   出现：`tk_list_devices` 按「总线 + 地址 + VID:PID」记住上次成功读到的
   字符串，读不到就回填，设备离场即清除记忆（防止旧名字串到接替同一地址的
   新设备上）。**「这次拿不到」≠「设备没有名字」**；一切 best-effort 字段
   同理 —— 消费方拿旧值兜底或生产方回填，二选一，否则瞬时失败会固化成
   持久的数据退化（纯逻辑在 `ReconcileDeviceStrings`，capi.support 有单测）。
   顺带修正 helper 的占用判定：原来的「session 非 nil」两头都错 —— 握手期间
   session 还没登记（并发枚举会往握手中的控制端点插传输），failed/stopped
   的死会话早已释放设备（拔掉重插后永远读不到名字）。改按「真的持有」判定：
   sessionStarting 标志 + runState ∈ {starting, running, stopping}。
18. **SwiftUI 不知道「全局查表」变了。** 文案改成运行期查表之后，切语言不会
   让任何 `@Observable` 属性看起来变过，视图体自然不会重算 —— 界面就那么留在
   旧语言里。对策是让语言变化本身成为一个可观察的值（`AppModel.languageRevision`
   每次切换加一），再把它当 identity 用：主窗口与菜单栏面板都挂
   `.id(model.languageRevision)`，强制整棵树重建。
   **`.commands { }` 里更隐蔽**：里面每个 `Button` 的标签各自是独立表达式，
   实测（AppleScript 读菜单项名核对）切完语言只有语言菜单自己变了 —— 它读了
   `languagePreference` 所以有依赖 —— 旁边的「检查更新…」还是旧语言。
   修法是把这一组包进**同一个 View**，在它的 body 里读一次 revision，
   整组就一起重算（见 `AppMenuItems`）。
   同一类问题还有一个变种：**`static let` 存的文案只求值一次**，切语言后
   永远不更新。凡是存文案的静态成员一律改成计算属性（`AppModel` 的三条授权
   提示、`NetworkCard.dnsHint` 都踩过）。

---

## 8. 常用命令

```bash
# 配置 + 构建（警告当错误）
cmake -S . -B build -DTETHERKIT_WARNINGS_AS_ERRORS=ON && cmake --build build -j10

# 跑测试
ctest --test-dir build --output-on-failure

# ThreadSanitizer 验证无锁队列（重要！）
cmake -S . -B build-tsan -DTETHERKIT_ENABLE_TSAN=ON && cmake --build build-tsan -j10 \
  && ctest --test-dir build-tsan --output-on-failure

# 性能基准（务必用未开消毒器的 Release 构建）
cmake -S . -B build-rel -DCMAKE_BUILD_TYPE=Release && cmake --build build-rel -j10 \
  && ./build-rel/bin/tetherkit_bench

# GUI：构建、测试、打包
TETHERKIT_LIB_DIR=$PWD/build/lib swift build --package-path gui
TETHERKIT_LIB_DIR=$PWD/build/lib swift test  --package-path gui
./gui/Scripts/build-gui.sh

# 两种语言各看一眼（改过文案就跑一下）
./build/bin/tetherkit-cli --lang en --help
./build/bin/tetherkit-cli --lang zh --list
ctest --test-dir build -R common.i18n --output-on-failure
```

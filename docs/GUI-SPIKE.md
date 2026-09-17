# GUI 与提权可行性验证

本文记录一次探索性验证的结论：**能不能在 TetherKit 之上做一个原生 Swift 图形界面，
并让它以合适的方式取得配置网络所需的 root 权限。**

结论是能，但过程中排除掉了三条看起来更"正统"的路线。**被排除的路线和排除理由，
比最终方案本身更值得记录** —— 否则下次还会有人再走一遍。

所有结论都在 macOS 26.6 / Apple Silicon / Xcode 26.6 / Swift 6.3.3 上实测。

---

## 1. 结论速览

| 能力 | 结论 | 依据 |
|---|---|---|
| C API 现状 | **不存在** | 全仓库零 `extern "C"`，只有 C++23 头 + CLI |
| Swift 调用 C++ | 不可行 | `std::expected` / `std::span` / 抽象基类，Swift interop 吞不下 |
| USB 枚举 | 不需要 root | 实测通过 |
| 创建 feth | 需要 root | 实测通过 |
| 配 IP（`SIOCAIFADDR`） | 可行，configd 不干预 | 实测通过 |
| 子网/具体路由 | 可行 | 实测通过 |
| DHCP | **系统客户端可用** | 实测拿到租约，`State: BOUND` |
| DNS | **自动配好**（scoped） | 实测 |
| scoped 默认路由 | **自动配好** | 实测 |
| 抢全局默认路由 | 需手工一步 | 仅当有更高优先级服务在跑时 |

---

## 2. 核心事实：feth 没有 IOKit 节点

这一条是后面一连串限制的**共同根因**。

`if_fake`（feth）通过 `SIOCIFCREATE` → `ifnet_attach` 创建，**不注册任何 IOKit
provider**，因此在 IORegistry 里没有 `IONetworkInterface` 节点。

实测对照：

```
IOKit IONetworkInterface：en0–en7、anpi0/1/3、vmenet0/1   ← 无 feth
NetworkInterfaces.plist： feth 出现 0 次
ipconfig getiflist：      en4 en5 en6 bridge0 en0 en7      ← 无 feth
SC 动态存储：             State:/Network/Interface/feth0/Link  ← 有！
```

最后一行是关键反差：configd 的**动态存储**能看见 feth 的链路状态（那一层由路由
socket / KEV 事件喂养），但 **SCNetworkInterface 服务层看不见**（那一层枚举 IOKit）。

一句话：**只读的链路状态拿得到，可写的服务配置拿不到。**

注意 `vmenet0/1`（Virtualization.framework）**在** IOKit 里 —— 虚拟接口本身没问题，
问题是 `if_fake` 这种纯 ifnet 附着的方式没有 IOKit 存在感。

---

## 3. 被排除的路线（3.1 后来被推翻，见 §3.1）

### 3.1 SCPreferences 建持久网络服务 ✅（立项时的判断是错的）

想法：用 `SCPreferences` + `SCNetworkService` 建一个真正的网络服务，让 macOS 自己
跑 DHCP、管 DNS、算路由。

立项时的排除理由：`SCNetworkInterfaceCopyAll()` 枚举的是 IOKit 节点，feth 不在
其中，以为无法为它创建 `SCNetworkService`。

**这条结论只对了一半，后来被实测推翻。** 被枚举不到 ≠ 建不出来：
`SCNetworkInterfaceCopyAll()` 确实只走 IOKit，但 SystemConfiguration 另有一个
按 BSD 名构造接口对象的 SPI，它只做 `SIOCGIFFLAGS` + 造 entity，**完全不碰
IOKit**（见 configd 开源实现 `SCNetworkInterface.c`）：

```c
// SCNetworkConfigurationPrivate.h（Apple 开源，macOS 10.5+ 起就有）
SCNetworkInterfaceRef
_SCNetworkInterfaceCreateWithBSDName(CFAllocatorRef allocator,
                                     CFStringRef    bsdName,
                                     UInt32         flags);
```

拿到接口对象之后，`SCNetworkServiceCreate` / `SCNetworkSetAddService` /
`SCPreferencesCommitChanges` 全是公开 API，feth 就此成为「系统设置 → 网络」里
一条真正的服务。实测 `networksetup -listallnetworkservices` 能列出它。

**为什么这件事非做不可**：`ipconfig set` 的临时服务只有 `State:` 层，没有
`Setup:` 层。普通流量不受影响，但 **NetworkExtension 的 packet-tunnel provider
会拒绝把这种接口当作可用的底层路径** —— FortiClient 在 feth0 明明有地址、有
scoped 路由的情况下照样报 "No network route to host"，日志里是
`SCNetworkReachability`/`nw_path` 找不到服务。换成注册服务后 VPN 一次就连上。

代价是服务会持久化（跨进程、跨重启），所以必须自己负责回收：网卡销毁时删、
启动兜底时按 TetherKit 标记全扫一遍（`src/capi/managed_network_service.cc`）。

要让 `SCNetworkInterfaceCopyAll()` 也看见 feth 才需要写 IOKit driver ——
而那一步并不需要。

### 3.2 SCDynamicStore 凭空注入服务 ❌

想法：绕开偏好设置层，直接往动态存储写 `State:/Network/Service/<uuid>/IPv4` 和
`/DNS`（VPN 客户端的常见手法），让 configd 自己把 feth 算成一个服务。

实测过程：

1. 只写 `/DNS` → 不被采纳
2. 补齐 `/IPv4`（含 `Addresses`、`SubnetMasks`、`InterfaceName`），且接口和地址
   都真实存在 → **仍不被采纳**

`scutil --dns` 里始终找不到注入的解析器；`State:/Network/Global/IPv4` 的
`PrimaryService` 是个 UUID，说明 IPMonitor 只认从 `Setup:` 层实例化出来的服务。

而写 `Setup:` 层要回到 3.1 的死结。

⚠️ **这条的适用范围很窄，别推广。** 它只证明"**手工捏造**的动态存储条目不被采纳"。

实测反证：`ipconfig set feth0 DHCP` 之后，IPConfiguration 发布了
`State:/Network/Service/DHCP-feth0/{DHCP,DNS,IPv4}` —— **和这里手工写失败的是同样的键** ——
IPMonitor 完全采纳（DNS 生效、默认路由装上）。见 §6.3。

差别在于服务是否经正规路径注册，不在于键的内容。所以 feth 上的 configd 集成
**是可行的**，只是不能用手写动态存储这条捷径。

### 3.3 SMAppService 安装特权 helper ❌

想法：用 macOS 13+ 的现代 API 注册 LaunchDaemon。

排除理由与技术无关，与**分发方式**有关：`SMPrivilegedExecutables` /
`SMAuthorizedClients` 靠代码签名的 designated requirement 双向绑定。源码分发
（Homebrew formula）下每台机器编译出的 cdhash 都不同，写死在 plist 里的 DR
必然对不上。

附带：SMAppService **不弹密码框** —— 审批入口是「系统设置 → 登录项与扩展」。
这是 Apple 从 macOS 13 起的刻意设计，会弹密码框的 `SMJobBless` 已废弃。

---

## 4. 最终方案

```
TetherKit.app (uid 501，不需要 root)
  │ ① 直接调 C API 做免 root 的事：环境预检、USB 枚举
  │ ② AuthorizationCopyRights → 弹指纹/密码 → AuthorizationRef
  │ ③ AuthorizationMakeExternalForm → 32 字节凭据
  │
  ├── XPC（com.tetherkit.helper，.privileged）──►  tetherkit-helper (uid 0)
  │                                                  │ ④ CreateFromExternalForm 还原
  │                                                  │ ⑤ CopyRights 复核
  │                                                  │    （**不带** interactionAllowed）
  │                                                  │ ⑥ 复核通过才执行特权操作
  └──────────────────────  结果  ◄───────────────────┘
```

helper 由传统 LaunchDaemon 拉起（`/Library/LaunchDaemons/` + `MachServices`），
按需启动，不需要 `KeepAlive`。

### 为什么安全性靠 AuthorizationRef 而不是代码签名

helper 的 root **来自 launchd**，跟用户按没按指纹毫无关系 —— 它一启动就是 root，
任何能连上 Mach 服务的进程都能发请求。所以"谁在调用"必须由 helper 自己回答。

两种答法：

- **校验调用方代码签名**（SMJobBless 的做法）—— 依赖证书，源码分发不可行
- **要求每次调用附带用户刚确认过的 AuthorizationRef** —— 不依赖任何证书

选后者。对开源、源码分发的工具这是更合适的模型：谁编译的都一样安全。

### 三条容易写错的细节

1. **复核时绝不能带 `interactionAllowed`。** daemon 没有 UI 会话；真让它能弹框，
   等于任何进程都能随意触发系统授权弹框骚扰用户。那一步只查"这份凭据里已经有
   这项权利了吗"，不获取新权利。
2. **`AuthorizationFree` 不能带 `destroyRights`。** 凭据归 App 所有，helper 只是
   借来核对；带了会把 App 那边的授权一起作废。
3. **连通性探测方法不要求授权。** 否则"helper 没装"和"授权没过"两种失败混在一起，
   没法给用户准确提示。

### 后补：helper 的安装本身也能走同一套授权（AEWP）

后来把「安装 helper」也从终端挪进了 App（`HelperInstaller.swift`）。机制是
废弃已久的 `AuthorizationExecuteWithPrivileges`，macOS 26 实测：

- `dlsym(RTLD_DEFAULT, "AuthorizationExecuteWithPrivileges")` 仍能解析；
- setuid 的执行载体 `/usr/libexec/security_authtrampoline` 仍在（mode 04711）。

它恰好接 `AuthorizationRef`，与 4 节的信任模型同源 —— App 缓存的令牌直接复用，
5 分钟窗口内安装一次框都不弹。`osascript with administrator privileges` 因为
自建授权会话、接不上令牌缓存而被排除。三个实测约束：

- **AEWP 的执行对象必须是二进制，不能是 shell 脚本。** trampoline 给子进程的
  凭据是 euid=0 / **ruid=调用者**，而 bash（zsh、dash 同理）在 euid ≠ ruid 且
  未带 `-p` 时会把 euid 降回 ruid —— 防 setuid 脚本的老规矩。直接 AEWP
  安装脚本，真机上得到的就是脚本自己的「需要 root 权限」报错。解法：AEWP
  helper 二进制的 `--install` 模式，先 `setgid(0)` + `setuid(0)` 归一化成与
  sudo 完全相同的凭据，再 exec 脚本（`InstallerMode.swift`）。
- **不给 pid 也不给退出码**，只有连到子进程 stdout 的管道 —— stderr 要在
  子进程里 dup2 并流，成败得用「装完能否连上匹配版本的 helper」这类真实
  结果判定；
- 用 dlsym 而不是直接链接：将来符号被移除时能降级成终端引导，而不是
  dyld 绑定失败。

---

## 5. 关键澄清：授权 ≠ root

`AuthorizationCopyRights` 成功**不改变进程的任何东西**。它产出的
`AuthorizationRef` 是一张**凭据**，语义是"用户在某时刻通过密码/指纹确认了，
同意授予某项权利"。进程的 uid、euid 一个都没动。

实测：App 在授权成功的下一行代码直接调 `tk_feth_create()`，仍然 `EPERM`；
同一个函数经 helper 调用则成功。

Authorization Services 从来就是**咨询式**授权系统，服务对象是那些本来就有 root
的组件。权限本身必须另有来源（launchd 启动的 daemon、setuid 二进制）。

**顺序不能反**：不能"先弹指纹拿到 root，再去建网卡"，只能"先有常驻的 root helper，
每次操作弹指纹拿凭据交给它复核"。

---

## 6. 网络配置能力边界

### 6.1 可行（纯内核 ioctl，configd 不参与）

- `SIOCAIFADDR` 配地址 —— 实测配上后 5 秒仍在，configd 不来收尸
- 地址配好后子网路由自动生成
- scoped 默认路由（`RTF_IFSCOPE`）—— macOS 支持每接口独立的默认路由，
  实测一台机器上同时存在 4 条 default（ipsec0 / en0 / bridge100 / bridge101）

configd 看不见 feth 只影响**它管不了 feth**，不影响**你自己管**。

### 6.2 DHCP：系统客户端可用

**IPConfiguration 接受 feth**，不需要自己实现 DHCP 客户端。

```bash
sudo ipconfig set feth9 DHCP     # exit=0
ipconfig getiflist               # → ... feth9    ← 出现了
ipconfig getsummary feth9        # → ConfigMethod: DHCP, ServiceID: DHCP-feth9
```

⚠️ **一个曾经把结论带偏的陷阱**：`ipconfig getiflist` 列的是「**当前有服务的接口**」，
不是「能配置的接口」。没跑过服务的接口一律不在里面 —— 连插着线的真网卡也不在
（实测 `ipconfig getsummary en1` 同样报 "interface doesn't exist"，而 en1 是块
正经的 Thunderbolt 网卡）。**不能拿它的缺席当作"IPConfiguration 不认这个接口"的证据。**

链路必须是 up 的：feth 没有 peer 时 `status: inactive`，服务会停在
`Active: FALSE` / `State: INACTIVE`。真实场景下 feth0↔feth1 已配对，链路 active。

**代价**：`ipconfig set` 建立的是**临时服务**，只活到下一次网络配置变更，且不出现在
「系统设置 → 网络」里。对 GUI 反而好办 —— App 自己就是配置入口，服务掉了可以重新 set。

### 6.3 一条命令换来的东西

在真实链路（feth0↔feth1 已配对、设备侧有 DHCP 服务器）上执行：

```bash
sudo ipconfig set feth0 DHCP
```

**IPConfiguration 会自动完成全部四件事**：

| 结果 | 实测证据 |
|---|---|
| 拿到租约 | `ipconfig getifaddr feth0` → `192.168.35.128`，`State: BOUND` |
| 配好 DNS（scoped） | `scutil --dns` 出现 `nameserver 192.168.35.7 / if_index 43 (feth0) / Scoped` |
| 装好 scoped 默认路由 | `netstat -rn` 出现 `default 192.168.35.7 UGScIg feth0` |
| 发布到动态存储 | `State:/Network/Service/DHCP-feth0/{DHCP,DNS,IPv4}`，`IsPublished: TRUE` |

最后一行值得注意：**这正是 §3.2 里手工写失败的那三个键**。IPConfiguration 通过
正规路径注册的服务，IPMonitor 完全采纳；手工捏造的不采纳。

### 6.4 唯一需要手工的一步：抢全局默认路由

feth0 **不会**自动成为主服务。实测时 `State:/Network/Global/IPv4` 的
`PrimaryInterface` 仍是 `ipsec0`（当时 VPN + Wi-Fi 都在跑，排名高于 feth0）。

结果是：feth0 有 **scoped** 默认路由（绑定到该接口的流量走它），但**未绑定的流量**
仍走主服务。

要让全局流量走设备，就是那条原本的命令：

```bash
sudo route -n change default $(ipconfig getoption feth0 router)
```

**注意适用条件**：只在有更高优先级服务同时具备连通性时才需要这一步。而 USB 网络
共享的典型场景恰恰是没有别的网络可用（用户正因为没 Wi-Fi 才插的手机），那时 feth0
大概率自然成为主服务，这条命令都不用跑。

### 6.5 对实现的影响

**`tk_net_*` 那组 C API 基本不需要了。** 原计划要自己实现的 DHCP 客户端
（在 feth0 上开 BPF 走 DISCOVER/OFFER/REQUEST/ACK，还要和 RNDIS 状态机做时序耦合）
整块省掉。helper 只需要：

1. `ipconfig set <feth0> DHCP` —— 或者用静态 IP 时走 §6.1 的 `SIOCAIFADDR`
2. 可选地 `route change default`

**代价**：`ipconfig set` 建立的是**临时服务**，只活到下一次网络配置变更，且不出现在
「系统设置 → 网络」里。对 GUI 反而好办 —— App 自己就是配置入口，服务掉了重新 set 即可。

**清理**：`sudo ipconfig set feth0 NONE`。

---

## 7. 踩过的坑

### Hardened Runtime 与 Homebrew 的 libusb

签名的 .app 启动即崩：

```
Library not loaded: /opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib
Reason: ... have different Team IDs
```

Hardened Runtime 下 macOS 拒绝加载 Team ID 与主程序不一致的库。Homebrew 的 libusb
是 ad-hoc 签名（无 Team ID），而 App 用开发者证书签（有 Team ID）。

**任何签名分发的 TetherKit.app 都必须内嵌 libusb** 并用同一身份重签。
另一条路是加 `com.apple.security.cs.disable-library-validation` 豁免，但那等于把
整个进程的库校验关掉，不划算。

注意：这个坑是**签名带来的**。源码构建的 ad-hoc 产物不存在此问题。

### `install_name_tool` 之后必须重签

arm64 要求可执行文件有有效签名，改字节会让签名失效，然后启动直接被内核拒绝
（`Killed: 9`），而且 launchd 日志里看不出原因。

### `install` 会把软链拆成独立文件

`libtetherkit.dylib` 和 `libtetherkit.0.dylib` 是指向 `.0.1.1.dylib` 的软链。
`install` 不保留软链，会各拷一份**独立的真实文件**。后续 `install_name_tool`
只改到其中一份，而按 `@rpath` 加载的恰好是没改到的那份 —— **修了个不被使用的副本，
问题却还在，且毫无征兆**。用 `cp -a`。

### 依赖要对着正确的对象查

`libusb` 是 `libtetherkit.dylib` 的依赖，不是 helper 可执行文件的。对着 helper 查
`otool -L` 得到空结果，整段处理被静默跳过 —— 装完看起来一切正常，实际仍依赖 Homebrew。

### UTF-8 locale 下 `$VAR` 紧跟全角标点会炸

```bash
echo "已清理（条目 + $IFACE）"   # → IFACE?: unbound variable
```

bash 按字节判断标识符字符，UTF-8 locale 下全角标点的首字节（0xEF）被 `isalnum()`
判为真，吸进了变量名。C locale 下不复现。

**规则：变量后面紧跟中文标点时必须写 `${VAR}`。**

### 部署目标默认跟宿主走

项目支持传 `CMAKE_OSX_DEPLOYMENT_TARGET` 但没设默认值，产物一直跟着宿主编译
（本次是 26.0），而 README 声称支持 13.3+。

顺带发现：Homebrew 的 libusb 本身也是按宿主版本编的，所以**预编译 Release 二进制
实际上跑不了 13.3**。这个与 GUI 无关，但影响现有的 Release 产物。

---

## 8. Homebrew 分发

### 实测的两条约束

- **`brew services` 的 service DSL 没有 `MachServices`**（查
  `Library/Homebrew/service.rb` 确认），注册不了 XPC 服务
- **`brew install` 从不以 root 运行**，formula 写不了 `/Library/LaunchDaemons`

→ helper 只能装进 prefix，由 caveats 引导用户跑一条 `sudo`。这是标准做法。

### .app 的位置

formula **可以**装 .app 进 Cellar（`python@3.14` 就装了两个），但**不会**出现在
`/Applications`、Launchpad 或聚焦搜索里 —— 需要 caveats 引导用户软链，或改走 Cask。

### 签名需求

| 分发方式 | 需要证书吗 |
|---|---|
| Formula（源码构建） | **不需要** —— 本地编译不带 quarantine，Gatekeeper 不参与 |
| Cask（预编译 .app） | 需要 Developer ID + 公证 —— Cask 默认给下载物加 quarantine |

源码构建路线之所以可行，正是因为安全模型选了 AuthorizationRef 复核而非签名绑定。

---

## 9. C API 缺口清单

若要继续，现有 C++ 层需要补的东西：

**必须新增的访问器** —— `Runtime` 目前只暴露 `SystemInterfaceName()` 和
`DeviceInfo()`，以下全部拿不到：桥接统计、RNDIS 当前状态、链路 up/down、
协商参数、驱动侧网卡名、致命错误原因。

**必须改的行为**：

- `RunUntilStopped()` 是阻塞的，GUI 用不了 —— `Start()` 必须自己起控制线程后返回
  （控制通道必须在非 libusb 事件线程上，这条约束不能省）
- 观察者的五个回调现在只打日志，需要转发给宿主

**建议用事件队列而非回调**：回调会从 libusb 事件线程和控制线程上来，Swift 侧要跨线程
marshal；更要命的是重入 —— 在回调里调停机会自等死锁（`Stop()` 要 join 控制线程）。

**其它缺口**：

| 缺口 | 说明 |
|---|---|
| 日志 sink | 日志只往 stderr 走，GUI 拿不到 |
| 设备字符串描述符 | `DeviceCandidate` 无厂商名/产品名/序列号，两台同型号设备无法区分 |
| 热插拔 | `Context::SupportsHotplug()` 存在但从未被使用 |
| 孤儿 feth 清理 | 进程被 SIGKILL 时析构不跑，网卡留在内核里 |
| helper 信号处理 | `launchctl bootout` 发 SIGTERM，Swift `deinit` 不会跑，同样漏网卡 |

孤儿清理是兜底，比信号处理更重要 —— SIGKILL 是任何信号处理器都拦不住的。

---

## 10. 验证命令备忘

```bash
# feth 是否在 IOKit 里（预期：不在）
ioreg -c IONetworkInterface -r -d1 | grep '"BSD Name"' | sort -u

# IPConfiguration 认不认 feth（预期：认，exit=0 且随后出现在 getiflist 里）
sudo ifconfig feth9 create
sudo ipconfig set feth9 DHCP && ipconfig getiflist
sudo ipconfig set feth9 NONE && sudo ifconfig feth9 destroy

# ⚠️ getiflist 列的是「当前有服务的接口」，不是「能配置的接口」。
#    没跑过服务的接口一律不在里面，插着线的真网卡也不在。
#    不要拿它的缺席当作「IPConfiguration 不认这个接口」的证据 —— 我踩过。

# 真实链路下的完整验证（需要接着设备、tetherkit 在跑）
sudo ipconfig set feth0 DHCP
ipconfig getifaddr feth0                     # 租约
scutil --dns | grep -A3 feth0                # scoped DNS（在后段，别用 head 截断）
netstat -rn -f inet | grep -E "^default"     # scoped 默认路由
ipconfig getsummary feth0 | grep -E "State|IsPublished|Router"
sudo ipconfig set feth0 NONE                 # 清理

# 内核肯不肯给 feth 配地址（预期：肯）
sudo ifconfig feth9 create
sudo ifconfig feth9 inet 10.99.99.1 netmask 255.255.255.0 up
netstat -rn -f inet | grep 10.99.99
sudo ifconfig feth9 destroy

# Homebrew service DSL 支不支持 MachServices（预期：不支持）
grep -i machservice /opt/homebrew/Library/Homebrew/service.rb
```

`netstat -rn` 输出里接口路由行尾的 `!` 是 scoped route 标记（`RTF_IFSCOPE`），
**不是错误** —— 正常的 en0/bridge 路由也带它。

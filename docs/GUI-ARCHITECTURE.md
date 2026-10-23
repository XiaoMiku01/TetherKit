# GUI 实现备忘

本文记录 TetherKit 图形界面**已经实现了什么、为什么这么实现、哪些地方碰不得**。

配套阅读：[GUI-SPIKE.md](GUI-SPIKE.md) 记录的是动手之前的可行性验证（尤其是被
排除的三条路线）；本文记录的是落地之后的结构与约束。**改 GUI 相关代码前先读
这两篇**，能省掉重新踩一遍坑的时间。

---

## 1. 进程与信任模型

```
┌─────────────────────────────┐         ┌──────────────────────────────┐
│  TetherKit.app  (uid 501)   │         │  tetherkit-helper  (uid 0)   │
│                             │   XPC   │                              │
│  · SwiftUI 界面             │ ──────► │  · 持有 RNDIS 会话           │
│  · 弹系统授权框取凭据       │         │  · 建/销毁 feth、开 BPF      │
│  · 定时拉状态刷界面         │ ◄────── │  · 配 IP（ipconfig / route） │
│  · 不碰 USB、不碰网卡       │         │  · 复核每次调用的凭据        │
└─────────────────────────────┘         └──────────────────────────────┘
                                              ▲
                                              │ 按需拉起（MachServices）
                                        ┌─────┴──────┐
                                        │  launchd   │
                                        └────────────┘
```

**helper 的 root 来自 launchd，跟用户按没按指纹毫无关系。** 它一启动就是 root，
任何能连上 Mach 服务的进程都能发请求。所以「谁在调用」必须由 helper 自己回答 ——
每个特权方法都要求附带一份 App 刚拿到的 `AuthorizationRef` 外部形式，并当场复核。

安全性建立在**凭据复核**而不是**代码签名校验**上。后者（SMJobBless 的做法）依赖
证书的 designated requirement，而源码分发下每台机器编出的 cdhash 都不同，写死的
DR 必然对不上。凭据复核对开源工具是更合适的模型：谁编译的都一样安全。

> **一句必须记住的话：授权 ≠ root。**
> `AuthorizationCopyRights` 成功不改变进程的任何东西，uid / euid 一个都没动。
> 它只产出一张「用户在某时刻确认过」的凭据。顺序不能反：不是「先弹框拿到
> root」，而是「先有常驻的 root helper，弹框拿到凭据后交给它复核」。

---

## 2. 目录结构

```
include/tetherkit/capi/tetherkit_c.h   全项目唯一的 extern "C" 边界
src/capi/                              C ABI 实现
├── capi_support.{h,cc}                定长缓冲拷贝、错误翻译、网卡名校验
├── core_foundation_support.{h,cc}     CF / SCDynamicStore 的最小 RAII 封装
├── environment.cc                     版本、环境预检、设备枚举（免 root）
├── log_ring.cc                        日志环形缓冲
├── net_config.cc                      DHCP / 静态 IP / 状态回读
├── orphan_cleanup.cc                  feth 落盘登记与孤儿清理
├── process_runner.{h,cc}              posix_spawn 执行外部工具（不过 shell）
└── session.cc                         会话生命周期、状态快照、事件轮询

gui/
├── Package.swift                      SwiftPM 工程
├── Sources/
│   ├── CTetherKit/                    C ABI 的模块映射（头是符号链接）
│   ├── TetherKitIPC/                  App 与 helper 共享：协议、模型、授权、文案表
│   ├── TetherKitCore/                 C ABI 的 Swift 封装
│   ├── TetherKitHelper/               特权 helper
│   └── TetherKitApp/                  SwiftUI 界面
├── Tests/TetherKitIPCTests/           授权凭据生命周期 + 文案表占位符一致性
├── Resources/                         Info.plist、LaunchDaemon plist
└── Scripts/                           构建 / 安装 / 卸载脚本
```

---

## 3. 数据流

| 方向 | 机制 | 周期 |
|---|---|---|
| 库 → helper：状态 | `tk_session_status_get` 拷贝快照 | 按需 |
| 库 → helper：事件 | `tk_session_poll_events` 取环形队列 | 随状态查询搭车 |
| 库 → helper：日志 | `tk_drain_logs` 取环形队列 | 每次 `drainFeed` |
| helper → App | XPC，JSON 编码的 Codable | 500 ms |

**全链路没有一个回调穿过语言边界。** 这是刻意的：底层的回调会从 libusb 事件
线程与控制线程上来，跨语言要 marshal；更要命的是重入 —— 在回调里调停机会自等
死锁（`Stop()` 要 join 控制线程）。一律改成「库内排队、宿主轮询」。

---

## 4. 关键实现约束（改代码时别破坏这些）

### 4.1 C ABI

- **不跨边界传所有权。** 输出一律写进调用方提供的定长结构体。唯一例外是
  `tk_session_t*`，创建 / 销毁配对明确。
- **定长缓冲的截断必须落在 UTF-8 字符边界上。** 错误消息全是中文，按字节硬切
  会让 Swift 侧 `String(cString:)` 整串变成替换字符。两个方向都要管：C 侧是
  `capi_support.h` 的 `CopyText`，Swift 侧是 `CInterop.swift`。
- **C 枚举与 C++ 枚举靠顺序一致直接强转**，`session.cc` 里有一组
  `static_assert` 把它焊死。中间插入一个枚举值会静默错位，且毫无报错。
- **`tk_session` 的成员声明顺序有约束**：`events` 必须在 `runtime` 之前，
  销毁时 `runtime` 才会先 join 控制线程。反过来就是 use-after-free。

### 4.2 Runtime 线程模型

`Runtime` 自己拥有一条控制线程，**启动序列、保活循环、停机拆除全部在它上面跑**。
这不只是为了让 `Start()` 非阻塞，更是把 `StateMachine` 的「所有方法同线程调用」
从口头约定变成结构性保证 —— 优雅停机要发同步控制消息，而 libusb 的同步 API 在
事件线程上会返回 `LIBUSB_ERROR_BUSY`。

宿主线程**只**通过 `Snapshot()` 读状态，绝不碰那些组件指针 —— 否则 `Stop()` 里的
`reset()` 与宿主的读会构成数据竞争，表现为随机崩溃。

`RequestStop()` 保持只写一个原子（异步信号安全），代价是最多晚一个循环周期
（≤250 ms）被看到；`Stop()` 额外用条件变量唤醒控制线程，所以界面上按「断开」
是立刻响应的。

### 4.3 网卡配置

- **地址一律经 `ipconfig` 下发，不要改回裸 `SIOCAIFADDR`。** 裸 ioctl 配出来的
  地址内核认、configd 不认 —— 不会有服务、不会有 scoped DNS、不会有默认路由。
  这一条已在 GUI-SPIKE 第 3.2 / 6.3 节实测确认。
- **外部工具用 `posix_spawn` 传 argv 数组，不过 shell。** 参数虽然都校验过，
  但只要经过 `/bin/sh`，防线就依赖「校验有没有漏」这一条。
- **先读空管道再 `waitpid`。** 反过来是经典的 pipe 死锁：子进程写满 64 KiB
  缓冲后阻塞在 `write`，我们阻塞在 `waitpid`。`process_runner.cc` 有对应测试。
- **网卡名只接受 `feth<数字>`。** 这不是洁癖 —— 挡的是「误把 en0 传进来，
  把用户的 Wi-Fi 配置冲掉」这类事故。
- **`SCDynamicStore` 句柄必须是进程级长命的。** 动态存储里的值由设置它的会话
  持有，会话一释放值就没了。用临时 store 会出现「写入返回成功、读回来是空」
  这种极难查的现象。

### 4.4 授权复核（`TetherKitIPC/Authorization.swift`）

三条一旦写错就是漏洞的细节，都写在那个文件的注释里：

1. helper 侧复核时**绝不能带 `.interactionAllowed`** —— daemon 没有 UI 会话，
   真让它能弹框，等于任何进程都能随意触发系统授权框骚扰用户。
2. **`AuthorizationFree` 不能带 `.destroyRights`** —— 凭据归 App 所有，helper
   只是借来核对，带上会把 App 那边的授权一起作废。
3. **探测类方法不要求授权** —— 否则「helper 没装」和「授权没过」两种失败会混在
   一起，没法给用户准确提示。

取凭据（App 侧，**要**带 `.interactionAllowed`）与复核（helper 侧，**不**带）
刻意写在同一个文件里：它们的差别只有一个标志位，改一边时另一边就在眼前。

第四条，**实际踩过一次**：

4. **`AuthorizationMakeExternalForm` 产出的 32 字节不是凭据本身，只是指向
   securityd 里那份授权的一把钥匙。** App 侧一旦在 XPC 往返完成**之前**释放
   `AuthorizationRef`（尤其是带 `.destroyRights`），helper 还原时就会失败，
   报 `errAuthorizationDenied (-60005)`。

   而这个错误码从代码上完全看不出「是被自己提前销毁的」—— 它看起来像是用户
   授权被拒。所以凭据由 `AuthorizationToken` 持有、`AuthorizationBroker
   .withAuthorization` 用 `withExtendedLifetime` 保证它活到调用结束。
   **不要裸接住 `requestAuthorization()` 的返回值再用** —— ARC 完全可以在最后
   一次读 `externalForm` 之后就把令牌释放掉。

   `gui/Tests/TetherKitIPCTests/AuthorizationTests.swift` 把这个行为钉住了，
   两条用例都不弹授权框，可以进 CI。

**令牌必须缓存复用，否则每个操作都要用户重新认证一次。**
`system.privilege.admin` 的实测参数（`security authorizationdb read`）：

| 字段 | 值 | 含义 |
|---|---|---|
| `shared` | `false` | 凭据**不跨 AuthorizationRef 共享**。每次 `AuthorizationCreate` 建新 ref 就必然重新认证 |
| `timeout` | `300` | 但同一个 ref 上的凭据 5 分钟内有效 |

所以 App 缓存 `AuthorizationToken` 复用：第一次操作弹一次框，之后 5 分钟内
「配网络」「断开」都不再打扰用户。过期后 helper 的复核会失败并把应答的第二个
参数置为 `true`，App 据此丢弃缓存、重新弹一次框、把这次操作重试一遍。

### 4.5 关于 Touch ID：这条路走不通（已验证）

**结论：`AuthorizationCopyRights` 弹出的系统授权框不支持指纹，只能输密码。**
这是 API 层面的限制，不是实现问题。别再花时间试了。

验证过程（本机 Touch ID 硬件存在、`bioutil -r` 显示已录入并启用）：

1. 写了个最小的探针 App 请求 `system.privilege.admin`，读取 SecurityAgent
   窗口的文本，得到的是 **「输入密码允许此操作。」** —— 界面上没有任何生物识别
   入口。
2. 对比系统自己的 `system.preferences` 规则，`class` / `group` /
   `authenticate-user` 完全相同，只有 `shared` 与 `timeout` 不同 ——
   而那两个字段只影响凭据缓存，不影响认证方式。所以换个权利名没有用。
3. 在 SDK 里找 LocalAuthentication 与 Authorization Services 之间的桥：
   `AuthorizationTags.h` 的环境项只有 username / password / shared / prompt /
   icon，**没有 LAContext**。唯一出现 `GetLAContext` 的地方是
   `AuthorizationPlugin.h` —— 那是给**编写 SecurityAgent 插件**用的回调，
   而且注释写明它返回的是智能卡 PIN（`LACredentialCTKPIN`），不是 Touch ID。

`LAContext.evaluatePolicy` 确实能弹指纹，但它产出的结果**无法转换成 helper
可以复核的凭据** —— 换成它就等于放弃了整个信任模型。真要做，只剩「自己写一个
SecurityAgent 插件装进 /Library/Security/SecurityAgentPlugins」这条路，
代价与风险都和这个项目完全不成比例。

可行的替代是**减少弹框频率**，也就是上面的令牌缓存。若还嫌频繁，可以在
`install-helper.sh` 里用 `security authorizationdb write` 装一条自己的权利，
把 `timeout` 调长、`shared` 设为 true —— 但那仍然是密码框，只是问得更少。

### 4.6 XPC 接口修订号

`HelperConstants.protocolRevision` 每次改动 `TetherKitHelperProtocol` 都要加一。
当前是 **3**（1 初版；2 特权方法应答加上「是否授权失败」；3 新增 `setLanguage`）。
helper 把它编进 `helperVersion` 的应答，App 一连上就比对。

**为什么不新增一个专门的方法来报版本**：新增方法本身就是一次协议变更，旧
helper 根本没有它 —— 那就又回到了「对不上还查不出来」。只有复用旧 helper 也
一定会应答的方法，才能可靠识别出旧 helper。旧 helper 返回的串里没有分隔符，
解析出的修订号是 0，界面据此显示「特权组件需要更新」。

### 4.7 Swift 侧

- **XPC 的错误块与 reply 块可能都被调用**（请求已发出后连接才断），而
  `CheckedContinuation` 兑现两次是直接崩溃。`HelperClient` 里每次调用都用
  `ContinuationGuard` 包一层。
- **连接断掉后必须丢弃缓存的 `NSXPCConnection`**，否则后续调用一直打在死连接
  上，表现为「helper 明明装好了却连不上」。
- **helper 里凡是可能耗时的操作都异步回复**（启动会话要 USB 握手，DHCP 要等
  租约最多 10 秒）。在 XPC 队列上阻塞会把同一条连接上后续的状态轮询一起卡住，
  界面表现成整个卡死。
- **速率的分母用库那边的单调时钟差**，不是界面定时器周期 —— 两次拉取之间的真实
  间隔会被调度拉长，用固定周期当分母会把速率算高。
- **C 的定长 char 数组在 Swift 里是元组**，不能下标也不能直接转 String，统一走
  `CInterop.swift`。读用「扫到 NUL 或扫到底」，不用 `String(cString:)` —— 后者
  在缓冲被写满、没有 NUL 时会越界读。
- **非负值的 C 枚举被导入成 `UInt32`**，而结构体字段是 `int32_t`，比较前必须
  显式转换。
- **MenuBarExtra 与 Window 同存时，点菜单栏图标会让 SwiftUI 擅自重建主窗口。**
  实测确认，且不走 `applicationShouldHandleReopen`（插桩证明该委托从未被调用，
  SwiftUI 生命周期不转发它），没有干净的委托口子可堵。对策在结果端：窗口每次
  出现时问 AppModel「这次展示登记过吗」（App 启动与「打开主窗口」按钮是仅有的
  两个登记点，3 秒时间窗），没登记过的当场 dismiss。见 `MainWindowRoot`。
- **轮询是自适应的**：会话在跑 / 正在启停 / 窗口开着 → 500 ms；纯后台待机 →
  2 秒。窗口重新打开时立刻补一次刷新，避免第一眼看到陈旧数据。
- **菜单栏使用原生文字与固定宽度**：等宽数字不能固定不同位数的总宽；把文字
  绘入模板图片又会引入缩放、字重与基线差异。`MenuBarController` 持有原生
  `NSStatusItem`，`MenuBarAppearance` 设置按钮的 `attributedTitle`：9.5pt 常规
  等宽字体、10pt 行高、右对齐，上行在上、下行在下。基线按实际按钮高度修正，
  图标和系统边距预留 30pt，六字符速率栏使运行状态下的总宽固定为约 66pt。
  文字由系统绘制与着色；只有状态图标使用模板图。菜单栏显示 B/s、K/s、M/s，
  模型与主窗口仍用 bit/s。空闲时只显示图标，VoiceOver 仍读取方向与完整单位。
- **原生菜单栏的生命周期由 App 持有**：控制器不随主窗口关闭而销毁；通过
  Observation 跟踪模型更新。原有 SwiftUI 面板托管在 `NSPopover` 中，显式关闭
  面板并使用 Window 场景提供的 `openWindow` 动作回到主窗口。避免在独立的
  NSHostingController 中依赖没有场景上下文的默认 `openWindow` / `dismiss`。

### 4.7b 界面语言

文案表编译进二进制，不走 `.lproj`。理由写在 `TetherKitIPC/Localization.swift`
顶部，核心是 **helper 是装在 `/Library/PrivilegedHelperTools` 的裸可执行文件**，
旁边没有、也不该有资源 bundle，而它同样要产生给用户看的文字。

改语言时必须**同时**更新三处，缺一处就会出现「界面英文、日志中文」：

| 处 | 怎么改 | 不改的后果 |
|---|---|---|
| Swift 文案表 | `L10n.apply(_:)` | 界面不变 |
| libtetherkit | `TetherKitLibrary.setLanguage(_:)` → `tk_set_language` | 日志卡里的库日志还是旧语言 |
| helper | XPC 的 `setLanguage(_:)` | helper 的提示与它那边的库日志还是旧语言 |

三处都在 `AppModel.applyLanguage` 里一起做，别在别处单独调其中一个。helper
之所以要单独告知：它以 root 跑在 launchd 下，看不到用户的语言偏好。

两条 SwiftUI 特有的坑（都实测踩过）：

- **切语言不会让任何 `@Observable` 属性看起来变过**，视图体因此不会重算。
  对策是把语言变化本身变成可观察的值（`AppModel.languageRevision` 每次加一），
  再当 identity 用：`.id(model.languageRevision)`，强制重建整棵树。
- **`.commands { }` 里的每个 `Button` 各自是独立表达式**，只有读过可观察值的
  那个会重算。实测切完语言只有语言菜单自己变了，旁边的「检查更新…」还是旧
  语言。修法是把这一组包进同一个 View（`AppMenuItems`），在它的 body 里读一次
  revision。同理，**存文案的 `static let` 只求值一次**，一律改成计算属性。

### 4.8 打包

- **拷 dylib 必须用 `cp -a`，不能用 `install`。** `libtetherkit.dylib` 与
  `libtetherkit.0.dylib` 是软链，`install` 会各拷一份独立的真实文件，之后
  `install_name_tool` 只改到其中一份，而按 `@rpath` 加载的恰好是没改到的那份。
- **`install_name_tool` 改完字节必须重签。** arm64 要求有效签名，改字节会让原
  签名失效，之后加载被内核直接拒绝（`Killed: 9`），日志里看不出原因。
- **libusb 是 `libtetherkit.dylib` 的依赖，不是可执行文件的。** 对着可执行文件
  查 `otool -L` 会得到空结果，整段处理被静默跳过 —— 装完看起来正常，实际仍依赖
  Homebrew。
- **发布产物里必须删掉指向构建目录的 rpath。** 它是绝对路径，在开发机上一定
  存在，dyld 会优先用它，内嵌的副本永远得不到验证 —— 等换台机器才暴露。
  `build-gui.sh` 会删；`Package.swift` 里也把它排在最后作为第二道保险。
- **bash 里变量后面紧跟中文标点必须写 `${VAR}`。** UTF-8 locale 下全角标点的
  首字节（0xEF）会被 `isalnum()` 判为真、吸进变量名。C locale 下不复现。

### 4.9 App 内一键安装特权组件（AEWP）

helper 缺失或版本不匹配时，界面给一个「安装 / 更新特权组件」按钮，点一下、
输一次管理员密码就装好 —— 不用打开终端。机制（`HelperInstaller.swift`）：

- **载荷内嵌在 .app 里**：`Contents/Library/HelperTools/` 平铺放着 helper
  二进制、dylib、plist 和安装 / 卸载脚本，`build-gui.sh` 组装。装的时候整目录
  拷走，安装源天然跟着 .app 走。旧的 `dist/helper/` 布局已废除。
- **提权走 `AuthorizationExecuteWithPrivileges`（AEWP）**：它接的正是
  AuthorizationRef，所以 App 缓存的授权令牌（4.4 节）直接复用 —— 5 分钟窗口内
  一次框都不弹；装完接着点「连接」也不再弹。osascript 方案被排除就是因为它
  自建授权会话，接不上这份缓存。SMJobBless / SMAppService 早已排除（SPIKE 3.3）。
- **AEWP 已废弃但可用（macOS 26 实测）**：符号可解析，setuid 执行载体
  `/usr/libexec/security_authtrampoline` 仍在。代码用 dlsym 运行时解析而不是
  直接链接：将来系统移除它时降级成「请用终端安装」，而不是 dyld 绑定失败。
- **AEWP 的执行对象必须是二进制，不能是脚本**：AEWP 给子进程的凭据是
  euid=0 / ruid=普通用户，而 bash 在 euid ≠ ruid 且未带 `-p` 时会把 euid 降回
  ruid —— 直接 AEWP 安装脚本，脚本开头的 root 检查必然报「需要 root 权限」
  （**真机踩过**）。所以 App 拉起的是载荷里 helper 二进制的 `--install` 模式
  （`InstallerMode.swift`）：setuid(0) 把凭据归一化成与 sudo 完全相同的真
  root，dup2 把 stderr 并进 stdout（AEWP 的管道只接 stdout），再 exec 同目录
  的 `install-helper.sh`。脚本按「脚本所在目录 → 仓库产物」自动定位载荷，
  终端与 App 两个入口共用一份实现。
- **成败不看退出码**：AEWP 不给 pid 也不给退出码，只有一根连到子进程 stdout
  的管道。判定标准是「读到 EOF 后能否真的连上匹配版本的 helper」——
  `AppModel.installHelper()` 用 XPC 往返兜底确认，失败时把脚本输出的末尾
  （剥掉 ANSI 色码）放进弹窗。
- **弹框之前先自检**：载荷不在（`swift run` 的裸可执行文件）或 AEWP 不在，
  都要在要密码**之前**报出来，并引导回终端脚本。
- **卸载走同一条链**：仪表盘底部的「卸载特权组件…」（低调的 caption 行 ——
  极低频动作不抢注意力，但必须存在于主界面）→ 确认框 → `--uninstall` →
  `uninstall-helper.sh`。成败判定方向相反：等的是「连不上」。卸载后界面
  自然回到安装引导页，随时可重装。

### 4.10 检查更新（只查不换）

`UpdateChecker.swift` 请求 GitHub 的 `releases/latest`，和 Info.plist 里的
版本号（CMakeLists 单一来源）做语义化比较。**刻意不做自动下载替换**：
免证书分发下，下载物带 quarantine，替换完的 .app 会被 Gatekeeper 拦死 ——
和不能走 Cask 是同一堵墙。真正的更新通道是 `brew upgrade` 或源码重编。

- 入口两个：App 菜单「检查更新…」（结果弹窗，带可复制的 brew 命令与
  发布页链接）；自动检查每天至多一次，发现新版只点亮管理行里的
  「有新版 x.y.z」，绝不弹窗打断。提示跨启动记忆（defaults），升级完成后
  因版本比较自然熄灭。
- 隐私：只访问 GitHub 公开 API，失败静默；
  `defaults write com.tetherkit.app updateCheckDisabled -bool YES` 彻底关闭。
- `swift run` 的裸可执行文件没有 Info.plist 版本号，检查自动跳过。
- 发版纪律：检查读的是 GitHub Releases，**每个版本必须打 `vX.Y.Z` tag 并
  发布 Release**，否则查不到。
- 查到新版后的落地由既有机制接力：`brew upgrade` 换掉 App，重启后
  `protocolRevision` 不匹配触发「更新特权组件」一键重装（4.6 / 4.9 节）。

---

## 5. 已实现 / 未实现

### 已实现

| 能力 | 位置 |
|---|---|
| 环境预检（root、feth sysctl、MTU 上限） | `tk_check_environment` |
| 设备枚举 + 厂商名/产品名/序列号 | `tk_list_devices` |
| 会话生命周期（非阻塞启动、状态快照、事件） | `tk_session_*` |
| 日志捕获与轮询 | `tk_drain_logs` |
| DHCP / 静态 IP / 撤销 | `tk_net_apply`、`tk_net_clear` |
| 真实生效状态回读（地址、网关、DNS、主默认路由） | `tk_net_query` |
| 孤儿 feth 清理 | `tk_cleanup_orphan_interfaces` |
| 特权 helper + 凭据复核 | `gui/Sources/TetherKitHelper` |
| App 内一键安装 / 更新 / 卸载特权组件 | `gui/Sources/TetherKitApp/HelperInstaller.swift` |
| 检查更新（只查不换，每日自动 + 手动菜单） | `gui/Sources/TetherKitApp/UpdateChecker.swift` |
| Finder 别名自动维护（首次启动建立，聚焦可搜可启动；brew postinstall 有沙箱建不了） | `gui/Sources/TetherKitApp/FinderAlias.swift` |
| SwiftUI 界面（状态、设备、网络、吞吐、日志） | `gui/Sources/TetherKitApp` |
| 菜单栏实时速率 + 后台运行（仅菜单栏模式） | `MenuBarController.swift`、`MenuBarAppearance.swift`、`Views/MenuBarPanel.swift` |
| 中英双语（运行期可切，界面 / 库日志 / helper 提示三处同步） | `gui/Sources/TetherKitIPC/Localization.swift`、`tk_set_language` |

### 未实现 / 已知限制

| 项 | 说明 |
|---|---|
| **静态 IP 的 DNS 未经真机验证** | IPConfiguration 只在 DHCP 模式发布 DNS。静态模式我们往它建立的服务上补一个 DNS 键，能否被 IPMonitor 采纳未经验证。因此 `tk_net_query` 一律**回读**真实生效的解析器，界面显示回读结果 —— 赌错了也只是 DNS 不生效，不会有破坏 |
| **端到端已在真实设备上跑通（DHCP 路径）** | 2026-07-28 用 Android 手机验证：插上 → App 连接 → feth0 经 DHCP 拿到手机网段地址 → 主机与手机双向 ping 通 → iperf3 打出 RX 325 / TX 235 Mbps。**「能上公网」这一步没能验证** —— 本机有 VPN 占着默认路由，走 tether 的流量被劫走，这是测试环境问题不是 GUI 问题。App 退出后会话仍由 helper 持有（后台运行模式，符合设计） |
| **授权只能输密码，没有指纹** | 系统 API 的限制，不是缺陷。已验证并记录在第 4.5 节。缓解手段是令牌缓存：5 分钟内只问一次 |
| **热插拔** | `Context::SupportsHotplug()` 存在但未接入；目前靠界面每 2 秒重新枚举 |
| **IPv6** | 网卡配置只覆盖 IPv4 |
| **多会话** | helper 同一时刻只允许一个会话 |
| **App 图标** | 尚无 `.icns`，用系统默认图标 |
| **只有中文与英文** | 文案表是编译进二进制的两列（不是 `.lproj`，理由见 `Localization.swift` 顶部）。加第三种语言要改 `Language` 枚举与两处 switch，不是加一个目录就行 |

---

## 6. 构建与安装

```bash
# 1. C++ 部分（产出 libtetherkit.dylib）
cmake -S . -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build -j

# 2. GUI（等价于直接跑 ./gui/Scripts/build-gui.sh）
cmake --build build --target gui

# 3. 运行。首次会引导安装特权组件：点按钮、输一次管理员密码即可（见 4.9 节）。
#    终端替代：sudo ./gui/Scripts/install-helper.sh
open dist/TetherKit.app
```

开发时也可以直接用 SwiftPM，不经过打包脚本：

```bash
export TETHERKIT_LIB_DIR="$PWD/build/lib"
swift build --package-path gui
swift test  --package-path gui     # TetherKitIPC 的单元测试
```

卸载：仪表盘底部的「卸载特权组件…」按钮（见 4.9 节），或：

```bash
sudo ./gui/Scripts/uninstall-helper.sh
```

排障入口：

| 现象 | 先看哪里 |
|---|---|
| 界面一直显示「需要先安装特权组件」 | `launchctl print system/com.tetherkit.helper` |
| helper 起不来 | `/var/log/tetherkit-helper.log` |
| 连接失败 | 界面里的「运行日志」面板（可一键复制） |
| 装完还是依赖 Homebrew | `otool -L dist/TetherKit.app/Contents/Frameworks/libtetherkit.0.*.dylib` |
| 点「连接」报「无法还原授权凭据（-60005）」 | App 侧提前释放了 AuthorizationRef，见第 4.4 节第 4 条 |
| 界面显示「特权组件需要更新」 | 改过 XPC 协议但没重装 helper，点「更新特权组件」（或跑安装脚本） |
| 点「安装特权组件」报「不带安装载荷」 | 跑的是 `swift run` 的裸可执行文件，载荷只在 build-gui.sh 组装的 .app 里；用终端脚本装 |
| 授权框只有密码、没有指纹 | 这是系统 API 的限制，不是缺陷，见第 4.5 节 |
| 设备拔掉重插后点「连接」报「会话已经在运行了」 | helper 是旧版（失败态旧会话未被清理），重装 helper |
| 仅菜单栏模式下双击访达图标没反应 | 已知权衡（见 MainWindowRoot 的说明），从菜单栏面板打开即可 |

// 虚拟网卡的上网方式配置：DHCP / 静态 IP / 撤销，以及真实生效状态的回读。
//
// ★ 为什么 DHCP 要建立真正的 macOS 网络服务 ★
//
//   `ipconfig set` 只建立 State:/Network/Service 下的临时服务。普通流量能用，
//   但 NetworkExtension 接管路由时不会把这种服务当作可靠的底层路径：VPN
//   provider 会在 feth0 明明仍有地址和 scoped 路由时得到 "No network route"。
//
//   DHCP 模式因此经 SCPreferences / SCNetworkService 在当前网络集里注册 feth。
//   feth 没有 IOKit 节点，公开 API 枚举不到；managed_network_service.cc 只用
//   Apple 自己导出的 BSD-name constructor SPI 补出 SCNetworkInterface，后续服务、
//   协议、提交与应用全部走公开 API。服务随 feth 销毁而移除。
//
// ★ 静态 IP 的 DNS 是「尽力而为 + 回读验证」★
//
//   IPConfiguration 只在 DHCP 模式下发布 DNS（那是从 DHCP 选项里来的）。
//   MANUAL 模式没有 DNS 来源，我们只能往它建立的那个服务上补一个 DNS 键。
//   这一手**未经真机验证**，所以绝不向上层承诺成功：tk_net_query 一律回读
//   系统里真实生效的解析器，GUI 显示的是回读结果而不是我们下发的值。
#include <SystemConfiguration/SystemConfiguration.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <format>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include "capi_support.h"
#include "core_foundation_support.h"
#include "managed_network_service.h"
#include "process_runner.h"
#include "tetherkit/capi/tetherkit_c.h"
#include "tetherkit/common/i18n.h"
#include "tetherkit/common/logging.h"

namespace {

using tetherkit::Error;
using tetherkit::Msg;
using tetherkit::Result;
using tetherkit::Status;
using tetherkit::Text;
using tetherkit::Tr;
using tetherkit::capi::ClearError;
using tetherkit::capi::CopyText;
using tetherkit::capi::CopyToStdString;
using tetherkit::capi::FillError;
using tetherkit::capi::FillGenericError;
using tetherkit::capi::IsValidFethName;
using tetherkit::capi::MakeCFString;
using tetherkit::capi::ProcessResult;
using tetherkit::capi::RunTool;
using tetherkit::capi::ScopedCFRef;
using tetherkit::capi::SharedDynamicStore;

constexpr std::string_view kIpconfigPath = "/usr/sbin/ipconfig";
constexpr std::string_view kRoutePath = "/sbin/route";

/// DHCP 租约的等待上限。
///
/// 取 10 秒的依据：DHCP 的 DISCOVER 重传是指数退避（1/2/4/8 秒），10 秒足够覆盖
/// 前三次重传。再长就该告诉用户「对面大概没有 DHCP 服务器」而不是继续转圈。
constexpr std::chrono::seconds kDhcpLeaseTimeout{10};
constexpr std::chrono::milliseconds kDhcpPollInterval{250};
/// 网关连续读到同一个值多少次才认为租约稳定了。
///
/// 8 次 x 250 ms = 2 秒。依据：Android 的 USB 网络共享先给一份 464XLAT 过渡租约
/// （192.0.0.2 / 网关 192.0.0.1），实测在 1 秒内就换成真正的网段；2 秒的静默期
/// 足以跨过那次切换，又不会让「一次就到位」的设备白等太久。
constexpr int kDhcpStableSamples = 8;

// ---------------------------------------------------------------------------
// 参数校验
// ---------------------------------------------------------------------------

[[nodiscard]] bool IsValidIpv4(std::string_view text) noexcept {
  if (text.empty() || text.size() >= TK_ADDRESS_CAPACITY) {
    return false;
  }
  const std::string owned{text};
  ::in_addr parsed{};
  return ::inet_pton(AF_INET, owned.c_str(), &parsed) == 1;
}

/// 校验接口名并翻译成人话错误。
[[nodiscard]] Status ValidateInterface(const char* interface_name) {
  if (interface_name == nullptr) {
    return std::unexpected(Error::Generic(Tr(Msg::kCapiInterfaceNameNull)));
  }
  if (!IsValidFethName(interface_name)) {
    return std::unexpected(Error::Generic(Tr(Msg::kCapiInterfaceNotOurs, interface_name)));
  }
  return tetherkit::Ok();
}

// ---------------------------------------------------------------------------
// 外部工具调用
// ---------------------------------------------------------------------------

/// 跑一条工具命令，非零退出即视为失败并把它的输出原样带上。
///
/// 原样带上很重要：ipconfig / route 的报错本身就是最准确的诊断信息，
/// 我们二次转述只会丢信息。
[[nodiscard]] Status RunOrFail(std::string_view executable,
                               const std::vector<std::string>& arguments,
                               std::string_view what) {
  TETHERKIT_ASSIGN_OR_RETURN(const ProcessResult result, RunTool(executable, arguments));
  if (!result.Succeeded()) {
    std::string detail{result.output};
    // 工具的输出常带尾随换行，拼进一行错误里很难看。
    while (!detail.empty() && (detail.back() == '\n' || detail.back() == '\r')) {
      detail.pop_back();
    }
    return std::unexpected(Error::Generic(
        Tr(Msg::kCapiCommandFailed, what, result.exit_code,
           detail.empty() ? std::string{Text(Msg::kCapiCommandNoOutput)} : detail)));
  }
  return tetherkit::Ok();
}

/// 读接口当前的 IPv4 地址；没有地址时返回 std::nullopt。
///
/// 用 ioctl 而不是 `ipconfig getifaddr`：这是内核里的真实状态，不经过任何
/// 中间层，而且不用 fork 一个进程。
[[nodiscard]] std::optional<std::string> QueryAddress(std::string_view interface_name,
                                                      unsigned long request) noexcept {
  const int fd = ::socket(AF_INET, SOCK_DGRAM, 0);
  if (fd < 0) {
    return std::nullopt;
  }

  ::ifreq ifr{};
  const std::size_t copy_length = std::min(interface_name.size(), sizeof(ifr.ifr_name) - 1);
  std::memcpy(ifr.ifr_name, interface_name.data(), copy_length);
  ifr.ifr_addr.sa_family = AF_INET;

  std::optional<std::string> result;
  if (::ioctl(fd, request, &ifr) == 0) {
    std::array<char, INET_ADDRSTRLEN> text{};
    // NOLINTNEXTLINE(cppcoreguidelines-pro-type-reinterpret-cast)
    const auto* address = reinterpret_cast<const ::sockaddr_in*>(&ifr.ifr_addr);
    if (::inet_ntop(AF_INET, &address->sin_addr, text.data(), text.size()) != nullptr) {
      result = std::string{text.data()};
    }
  }
  ::close(fd);
  return result;
}

// ---------------------------------------------------------------------------
// SCDynamicStore 查询
// ---------------------------------------------------------------------------

/// 找到 IPConfiguration 为该接口建立的服务 ID。
///
/// 做法是枚举 `State:/Network/Service/<id>/IPv4` 并按 `InterfaceName` 匹配，
/// 而**不是**去猜服务 ID 的拼法。实测 `ipconfig set feth0 DHCP` 得到的 ID 是
/// "DHCP-feth0"，看起来可以直接拼，但那是实现细节，按字段匹配才靠得住。
[[nodiscard]] std::optional<std::string> FindServiceId(SCDynamicStoreRef store,
                                                       std::string_view interface_name) {
  const ScopedCFRef<CFStringRef> pattern = MakeCFString("State:/Network/Service/[^/]+/IPv4");
  const ScopedCFRef<CFArrayRef> keys{
      ::SCDynamicStoreCopyKeyList(store, pattern.Get())};
  if (!keys) {
    return std::nullopt;
  }

  const CFIndex count = ::CFArrayGetCount(keys.Get());
  for (CFIndex i = 0; i < count; ++i) {
    const auto* const key = static_cast<CFStringRef>(::CFArrayGetValueAtIndex(keys.Get(), i));
    const ScopedCFRef<CFDictionaryRef> entry{
        static_cast<CFDictionaryRef>(::SCDynamicStoreCopyValue(store, key))};
    if (!entry) {
      continue;
    }
    const auto* const name = static_cast<CFStringRef>(
        ::CFDictionaryGetValue(entry.Get(), CFSTR("InterfaceName")));
    if (name == nullptr || CopyToStdString(name) != interface_name) {
      continue;
    }

    // 从 "State:/Network/Service/<id>/IPv4" 里截出 <id>。
    const std::string full = CopyToStdString(key);
    constexpr std::string_view kPrefix = "State:/Network/Service/";
    constexpr std::string_view kSuffix = "/IPv4";
    if (full.size() <= kPrefix.size() + kSuffix.size()) {
      continue;
    }
    return full.substr(kPrefix.size(), full.size() - kPrefix.size() - kSuffix.size());
  }
  return std::nullopt;
}

[[nodiscard]] ScopedCFRef<CFDictionaryRef> CopyServiceEntry(SCDynamicStoreRef store,
                                                            std::string_view service_id,
                                                            std::string_view leaf) {
  const ScopedCFRef<CFStringRef> key =
      MakeCFString(std::format("State:/Network/Service/{}/{}", service_id, leaf));
  return ScopedCFRef<CFDictionaryRef>{
      static_cast<CFDictionaryRef>(::SCDynamicStoreCopyValue(store, key.Get()))};
}

/// 取字典里的字符串字段；缺失时返回空串。
[[nodiscard]] std::string StringField(CFDictionaryRef dictionary, CFStringRef field) {
  if (dictionary == nullptr) {
    return {};
  }
  const auto* const value = static_cast<CFStringRef>(::CFDictionaryGetValue(dictionary, field));
  if (value == nullptr || ::CFGetTypeID(value) != ::CFStringGetTypeID()) {
    return {};
  }
  return CopyToStdString(value);
}

/// 取字典里的字符串数组字段。
[[nodiscard]] std::vector<std::string> StringArrayField(CFDictionaryRef dictionary,
                                                        CFStringRef field) {
  std::vector<std::string> values;
  if (dictionary == nullptr) {
    return values;
  }
  const auto* const array = static_cast<CFArrayRef>(::CFDictionaryGetValue(dictionary, field));
  if (array == nullptr || ::CFGetTypeID(array) != ::CFArrayGetTypeID()) {
    return values;
  }
  const CFIndex count = ::CFArrayGetCount(array);
  values.reserve(static_cast<std::size_t>(count));
  for (CFIndex i = 0; i < count; ++i) {
    const auto* const item = static_cast<CFStringRef>(::CFArrayGetValueAtIndex(array, i));
    if (item != nullptr && ::CFGetTypeID(item) == ::CFStringGetTypeID()) {
      values.push_back(CopyToStdString(item));
    }
  }
  return values;
}

/// 全局默认路由当前指向哪个接口。
[[nodiscard]] std::string PrimaryInterface(SCDynamicStoreRef store) {
  const ScopedCFRef<CFStringRef> key = MakeCFString("State:/Network/Global/IPv4");
  const ScopedCFRef<CFDictionaryRef> global{
      static_cast<CFDictionaryRef>(::SCDynamicStoreCopyValue(store, key.Get()))};
  return StringField(global.Get(), CFSTR("PrimaryInterface"));
}

// ---------------------------------------------------------------------------
// 下发
// ---------------------------------------------------------------------------

/// 把 DNS 服务器写到 IPConfiguration 建立的那个服务上。
///
/// ⚠️ **未经真机验证的一手。** 已确认的是：手工**捏造**整个服务不会被 IPMonitor
/// 采纳（GUI-SPIKE 第 3.2 节）。这里的赌注是「往一个**已经正规注册**的服务上
/// 补 DNS 键会被采纳」。赌错了也不会有破坏，只是 DNS 不生效 —— 所以失败一律
/// 只记日志，绝不让整个静态 IP 配置失败。真实结果由 tk_net_query 回读汇报。
///
/// 另外注意：SCDynamicStore 里的值**由设置它的会话持有**，会话一释放值就没了。
/// 因此这里用的是进程级长命的 store（见 SharedDynamicStore 的说明），
/// 绝不能改成局部创建。
void TryPublishDns(SCDynamicStoreRef store, std::string_view service_id,
                   const std::vector<std::string>& servers) {
  if (servers.empty()) {
    return;
  }

  std::vector<ScopedCFRef<CFStringRef>> owned;
  std::vector<const void*> raw;
  owned.reserve(servers.size());
  raw.reserve(servers.size());
  for (const std::string& server : servers) {
    owned.push_back(MakeCFString(server));
    raw.push_back(owned.back().Get());
  }

  const ScopedCFRef<CFArrayRef> addresses{::CFArrayCreate(
      kCFAllocatorDefault, raw.data(), static_cast<CFIndex>(raw.size()), &kCFTypeArrayCallBacks)};
  const void* keys[] = {CFSTR("ServerAddresses")};
  const void* values[] = {addresses.Get()};
  const ScopedCFRef<CFDictionaryRef> payload{
      ::CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                           &kCFTypeDictionaryValueCallBacks)};

  const ScopedCFRef<CFStringRef> key =
      MakeCFString(std::format("State:/Network/Service/{}/DNS", service_id));
  if (::SCDynamicStoreSetValue(store, key.Get(), payload.Get()) == 0) {
    TETHERKIT_WARN_TR(Msg::kCapiDnsPublishFailed, service_id);
  }
}

/// 等**本次新建的**服务发布出一个**稳定**的租约，返回它的网关。
///
/// 判定用 `State:/Network/Service/<id>/IPv4` 里的 `InterfaceName` + `Addresses`
/// + `Router`，而**不是**只看接口地址：旧服务刚被移除时接口上仍留着上一次的地址。
///
/// ★ 为什么还要等「稳定」★
///   Android 的 USB 网络共享会**先**发一份 464XLAT 过渡租约
///   （192.0.0.2 / 网关 192.0.0.1），几秒后才换成真正的 172.19.x.x 段。实测拿
///   第一份就装 scoped 路由，会在设备换租约后留下一条指向已失效网关的路由 ——
///   而那正是 NetworkExtension 按接口查路径时会用的那条。所以要求网关连续
///   kDhcpStableSamples 次读到同一个值才算稳。
///
/// ⚠️ 不能查 `ConfigMethod` 或 DHCP 字典里的 `State` —— **持久服务的动态存储条目
/// 里没有这两个键**（实测：注册服务只有 Addresses / Router / InterfaceName /
/// AdditionalRoutes，DHCP 字典只有 Lease* 与 Option_*；那两个键只出现在
/// `ipconfig set` 建立的临时服务上）。
[[nodiscard]] std::optional<std::string> WaitForStableLease(std::string_view interface_name,
                                                            std::string_view service_id) {
  SCDynamicStoreRef store = SharedDynamicStore();
  if (store == nullptr) {
    return std::nullopt;
  }

  // 读一次「本服务当前发布的网关」；地址与接口名对不上时视为还没就绪。
  const auto published_router = [&]() -> std::optional<std::string> {
    const std::optional<std::string> address = QueryAddress(interface_name, SIOCGIFADDR);
    if (!address.has_value()) {
      return std::nullopt;
    }
    const ScopedCFRef<CFDictionaryRef> ipv4 = CopyServiceEntry(store, service_id, "IPv4");
    if (StringField(ipv4.Get(), CFSTR("InterfaceName")) != interface_name) {
      return std::nullopt;
    }
    const std::vector<std::string> addresses = StringArrayField(ipv4.Get(), CFSTR("Addresses"));
    if (std::ranges::find(addresses, *address) == addresses.end()) {
      return std::nullopt;
    }
    const std::string router = StringField(ipv4.Get(), CFSTR("Router"));
    return IsValidIpv4(router) ? std::optional{router} : std::nullopt;
  };

  std::optional<std::string> candidate;
  int stable_samples = 0;
  const auto deadline = std::chrono::steady_clock::now() + kDhcpLeaseTimeout;
  while (std::chrono::steady_clock::now() < deadline) {
    const std::optional<std::string> router = published_router();
    if (router.has_value() && router == candidate) {
      if (++stable_samples >= kDhcpStableSamples) {
        return candidate;
      }
    } else {
      candidate = router;
      stable_samples = router.has_value() ? 1 : 0;
    }
    std::this_thread::sleep_for(kDhcpPollInterval);
  }
  return std::nullopt;
}

/// 装一条**绑定到本接口**的默认路由。
///
/// scoped 路由（RTF_IFSCOPE）是 macOS 支持的每接口独立默认路由：绑定到该接口的
/// 流量走它，不影响系统主服务。IPConfiguration 通常会为 DHCP 服务装好这一条；
/// 但 feth 成为主服务时，macOS 可能只保留全局默认路由。这里显式补齐，保证
/// NetworkExtension 等按接口做路由查询的调用方仍能找到路径。
///
/// 先删再加，不用 `change`：接口上可能残留一条指向**旧网关**的 scoped 路由
/// （设备换过租约），`change` 改不动 destination 相同但已失效的那条的语义歧义，
/// 删掉重建才能保证最终只有一条、且指向当前网关。删除失败通常意味着本来就没有，
/// 属于正常情况，故忽略其结果。
[[nodiscard]] Status InstallScopedDefaultRoute(std::string_view interface_name,
                                               std::string_view router) {
  const std::vector<std::string> delete_arguments{
      "-n", "delete", "-inet", "-ifscope", std::string{interface_name}, "default"};
  std::ignore = RunTool(kRoutePath, delete_arguments);

  const std::vector<std::string> add_arguments{
      "-n", "add", "-inet", "-ifscope", std::string{interface_name}, "default", std::string{router}};
  return RunOrFail(kRoutePath, add_arguments, Text(Msg::kCapiWhatAddScopedRoute));
}

/// 把**全局**默认路由改到指定网关。
[[nodiscard]] Status PromoteToGlobalDefaultRoute(std::string_view router) {
  const std::vector<std::string> arguments{"-n", "change", "-inet", "default", std::string{router}};
  if (const auto status = RunOrFail(kRoutePath, arguments, Text(Msg::kCapiWhatSwitchGlobalRoute));
      status) {
    return tetherkit::Ok();
  }
  // 系统当前可能压根没有全局默认路由（没连任何网络），此时 change 会失败，
  // 该用 add。这正是 USB 网络共享最典型的场景，必须处理。
  const std::vector<std::string> add_arguments{"-n", "add", "-inet", "default",
                                               std::string{router}};
  return RunOrFail(kRoutePath, add_arguments, Text(Msg::kCapiWhatAddGlobalRoute));
}



[[nodiscard]] Status ApplyDhcp(std::string_view interface_name, bool set_default_route) {
  // 先清掉同接口的旧服务。`ipconfig NONE` 负责兼容升级前留下的临时服务；
  // SCNetworkService 才是本次 DHCP 真正使用的服务。
  TETHERKIT_RETURN_IF_ERROR(tetherkit::capi::RemoveManagedNetworkService(interface_name));
  TETHERKIT_RETURN_IF_ERROR(
      RunOrFail(kIpconfigPath, {"set", std::string{interface_name}, "NONE"},
                Text(Msg::kCapiWhatClearConfig)));
  TETHERKIT_ASSIGN_OR_RETURN(
      const std::string service_id,
      tetherkit::capi::ConfigureManagedDhcpService(interface_name));

  // 等一个稳定的租约。IPConfiguration 会拿租约、配 scoped DNS，并把服务发布到
  // 动态存储；scoped 默认路由要我们显式补齐（feth 成为主服务时 macOS 可能只留
  // 全局路由，NetworkExtension 对 feth 的 scoped 查询就会得到「No network route」）。
  const std::optional<std::string> router = WaitForStableLease(interface_name, service_id);
  if (!router.has_value()) {
    // 地址都还没有 —— 对面很可能没在做网络共享，这才是真正的超时。
    if (!QueryAddress(interface_name, SIOCGIFADDR).has_value()) {
      return std::unexpected(Error::Generic(Tr(Msg::kCapiDhcpTimeout, kDhcpLeaseTimeout.count())));
    }
    // 有地址但网关一直没稳定下来：不装任何默认路由，免得留下一条指向过期网关的。
    if (set_default_route) {
      return std::unexpected(Error::Generic(Tr(Msg::kCapiDhcpNoRouter)));
    }
    return tetherkit::Ok();
  }

  TETHERKIT_RETURN_IF_ERROR(InstallScopedDefaultRoute(interface_name, *router));
  if (!set_default_route) {
    return tetherkit::Ok();
  }
  return PromoteToGlobalDefaultRoute(*router);
}

[[nodiscard]] Status ApplyManual(std::string_view interface_name, const tk_ip_config_t& config) {
  if (!IsValidIpv4(config.address)) {
    return std::unexpected(
        Error::Generic(Tr(Msg::kCapiInvalidAddress, config.address)));
  }
  if (!IsValidIpv4(config.netmask)) {
    return std::unexpected(
        Error::Generic(Tr(Msg::kCapiInvalidNetmask, config.netmask)));
  }
  const std::string_view router{config.router};
  if (!router.empty() && !IsValidIpv4(router)) {
    return std::unexpected(
        Error::Generic(Tr(Msg::kCapiInvalidRouter, router)));
  }
  if (config.set_default_route && router.empty()) {
    return std::unexpected(Error::Generic(Tr(Msg::kCapiDefaultRouteNeedsRouter)));
  }

  std::vector<std::string> dns_servers;
  for (std::int32_t i = 0; i < config.dns_count && i < TK_DNS_MAX; ++i) {
    const std::string_view server{config.dns[i]};
    if (server.empty()) {
      continue;
    }
    if (!IsValidIpv4(server)) {
      return std::unexpected(
          Error::Generic(Tr(Msg::kCapiInvalidDns, server)));
    }
    dns_servers.emplace_back(server);
  }

  TETHERKIT_RETURN_IF_ERROR(tetherkit::capi::RemoveManagedNetworkService(interface_name));
  // 地址仍然经 IPConfiguration 下发，理由见文件头。
  TETHERKIT_RETURN_IF_ERROR(RunOrFail(
      kIpconfigPath,
      {"set", std::string{interface_name}, "MANUAL", config.address, config.netmask},
      Text(Msg::kCapiWhatApplyManual)));

  if (!router.empty()) {
    TETHERKIT_RETURN_IF_ERROR(InstallScopedDefaultRoute(interface_name, router));
    if (config.set_default_route) {
      TETHERKIT_RETURN_IF_ERROR(PromoteToGlobalDefaultRoute(router));
    }
  }

  if (!dns_servers.empty()) {
    SCDynamicStoreRef store = SharedDynamicStore();
    if (store != nullptr) {
      if (const std::optional<std::string> service_id = FindServiceId(store, interface_name);
          service_id.has_value()) {
        TryPublishDns(store, *service_id, dns_servers);
      } else {
        TETHERKIT_WARN_TR(Msg::kCapiNoServiceForDns, interface_name);
      }
    }
  }
  return tetherkit::Ok();
}

[[nodiscard]] Status ApplyNone(std::string_view interface_name) {
  TETHERKIT_RETURN_IF_ERROR(tetherkit::capi::RemoveManagedNetworkService(interface_name));
  return RunOrFail(kIpconfigPath, {"set", std::string{interface_name}, "NONE"},
                   Text(Msg::kCapiWhatClearConfig));
}

}  // namespace

void tk_ip_config_init(tk_ip_config_t* out_config) {
  if (out_config == nullptr) {
    return;
  }
  *out_config = tk_ip_config_t{};
  // 默认 DHCP：RNDIS 设备几乎总是自带 DHCP 服务器，这是绝大多数用户唯一需要的选项。
  out_config->mode = TK_IP_MODE_DHCP;
  // 默认**不**抢全局默认路由。只有在同时存在更高优先级的连通服务时才需要它，
  // 而 USB 网络共享的典型场景恰恰是没有别的网络可用 —— 那时本网卡自然就是主服务。
  out_config->set_default_route = false;
}

tk_result_t tk_net_apply(const char* interface_name, const tk_ip_config_t* config,
                         tk_error_t* out_error) {
  ClearError(out_error);
  if (config == nullptr) {
    FillGenericError(out_error, Tr(Msg::kCapiApplyConfigNull));
    return TK_ERR_INVALID_ARGUMENT;
  }
  if (const auto status = ValidateInterface(interface_name); !status) {
    FillError(out_error, status.error());
    return TK_ERR_INVALID_ARGUMENT;
  }
  if (::geteuid() != 0) {
    FillGenericError(out_error, Tr(Msg::kCapiApplyNeedsRoot));
    return TK_ERR_PERMISSION;
  }

  Status status = tetherkit::Ok();
  switch (config->mode) {
    case TK_IP_MODE_DHCP:
      status = ApplyDhcp(interface_name, config->set_default_route);
      break;
    case TK_IP_MODE_MANUAL:
      status = ApplyManual(interface_name, *config);
      break;
    case TK_IP_MODE_NONE:
      status = ApplyNone(interface_name);
      break;
    default:
      FillGenericError(out_error, Tr(Msg::kCapiUnknownIpMode, config->mode));
      return TK_ERR_INVALID_ARGUMENT;
  }

  if (!status) {
    FillError(out_error, status.error());
    return TK_ERR_FAILED;
  }
  return TK_OK;
}

tk_result_t tk_net_clear(const char* interface_name, tk_error_t* out_error) {
  ClearError(out_error);
  if (const auto status = ValidateInterface(interface_name); !status) {
    FillError(out_error, status.error());
    return TK_ERR_INVALID_ARGUMENT;
  }
  if (::geteuid() != 0) {
    FillGenericError(out_error, Tr(Msg::kCapiClearNeedsRoot));
    return TK_ERR_PERMISSION;
  }

  // 先撤掉我们自己写的 DNS 键（如果有），再让 IPConfiguration 拆服务。
  // 顺序反了的话服务已经没了，键会变成没人认领的孤儿。
  if (SCDynamicStoreRef store = SharedDynamicStore(); store != nullptr) {
    if (const std::optional<std::string> service_id = FindServiceId(store, interface_name);
        service_id.has_value()) {
      const ScopedCFRef<CFStringRef> key =
          MakeCFString(std::format("State:/Network/Service/{}/DNS", *service_id));
      ::SCDynamicStoreRemoveValue(store, key.Get());
    }
  }

  if (const auto status = ApplyNone(interface_name); !status) {
    FillError(out_error, status.error());
    return TK_ERR_FAILED;
  }
  return TK_OK;
}

tk_result_t tk_net_query(const char* interface_name, tk_net_state_t* out_state,
                         tk_error_t* out_error) {
  ClearError(out_error);
  if (out_state == nullptr) {
    return TK_ERR_INVALID_ARGUMENT;
  }
  if (const auto status = ValidateInterface(interface_name); !status) {
    FillError(out_error, status.error());
    return TK_ERR_INVALID_ARGUMENT;
  }
  *out_state = tk_net_state_t{};

  // ---- 地址与掩码：内核里的真实状态 ----
  if (const std::optional<std::string> address = QueryAddress(interface_name, SIOCGIFADDR);
      address.has_value()) {
    out_state->has_address = true;
    CopyText(out_state->address, *address);
  }
  if (const std::optional<std::string> netmask = QueryAddress(interface_name, SIOCGIFNETMASK);
      netmask.has_value()) {
    CopyText(out_state->netmask, *netmask);
  }

  // ---- 服务级信息：网关、DNS、配置方式 ----
  SCDynamicStoreRef store = SharedDynamicStore();
  if (store == nullptr) {
    // 拿不到动态存储不算查询失败 —— 地址那一半已经有了，照常返回。
    return TK_OK;
  }

  const std::optional<std::string> service_id = FindServiceId(store, interface_name);
  if (service_id.has_value()) {
    const ScopedCFRef<CFDictionaryRef> ipv4 = CopyServiceEntry(store, *service_id, "IPv4");
    const std::string router = StringField(ipv4.Get(), CFSTR("Router"));
    if (!router.empty()) {
      CopyText(out_state->router, router);
      out_state->has_default_route = true;
    }
    // ConfigMethod / State 只有临时服务才发布；持久服务没有这两个键，此时按
    // 「DHCP 租约字典存不存在」回推配置方式与服务状态，免得界面显示空白。
    //
    // ⚠️ 判据必须是**字典本身**，不能读里面的 LeaseStartTime —— 那个值是
    // **CFDate 而不是 CFString**，StringField 会一律返回空串，于是每个 DHCP
    // 服务都会被误判成 MANUAL（界面上真实出现过这个错 badge）。
    const ScopedCFRef<CFDictionaryRef> dhcp = CopyServiceEntry(store, *service_id, "DHCP");

    std::string method = StringField(ipv4.Get(), CFSTR("ConfigMethod"));
    if (method.empty() && out_state->has_address) {
      method = dhcp ? "DHCP" : "MANUAL";
    }
    CopyText(out_state->method, method);

    std::string service_state = StringField(dhcp.Get(), CFSTR("State"));
    if (service_state.empty() && dhcp && out_state->has_address) {
      service_state = "BOUND";
    }
    CopyText(out_state->service_state, service_state);

    // DNS 一律回读**系统里真实生效的**，而不是复述我们下发的值 ——
    // 静态模式下 DNS 能不能生效取决于 IPMonitor 认不认，只有回读才准。
    const ScopedCFRef<CFDictionaryRef> dns = CopyServiceEntry(store, *service_id, "DNS");
    const std::vector<std::string> servers = StringArrayField(dns.Get(), CFSTR("ServerAddresses"));
    for (const std::string& server : servers) {
      if (out_state->dns_count >= TK_DNS_MAX) {
        break;
      }
      CopyText(out_state->dns[out_state->dns_count], TK_ADDRESS_CAPACITY, server);
      ++out_state->dns_count;
    }
  }

  out_state->is_primary_default_route = PrimaryInterface(store) == interface_name;
  return TK_OK;
}

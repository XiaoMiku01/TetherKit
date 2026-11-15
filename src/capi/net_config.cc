// 虚拟网卡的上网方式配置：DHCP / 静态 IP / 撤销，以及真实生效状态的回读。
//
// ★ 为什么走 `ipconfig` 而不是自己 SIOCAIFADDR ★
//
//   裸 ioctl 配出来的地址内核是认的（docs/GUI-SPIKE.md 第 6.1 节实测），但
//   **configd 完全不认** —— 不会有服务、不会有 scoped DNS、不会有默认路由。
//   而 `ipconfig set` 走的是 IPConfiguration 的正规注册路径，由它建立的服务
//   IPMonitor 完全采纳。同一批动态存储键，手工写不认、IPConfiguration 写就认，
//   差别只在服务是否经正规路径注册（第 3.2 / 6.3 节）。
//
//   代价：`ipconfig set` 建立的是**临时服务**，只活到下一次网络配置变更，且
//   不出现在「系统设置 → 网络」里。对 GUI 反而好办 —— App 自己就是配置入口，
//   服务掉了重新 set 即可。
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
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include "capi_support.h"
#include "core_foundation_support.h"
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

/// 等 DHCP 拿到租约。超时返回 false。
[[nodiscard]] bool WaitForLease(std::string_view interface_name) {
  const auto deadline = std::chrono::steady_clock::now() + kDhcpLeaseTimeout;
  while (std::chrono::steady_clock::now() < deadline) {
    if (QueryAddress(interface_name, SIOCGIFADDR).has_value()) {
      return true;
    }
    std::this_thread::sleep_for(kDhcpPollInterval);
  }
  return QueryAddress(interface_name, SIOCGIFADDR).has_value();
}

/// 装一条**绑定到本接口**的默认路由。
///
/// scoped 路由（RTF_IFSCOPE）是 macOS 支持的每接口独立默认路由：绑定到该接口的
/// 流量走它，不影响系统主服务。DHCP 模式下 IPConfiguration 会自己装好这一条，
/// 只有静态模式需要我们补。
[[nodiscard]] Status InstallScopedDefaultRoute(std::string_view interface_name,
                                               std::string_view router) {
  const std::vector<std::string> add_arguments{
      "-n", "add", "-inet", "-ifscope", std::string{interface_name}, "default", std::string{router}};
  if (const auto status =
          RunOrFail(kRoutePath, add_arguments, Text(Msg::kCapiWhatAddScopedRoute));
      status) {
    return tetherkit::Ok();
  }
  // 已经存在同样一条时 add 会失败（EEXIST），改成 change 再试一次。
  const std::vector<std::string> change_arguments{
      "-n",      "change",  "-inet",   "-ifscope",
      std::string{interface_name}, "default", std::string{router}};
  return RunOrFail(kRoutePath, change_arguments, Text(Msg::kCapiWhatUpdateScopedRoute));
}

struct CurrentDefaultRoute {
  std::string gateway;
  std::string interface;
};

/// 查询系统当前的全局默认网关与接口（若存在）。
[[nodiscard]] std::optional<CurrentDefaultRoute> QueryCurrentDefaultRoute() {
  const auto result = RunTool(kRoutePath, {"-n", "get", "default"});
  if (!result || !result->Succeeded()) {
    return std::nullopt;
  }
  const std::string_view output = result->output;
  CurrentDefaultRoute info;

  if (const auto gw_pos = output.find("gateway: "); gw_pos != std::string_view::npos) {
    const auto line_end = output.find('\n', gw_pos);
    const auto gw_start = gw_pos + 9;
    std::string gw{output.substr(gw_start, (line_end == std::string_view::npos ? output.size() : line_end) - gw_start)};
    while (!gw.empty() && (gw.back() == ' ' || gw.back() == '\r')) {
      gw.pop_back();
    }
    if (IsValidIpv4(gw)) {
      info.gateway = gw;
    }
  }

  if (const auto if_pos = output.find("interface: "); if_pos != std::string_view::npos) {
    const auto line_end = output.find('\n', if_pos);
    const auto if_start = if_pos + 11;
    std::string iface{output.substr(if_start, (line_end == std::string_view::npos ? output.size() : line_end) - if_start)};
    while (!iface.empty() && (iface.back() == ' ' || iface.back() == '\r')) {
      iface.pop_back();
    }
    info.interface = iface;
  }

  if (info.gateway.empty()) {
    return std::nullopt;
  }
  return info;
}

// 跟踪当前由 TetherKit 改动全局默认路由前的原有网关与本网卡装上的网关，
// 用于在停机或撤销时完整恢复，避免破坏用户的 Wi-Fi / 有线连接。
std::mutex g_global_route_mutex;
std::string g_installed_global_router;
std::string g_previous_global_router;

/// 把**全局**默认路由改到指定网关。
[[nodiscard]] Status PromoteToGlobalDefaultRoute(std::string_view router) {
  // 记录改动前的默认网关（只要它不是当前要设的 router，且不属于 feth 网卡自身）
  {
    const std::lock_guard<std::mutex> guard(g_global_route_mutex);
    if (const auto current = QueryCurrentDefaultRoute(); current.has_value()) {
      if (current->gateway != router && !current->interface.starts_with("feth")) {
        g_previous_global_router = current->gateway;
      }
    }
  }

  const std::vector<std::string> arguments{"-n", "change", "-inet", "default", std::string{router}};
  if (const auto status = RunOrFail(kRoutePath, arguments, Text(Msg::kCapiWhatSwitchGlobalRoute));
      status) {
    const std::lock_guard<std::mutex> guard(g_global_route_mutex);
    g_installed_global_router = std::string{router};
    return tetherkit::Ok();
  }
  // 系统当前可能压根没有全局默认路由（没连任何网络），此时 change 会失败，
  // 该用 add。这正是 USB 网络共享最典型的场景，必须处理。
  const std::vector<std::string> add_arguments{"-n", "add", "-inet", "default",
                                               std::string{router}};
  const auto status = RunOrFail(kRoutePath, add_arguments, Text(Msg::kCapiWhatAddGlobalRoute));
  if (status) {
    const std::lock_guard<std::mutex> guard(g_global_route_mutex);
    g_installed_global_router = std::string{router};
  }
  return status;
}

/// DHCP 模式下，从租约里取出网关地址。
[[nodiscard]] std::optional<std::string> QueryDhcpRouter(std::string_view interface_name) {
  const auto result = RunTool(kIpconfigPath, {"getoption", interface_name, "router"});
  if (!result || !result->Succeeded()) {
    return std::nullopt;
  }
  std::string router{result->output};
  while (!router.empty() && (router.back() == '\n' || router.back() == '\r')) {
    router.pop_back();
  }
  return IsValidIpv4(router) ? std::optional{router} : std::nullopt;
}

[[nodiscard]] Status ApplyDhcp(std::string_view interface_name, bool set_default_route) {
  TETHERKIT_RETURN_IF_ERROR(
      RunOrFail(kIpconfigPath, {"set", std::string{interface_name}, "DHCP"},
                Text(Msg::kCapiWhatStartDhcp)));

  // 等租约。IPConfiguration 会自动完成四件事：拿租约、配 scoped DNS、
  // 装 scoped 默认路由、把服务发布到动态存储 —— 我们什么都不用做。
  if (!WaitForLease(interface_name)) {
    return std::unexpected(Error::Generic(Tr(Msg::kCapiDhcpTimeout, kDhcpLeaseTimeout.count())));
  }

  if (!set_default_route) {
    return tetherkit::Ok();
  }
  const std::optional<std::string> router = QueryDhcpRouter(interface_name);
  if (!router.has_value()) {
    return std::unexpected(Error::Generic(Tr(Msg::kCapiDhcpNoRouter)));
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

void ClearGlobalDefaultRoute(std::string_view interface_name) {
  std::string installed;
  std::string previous;
  {
    const std::lock_guard<std::mutex> guard(g_global_route_mutex);
    installed = std::move(g_installed_global_router);
    previous = std::move(g_previous_global_router);
    g_installed_global_router.clear();
    g_previous_global_router.clear();
  }

  // 1. 若记录了改动前的网关，优先恢复它（例如恢复 Wi-Fi / 有线网关）
  if (!previous.empty()) {
    const auto restore_result =
        RunTool(kRoutePath, {"-n", "change", "-inet", "default", previous});
    if (restore_result && restore_result->Succeeded()) {
      return;
    }
  }

  // 2. 否则，清除 TetherKit 写入的全局默认路由
  if (!installed.empty()) {
    static_cast<void>(
        RunTool(kRoutePath, {"-n", "delete", "-inet", "default", installed}));
    return;
  }

  // 3. 兜底保护（如 helper 重启）：若当前默认路由绑定在当前 feth 网卡上，删除它避免留下死路由
  if (const auto current = QueryCurrentDefaultRoute(); current.has_value()) {
    if (current->interface == interface_name) {
      static_cast<void>(
          RunTool(kRoutePath, {"-n", "delete", "-inet", "default", current->gateway}));
    }
  }
}

[[nodiscard]] Status ApplyNone(std::string_view interface_name) {
  ClearGlobalDefaultRoute(interface_name);
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
    CopyText(out_state->method, StringField(ipv4.Get(), CFSTR("ConfigMethod")));

    // DHCP 字典只在 DHCP 模式下存在，State 是 BOUND / INIT 之类。
    const ScopedCFRef<CFDictionaryRef> dhcp = CopyServiceEntry(store, *service_id, "DHCP");
    CopyText(out_state->service_state, StringField(dhcp.Get(), CFSTR("State")));

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

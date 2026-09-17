// 孤儿 feth 网卡的登记与清理。
//
// ★ 要解决的问题 ★
//   FethInterface 是 RAII 的，正常退出时网卡会被销毁。但**进程被 SIGKILL 时
//   析构根本不跑**，网卡就永远留在内核里了 —— 而 SIGKILL 是任何信号处理器都
//   拦不住的，所以「装个信号处理器」解决不了这件事。
//
//   唯一可靠的兜底是把创建过的接口名落盘，下次启动时清理。本文件就是那个落盘
//   与清理的实现。
//
// ★ 为什么不是「启动时销毁所有 feth」★
//   feth 是公共设施，别的程序（或用户手工 ifconfig）也可能在用。只销毁我们
//   自己登记过的，才不会误伤。
#include <unistd.h>

#include <cstddef>
#include <cstdio>
#include <fstream>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

#include "capi_support.h"
#include "managed_network_service.h"
#include "tetherkit/capi/tetherkit_c.h"
#include "tetherkit/common/i18n.h"
#include "tetherkit/common/logging.h"
#include "tetherkit/net/feth_device.h"

namespace {

using tetherkit::Msg;
using tetherkit::Tr;
using tetherkit::capi::ClearError;
using tetherkit::capi::FillGenericError;
using tetherkit::capi::IsValidFethName;

/// 登记文件路径。
///
/// 放 /var/run（= /private/var/run）而不是 /tmp：这里只有 root 可写，而能写
/// 这个文件就等于能让我们去销毁任意名字的接口 —— 虽然名字有 feth<数字> 的
/// 校验兜底，但把权限收紧成 root-only 才是正确的第一道防线。
///
/// 系统重启时 /var/run 会被清空，而重启也会顺带清掉所有 feth —— 两者的生命周期
/// 恰好一致，不需要额外处理陈旧条目。
constexpr const char* kRegistryPath = "/var/run/tetherkit-interfaces";

std::mutex& RegistryMutex() {
  static std::mutex mutex;
  return mutex;
}

[[nodiscard]] std::vector<std::string> ReadRegistry() {
  std::vector<std::string> names;
  std::ifstream input{kRegistryPath};
  if (!input) {
    return names;
  }
  std::string line;
  while (std::getline(input, line)) {
    // 去掉可能的尾随空白，再做一次名字校验 —— 文件内容永远当作不可信输入。
    while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) {
      line.pop_back();
    }
    if (IsValidFethName(line)) {
      names.push_back(line);
    }
  }
  return names;
}

void WriteRegistry(const std::vector<std::string>& names) noexcept {
  // 空列表就把文件删掉，省得留一个空文件让人以为还有残留。
  if (names.empty()) {
    ::unlink(kRegistryPath);
    return;
  }
  std::ofstream output{kRegistryPath, std::ios::trunc};
  if (!output) {
    return;
  }
  for (const std::string& name : names) {
    output << name << '\n';
  }
}

/// 安装给 net::SetInterfaceRegistry 的回调。
///
/// 每次创建/销毁都整读整写一遍文件。听起来浪费，但一次会话只创建两张网卡，
/// 而换成「只追加」就得处理销毁时的行删除与文件增长，复杂度不值得。
void OnInterfaceChanged(std::string_view name, bool created) noexcept {
  // 整个回调必须 noexcept —— 销毁路径可能在析构里。fstream 默认不抛异常
  // （没有 exceptions() 设置），SystemConfiguration 的清理则显式兜住异常。
  {
    const std::lock_guard<std::mutex> guard(RegistryMutex());
    std::vector<std::string> names = ReadRegistry();

    if (created) {
      for (const std::string& existing : names) {
        if (existing == name) {
          return;
        }
      }
      names.emplace_back(name);
    } else {
      std::erase(names, std::string{name});
    }
    WriteRegistry(names);
  }

  if (!created) {
    // 网卡没了，为它注册的网络服务也该跟着走，否则会在「系统设置 → 网络」里
    // 留下一条指向不存在接口的死条目。
    try {
      if (const auto status = tetherkit::capi::RemoveManagedNetworkService(name); !status) {
        TETHERKIT_WARN_TR(Msg::kCapiServiceRemoveFailed, name, status.error().ToString());
      }
    } catch (...) {
      TETHERKIT_WARN_TR(Msg::kCapiServiceRemoveFailed, name,
                        Text(Msg::kCapiCommandNoOutput));
    }
  }
}

}  // namespace

namespace tetherkit::capi {

void InstallInterfaceRegistry() {
  net::SetInterfaceRegistry(&OnInterfaceChanged);
}

}  // namespace tetherkit::capi

tk_result_t tk_cleanup_orphan_interfaces(size_t* out_removed, tk_error_t* out_error) {
  ClearError(out_error);
  if (out_removed != nullptr) {
    *out_removed = 0;
  }
  if (::geteuid() != 0) {
    FillGenericError(out_error, Tr(Msg::kCapiCleanupNeedsRoot));
    return TK_ERR_PERMISSION;
  }

  // Setup:/Network/Service 会跨进程乃至重启持久化。先扫掉带 TetherKit 标记的
  // feth 服务，才能兜住上次 helper 被 SIGKILL、系统随后又重启的情况：那时
  // /var/run 的接口登记已经没了，但网络偏好设置里的服务仍可能留着。
  //
  // 失败只记日志：清网卡比清服务重要得多，不能让一个服务删不掉就把整轮兜底
  // 清理挡住（残留的 feth 会一直占着内核资源）。
  if (const auto status = tetherkit::capi::RemoveAllManagedNetworkServices(); !status) {
    TETHERKIT_WARN_TR(Msg::kCapiStaleServiceCleanupFailed, status.error().ToString());
  }

  // ⚠️ 销毁循环里**绝不能**持有 RegistryMutex：DestroyInterfaceByName 成功后会
  // 触发登记回调，而回调要拿同一把锁 —— std::mutex 不可重入，持着进去就是当场
  // 自等死锁。所以这里把「读」「销毁」「收尾」拆成三段，锁只在头尾两段持有。
  std::vector<std::string> names;
  {
    const std::lock_guard<std::mutex> guard(RegistryMutex());
    names = ReadRegistry();
  }
  if (names.empty()) {
    return TK_OK;
  }

  std::size_t removed = 0;
  for (const std::string& name : names) {
    // 销毁失败最常见的原因是接口已经不存在了（比如系统重启过），那正是我们
    // 想要的结果。真正的失败只记日志，不阻断其余条目。
    if (const auto status = tetherkit::net::DestroyInterfaceByName(name); status) {
      ++removed;
      continue;
    }
    TETHERKIT_DEBUG_TR(Msg::kCapiOrphanAlreadyGone, name);
  }

  // 收尾：能销毁的已经由回调逐行删掉了，剩下的是「本来就不在内核里」的条目，
  // 留着只会让下次启动重复尝试，一并清空。
  {
    const std::lock_guard<std::mutex> guard(RegistryMutex());
    WriteRegistry({});
  }

  if (out_removed != nullptr) {
    *out_removed = removed;
  }
  return TK_OK;
}

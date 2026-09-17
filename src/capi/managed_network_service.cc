// Register feth as a real macOS network service while TetherKit owns it.
//
// `ipconfig set <if> DHCP` publishes a dynamic State:/ service, but no
// Setup:/Network/Service entry. Packet-tunnel providers can lose that transient
// interface when NetworkExtension takes over routing. A service in the current
// SCNetworkSet gives configd the durable interface metadata it needs to preserve
// the underlying path during tunnel startup.
#include "managed_network_service.h"

#include <SystemConfiguration/SystemConfiguration.h>

#include <cstdint>
#include <format>
#include <optional>
#include <string>
#include <string_view>

#include "capi_support.h"
#include "core_foundation_support.h"
#include "tetherkit/common/i18n.h"

namespace {

using tetherkit::Error;
using tetherkit::Msg;
using tetherkit::Status;
using tetherkit::Tr;
using tetherkit::capi::CopyToStdString;
using tetherkit::capi::IsValidFethName;
using tetherkit::capi::MakeCFString;
using tetherkit::capi::ScopedCFRef;

// SystemConfiguration exports this SPI on every supported macOS version. The
// public API can enumerate only IOKit-backed interfaces, while feth is a pure
// ifnet. The SPI constructs the same Ethernet SCNetworkInterface object from a
// BSD name; all subsequent service/configuration calls are public API.
// Source: apple-oss-distributions/configd, SCNetworkConfigurationPrivate.h.
extern "C" SCNetworkInterfaceRef _SCNetworkInterfaceCreateWithBSDName(
    CFAllocatorRef allocator, CFStringRef bsd_name, std::uint32_t flags);

constexpr std::uint32_t kIncludeAllVirtualInterfaces = 0xFFFF'FFFFU;
constexpr std::string_view kManagedServicePrefix = "TetherKit ";

[[nodiscard]] std::unexpected<Error> SystemConfigurationFailure(
    std::string_view operation) {
  const int code = ::SCError();
  const char* const reason = ::SCErrorString(code);
  return std::unexpected(Error::Generic(Tr(
      Msg::kCapiSystemConfigurationFailed, operation, code,
      reason != nullptr ? std::string_view{reason} : std::string_view{"unknown error"})));
}

[[nodiscard]] bool IsManagedService(SCNetworkServiceRef service,
                                    std::optional<std::string_view> interface_name) {
  const CFStringRef name = ::SCNetworkServiceGetName(service);
  const ScopedCFRef<CFStringRef> prefix = MakeCFString(kManagedServicePrefix);
  if (name == nullptr || !::CFStringHasPrefix(name, prefix.Get())) {
    return false;
  }

  const SCNetworkInterfaceRef interface = ::SCNetworkServiceGetInterface(service);
  if (interface == nullptr) {
    return false;
  }
  const std::string bsd_name = CopyToStdString(::SCNetworkInterfaceGetBSDName(interface));
  if (!IsValidFethName(bsd_name)) {
    return false;
  }
  return !interface_name.has_value() || bsd_name == *interface_name;
}

[[nodiscard]] Status RemoveMatchingServices(
    SCPreferencesRef preferences, std::optional<std::string_view> interface_name,
    bool& changed) {
  const ScopedCFRef<CFArrayRef> services{::SCNetworkServiceCopyAll(preferences)};
  if (!services) {
    return SystemConfigurationFailure("SCNetworkServiceCopyAll");
  }

  const CFIndex count = ::CFArrayGetCount(services.Get());
  for (CFIndex index = 0; index < count; ++index) {
    const auto service = static_cast<SCNetworkServiceRef>(
        ::CFArrayGetValueAtIndex(services.Get(), index));
    if (!IsManagedService(service, interface_name)) {
      continue;
    }
    if (::SCNetworkServiceRemove(service) == 0) {
      return SystemConfigurationFailure("SCNetworkServiceRemove");
    }
    changed = true;
  }
  return tetherkit::Ok();
}

[[nodiscard]] Status CommitAndApply(SCPreferencesRef preferences) {
  if (::SCPreferencesCommitChanges(preferences) == 0) {
    return SystemConfigurationFailure("SCPreferencesCommitChanges");
  }
  if (::SCPreferencesApplyChanges(preferences) == 0) {
    return SystemConfigurationFailure("SCPreferencesApplyChanges");
  }
  return tetherkit::Ok();
}

[[nodiscard]] ScopedCFRef<SCPreferencesRef> CreatePreferences() {
  return ScopedCFRef<SCPreferencesRef>{
      ::SCPreferencesCreate(kCFAllocatorDefault, CFSTR("TetherKit"), nullptr)};
}

[[nodiscard]] Status RemoveManagedServices(
    std::optional<std::string_view> interface_name) {
  const ScopedCFRef<SCPreferencesRef> preferences = CreatePreferences();
  if (!preferences) {
    return SystemConfigurationFailure("SCPreferencesCreate");
  }

  bool changed = false;
  TETHERKIT_RETURN_IF_ERROR(
      RemoveMatchingServices(preferences.Get(), interface_name, changed));
  return changed ? CommitAndApply(preferences.Get()) : tetherkit::Ok();
}

}  // namespace

namespace tetherkit::capi {

Result<std::string> ConfigureManagedDhcpService(std::string_view interface_name) {
  const ScopedCFRef<SCPreferencesRef> preferences = CreatePreferences();
  if (!preferences) {
    return SystemConfigurationFailure("SCPreferencesCreate");
  }

  bool removed_existing = false;
  TETHERKIT_RETURN_IF_ERROR(
      RemoveMatchingServices(preferences.Get(), interface_name, removed_existing));

  const ScopedCFRef<CFStringRef> bsd_name = MakeCFString(interface_name);
  const ScopedCFRef<SCNetworkInterfaceRef> interface{
      _SCNetworkInterfaceCreateWithBSDName(kCFAllocatorDefault, bsd_name.Get(),
                                           kIncludeAllVirtualInterfaces)};
  if (!interface) {
    return SystemConfigurationFailure("_SCNetworkInterfaceCreateWithBSDName");
  }

  const ScopedCFRef<SCNetworkServiceRef> service{
      ::SCNetworkServiceCreate(preferences.Get(), interface.Get())};
  if (!service) {
    return SystemConfigurationFailure("SCNetworkServiceCreate");
  }

  const ScopedCFRef<CFStringRef> service_name =
      MakeCFString(std::format("TetherKit ({})", interface_name));
  if (::SCNetworkServiceSetName(service.Get(), service_name.Get()) == 0) {
    return SystemConfigurationFailure("SCNetworkServiceSetName");
  }
  if (::SCNetworkServiceEstablishDefaultConfiguration(service.Get()) == 0) {
    return SystemConfigurationFailure("SCNetworkServiceEstablishDefaultConfiguration");
  }
  if (::SCNetworkServiceSetEnabled(service.Get(), true) == 0) {
    return SystemConfigurationFailure("SCNetworkServiceSetEnabled");
  }

  const ScopedCFRef<SCNetworkProtocolRef> ipv4{
      ::SCNetworkServiceCopyProtocol(service.Get(), kSCNetworkProtocolTypeIPv4)};
  if (!ipv4) {
    return SystemConfigurationFailure("SCNetworkServiceCopyProtocol(IPv4)");
  }
  const void* keys[] = {kSCPropNetIPv4ConfigMethod};
  const void* values[] = {kSCValNetIPv4ConfigMethodDHCP};
  const ScopedCFRef<CFDictionaryRef> configuration{::CFDictionaryCreate(
      kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks)};
  if (::SCNetworkProtocolSetConfiguration(ipv4.Get(), configuration.Get()) == 0) {
    return SystemConfigurationFailure("SCNetworkProtocolSetConfiguration(IPv4)");
  }

  const ScopedCFRef<SCNetworkSetRef> network_set{
      ::SCNetworkSetCopyCurrent(preferences.Get())};
  if (!network_set) {
    return SystemConfigurationFailure("SCNetworkSetCopyCurrent");
  }
  if (::SCNetworkSetAddService(network_set.Get(), service.Get()) == 0) {
    return SystemConfigurationFailure("SCNetworkSetAddService");
  }

  const std::string service_id = CopyToStdString(::SCNetworkServiceGetServiceID(service.Get()));
  TETHERKIT_RETURN_IF_ERROR(CommitAndApply(preferences.Get()));
  return service_id;
}

Status RemoveManagedNetworkService(std::string_view interface_name) {
  return RemoveManagedServices(interface_name);
}

Status RemoveAllManagedNetworkServices() {
  return RemoveManagedServices(std::nullopt);
}

}  // namespace tetherkit::capi

#!/usr/bin/env bash
#
# 卸载 tetherkit-helper。**必须用 sudo 运行。**
#
#   sudo ./gui/Scripts/uninstall-helper.sh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# 与安装器保持相同的载荷定位规则。平铺载荷里的精确文件名用于卸载，避免在
# 共享的 PrivilegedHelperTools 目录里用 libusb-*.dylib 发现并删除别的软件文件。
if [[ -f "${SCRIPT_DIR}/com.tetherkit.helper" ]]; then
  SOURCE_DIR="${SCRIPT_DIR}"
elif [[ -n "${TETHERKIT_HELPER_DIR:-}" ]]; then
  SOURCE_DIR="${TETHERKIT_HELPER_DIR}"
else
  SOURCE_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)/dist/TetherKit.app/Contents/Library/HelperTools"
fi

LABEL="com.tetherkit.helper"
TOOLS_DIR="/Library/PrivilegedHelperTools"
INSTALL_PATH="${TOOLS_DIR}/${LABEL}"
PLIST_PATH="/Library/LaunchDaemons/${LABEL}.plist"
STATE_FILE="/var/run/tetherkit-interfaces"

log() { printf '\033[32m==>\033[0m %s\n' "$1"; }

[[ "${EUID}" -eq 0 ]] || { printf '需要 root 权限，请用 sudo 运行\n' >&2; exit 1; }

# bootout 发的是 SIGTERM，helper 接住后会停会话并销毁虚拟网卡。
# 必须在删文件**之前**做 —— 二进制没了它就没法优雅退出了。
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
  log "停止并注销服务"
  launchctl bootout "system/${LABEL}" 2>/dev/null || true
  # 给它一点时间跑完停机拆除。
  sleep 1
fi

log "删除文件"
rm -f "${PLIST_PATH}" "${INSTALL_PATH}"
for source_library in "${SOURCE_DIR}"/libtetherkit*.dylib \
                      "${SOURCE_DIR}"/libusb-*.dylib; do
  [[ -e "${source_library}" || -L "${source_library}" ]] || continue
  rm -f "${TOOLS_DIR}/$(basename "${source_library}")"
done

# 兜底：helper 若曾被强杀，登记文件里可能还留着没销毁的网卡。
if [[ -f "${STATE_FILE}" ]]; then
  while read -r interface; do
    [[ "${interface}" =~ ^feth[0-9]+$ ]] || continue
    log "销毁残留的虚拟网卡 ${interface}"
    ifconfig "${interface}" destroy 2>/dev/null || true
  done < "${STATE_FILE}"
  rm -f "${STATE_FILE}"
fi

log "已卸载"

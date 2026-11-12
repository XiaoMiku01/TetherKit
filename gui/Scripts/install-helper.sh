#!/usr/bin/env bash
#
# 安装 tetherkit-helper 并注册 LaunchDaemon。**必须以 root 运行。**
#
#   sudo ./gui/Scripts/install-helper.sh
#
# 为什么要这一步：创建 feth 虚拟网卡与打开 /dev/bpf* 都需要 root，而 App 本身
# 以普通用户身份运行。helper 的 root 来自 launchd —— 详见 docs/GUI-ARCHITECTURE.md。
#
# App 里的「安装特权组件」按钮跑的也是本脚本：build-gui.sh 把它连同载荷一起
# 打进 .app 的 Contents/Library/HelperTools/，App 经 AuthorizationExecuteWith-
# Privileges 以 root 执行那份拷贝（SMAppService 路线在源码分发下不可用 ——
# 每台机器编出的 cdhash 不同，代码签名绑定必然对不上，见 docs/GUI-SPIKE.md
# 第 3.3 节）。终端入口保留给无 GUI 的场景和不愿在 App 里输密码的人。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# 载荷目录按优先级定位：
#   1. TETHERKIT_HELPER_DIR —— 打包 / CI 想指哪就指哪；
#   2. 脚本自己所在目录 —— 打进 .app 载荷目录的那份拷贝走这条：载荷就在旁边；
#   3. 仓库默认产物位置 —— 在仓库里 sudo ./gui/Scripts/install-helper.sh 走这条。
if [[ -n "${TETHERKIT_HELPER_DIR:-}" ]]; then
  SOURCE_DIR="${TETHERKIT_HELPER_DIR}"
elif [[ -f "${SCRIPT_DIR}/com.tetherkit.helper" ]]; then
  SOURCE_DIR="${SCRIPT_DIR}"
else
  SOURCE_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)/dist/TetherKit.app/Contents/Library/HelperTools"
fi

LABEL="com.tetherkit.helper"
TOOLS_DIR="/Library/PrivilegedHelperTools"
INSTALL_PATH="${TOOLS_DIR}/${LABEL}"
PLIST_PATH="/Library/LaunchDaemons/${LABEL}.plist"

log() { printf '\033[32m==>\033[0m %s\n' "$1"; }
die() { printf '\033[31m错误：\033[0m%s\n' "$1" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "需要 root 权限，请用 sudo 运行本脚本"
[[ -f "${SOURCE_DIR}/${LABEL}" ]] || die "找不到 ${SOURCE_DIR}/${LABEL}
  请先构建：./gui/Scripts/build-gui.sh"

# ------------------------------------------------------------------------------
# 先卸载旧的
#
# 顺序很重要：必须先 bootout 再覆盖文件。反过来的话 launchd 还持有旧二进制的
# 引用，覆盖之后下一次拉起的可能仍是旧的，且没有任何提示。
# ------------------------------------------------------------------------------
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
  log "卸载已注册的旧版本"
  launchctl bootout "system/${LABEL}" 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 安装文件
# ------------------------------------------------------------------------------
log "安装到 ${INSTALL_PATH}"
mkdir -p "${TOOLS_DIR}"

# 用 cp -a 而不是 install：libtetherkit 的两个软链必须保留成软链。
# install 会把它们各拷成独立的真实文件，之后 @rpath 加载到的是哪一份就说不准了。
cp -a "${SOURCE_DIR}/${LABEL}" "${INSTALL_PATH}"
cp -a "${SOURCE_DIR}"/libtetherkit*.dylib "${TOOLS_DIR}/"
if compgen -G "${SOURCE_DIR}/libusb-*.dylib" >/dev/null; then
  cp -a "${SOURCE_DIR}"/libusb-*.dylib "${TOOLS_DIR}/"
fi

# LaunchDaemon 对权限有硬性要求：TetherKit 安装的 helper 与 dylib 必须属于
# root:wheel，且不能对组或其他用户可写。TOOLS_DIR 是多个应用共用的目录；
# 绝不能递归 chown/chmod 整个目录，否则会改动其他应用的 helper，或因受保护
# 文件导致安装中断。
chown root:wheel "${INSTALL_PATH}"
chmod 544 "${INSTALL_PATH}"
for library in "${TOOLS_DIR}"/libtetherkit*.dylib "${TOOLS_DIR}"/libusb-*.dylib; do
  [[ -f "${library}" ]] || continue
  chown root:wheel "${library}"
  chmod 444 "${library}"
done

log "安装 ${PLIST_PATH}"
cp "${SOURCE_DIR}/${LABEL}.plist" "${PLIST_PATH}"
chown root:wheel "${PLIST_PATH}"
chmod 644 "${PLIST_PATH}"

# ------------------------------------------------------------------------------
# 注册
# ------------------------------------------------------------------------------
log "注册 LaunchDaemon"
launchctl bootstrap system "${PLIST_PATH}"

# 声明了 MachServices 的服务是**按需**拉起的，注册完不会立刻有进程 ——
# 这是正常的，不要以为失败了。校验方式是看服务是否已登记。
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
  log "完成。TetherKit.app 会自动检测到它，不需要重启 App。"
else
  die "注册后仍查不到服务，请检查 /var/log/tetherkit-helper.log"
fi

cat <<EOF

已安装：
  ${INSTALL_PATH}
  ${PLIST_PATH}

日志：
  /var/log/tetherkit-helper.log

卸载：
  sudo "${SOURCE_DIR}/uninstall-helper.sh"
EOF

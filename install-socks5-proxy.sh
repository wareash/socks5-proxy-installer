#!/bin/bash
#
# SOCKS5 代理一键部署脚本 (microsocks)
# 用法: sudo bash install-socks5-proxy.sh
#
# 兼容: Debian 10+, Ubuntu 18.04+
# 处理: held broken packages, 缺少编译工具等各种异常环境
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  err "请使用 root 运行: sudo bash $0"
fi

CREDS_FILE="/etc/microsocks/credentials.env"
INFO_FILE="${HOME}/socks5-proxy-info.txt"
[[ -n "${SUDO_USER:-}" && "${HOME}" == "/root" ]] && INFO_FILE="/home/${SUDO_USER}/socks5-proxy-info.txt"
BUILD_DIR="/tmp/microsocks-build-$$"
MICROSOCKS_REPO="https://github.com/rofl0r/microsocks.git"

cleanup_build() {
  rm -rf "${BUILD_DIR}"
}
trap cleanup_build EXIT

get_public_ip() {
  curl -s --max-time 5 ifconfig.me 2>/dev/null \
    || curl -s --max-time 5 icanhazip.com 2>/dev/null \
    || hostname -I 2>/dev/null | awk '{print $1}' \
    || echo "127.0.0.1"
}

pick_free_port() {
  local port
  for _ in $(seq 1 50); do
    port=$(shuf -i 20000-65000 -n 1)
    if ! ss -tln | awk '{print $4}' | grep -q ":${port}$"; then
      echo "${port}"
      return
    fi
  done
  err "无法找到可用端口"
}

# ---------------------------------------------------------------------------
# 依赖安装 - 多层策略
# ---------------------------------------------------------------------------

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

# 策略 1: 正常 apt-get install
try_apt_install() {
  local pkg="$1"
  pkg_installed "${pkg}" && return 0
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    --no-install-recommends "${pkg}" 2>/dev/null && return 0
  return 1
}

# 策略 2: 下载 .deb 后用 dpkg 强制安装（绕过 apt 依赖解析器）
try_dpkg_force_install() {
  local pkg="$1"
  pkg_installed "${pkg}" && return 0

  local tmp_dir="/tmp/dpkg-force-$$"
  mkdir -p "${tmp_dir}"

  if apt-get download "${pkg}" -o Dir::Cache::Archives="${tmp_dir}" 2>/dev/null; then
    local deb_file
    deb_file=$(find "${tmp_dir}" -name "${pkg}*.deb" 2>/dev/null | head -1)
    if [[ -z "${deb_file}" ]]; then
      deb_file=$(ls /tmp/dpkg-force-$$/${pkg}*.deb 2>/dev/null | head -1)
    fi
    if [[ -z "${deb_file}" ]]; then
      deb_file=$(ls ./${pkg}*.deb 2>/dev/null | head -1)
    fi
    if [[ -n "${deb_file}" ]]; then
      dpkg --force-depends --force-confdef -i "${deb_file}" 2>/dev/null && {
        rm -rf "${tmp_dir}" ./${pkg}*.deb
        return 0
      }
    fi
  fi

  # apt-get download 有时会把文件放在当前目录
  local deb_file
  deb_file=$(ls ./${pkg}*.deb 2>/dev/null | head -1)
  if [[ -n "${deb_file}" ]]; then
    dpkg --force-depends --force-confdef -i "${deb_file}" 2>/dev/null && {
      rm -f ./${pkg}*.deb
      rm -rf "${tmp_dir}"
      return 0
    }
  fi

  rm -rf "${tmp_dir}"
  return 1
}

# 策略 3: 从 snapshot.debian.org 直接下载 .deb（完全不依赖本地 apt）
try_direct_download_install() {
  local pkg="$1"
  pkg_installed "${pkg}" && return 0

  local arch
  arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")

  # 使用 apt-cache 查找下载 URL
  local url
  url=$(apt-cache show "${pkg}" 2>/dev/null | grep -m1 "^Filename:" | awk '{print $2}')

  if [[ -n "${url}" ]]; then
    # 从 sources.list 中提取 mirror
    local mirror
    mirror=$(grep -m1 "^deb http" /etc/apt/sources.list 2>/dev/null | awk '{print $2}' || echo "")

    if [[ -n "${mirror}" ]]; then
      local full_url="${mirror}/${url}"
      local deb_file="/tmp/${pkg}_direct_$$.deb"

      if curl -fsSL -o "${deb_file}" "${full_url}" 2>/dev/null \
         || wget -q -O "${deb_file}" "${full_url}" 2>/dev/null; then
        dpkg --force-depends --force-confdef -i "${deb_file}" 2>/dev/null && {
          rm -f "${deb_file}"
          return 0
        }
      fi
      rm -f "${deb_file}"
    fi
  fi

  return 1
}

# 组合策略: 依次尝试所有方法安装一个包
ensure_pkg() {
  local pkg="$1"
  pkg_installed "${pkg}" && return 0
  try_apt_install "${pkg}" && return 0
  try_dpkg_force_install "${pkg}" && return 0
  try_direct_download_install "${pkg}" && return 0
  return 1
}

compiler_ready() {
  command -v gcc &>/dev/null || return 1
  command -v make &>/dev/null || return 1

  local probe="/tmp/microsocks-probe-$$"
  if printf '#include <unistd.h>\nint main(void){return 0;}\n' | gcc -x c - -o "${probe}" 2>/dev/null; then
    rm -f "${probe}"
    return 0
  fi
  rm -f "${probe}"
  return 1
}

install_build_deps() {
  export DEBIAN_FRONTEND=noninteractive

  log "修复 dpkg 状态..."
  dpkg --configure -a 2>/dev/null || true

  log "解除 held 包..."
  local held_pkgs
  held_pkgs=$(apt-mark showhold 2>/dev/null || true)
  if [[ -n "${held_pkgs}" ]]; then
    echo "${held_pkgs}" | xargs apt-mark unhold 2>/dev/null || true
    log "已解除: ${held_pkgs}"
  fi

  log "更新软件包索引..."
  apt-get update -qq 2>&1 | grep -v '^W:' || true

  log "修复 apt 依赖..."
  apt-get --fix-broken install -y 2>/dev/null || true

  # 基础工具
  local basic_ok=true
  for pkg in ca-certificates curl git openssl; do
    if ! ensure_pkg "${pkg}"; then
      # curl/git/openssl 可能已预装（通过 PATH 可用即可）
      if ! command -v "${pkg}" &>/dev/null; then
        warn "${pkg} 安装失败"
        basic_ok=false
      fi
    fi
  done

  if ! command -v git &>/dev/null; then
    err "git 不可用。请手动安装 git 后重试。"
  fi
  if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
    err "curl/wget 均不可用。请手动安装后重试。"
  fi

  # 编译工具
  if compiler_ready; then
    log "编译工具已就绪"
    return 0
  fi

  log "安装编译工具..."

  # 尝试 build-essential（一步到位）
  if ensure_pkg build-essential && compiler_ready; then
    log "已安装 build-essential"
    return 0
  fi

  # 分步安装
  log "逐步安装编译依赖..."
  ensure_pkg make || true
  if ! command -v make &>/dev/null; then
    err "make 安装失败，请手动执行: dpkg --configure -a && apt-get install -y make"
  fi

  # libc6-dev 提供 C 头文件（unistd.h 等）
  ensure_pkg libc6-dev || ensure_pkg libc-dev || true

  # gcc: 尝试多个版本
  local gcc_installed=false
  for candidate in gcc-10 gcc-12 gcc-11 gcc-9 gcc-8 gcc; do
    if ensure_pkg "${candidate}"; then
      gcc_installed=true
      # 确保 /usr/bin/gcc 存在
      if ! command -v gcc &>/dev/null; then
        local real_gcc
        real_gcc=$(command -v "${candidate}" 2>/dev/null || find /usr/bin -name "${candidate}*" -type f 2>/dev/null | head -1)
        if [[ -n "${real_gcc}" ]]; then
          ln -sf "${real_gcc}" /usr/bin/gcc
        fi
      fi
      break
    fi
  done

  if ! "${gcc_installed}"; then
    err "无法安装 gcc。请手动执行: dpkg --configure -a && apt-get install -y gcc libc6-dev make"
  fi

  # linux-libc-dev 提供某些内核头文件
  ensure_pkg linux-libc-dev 2>/dev/null || true

  # 最终验证
  if compiler_ready; then
    log "编译环境已就绪"
    return 0
  fi

  # 最后一搏: 检查缺什么
  if ! printf '#include <unistd.h>\nint main(void){return 0;}\n' | gcc -x c - -o /dev/null 2>/tmp/gcc-err-$$; then
    local gcc_error
    gcc_error=$(cat /tmp/gcc-err-$$ 2>/dev/null || echo "unknown")
    rm -f /tmp/gcc-err-$$
    err "编译器测试失败: ${gcc_error}\n请手动执行: apt-get install -y gcc libc6-dev make"
  fi
}

# ---------------------------------------------------------------------------
# 获取 microsocks 二进制 - 编译 或 下载预编译
# ---------------------------------------------------------------------------

MICROSOCKS_BIN="/usr/local/bin/microsocks"

get_microsocks() {
  # 方案 1: 从源码编译
  if compiler_ready; then
    log "编译 microsocks..."
    rm -rf "${BUILD_DIR}"
    git clone --depth 1 "${MICROSOCKS_REPO}" "${BUILD_DIR}"
    if make -C "${BUILD_DIR}" -s 2>/dev/null; then
      install -m 755 "${BUILD_DIR}/microsocks" "${MICROSOCKS_BIN}"
      log "microsocks 编译安装完成"
      return 0
    fi
    warn "编译失败，尝试下载预编译二进制..."
  fi

  # 方案 2: 下载预编译静态二进制
  download_prebuilt
}

download_prebuilt() {
  local arch
  arch=$(uname -m)
  local binary_url=""

  case "${arch}" in
    x86_64|amd64)
      binary_url="https://github.com/wareash/socks5-proxy-installer/releases/download/v1.0/microsocks-linux-amd64"
      ;;
    aarch64|arm64)
      binary_url="https://github.com/wareash/socks5-proxy-installer/releases/download/v1.0/microsocks-linux-arm64"
      ;;
    *)
      err "不支持的架构: ${arch}，且编译失败。请手动修复编译环境后重试。"
      ;;
  esac

  log "下载预编译 microsocks (${arch})..."
  if curl -fsSL -o "${MICROSOCKS_BIN}" "${binary_url}" 2>/dev/null \
     || wget -q -O "${MICROSOCKS_BIN}" "${binary_url}" 2>/dev/null; then
    chmod 755 "${MICROSOCKS_BIN}"
    # 验证二进制可执行
    if "${MICROSOCKS_BIN}" --help &>/dev/null || true; then
      log "预编译 microsocks 下载完成"
      return 0
    fi
  fi

  err "无法下载预编译 microsocks，且编译环境不可用。\n请手动修复: dpkg --configure -a && apt-get install -y gcc libc6-dev make git"
}

# ---------------------------------------------------------------------------
# 防火墙
# ---------------------------------------------------------------------------

open_firewall_port() {
  local port="$1"
  if command -v iptables &>/dev/null; then
    if ! iptables -C INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null; then
      iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT
      log "已添加 iptables 规则: TCP ${port}"
    else
      log "iptables 规则已存在: TCP ${port}"
    fi
    if command -v netfilter-persistent &>/dev/null; then
      netfilter-persistent save &>/dev/null || true
      log "iptables 规则已持久化"
    fi
  elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${port}/tcp"
    log "已添加 ufw 规则: TCP ${port}"
  else
    warn "未检测到 iptables/ufw，请自行在云安全组放行端口 ${port}"
  fi

  # 可选: iptables-persistent
  if ! pkg_installed iptables-persistent; then
    ensure_pkg iptables-persistent 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

if systemctl is-active --quiet microsocks.service 2>/dev/null; then
  warn "检测到已有 microsocks 服务，将重新部署并生成新凭据"
  systemctl stop microsocks.service 2>/dev/null || true
  pkill -9 microsocks 2>/dev/null || true
fi

install_build_deps
get_microsocks

# 验证 microsocks 可用
if [[ ! -x "${MICROSOCKS_BIN}" ]]; then
  err "microsocks 安装失败"
fi

PORT=$(pick_free_port)
USER=$(openssl rand -hex 8)
PASS=$(openssl rand -hex 12)

log "生成随机凭据 (端口 ${PORT})..."
mkdir -p /etc/microsocks
cat > "${CREDS_FILE}" <<EOF
SOCKS_PORT=${PORT}
SOCKS_USER=${USER}
SOCKS_PASS=${PASS}
EOF
chmod 600 "${CREDS_FILE}"

log "写入启动脚本与 systemd 服务..."
cat > /usr/local/bin/microsocks-start.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail
source /etc/microsocks/credentials.env
exec /usr/local/bin/microsocks -i 0.0.0.0 -p "${SOCKS_PORT}" -u "${SOCKS_USER}" -P "${SOCKS_PASS}"
SCRIPT
chmod +x /usr/local/bin/microsocks-start.sh

cat > /etc/systemd/system/microsocks.service <<'UNIT'
[Unit]
Description=SOCKS5 proxy (microsocks)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/microsocks-start.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

open_firewall_port "${PORT}"

log "启动服务..."
systemctl daemon-reload
systemctl enable microsocks.service
systemctl restart microsocks.service
sleep 1

if ! systemctl is-active --quiet microsocks.service; then
  systemctl status microsocks.service --no-pager || true
  err "microsocks 服务启动失败"
fi

PUBLIC_IP=$(get_public_ip)
PROXY_URL="socks5://${USER}:${PASS}@${PUBLIC_IP}:${PORT}"

cat > "${INFO_FILE}" <<EOF
SOCKS5 代理连接信息
====================
服务器: ${PUBLIC_IP}
端口:   ${PORT}
用户名: ${USER}
密码:   ${PASS}

连接 URL:
${PROXY_URL}

服务管理:
  sudo systemctl status microsocks
  sudo systemctl restart microsocks
  sudo systemctl stop microsocks

凭据文件: ${CREDS_FILE}
EOF

if [[ -n "${SUDO_USER:-}" ]]; then
  chown "${SUDO_USER}:${SUDO_USER}" "${INFO_FILE}" 2>/dev/null || true
fi

log "测试代理连接..."
if curl -s --max-time 10 -x "${PROXY_URL}" https://httpbin.org/ip &>/dev/null; then
  log "代理测试通过"
else
  warn "本地代理测试未通过，请检查云安全组是否放行 TCP ${PORT}"
fi

echo ""
echo "============================================"
echo -e "${GREEN}SOCKS5 代理部署完成${NC}"
echo "============================================"
echo "服务器: ${PUBLIC_IP}"
echo "端口:   ${PORT}"
echo "用户名: ${USER}"
echo "密码:   ${PASS}"
echo ""
echo "连接 URL:"
echo "  ${PROXY_URL}"
echo ""
echo "信息已保存至: ${INFO_FILE}"
echo "============================================"

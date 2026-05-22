#!/bin/bash
#
# SOCKS5 代理一键部署脚本 (microsocks)
# 用法: sudo bash install-socks5-proxy.sh
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
}

if systemctl is-active --quiet microsocks.service 2>/dev/null; then
  warn "检测到已有 microsocks 服务，将重新部署并生成新凭据"
  systemctl stop microsocks.service 2>/dev/null || true
  pkill -9 microsocks 2>/dev/null || true
fi

log "安装编译依赖..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git build-essential curl openssl iptables-persistent 2>/dev/null \
  || apt-get install -y -qq git build-essential curl openssl

log "编译 microsocks..."
rm -rf "${BUILD_DIR}"
git clone --depth 1 "${MICROSOCKS_REPO}" "${BUILD_DIR}"
make -C "${BUILD_DIR}" -s
install -m 755 "${BUILD_DIR}/microsocks" /usr/local/bin/microsocks

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

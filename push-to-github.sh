#!/bin/bash
# 在 GitHub 登录后运行此脚本，创建远程仓库并推送
set -euo pipefail

REPO_NAME="${1:-socks5-proxy-installer}"
REPO_DESC="One-click SOCKS5 proxy installer based on microsocks"

cd "$(dirname "$0")"

if ! gh auth status &>/dev/null; then
  echo "请先登录 GitHub："
  echo "  gh auth login"
  echo ""
  echo "或提供 Token："
  echo "  echo 'YOUR_GITHUB_TOKEN' | gh auth login --with-token"
  exit 1
fi

echo "当前 GitHub 账号："
gh api user --jq '.login'

echo ""
echo "创建仓库: ${REPO_NAME}"
gh repo create "${REPO_NAME}" \
  --public \
  --description "${REPO_DESC}" \
  --source=. \
  --remote=origin \
  --push

echo ""
echo "完成！仓库地址："
gh repo view --web 2>/dev/null || gh repo view --json url --jq '.url'

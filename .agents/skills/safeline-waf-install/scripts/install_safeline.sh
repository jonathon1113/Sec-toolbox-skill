#!/usr/bin/env bash
# install_safeline.sh - 执行雷池官方一键安装脚本
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] 雷池安装需要 root 权限，请用 sudo 运行本脚本。"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "[X] Docker 未就绪。请先执行 linux-docker-env/scripts/install_docker.sh"
  exit 10
fi

echo "==> 执行官方一键安装：bash -c \"\$(curl -fsSLk https://waf-ce.chaitin.cn/release/latest/manager.sh)\""
echo "==> 过程可能需要数分钟，请勿中断。"
echo

bash -c "$(curl -fsSLk https://waf-ce.chaitin.cn/release/latest/manager.sh)"
RC=$?

if [ "$RC" -ne 0 ]; then
  echo
  echo "[X] 官方安装脚本退出码 $RC。排查参考 references/故障排查.md"
  exit "$RC"
fi

echo
echo "[OK] 安装脚本执行完成。接着运行 init_admin.sh 与 verify.sh。"

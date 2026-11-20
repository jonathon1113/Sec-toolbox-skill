#!/usr/bin/env bash
# install_docker.sh - 通过轩辕镜像一键脚本安装/修复 Docker 与 Docker Compose
# 用法: bash install_docker.sh [--force]
#   --force  即使环境已就绪也重新执行安装脚本（用于重装/修复）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIN_DOCKER="20.10.14"
MIN_COMPOSE="2.0.0"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

MIRRORS=(
  "https://get.xuanyuan.cloud/docker.sh"
  "https://get.xuanyuan.me/docker.sh"
)

have() { command -v "$1" >/dev/null 2>&1; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

# ---------- sudo 处理 ----------
if ! have sudo; then
  echo "[i] 未检测到 sudo，脚本将以当前用户（需 root）身份执行"
  sudo() { "$@"; }
  export -f sudo
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "[!] 当前不是 root，请确认 sudo 可用（后续命令会自动加 sudo）"
fi

echo "========== 1/4 预检查 =========="
bash "$SCRIPT_DIR/check_env.sh" >/tmp/check_env_pre.txt 2>&1
PRE_EXIT=$?
tail -25 /tmp/check_env_pre.txt

if [ "$PRE_EXIT" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
  echo
  echo "[OK] Docker 环境已就绪，跳过安装（如需重装请加 --force）"
  exit 0
fi

echo
echo "========== 2/4 执行轩辕镜像一键安装脚本 =========="
SUCCESS=0
for url in "${MIRRORS[@]}"; do
  echo "--> 尝试镜像源: $url"
  if bash -c "curl -fsSL --retry 3 --connect-timeout 15 '$url' -o /tmp/xy_docker_install.sh" 2>/dev/null \
     && [ -s /tmp/xy_docker_install.sh ]; then
    echo "    下载成功，开始执行（该脚本将配置镜像加速并重启 docker 服务）"
    if bash /tmp/xy_docker_install.sh; then
      SUCCESS=1
      break
    else
      echo "    执行失败，换下一个镜像源"
    fi
  else
    echo "    下载失败，换下一个镜像源"
  fi
done

if [ "$SUCCESS" -ne 1 ]; then
  echo
  echo "[X] 所有镜像源均失败。"
  echo "    可能原因: 目标主机无法访问外网（离线环境）。"
  echo "    离线方案见: $SCRIPT_DIR/../references/离线安装.md"
  exit 1
fi

echo
echo "========== 3/4 安装后校验 =========="
sleep 3
bash "$SCRIPT_DIR/check_env.sh" --registry
RC=$?

if [ "$RC" -ne 0 ]; then
  echo
  echo "[X] 安装脚本执行完毕，但校验未通过（退出码 $RC）。请检查上面的输出。"
  exit $RC
fi

echo
echo "========== 4/4 优选镜像加速源 =========="
# 轩辕脚本会写入它自己的镜像源，但不保证是最快的。
# 这里统一重新测速，自动写入实测最快的源（失效可随时重跑本脚本自动切换）。
bash "$SCRIPT_DIR/configure_mirrors.sh" --top 1
MIRROR_RC=$?
if [ "$MIRROR_RC" -ne 0 ]; then
  echo
  echo "[!] 镜像加速源自动优选未完成（退出码 $MIRROR_RC）。Docker 本身已可用，"
  echo "    拉取镜像慢时可手动重跑： bash $SCRIPT_DIR/configure_mirrors.sh --force"
fi

echo
echo "[OK] Docker 环境安装并校验通过。"
exit 0

#!/usr/bin/env bash
# install_docker.sh - 安装 / 修复 Docker 与 Docker Compose
#
# 流程:
#   1. 预检查（幂等，已就绪则跳过）
#   2. 执行轩辕镜像一键安装脚本（自动应答交互菜单）
#   3. 补装 python3（CentOS 7 等发行版默认缺失，雷池等工具强依赖）
#   4. 补装 Docker Compose v2
#   5. 校验
#   6. 实测优选镜像加速源
#
# 用法: bash install_docker.sh [--force]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIN_DOCKER="20.10.14"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

MIRRORS=(
  "https://get.xuanyuan.cloud/docker.sh"
  "https://get.xuanyuan.me/docker.sh"
)

have() { command -v "$1" >/dev/null 2>&1; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

if have sudo; then SUDO="sudo"; else SUDO=""; fi

echo "========== 1/6 预检查 =========="
bash "$SCRIPT_DIR/check_env.sh" >/tmp/check_env_pre.txt 2>&1
PRE_EXIT=$?
tail -12 /tmp/check_env_pre.txt

if [ "$PRE_EXIT" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
  echo
  echo "[OK] Docker 环境已就绪，跳过安装（如需重装请加 --force）"
  exit 0
fi

# ---------- 补装 python3 ----------
echo
echo "========== 2/6 确保 python3 可用 =========="
# 雷池等工具的官方脚本强依赖 python3；CentOS 7 默认只有 python2.7
if have python3; then
  echo "[OK] python3 已安装：$(python3 --version 2>&1)"
else
  echo "[i] 未检测到 python3，开始安装..."
  if have yum; then
    timeout 300 yum install -y python3 >/tmp/py3.log 2>&1
  elif have apt-get; then
    timeout 300 bash -c 'apt-get update && apt-get install -y python3' >/tmp/py3.log 2>&1
  elif have dnf; then
    timeout 300 dnf install -y python3 >/tmp/py3.log 2>&1
  fi
  if have python3; then
    echo "[OK] python3 安装成功：$(python3 --version 2>&1)"
  else
    echo "[!] python3 安装失败（详见 /tmp/py3.log），继续尝试 Docker 安装"
  fi
fi

# ---------- 后台预取 Compose 二进制 ----------
# Docker 二进制下载动辄十几分钟，Compose 二进制可以并行预取，节省总耗时。
echo "==> 后台预取 Docker Compose 二进制（与 Docker 安装并行）"
mkdir -p /tmp/docker-compose-cache 2>/dev/null
(
  for v in v2.24.6 v2.20.3 v2.17.3; do
    dest="/tmp/docker-compose-cache/docker-compose-$v"
    [ -s "$dest" ] && break
    curl -fsSL --max-time 900 -o "$dest" \
      "https://github.com/docker/compose/releases/download/${v}/docker-compose-linux-x86_64" && break
  done
) >/tmp/compose_prefetch.log 2>&1 &
PREFETCH_PID=$!

# ---------- 轩辕镜像一键安装 ----------
echo
echo "========== 3/6 执行轩辕镜像一键安装脚本 =========="
SUCCESS=0
for url in "${MIRRORS[@]}"; do
  echo "--> 尝试镜像源: $url"
  if curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 "$url" -o /tmp/xy_docker_install.sh \
     && [ -s /tmp/xy_docker_install.sh ]; then
    echo "    下载成功，开始执行（会配置镜像加速并重启 docker 服务）"

    # 轩辕脚本是交互式的（主菜单需要选 1），必须分配 TTY，
    # 否则 read 拿到 EOF 会陷入死循环。
    if have python3; then
      python3 "$SCRIPT_DIR/pty_runner.py" "bash /tmp/xy_docker_install.sh" /tmp/xy_docker_install.log
    else
      # 无 python3 时退化为管道喂入选项 1
      yes 1 | bash /tmp/xy_docker_install.sh
    fi

    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      SUCCESS=1
      break
    fi
    echo "    执行后 docker 仍不可用，换下一个镜像源"
  else
    echo "    下载失败，换下一个镜像源"
  fi
done

if [ "$SUCCESS" -ne 1 ]; then
  echo
  echo "[X] 轩辕脚本未能完成 Docker 安装。"
  echo "    兜底方案（静态二进制）：见 references/离线安装.md"
  exit 1
fi

# ---------- 补装 Compose ----------
echo
echo "========== 4/6 确保 Docker Compose v2 可用 =========="
# 等待后台预取（最多 300 秒），避免重复下载
WAITED=0
while [ "$WAITED" -lt 300 ]; do
  ls /tmp/docker-compose-cache/docker-compose-* >/dev/null 2>&1 && break
  kill -0 "$PREFETCH_PID" 2>/dev/null || break
  sleep 5
  WAITED=$((WAITED + 5))
done
bash "$SCRIPT_DIR/install_compose.sh" || {
  echo "[X] Compose 安装失败。雷池等工具需要 Compose v2，请按 references/离线安装.md 处理。"
  exit 1
}

# ---------- 校验 ----------
echo
echo "========== 5/6 安装后校验 =========="
sleep 3
bash "$SCRIPT_DIR/check_env.sh"
RC=$?
if [ "$RC" -ne 0 ]; then
  echo
  echo "[X] 安装脚本执行完毕，但校验未通过（退出码 $RC）。请检查上面的输出。"
  exit "$RC"
fi

# ---------- 镜像源优选 ----------
echo
echo "========== 6/6 实测优选镜像加速源 =========="
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

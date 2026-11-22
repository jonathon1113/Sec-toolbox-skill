#!/usr/bin/env bash
# install_safeline.sh - 执行雷池官方一键安装脚本
#
# 关键点：官方 manager.py 要求 STDIN 是标准 TTY，否则报错退出。
# 因此这里用 pty_runner.py 分配伪终端并自动应答菜单（选择动作=1、安装目录=默认值）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] 雷池安装需要 root 权限，请用 sudo 运行本脚本。"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "[X] Docker 未就绪。请先执行 linux-docker-env/scripts/install_docker.sh"
  exit 10
fi

# 校验 compose（manager.py 要求 v2）
if ! (docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1); then
  echo "[X] 未检测到 Docker Compose。请先执行 linux-docker-env/scripts/install_docker.sh"
  exit 10
fi

# python3：雷池管理脚本与 pty 应答器都需要
if ! command -v python3 >/dev/null 2>&1; then
  echo "[!] 未检测到 python3，正在尝试安装..."
  if command -v yum >/dev/null 2>&1; then yum install -y python3 >/dev/null 2>&1; fi
  if ! command -v yum >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    apt-get update >/dev/null 2>&1 && apt-get install -y python3 >/dev/null 2>&1
  fi
  command -v python3 >/dev/null 2>&1 || { echo "[X] python3 安装失败"; exit 1; }
fi

INSTALL_CMD='bash -c "$(curl -fsSLk https://waf-ce.chaitin.cn/release/latest/manager.sh)"'
LOG=/tmp/safeline_install.log

echo "==> 通过伪终端执行官方安装：$INSTALL_CMD"
echo "==> 日志：$LOG"
echo "==> 过程可能需要数分钟（拉取镜像约 2~5 GB），请勿中断。"
echo

: > "$LOG"
python3 "$SCRIPT_DIR/pty_runner.py" "$INSTALL_CMD" "$LOG"
RC=$?

echo
echo "==> 安装输出末尾："
grep -a -E "INFO|ERROR|WARN" "$LOG" | tail -15

if [ "$RC" -ne 0 ]; then
  echo
  echo "[X] 安装脚本异常退出（rc=$RC），详见 $LOG"
  exit "$RC"
fi

# 判断是否真的装成功：容器是否存在
if ! docker ps -a --format '{{.Names}}' | grep -q '^safeline'; then
  echo
  echo "[X] 未发现雷池容器，安装未成功。详见 $LOG"
  echo "    排查参考 references/故障排查.md"
  exit 1
fi

echo
echo "[OK] 雷池安装完成。接着运行 init_admin.sh 与 verify.sh。"

# 重启策略规范化：官方 compose 用 restart: always（手动 stop 后开机仍会被拉起），
# 改成 unless-stopped —— 手动 stop 的不再开机自启，崩溃/daemon 重启仍自动恢复。
if [ -f /data/safeline/docker-compose.yaml ]; then
  echo
  echo "==> 规范化重启策略为 unless-stopped"
  bash "$SCRIPT_DIR/set_restart_policy.sh" --compose /data/safeline/docker-compose.yaml || true
fi

# 生成统一启停入口（雷池官方目录固定为 /data/safeline，这里在 /opt/safeline 放一个转发入口）
mkdir -p /opt/safeline
bash "$SCRIPT_DIR/make_ctl.sh" compose "雷池 SafeLine CE" /opt/safeline /data/safeline/docker-compose.yaml


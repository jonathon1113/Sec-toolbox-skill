#!/usr/bin/env bash
# install_cyberstrike.sh - 安装 CyberStrikeAI（AI 原生渗透测试平台）
#
# 官方来源: https://github.com/AIPentest/CyberStrikeAI
#   README "Basic Usage → Quick Start (One-Command Deployment)":
#     git clone ... && cd CyberStrikeAI && chmod +x run.sh && ./run.sh
#
# 说明: **上游没有提供 Dockerfile / docker-compose**，官方部署方式就是源码构建 + run.sh，
#       所以这里走的是官方唯一路径，不是"跳过 Docker 的降级"。
#       run.sh 默认已使用国内镜像（PIP_INDEX_URL=清华源, GOPROXY=goproxy.cn），通常无需代理。
#
# 用法: bash install_cyberstrike.sh [--dir /opt/cyberstrike] [--http] [--proxy host:port] [--foreground]
#   --dir         安装目录，默认 /opt/cyberstrike
#   --http        以明文 HTTP 启动（默认官方是 HTTPS + 自签证书）
#   --proxy       本次运行使用的代理 host:port（仅本次生效，不落盘）
#   --foreground  前台运行（调试用）；默认后台跑并写 /var/log/cyberstrike.log
#   --systemd     注册 systemd 服务（开机自启 + 崩溃自愈），日常用 systemctl 管理
set -uo pipefail

INSTALL_DIR="/opt/cyberstrike"
USE_HTTP=0
PROXY=""
FOREGROUND=0
USE_SYSTEMD=1
REPO="https://github.com/AIPentest/CyberStrikeAI.git"
LOG="/var/log/cyberstrike.log"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --dir=*) INSTALL_DIR="${1#--dir=}"; shift ;;
    --http) USE_HTTP=1; shift ;;
    --proxy) PROXY="${2:-}"; shift 2 ;;
    --proxy=*) PROXY="${1#--proxy=}"; shift ;;
    --foreground) FOREGROUND=1; shift ;;
    --systemd) USE_SYSTEMD=1; shift ;;
    --no-systemd) USE_SYSTEMD=0; shift ;;
    *) echo "[!] 未知参数: $1"; shift ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] CyberStrikeAI 安装需要 root 权限（要装 Go/Python 依赖与系统工具），请用 sudo 运行。"
  exit 1
fi

# 代理仅本次生效，不写入任何文件
if [ -n "$PROXY" ]; then
  export http_proxy="http://${PROXY}" https_proxy="http://${PROXY}"
  export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy"
  echo "[*] 本次使用代理: ${PROXY}"
fi

# ---------- 依赖检查 ----------
need_cmd() { command -v "$1" >/dev/null 2>&1; }

if need_cmd go; then
  GOVER="$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//')"
  echo "Go         : $(go version)"
  if [ -n "$GOVER" ] && [ "$(printf '%s\n1.25\n' "$GOVER" | sort -V | head -1)" != "1.25" ]; then
    echo "[X] Go 版本过低（需要 >= 1.25，当前 $GOVER）。升级: https://go.dev/dl/"
    exit 1
  fi
else
  echo "[X] 未检测到 Go（需要 >= 1.25）。"
  echo "    安装: yum install -y golang   或   apt install -y golang-go   或   https://go.dev/dl/"
  exit 1
fi

if need_cmd python3; then
  echo "Python     : $(python3 -V 2>&1)"
  if ! python3 -c "import venv" >/dev/null 2>&1; then
    echo "[!] python3 缺 venv 模块，run.sh 建虚拟环境会失败。请先装："
    echo "    Debian/Ubuntu: apt install -y python3-venv"
    echo "    RHEL/CentOS  : yum install -y python3 python3-pip"
    exit 1
  fi
else
  echo "[X] 未检测到 python3（需要 >= 3.10）。请先安装 python3。"
  exit 1
fi

if need_cmd node; then
  NODEV="$(node -v 2>/dev/null | sed 's/^v//')"
  echo "Node       : $(node -v)"
  if [ -n "$NODEV" ] && [ "$(printf '%s
22.19
' "$NODEV" | sort -V | head -1)" != "22.19" ]; then
    echo "[X] Node 版本过低（run.sh 的 Pi agent runtime 需要 >= 22.19，当前 $NODEV）。"
    echo "    安装: https://nodejs.org/dist/ 或 NodeSource setup_22.x"
    exit 1
  fi
else
  echo "[X] 未检测到 node（run.sh 需要 Node >= 22.19，用于 Pi agent runtime）。"
  echo "    README 的 Prerequisites 里没写这一条，但缺了 run.sh 会直接失败。"
  echo "    安装: https://nodejs.org/dist/ 或 curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -"
  exit 1
fi

if ! need_cmd gcc && ! need_cmd cc; then
  echo "[X] 未检测到 C 编译器。项目使用 SQLite(go-sqlite3)，需要 CGO_ENABLED=1；"
  echo "    缺 C 编译器时 Go 会自动禁用 CGO，编译出的二进制启动即 fatal。"
  echo "    安装: yum install -y gcc   或   apt install -y build-essential"
  exit 1
fi
echo "C 编译器   : $( (gcc --version 2>/dev/null || cc --version 2>/dev/null) | head -1)"

if ! need_cmd git; then
  echo "[X] 未检测到 git。请先安装（yum install -y git / apt install -y git）。"
  exit 1
fi

# ---------- 代码 ----------
if [ -d "$INSTALL_DIR/.git" ]; then
  echo "[*] 检测到已存在 $INSTALL_DIR，尝试更新"
  git -C "$INSTALL_DIR" pull --ff-only || { echo "[!] git pull 失败"; exit 1; }
else
  echo "==> 克隆代码到 $INSTALL_DIR"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  if ! timeout 600 git clone --depth 1 "$REPO" "$INSTALL_DIR"; then
    echo "[X] clone 失败或超时（仓库较大，直连 GitHub 可能很慢）。"
    echo "    处理：① 用代理重跑: bash install_cyberstrike.sh --proxy <host:port>"
    echo "          ② 或先在本地 clone 再传上目标机"
    rm -rf "$INSTALL_DIR"
    exit 1
  fi
fi

cd "$INSTALL_DIR" || exit 1
chmod +x run.sh 2>/dev/null

# ---------- 启动 ----------
ARGS=""
[ "$USE_HTTP" = "1" ] && ARGS="--http"

echo
echo "==> 启动（run.sh 会建 venv、装 Python 依赖、拉 Go 依赖、go build，然后启动服务）"
echo "    首次构建可能需要 5~15 分钟；run.sh 默认已用清华 pypi 源与 goproxy.cn。"
echo

if [ "$FOREGROUND" = "1" ]; then
  ./run.sh $ARGS
  exit $?
fi

: > "$LOG"
setsid nohup ./run.sh $ARGS >> "$LOG" 2>&1 < /dev/null &
echo "[+] 已后台启动，日志: $LOG"

echo "==> 等待服务就绪（最多 180 秒）..."
for i in $(seq 1 90); do
  if grep -qaE 'ADMIN SETUP REQUIRED|listening|ONLINE|Web UI|http://|https://' "$LOG" 2>/dev/null; then
    if ss -lnt 2>/dev/null | grep -qE ':8080[[:space:]]'; then
      echo "[+] 服务已监听 8080"
      break
    fi
  fi
  sleep 2
done

echo
echo "==> 启动输出（末尾）:"
tail -25 "$LOG" 2>/dev/null
# ---------- systemd 托管 ----------
if [ "$USE_SYSTEMD" = "1" ] && [ "$FOREGROUND" != "1" ]; then
  echo
  echo "==> 注册 systemd 服务（开机自启 + 自动重启）"
  cat > /etc/systemd/system/cyberstrike.service <<UNIT
[Unit]
Description=CyberStrikeAI - AI-native cybersecurity platform
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/cyberstrike-ai -config ${INSTALL_DIR}/config.yaml $( [ "$USE_HTTP" = "1" ] && echo "--http" || echo "--https" )
Restart=always
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=30
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
  # 先停掉用 run.sh 起的实例：它占着 8080，systemd 的实例会因端口冲突退出（auto-restart 循环）
  if pgrep -x cyberstrike-ai >/dev/null 2>&1; then
    echo "[*] 停止已有 cyberstrike-ai 进程（避免与 systemd 实例抢 8080）"
    pkill -x cyberstrike-ai
    for i in $(seq 1 15); do
      pgrep -x cyberstrike-ai >/dev/null 2>&1 || break
      sleep 1
    done
  fi
  systemctl daemon-reload
  systemctl enable cyberstrike >/dev/null 2>&1 && echo "[+] 已 enable，开机自启"
  systemctl restart cyberstrike 2>&1 | tail -1
  sleep 6
  systemctl is-active cyberstrike
  echo "    日常: systemctl status|restart cyberstrike ; journalctl -u cyberstrike -f"
  echo "    注意：systemd 下直接跑二进制，不用 run.sh（run.sh 会每次重新构建）"
fi

echo

# 生成统一启停入口: <安装目录>/ctl.sh
bash "$(dirname "${BASH_SOURCE[0]}")/make_ctl.sh" systemd CyberStrikeAI "$INSTALL_DIR" cyberstrike 2>/dev/null || true
echo "==> 下一步："
echo "    1) 取 admin 密码: bash scripts/init_admin.sh --app cyberstrike"
echo "    2) 自检:          bash scripts/verify.sh --app cyberstrike"
echo "    3) 打开 UI:       $( [ "$USE_HTTP" = "1" ] && echo 'http://<服务器IP>:8080/' || echo 'https://<服务器IP>:8080/' ) （HTTPS 为自签证书，需手动接受一次告警）"
echo "    4) 配置 AI 渠道:  System Settings → Basic Settings → AI Channel Configuration（不配则任务跑不了）"

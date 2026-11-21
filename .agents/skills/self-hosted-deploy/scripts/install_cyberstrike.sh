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
set -uo pipefail

INSTALL_DIR="/opt/cyberstrike"
USE_HTTP=0
PROXY=""
FOREGROUND=0
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
  git clone --depth 1 "$REPO" "$INSTALL_DIR" || { echo "[X] clone 失败（网络不通？）"; exit 1; }
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
echo
echo "==> 下一步："
echo "    1) 取 admin 密码: bash scripts/init_admin.sh --app cyberstrike"
echo "    2) 自检:          bash scripts/verify.sh --app cyberstrike"
echo "    3) 打开 UI:       $( [ "$USE_HTTP" = "1" ] && echo 'http://<服务器IP>:8080/' || echo 'https://<服务器IP>:8080/' ) （HTTPS 为自签证书，需手动接受一次告警）"
echo "    4) 配置 AI 渠道:  System Settings → Basic Settings → AI Channel Configuration（不配则任务跑不了）"

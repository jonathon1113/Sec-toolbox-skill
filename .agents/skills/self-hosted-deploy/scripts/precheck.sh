#!/usr/bin/env bash
# precheck.sh - 自托管服务部署前置检查（只读，绝不改动系统）
# 用法: bash precheck.sh --app <safeline|artex> [--docker]
# 退出码: 0=通过 20=硬件/依赖不满足 21=端口冲突 10=Docker未就绪
set -uo pipefail

APP=""
CHECK_DOCKER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --docker) CHECK_DOCKER=1; shift ;;
    --app=*) APP="${1#--app=}"; shift ;;
    *) shift ;;
  esac
done

[ -z "$APP" ] && { echo "[X] 必须指定 --app <safeline|artex>"; exit 20; }

FAIL=0
WARN=0
have() { command -v "$1" >/dev/null 2>&1; }

# ---- 各应用的专属参数 ----
case "$APP" in
  safeline)
    TITLE="雷池 SafeLine CE"
    PORTS="9443"
    PORT_DESC="雷池控制台默认端口"
    MIN_MEM=2048
    MIN_DISK=5
    ;;
  cyberstrike)
    TITLE="CyberStrikeAI (AI 原生渗透测试平台)"
    PORTS="8080"
    PORT_DESC="CyberStrikeAI Web UI 默认端口"
    MIN_MEM=2048
    MIN_DISK=5
    ;;
  artex)
    TITLE="ARTEX (AI 自主渗透测试系统)"
    PORTS="8787"
    PORT_DESC="ARTEX Web UI 默认端口"
    MIN_MEM=4096      # compose 构建期需要（npm ci + go build）
    MIN_DISK=10
    ;;
  *)
    echo "[X] 未知 --app: $APP（可选 safeline | artex）"; exit 20 ;;
esac

echo "=========================================="
echo " $TITLE 部署前置检查"
echo "=========================================="

# ---------- OS / 架构 ----------
if [ -r /etc/os-release ]; then . /etc/os-release; OS="${PRETTY_NAME:-$ID}"; else OS="unknown"; fi
ARCH="$(uname -m)"
echo "系统        : $OS"
echo "架构        : $ARCH"

case "$ARCH" in
  x86_64|amd64)
    FLAGS=""
    have lscpu && FLAGS="$(lscpu 2>/dev/null)"
    if echo "$FLAGS" | grep -q ssse3; then
      echo "CPU ssse3   : 支持"
    elif [ "$APP" = "safeline" ]; then
      echo "CPU ssse3   : 不支持  <== 雷池 x86_64 必须支持 ssse3"
      FAIL=1
    fi
    if echo "$FLAGS" | grep -q avx2; then echo "CPU avx2    : 支持 (推荐)"; else echo "CPU avx2    : 不支持 (不阻断，但性能下降)"; fi
    ;;
  aarch64|arm64)
    echo "CPU         : arm64 架构 natively supported"
    ;;
  *)
    echo "架构        : $ARCH 不受支持  <== 仅支持 x86_64 / arm64"
    FAIL=1
    ;;
esac

# ---------- 内存 / 磁盘 ----------
MEM_MB=0
have free && MEM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
DISK_GB=0
have df && DISK_GB=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
[ -z "$DISK_GB" ] && DISK_GB=0
SWAP_MB=0
have free && SWAP_MB=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}')
echo "内存        : ${MEM_MB} MB (建议 >= ${MIN_MEM} MB)"
echo "Swap        : ${SWAP_MB} MB"
echo "根分区可用  : ${DISK_GB} GB (需 >= ${MIN_DISK} GB)"
if [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -lt "$MIN_MEM" ]; then
  # swap >= 1024 MB 即可作为兜底（2047/2048 这类边界很常见，别卡在这里）
  if [ "$SWAP_MB" -ge 1024 ]; then
    if [ "$APP" = "artex" ]; then
      echo "  <== 内存不足；有 ${SWAP_MB} MB swap 兜底。"
      echo "      Docker 方案（compose 构建）建议 >= 4GB：请优先加内存或加 swap 后再走 Docker 方案；"
      echo "      实在不够再考虑二进制降级方案（见 references/artex.md）。"
    else
      echo "  <== 内存不足；有 ${SWAP_MB} MB swap 兜底，但运行时可能 OOM，建议加物理内存"
    fi
    WARN=1
  else
    echo "  <== 内存不足且 swap 不足 1GB"
    FAIL=1
  fi
fi
[ "$DISK_GB" -gt 0 ] && [ "$DISK_GB" -lt "$MIN_DISK" ] && { echo "  <== 磁盘不足"; FAIL=1; }

# ---------- 端口 ----------
echo "--- 端口检查 ---"
for PORT in $PORTS; do
  IN_USE=0
  if have ss; then
    ss -lntp 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$" && IN_USE=1
  elif have netstat; then
    netstat -lntp 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]" && IN_USE=1
  fi
  if [ "$IN_USE" = "1" ]; then
    echo "端口 ${PORT}   : 已被占用  <== ${PORT_DESC}冲突"
    FAIL=1
  else
    echo "端口 ${PORT}   : 空闲"
  fi
done

# ---------- 应用专属 ----------
case "$APP" in
  safeline)
    if have docker && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^safeline'; then
      echo "检测到已有雷池容器："
      docker ps -a --filter "name=safeline" --format '  {{.Names}}\t{{.Status}}' 2>/dev/null
      echo "  <== 已安装过，如需重装请先与用户确认"
    fi
    ;;
  cyberstrike)
    if have git; then echo "git         : $(git --version)"; else echo "git         : 缺失  <== 需要 git clone"; FAIL=1; fi
    if have go; then
      GOV="$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//')"
      echo "Go          : $(go version)"
      if [ -n "$GOV" ] && [ "$(printf '%s
1.25
' "$GOV" | sort -V | head -1)" != "1.25" ]; then
        echo "Go 版本     : $GOV <== 需要 >= 1.25"; FAIL=1
      fi
    else
      echo "Go          : 缺失  <== 需要 >= 1.25（https://go.dev/dl/）"; FAIL=1
    fi
    if have python3; then
      echo "Python      : $(python3 -V 2>&1)"
      if ! python3 -c "import venv" >/dev/null 2>&1; then
        echo "venv 模块   : 缺失  <== 需要 python3-venv（apt install -y python3-venv）"; FAIL=1
      else
        echo "venv 模块   : 可用"
      fi
    else
      echo "Python      : 缺失  <== 需要 >= 3.10"; FAIL=1
    fi
    if [ -d /opt/cyberstrike ]; then
      echo "检测到已有 /opt/cyberstrike 目录  <== 可能已安装过，重装前先与用户确认"
    fi
    ;;
  artex)
    if have git; then echo "git         : $(git --version)"; else echo "git         : 缺失  <== 需要 git clone"; FAIL=1; fi
    if have curl; then echo "curl        : 已安装"; else echo "curl        : 缺失  <== 建议安装（下载 release / 排查用）"; WARN=1; fi
    if have unzip; then echo "unzip       : 已安装"; else echo "unzip       : 缺失  <== release 二进制路径需要"; WARN=1; fi
    if [ -d /opt/artex ]; then
      echo "检测到已有 /opt/artex 目录  <== 可能已安装过，重装前先与用户确认"
    fi
    ;;
esac

# ---------- Docker ----------
if [ "$CHECK_DOCKER" = "1" ]; then
  echo "--- Docker 检查 ---"
  if have docker && docker info >/dev/null 2>&1; then
    echo "Docker      : $(docker version --format '{{.Server.Version}}' 2>/dev/null) 可用"
    if docker compose version >/dev/null 2>&1; then
      echo "Compose     : $(docker compose version --short 2>/dev/null) 可用"
    elif have docker-compose; then
      echo "Compose     : $(docker-compose --version 2>/dev/null) 可用"
    else
      echo "Compose     : 缺失  <== 需 >= 2.0.0"
      FAIL=1
    fi
  else
    echo "Docker      : 缺失或不可用  <== 请先执行 linux-docker-env/scripts/install_docker.sh"
    FAIL=1
  fi
fi

echo "=========================================="
if [ "$FAIL" = "0" ]; then
  echo "结论: 前置检查通过"
  [ "$WARN" = "1" ] && echo "注意: 有告警项（如上），请与用户确认后再继续"
  exit 0
else
  echo "结论: 前置检查未通过，请先解决上面的问题"
  [ "$CHECK_DOCKER" = "1" ] && exit 10
  exit 20
fi

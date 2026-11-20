#!/usr/bin/env bash
# precheck.sh - 雷池安装前置检查（只读）
# 用法: bash precheck.sh [--docker]
# 退出码: 0=通过 20=硬件不满足 21=端口冲突 10=Docker未就绪
set -uo pipefail

CHECK_DOCKER=0
[ "${1:-}" = "--docker" ] && CHECK_DOCKER=1

FAIL=0
have() { command -v "$1" >/dev/null 2>&1; }

echo "=========================================="
echo " 雷池 SafeLine 部署前置检查"
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
    else
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
echo "内存        : ${MEM_MB} MB (需 >= 2048 MB)"
echo "根分区可用  : ${DISK_GB} GB (需 >= 5 GB)"
[ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -lt 2048 ] && { echo "  <== 内存不足"; FAIL=1; }
[ "$DISK_GB" -gt 0 ] && [ "$DISK_GB" -lt 5 ] && { echo "  <== 磁盘不足"; FAIL=1; }

# ---------- 端口 ----------
echo "--- 端口检查 ---"
PORT=9443
IN_USE=0
if have ss; then
  ss -lntp 2>/dev/null | awk '{print $4}' | grep -E "[:.]${PORT}\$" && IN_USE=1
elif have netstat; then
  netstat -lntp 2>/dev/null | grep -E "[:.]${PORT}[[:space:]]" && IN_USE=1
fi
if [ "$IN_USE" = "1" ]; then
  echo "端口 ${PORT}   : 已被占用  <== 雷池控制台默认端口冲突"
  FAIL=1
else
  echo "端口 ${PORT}   : 空闲"
fi

# ---------- 已有雷池实例 ----------
if have docker && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^safeline'; then
  echo "检测到已有雷池容器："
  docker ps -a --filter "name=safeline" --format '  {{.Names}}\t{{.Status}}'
  echo "  <== 已安装过，如需重装请先确认"
fi

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
  exit 0
else
  echo "结论: 前置检查未通过，请先解决上面的问题"
  [ "$CHECK_DOCKER" = "1" ] && exit 10
  exit 20
fi

#!/usr/bin/env bash
# precheck.sh - <工具名> 部署前置检查（只读）
# 退出码: 0=通过 20=硬件不满足 21=端口冲突 10=依赖未就绪
set -uo pipefail

FAIL=0
have() { command -v "$1" >/dev/null 2>&1; }

echo "=========================================="
echo " <工具名> 部署前置检查"
echo "=========================================="

OS="unknown"
[ -r /etc/os-release ] && { . /etc/os-release; OS="${PRETTY_NAME:-$ID}"; }
ARCH="$(uname -m)"
echo "系统        : $OS"
echo "架构        : $ARCH"

# TODO: 补充架构白名单、内存/磁盘门槛
# case "$ARCH" in
#   x86_64|amd64|aarch64|arm64) ;;
#   *) echo "架构不受支持"; FAIL=1 ;;
# esac

echo "=========================================="
[ "$FAIL" = "0" ] && { echo "结论: 前置检查通过"; exit 0; }
echo "结论: 前置检查未通过"; exit 20

#!/usr/bin/env bash
# switch_mirror.sh - 镜像加速源一键切换（失效自动换源）
#
# 用法:
#   bash switch_mirror.sh              # 检查当前源，不可用则切到最快的可用源
#   bash switch_mirror.sh --force      # 无条件切到当前最快的源
#   bash switch_mirror.sh --test       # 只测速展示，不做任何修改
#   bash switch_mirror.sh --full       # 使用真实拉取测速（更准）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  --force) exec bash "$SCRIPT_DIR/configure_mirrors.sh" --force "${@:2}" ;;
  --test)  exec bash "$SCRIPT_DIR/configure_mirrors.sh" --dry-run "${@:2}" ;;
  --full)  exec bash "$SCRIPT_DIR/configure_mirrors.sh" --full "${@:2}" ;;
  *)       exec bash "$SCRIPT_DIR/configure_mirrors.sh" "${@:2}" ;;
esac

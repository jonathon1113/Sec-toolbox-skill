#!/usr/bin/env bash
# init_admin.sh - 初始化 / 重置服务凭据
# 用法: bash init_admin.sh --app <safeline|artex>
# 密码 / token 只在终端打印一次，不写入任何文件。
set -uo pipefail

APP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --app=*) APP="${1#--app=}"; shift ;;
    *) shift ;;
  esac
done

if [ -z "$APP" ]; then
  echo "用法: bash init_admin.sh --app <safeline|artex>"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "[X] 未找到 docker"; exit 1
fi

case "$APP" in
  safeline)
    if ! docker ps -a --format '{{.Names}}' | grep -q '^safeline-mgt'; then
      echo "[X] 未找到 safeline-mgt 容器，雷池似乎未安装。"; exit 1
    fi
    echo "==> 重置 admin 密码（密码仅本次输出，请立刻保存）："
    echo "    注意：旧密码会立即失效。"
    echo
    docker exec safeline-mgt resetadmin
    ;;

  artex)
    if ! docker ps -a --format '{{.Names}}' | grep -qE '(^|-)artex$'; then
      echo "[X] 未找到 artex 容器，ARTEX 似乎未安装。"; exit 1
    fi
    echo "==> 取一次性 setup token（仅本次输出，请立刻保存）："
    echo "    用于首次访问 /setup 完成认领；认领后失效。"
    echo
    docker logs artex 2>&1 | grep -i "setup token" | tail -3
    ;;

  *)
    echo "[X] 未知 --app: $APP（可选 safeline | artex）"; exit 1 ;;
esac

#!/usr/bin/env bash
# init_admin.sh - 初始化 / 重置雷池管理员账号
set -uo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "[X] 未找到 docker"; exit 1
fi

if ! docker ps -a --format '{{.Names}}' | grep -q '^safeline-mgt'; then
  echo "[X] 未找到 safeline-mgt 容器，雷池似乎未安装。"; exit 1
fi

echo "==> 重置 admin 密码（密码仅本次输出，请立刻保存）："
echo
docker exec safeline-mgt resetadmin

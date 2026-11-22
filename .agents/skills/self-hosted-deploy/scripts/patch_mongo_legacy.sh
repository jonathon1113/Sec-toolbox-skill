#!/usr/bin/env bash
# patch_mongo_legacy.sh - 把 ScopeSentry 的 compose 适配到无 AVX 的 CPU
#
# 背景: 官方 compose 用 mongo:7.0.28，而 MongoDB 5.0+ 强制要求 CPU 支持 AVX。
#       没有 AVX 的机器（如 QEMU 老 vCPU）上容器会 Illegal instruction（退出码 132）反复崩溃。
# 处理: mongo 降到 4.4（不需要 AVX），并把 healthcheck 换成**带认证**的 mongo shell 探活
#       （4.4 的 healthcheck 用 mongosh，而 4.4 没有 mongosh；不带认证也会失败）。
#
# 用法: bash patch_mongo_legacy.sh <compose文件路径>
set -uo pipefail

F="${1:?用法: patch_mongo_legacy.sh <compose文件>}"
[ -f "$F" ] || { echo "[X] 文件不存在: $F"; exit 1; }

if ! grep -q 'image: mongo:7' "$F"; then
  echo "[*] compose 已是 mongo 4.4（或非 7.x），无需处理"
  exit 0
fi

sed -i 's|image: mongo:7\.[0-9.]*|image: mongo:4.4|' "$F"

python3 - "$F" <<'PYEOF'
import io, sys

p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
lines = s.split("\n")

new_test = (
    '      test: ["CMD-SHELL", "mongo --quiet '
    '-u \\"$$MONGO_INITDB_ROOT_USERNAME\\" '
    '-p \\"$$MONGO_INITDB_ROOT_PASSWORD\\" '
    '--authenticationDatabase admin '
    '--eval \\"db.runCommand({ping:1}).ok\\" | grep -q 1"]'
)

for i, l in enumerate(lines):
    if "test:" in l and "mongo" in l:
        lines[i] = new_test
        print("    healthcheck 已改为带认证的探活")
        break

io.open(p, "w", encoding="utf-8").write("\n".join(lines))
PYEOF

echo "    mongo 已降级到 4.4"

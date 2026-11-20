#!/usr/bin/env bash
# verify.sh - 雷池安装后自检
set -uo pipefail

FAIL=0
have() { command -v "$1" >/dev/null 2>&1; }

echo "=========================================="
echo " 雷池安装自检"
echo "=========================================="

echo "--- 1) 容器状态 ---"
if have docker && docker info >/dev/null 2>&1; then
  docker ps -a --filter "name=safeline" --format '  {{.Names}}\t{{.Status}}\t{{.Ports}}'
  RUNNING=$(docker ps --filter "name=safeline" --format '{{.Names}}' | wc -l | tr -dc '0-9')
  TOTAL=$(docker ps -a --filter "name=safeline" --format '{{.Names}}' | wc -l | tr -dc '0-9')
  echo "  运行中: ${RUNNING} / 共 ${TOTAL}"
  [ "${TOTAL:-0}" -eq 0 ] && { echo "  <== 未发现雷池容器"; FAIL=1; }
  [ "${RUNNING:-0}" -lt "${TOTAL:-0}" ] && { echo "  <== 有容器未运行"; FAIL=1; }
else
  echo "  <== Docker 不可用"; FAIL=1
fi

echo "--- 2) 9443 端口监听 ---"
LISTEN=0
if have ss; then
  ss -lnt 2>/dev/null | grep -E '[:.]9443[[:space:]]' && LISTEN=1
elif have netstat; then
  netstat -lnt 2>/dev/null | grep -E '[:.]9443[[:space:]]' && LISTEN=1
fi
[ "$LISTEN" = "1" ] || { echo "  <== 9443 未监听"; FAIL=1; }

echo "--- 3) 控制台 HTTP 探测 ---"
if have curl; then
  CODE=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1:9443/ 2>/dev/null)
elif have wget; then
  CODE=$(wget -q --no-check-certificate --spider --timeout=10 "https://127.0.0.1:9443/" >/dev/null 2>&1 && echo 200 || echo 000)
else
  CODE="skip"
fi
echo "  HTTP 状态码: $CODE"
case "$CODE" in
  200|302|301|200) : ;;
  skip) echo "  (无 curl/wget，跳过)";;
  *) echo "  <== 控制台响应异常"; FAIL=1;;
esac

echo "--- 4) 安装目录 ---"
if [ -d /data/safeline ]; then
  echo "  /data/safeline 存在（官方默认安装目录）"
  ls /data/safeline 2>/dev/null | head -5 | sed 's/^/    /'
elif [ -d /opt/safeline ]; then
  echo "  /opt/safeline 存在"
else
  echo "  (未发现 /data/safeline 或 /opt/safeline)"
fi

echo "=========================================="
if [ "$FAIL" = "0" ]; then
  echo "自检通过。控制台地址: https://<服务器IP>:9443/"
  exit 0
else
  echo "自检未通过，排查见 references/故障排查.md"
  exit 1
fi

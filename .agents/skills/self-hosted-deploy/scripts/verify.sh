#!/usr/bin/env bash
# verify.sh - 部署自检（只读）
# 用法: bash verify.sh --app <safeline|artex>
# 退出码: 0=自检通过 1=自检失败
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
  echo "用法: bash verify.sh --app <safeline|artex>"
  exit 1
fi

have() { command -v "$1" >/dev/null 2>&1; }
FAIL=0

echo "=========================================="
case "$APP" in
  safeline) echo " 雷池 SafeLine CE 自检" ;;
  artex)    echo " ARTEX 自检" ;;
  *) echo "[X] 未知 --app: $APP"; exit 1 ;;
esac
echo "=========================================="

# ---------- 1) 容器 ----------
echo "--- 1) 容器状态 ---"
if have docker && docker info >/dev/null 2>&1; then
  case "$APP" in
    safeline)
      docker ps -a --filter "name=safeline" --format '{{.Names}}\t{{.Status}}' 2>/dev/null | sed 's/^/  /'
      TOTAL=$(docker ps -a --filter "name=safeline" --format '{{.Names}}' 2>/dev/null | wc -l)
      RUNNING=$(docker ps --filter "name=safeline" --format '{{.Names}}' 2>/dev/null | wc -l)
      if [ "$TOTAL" -lt 7 ] || [ "$RUNNING" -lt 7 ]; then
        echo "  <== 容器未全部就绪（运行 $RUNNING / 共 $TOTAL，期望 7/7）"; FAIL=1
      else
        echo "  运行中: $RUNNING / 共 $TOTAL"
      fi
      ;;
    artex)
      # compose 模式：容器名含 artex；binary 模式：宿主机进程
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '(^|-)artex$'; then
        docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null | grep -E 'artex|postgres' | sed 's/^/  /'
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q postgres; then
          echo "  postgres: 运行中"
        else
          echo "  <== 未找到 postgres 容器（ARTEX 依赖 PostgreSQL）"; FAIL=1
        fi
      elif pgrep -x artex >/dev/null 2>&1; then
        echo "  artex: 进程运行中（binary 模式）"
        pgrep -ax artex 2>/dev/null | head -2 | sed 's/^/    /'
      else
        echo "  <== 未找到运行中的 artex 容器或进程"; FAIL=1
      fi
      ;;
  esac
else
  echo "  <== Docker 不可用"; FAIL=1
fi

# ---------- 2) 端口 ----------
echo "--- 2) 端口监听 ---"
case "$APP" in
  safeline) PORT=9443 ;;
  artex)    PORT=8787 ;;
esac
if have ss; then
  if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$"; then
    echo "  端口 ${PORT}: 监听中"
  else
    echo "  <== 端口 ${PORT} 未监听"; FAIL=1
  fi
else
  echo "  (无 ss 命令，跳过)"
fi

# ---------- 3) HTTP 探测 ----------
echo "--- 3) HTTP 探测 ---"
case "$APP" in
  safeline) URL="https://127.0.0.1:${PORT}/" ;;
  artex)    URL="http://127.0.0.1:${PORT}/" ;;
esac
if have curl; then
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "$URL" 2>/dev/null)"
  echo "  ${URL} -> HTTP ${CODE:-000}"
  case "$CODE" in
    200|302|301|303) ;;
    *) echo "  <== HTTP 探测未返回正常状态码"; FAIL=1 ;;
  esac
else
  echo "  (无 curl 命令，跳过)"
fi

# ---------- 4) 安装目录 / 配置 ----------
echo "--- 4) 安装目录与配置 ---"
case "$APP" in
  safeline)
    if [ -d /data/safeline ]; then
      echo "  /data/safeline 存在（官方默认安装目录）"
      ls /data/safeline 2>/dev/null | sed 's/^/    /' | head -6
    else
      echo "  <== /data/safeline 不存在"; FAIL=1
    fi
    ;;
  artex)
    FOUND_DIR=""
    for d in /opt/artex /opt/artex/*/; do
      if [ -f "$d/config.json" ] || [ -f "$d/start.sh" ]; then FOUND_DIR="${d%/}"; break; fi
    done
    if [ -n "$FOUND_DIR" ]; then
      echo "  安装目录: $FOUND_DIR"
      [ -f "$FOUND_DIR/config.json" ] && echo "    config.json 存在" || echo "    <== config.json 缺失（需填 database 段）"
      [ -f "$FOUND_DIR/artex" ] && echo "    artex 二进制存在"
      [ -d "$FOUND_DIR/skills" ] && echo "    skills/ 存在（持久化）"
      [ -d "$FOUND_DIR/data" ] && echo "    data/ 存在（持久化）"
      if [ -f "$FOUND_DIR/artex.log" ] && grep -qa "setup token" "$FOUND_DIR/artex.log"; then
        echo "  setup token: 已在 artex.log 中（用 scripts/init_admin.sh --app artex 取出）"
      fi
    else
      echo "  未找到 /opt/artex 安装目录（compose 模式可用 --dir 指定其它位置）"
    fi
    ;;
esac

echo "=========================================="
if [ "$FAIL" = "0" ]; then
  echo "自检通过。"
  case "$APP" in
    safeline) echo "控制台地址: https://<服务器IP>:${PORT}/" ;;
    artex)    echo "Web UI: http://<服务器IP>:${PORT}/  （首次访问 /setup 用 setup token 认领）" ;;
  esac
  exit 0
else
  echo "自检失败，请参考 references/故障排查.md。"
  exit 1
fi

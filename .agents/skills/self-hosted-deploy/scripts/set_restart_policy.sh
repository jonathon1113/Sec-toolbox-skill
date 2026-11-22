#!/usr/bin/env bash
# set_restart_policy.sh - 统一 Docker 容器的重启策略为 unless-stopped
#
# 为什么: Docker 的两种策略语义不同——
#   restart: always           → 容器手动 stop 后，daemon 重启/开机仍会被拉起（不符合预期）
#   restart: unless-stopped   → 只有**手动 stop** 的容器不会被拉起；
#                                崩溃退出、daemon 重启、机器重启后仍会自动恢复
# 需求: 手动 stop 之后不要开机自启；除此之外（异常退出、机器重启）都要自动恢复
#       → 正是 unless-stopped 的语义
#
# 用法:
#   bash set_restart_policy.sh --compose <compose文件>      # 改文件里的策略 + 该文件定义的容器
#   bash set_restart_policy.sh --all                        # 所有容器
#   bash set_restart_policy.sh --names <容器名> [容器名...] # 指定容器
#
# 说明: docker update --restart 对**已停止**的容器同样生效（只记录策略），
#       所以手动 stop 过的容器不会被意外拉起。
set -uo pipefail

MODE=""
COMPOSE_FILE=""
NAMES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --compose) MODE="compose"; COMPOSE_FILE="${2:-}"; shift 2 ;;
    --compose=*) MODE="compose"; COMPOSE_FILE="${1#--compose=}"; shift ;;
    --all) MODE="all"; shift ;;
    --names) MODE="names"; shift; while [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; do NAMES+=("$1"); shift; done ;;
    --names=*) MODE="names"; NAMES+=("${1#--names=}"); shift ;;
    *) NAMES+=("$1"); shift ;;
  esac
done

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "[X] Docker 不可用"; exit 1
fi

# ---------- 1) 改 compose 文件里的策略 ----------
if [ "$MODE" = "compose" ]; then
  if [ -z "$COMPOSE_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; then
    echo "[X] compose 文件不存在: ${COMPOSE_FILE:-<空>}"; exit 1
  fi
  if grep -q 'restart:[[:space:]]*always' "$COMPOSE_FILE"; then
    sed -i 's|restart:[[:space:]]*always|restart: unless-stopped|g' "$COMPOSE_FILE"
    echo "[+] 已把 $COMPOSE_FILE 里的 'restart: always' 改为 'unless-stopped'"
  else
    echo "[*] $COMPOSE_FILE 中没有 restart: always，无需改文件"
  fi
  # 该 compose 文件里定义的容器名（用 compose 命令列出，最准）
  DIR="$(cd "$(dirname "$COMPOSE_FILE")" && pwd)"
  F="$(basename "$COMPOSE_FILE")"
  CDIRS=()
  while IFS= read -r n; do
    [ -n "$n" ] && NAMES+=("$n")
  done < <(cd "$DIR" && docker compose -f "$F" ps -a --format '{{.Name}}' 2>/dev/null)
fi

# ---------- 2) 处理容器 ----------
if [ "$MODE" = "all" ]; then
  while IFS= read -r n; do
    [ -n "$n" ] && NAMES+=("$n")
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
fi

if [ "${#NAMES[@]}" -eq 0 ]; then
  echo "[!] 没有指定容器（用 --compose / --all / --names）"; exit 1
fi

CHANGED=0
SKIPPED=0
for n in "${NAMES[@]}"; do
  if ! docker inspect "$n" >/dev/null 2>&1; then
    continue
  fi
  CUR="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$n" 2>/dev/null)"
  if [ "$CUR" = "unless-stopped" ]; then
    SKIPPED=$((SKIPPED+1))
    continue
  fi
  if docker update --restart=unless-stopped "$n" >/dev/null 2>&1; then
    echo "[+] $n: ${CUR:-no} -> unless-stopped"
    CHANGED=$((CHANGED+1))
  else
    echo "[X] $n: 修改失败"
  fi
done

echo
echo "完成：改动 $CHANGED 个容器，已是 unless-stopped 的 $SKIPPED 个"
echo "语义：手动 stop 的容器重启机器后不会再被拉起；崩溃/daemon 重启仍会自动恢复。"

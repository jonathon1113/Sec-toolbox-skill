#!/usr/bin/env bash
# configure_mirrors.sh - 自动测速并配置最优 Docker 镜像加速源
#
# 用法:
#   bash configure_mirrors.sh              # 测速后写入最优源（写入前自动备份）
#   bash configure_mirrors.sh --full       # 使用真实拉取测速（更准，更慢）
#   bash configure_mirrors.sh --top 3      # 写入前 3 个可用源（默认 1，即只写最快的）
#   bash configure_mirrors.sh --dry-run    # 只测速并展示，不修改系统
#   bash configure_mirrors.sh --check      # 只检查当前配置的源是否仍然可用
#   bash configure_mirrors.sh --fallback  # 当前源不可用时才切换（默认行为）
#
# 退出码: 0=成功 1=全部源不可用 2=配置写入失败
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_JSON="/etc/docker/daemon.json"
BACKUP_DIR="/etc/docker/daemon.json.bak"

MODE="fast"
TOP=1
DRY=0
CHECK_ONLY=0
FORCE=0
TMP_JSON="$(mktemp)"

while [ $# -gt 0 ]; do
  case "$1" in
    --full)     MODE="full"; shift ;;
    --top)      TOP="$2"; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    --check)    CHECK_ONLY=1; shift ;;
    --fallback) FORCE=0; shift ;;
    --force)    FORCE=1; shift ;;
    -h|--help)  sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }
have_root() { [ "$(id -u)" -eq 0 ]; }

# ---------- sudo 处理 ----------
if ! have_root; then
  if have sudo; then
    SUDO="sudo"
  else
    echo "[X] 需要 root 权限且系统无 sudo" >&2
    exit 1
  fi
else
  SUDO=""
fi

# ---------- 当前配置的镜像源 ----------
current_mirrors() {
  [ -r "$DAEMON_JSON" ] || return 0
  grep -o 'https\?://[a-zA-Z0-9._/-]*' "$DAEMON_JSON" 2>/dev/null | sort -u
}

# ---------- 只检查模式 ----------
if [ "$CHECK_ONLY" = "1" ]; then
  echo "=== 当前配置的镜像源健康检查 ==="
  CUR=$(current_mirrors)
  if [ -z "$CUR" ]; then
    echo "[X] $DAEMON_JSON 中未配置 registry-mirrors"
    exit 1
  fi
  echo "$CUR" | while read -r u; do
    [ -z "$u" ] && continue
    code=$(curl -s -o /dev/null --max-time 10 -w '%{http_code}' "$u/v2/" 2>/dev/null)
    case "$code" in
      200|401) echo "  [OK]   $u (HTTP $code)" ;;
      *)       echo "  [FAIL] $u (HTTP $code)" ;;
    esac
  done
  exit 0
fi

# ---------- 测速 ----------
echo "=========================================="
echo " Docker 镜像加速源测速"
echo "=========================================="
bash "$SCRIPT_DIR/test_mirrors.sh" --json ${MODE:+$([ "$MODE" = full ] && echo --full)} > "$TMP_JSON" 2>/tmp/mirror_test.err
TEST_RC=$?
if [ "$TEST_RC" -ne 0 ] && [ ! -s "$TMP_JSON" ]; then
  cat /tmp/mirror_test.err 2>/dev/null
  echo "[X] 测速失败或全部源不可用"
  exit 1
fi

# 解析排序后的可用源（用 python3 精确解析，缺失时回退到 awk）
BEST_LIST=""
if have python3; then
  BEST_LIST=$(python3 - "$TMP_JSON" <<'PYEOF' 2>/dev/null
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
for r in data.get("results", []):
    if r.get("reachable"):
        print(r["mirror"])
PYEOF
)
fi
if [ -z "$BEST_LIST" ]; then
  # 回退：awk 解析（注意 reachable 是布尔字面量，不是字符串）
  BEST_LIST=$(grep -o '{[^}]*}' "$TMP_JSON" 2>/dev/null | awk '
    /"reachable":[[:space:]]*true/ {
      if (match($0, /"mirror":[[:space:]]*"[^"]+"/)) {
        s = substr($0, RSTART, RLENGTH)
        gsub(/.*"mirror":[[:space:]]*"/, "", s)
        gsub(/"$/, "", s)
        print s
      }
    }')
fi
COUNT=$(printf '%s\n' "$BEST_LIST" | grep -c . )

echo
echo "可用源（按速度排序）："
printf '%s\n' "$BEST_LIST" | head -10 | nl -w2 -s'. '

if [ "${COUNT:-0}" -eq 0 ]; then
  echo
  echo "[X] 所有候选镜像源均不可用。"
  echo "    排查方向: 出网/DNS/防火墙；或改用内网 registry；或离线 docker load 导入。"
  exit 1
fi

# ---------- 判断是否需要切换 ----------
CURRENT_FIRST=$(current_mirrors | head -1)
NEED_SWITCH=1
if [ "$FORCE" -eq 0 ] && [ -n "$CURRENT_FIRST" ]; then
  # 归一化比较（去掉协议头与尾部斜杠）
  CUR_NORM=$(printf '%s' "$CURRENT_FIRST" | sed -e 's#^https\?://##' -e 's#/$##')
  if printf '%s\n' "$BEST_LIST" | sed -e 's#^https\?://##' -e 's#/$##' | grep -qx "$CUR_NORM"; then
    echo
    echo "当前首选源 $CURRENT_FIRST 仍在可用列表中。"
    RANK=$(printf '%s\n' "$BEST_LIST" | sed -e 's#^https\?://##' -e 's#/$##' | grep -n "^$CUR_NORM$" | cut -d: -f1)
    if [ "${RANK:-99}" -le "${TOP:-1}" ]; then
      echo "[OK] 无需切换（当前源排名第 $RANK）。"
      NEED_SWITCH=0
    else
      echo "[i] 当前源排名第 $RANK，低于期望的 TOP=$TOP，切换到更快的源。"
    fi
  else
    echo
    echo "[!] 当前源 $CURRENT_FIRST 已不可用，将自动切换。"
  fi
fi

if [ "$NEED_SWITCH" -eq 0 ]; then
  exit 0
fi

# ---------- 组装新配置 ----------
SELECTED=$(printf '%s\n' "$BEST_LIST" | head -"$TOP")
# 补全协议头（测速输出可能已含 https://）
JSON_MIRRORS=$(printf '%s\n' "$SELECTED" | sed -e 's#^[^h]*://#https://#' | sed 's#^#    "#; s#$#",#' | sed '$ s#,$##')

if [ "$DRY" = "1" ]; then
  echo
  echo "=== --dry-run：将写入以下内容到 $DAEMON_JSON ==="
  cat <<EOF
{
  "registry-mirrors": [
$JSON_MIRRORS
  ]
}
EOF
  echo "(未实际修改)"
  exit 0
fi

# ---------- 备份并写入 ----------
echo
echo "==> 备份现有配置"
if [ -f "$DAEMON_JSON" ]; then
  STAMP=$(date +%Y%m%d-%H%M%S)
  $SUDO cp -a "$DAEMON_JSON" "${DAEMON_JSON}.${STAMP}.bak"
  echo "    已备份到 ${DAEMON_JSON}.${STAMP}.bak"
else
  echo "    (无现有配置)"
fi

# 保留 daemon.json 里的其它字段（如 data-root、log-driver）
EXISTING_OTHER=""
if [ -f "$DAEMON_JSON" ]; then
  EXISTING_OTHER=$(grep -v 'registry-mirrors' "$DAEMON_JSON" | grep -v '"[[:space:]]*"' || true)
fi

TMP_NEW=$(mktemp)
if [ -n "$EXISTING_OTHER" ] && printf '%s' "$EXISTING_OTHER" | grep -q '{'; then
  # 简单合并：删除旧 registry-mirrors 块后插入新的
  {
    printf '{\n'
    printf '  "registry-mirrors": [\n%s\n  ]' "$JSON_MIRRORS"
    printf ',\n'
    # 去掉多余逗号后拼接其余字段
    printf '%s' "$EXISTING_OTHER" | sed -e 's/^[[:space:]]*//' -e '/^$/d' | grep -v '^\s*"registry-mirrors"'
    printf '\n}\n'
  } > "$TMP_NEW"
else
  cat > "$TMP_NEW" <<EOF
{
  "registry-mirrors": [
$JSON_MIRRORS
  ]
}
EOF
fi

# 校验 JSON 合法性
if have python3; then
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$TMP_NEW" 2>/dev/null; then
    echo "[X] 生成的 JSON 不合法，已放弃修改："
    cat "$TMP_NEW"
    rm -f "$TMP_NEW"
    exit 2
  fi
fi

$SUDO cp "$TMP_NEW" "$DAEMON_JSON"
rm -f "$TMP_NEW"
echo "==> 已写入 $DAEMON_JSON："
$SUDO cat "$DAEMON_JSON"

# ---------- 重启 docker ----------
echo
echo "==> 重启 Docker 服务使配置生效"
$SUDO systemctl daemon-reload 2>/dev/null
if $SUDO systemctl restart docker 2>/dev/null; then
  sleep 3
  echo "    重启完成"
else
  echo "[!] systemctl restart docker 失败（可能是容器环境无 systemd）。请手动重启 Docker。"
fi

# ---------- 验证 ----------
echo
echo "==> 验证拉取"
if have docker && docker info >/dev/null 2>&1; then
  if timeout 90 docker pull hello-world:latest >/dev/null 2>&1; then
    echo "    [OK] hello-world 拉取成功"
  else
    echo "    [!] hello-world 拉取失败，请查看 docker info | grep -A5 'Registry Mirrors'"
  fi
fi

exit 0

#!/usr/bin/env bash
# test_mirrors.sh - Docker 镜像加速源测速与优选
#
# 用法:
#   bash test_mirrors.sh                 # 快速测速(连通性+延迟)，表格输出
#   bash test_mirrors.sh --full          # 真实拉取测速(拉取 alpine manifest)，更准但更慢
#   bash test_mirrors.sh --json          # 输出 JSON，便于上层脚本解析
#   bash test_mirrors.sh --mirror <url>  # 只测指定源
#   bash test_mirrors.sh --timeout 15    # 单源超时秒数(默认 10)
#
# 退出码: 0=至少有一个可用源 1=全部不可用
set -uo pipefail

# ---------- 候选镜像源（按经验优先级排列，实测再定优） ----------
# 说明: 以下为社区维护的公共加速地址，随时可能限流/下线，
#       因此本脚本坚持"先测速后使用"，不盲目信任任何一条。
DEFAULT_MIRRORS=(
  "https://docker.1ms.run"
  "https://hub.rat.dev"
  "https://ccr.ccs.tencentyun.com"
  "https://docker.1panel.live"
  "https://docker.shootchat.top"
  "https://docker.xuanyuan.me"
  "https://xuanyuan.me"
)

# 真实拉取测速用的探测对象（极小镜像）
PROBE_REPO="library/alpine"
PROBE_TAG="latest"

MODE="fast"       # fast | full
OUTPUT="table"    # table | json
ONLY_MIRROR=""
TIMEOUT=8         # 单源超时（默认 8 秒，别设太大）
BUDGET=60         # 全局总预算秒数，超出则跳过剩余源
EXTRA_MIRRORS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --full)    MODE="full"; shift ;;
    --json)    OUTPUT="json"; shift ;;
    --mirror)  ONLY_MIRROR="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --budget)  BUDGET="$2"; shift 2 ;;
    --extra)   EXTRA_MIRRORS+=("$2"); shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

if [ -n "$ONLY_MIRROR" ]; then
  MIRRORS=("$ONLY_MIRROR")
else
  MIRRORS=("${DEFAULT_MIRRORS[@]}" "${EXTRA_MIRRORS[@]+"${EXTRA_MIRRORS[@]}"}")
fi

have() { command -v "$1" >/dev/null 2>&1; }

if ! have curl; then
  echo "[X] 未找到 curl，无法测速" >&2
  exit 1
fi

# ---------- 获取匿名 token（用于真实拉取测速） ----------
# 优先从镜像源自身的 WWW-Authenticate realm 取 token（各加速源都有自己的 token 服务，
# 不依赖 auth.docker.io —— 后者在部分国内网络不可达）。
# 失败时回退到 Docker Hub 官方 token 服务。
get_token_from_realm() {
  local m="$1"
  local hdr realm service scope tok
  hdr=$(curl -sIL -m "$TIMEOUT" "$m/v2/" 2>/dev/null | grep -i '^www-authenticate:' | tail -1)
  [ -z "$hdr" ] && return 1

  realm=$(printf '%s' "$hdr" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')
  service=$(printf '%s' "$hdr" | sed -n 's/.*service="\([^"]*\)".*/\1/p')
  scope=$(printf '%s' "$hdr" | sed -n 's/.*scope="\([^"]*\)".*/\1/p')
  [ -z "$realm" ] && return 1
  [ -z "$scope" ] && scope="repository:${PROBE_REPO}:pull"

  local url="$realm?service=${service:-registry.docker.io}&scope=${scope}"
  tok=$(curl -s --max-time "$TIMEOUT" "$url" 2>/dev/null \
        | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -z "$tok" ] && return 1
  printf '%s' "$tok"
}

get_token_hub() {
  curl -s --max-time "$TIMEOUT" \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${PROBE_REPO}:pull" \
    2>/dev/null | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

TOKEN=""
HUB_TOKEN=""
if [ "$MODE" = "full" ]; then
  HUB_TOKEN="$(get_token_hub)"
  [ -z "$HUB_TOKEN" ] && echo "[i] Docker Hub 官方 token 服务不可达，将改用各加速源自带的 token 服务" >&2
fi

# ---------- 测单个源 ----------
# 输出: name|reachable|code|connect_s|time_total_s|download_Bps|score
test_mirror() {
  local m="$1"
  local mname
  mname="$(printf '%s' "$m" | sed -e 's#^https\?://##' -e 's#/$##')"
  local code="000" tconn="" ttot="" speed=""

  # /v2/ 是 registry v2 端点：返回 200/401 都表示服务在线
  # 用 -L 跟随重定向（部分加速源如 hub.rat.dev 会 302 到真实源）
  local out
  out=$(curl -sL -o /dev/null \
        --max-time "$TIMEOUT" \
        -w '%{http_code} %{time_connect} %{time_total} %{url_effective}' \
        "$m/v2/" 2>/dev/null)
  code=$(printf '%s' "$out" | awk '{print $1}')
  tconn=$(printf '%s' "$out" | awk '{print $2}')
  ttot=$(printf '%s' "$out" | awk '{print $3}')
  EFFECTIVE_URL=$(printf '%s' "$out" | awk '{print $4}')

  local reachable=0
  case "$code" in
    200|401) reachable=1 ;;
  esac

  # 真实拉取：拉取 manifest，测下载速度
  # 关键点：
  #   1) token 与 host 绑定，且 curl 跨主机重定向会丢弃 Authorization 头，
  #      因此直接请求重定向后的最终 URL；
  #   2) 依次尝试：无 token -> 最终URL的 realm token -> 原始URL的 realm token -> Hub 官方 token，
  #      第一个返回 200 的即采用（有些加速源允许匿名拉取）。
  if [ "$MODE" = "full" ] && [ "$reachable" = "1" ]; then
    local target=""
    local eff="${EFFECTIVE_URL:-}"
    # EFFECTIVE_URL 形如 https://host/v2/ ，去掉尾部 /v2/ 得到基地址
    local eff_base="${eff%/}"
    eff_base="${eff_base%/v2}"
    local m_base="${m%/}"
    if [ -n "$eff_base" ] && [ "$eff_base" != "$m_base" ]; then
      # 发生了跨主机跳转：直接请求最终主机（避免 curl 丢弃 Authorization 头）
      target="$eff_base/v2/${PROBE_REPO}/manifests/${PROBE_TAG}"
    else
      target="$m_base/v2/${PROBE_REPO}/manifests/${PROBE_TAG}"
    fi

    local c2="000" t2="" s2=""
    local -a authargs=()
    local -a toks=()
    local t
    t="$(get_token_from_realm "$target")";                   [ -n "$t" ] && toks+=("$t")
    t="$(get_token_from_realm "$m")";                        [ -n "$t" ] && toks+=("$t")
    [ -n "$HUB_TOKEN" ] && toks+=("$HUB_TOKEN")

    local out2
    # 先试匿名
    out2=$(curl -sL -o /dev/null --max-time "$((TIMEOUT * 2))" \
          -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
          -w '%{http_code} %{time_total} %{speed_download}' \
          "$target" 2>/dev/null)
    c2=$(printf '%s' "$out2" | awk '{print $1}')

    # 匿名不行再依次试 token（最多试 2 个，控制总耗时）
    local tried=0
    if [ "$c2" != "200" ]; then
      for t in "${toks[@]+"${toks[@]}"}"; do
        [ "$tried" -ge 2 ] && break
        tried=$((tried+1))
        out2=$(curl -sL -o /dev/null --max-time "$((TIMEOUT * 2))" \
              -H "Authorization: Bearer $t" \
              -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
              -w '%{http_code} %{time_total} %{speed_download}' \
              "$target" 2>/dev/null)
        c2=$(printf '%s' "$out2" | awk '{print $1}')
        if [ "$c2" = "200" ]; then break; fi
      done
    fi

    if [ "$c2" = "200" ]; then
      t2=$(printf '%s' "$out2" | awk '{print $2}')
      s2=$(printf '%s' "$out2" | awk '{print $3}')
      ttot="$t2"
      speed="$s2"
    else
      # manifest 拉取失败 -> 降级为不可用
      reachable=0
    fi
  fi

  # 综合评分：越大越好
  # - 真实拉取模式：以速度(字节/秒)为主
  # - 快速模式：以 1/总耗时 为主，连接时间做小幅加权
  local score="0"
  if [ "$reachable" = "1" ]; then
    if [ "$MODE" = "full" ] && [ -n "$speed" ] && [ "${speed%.*}" -gt 0 ] 2>/dev/null; then
      score="${speed%.*}"
    else
      score=$(awk -v t="${ttot:-99}" -v c="${tconn:-99}" 'BEGIN{ if(t<=0)t=0.001; printf "%d", (1000.0/t) + (100.0/(c>0?c:99)) }')
    fi
  fi

  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$mname" "$reachable" "$code" "${tconn:-0}" "${ttot:-0}" "${speed:-0}" "$score" "$m"
}

# ---------- 执行 ----------
RESULTS=()
i=0
START_TS=$(date +%s)
for m in "${MIRRORS[@]}"; do
  [ -z "$m" ] && continue
  # 全局预算控制：单个源最多消耗 BUDGET/TOTAL 个源的时间
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TS))
  if [ "$ELAPSED" -gt "$BUDGET" ]; then
    echo "[!] 已超出总时间预算 ${BUDGET}s，跳过剩余源测速" >&2
    break
  fi
  line="$(test_mirror "$m")"
  RESULTS+=("$line")
  i=$((i+1))
  if [ "$OUTPUT" = "table" ]; then
    IFS='|' read -r nm reach code tc tt sp sc url <<<"$line"
    if [ "$reach" = "1" ]; then
      printf '  [%-28s] 可用  HTTP %s  握手 %ss  总耗时 %ss' "$nm" "$code" "${tc:0:6}" "${tt:0:6}"
      [ "${sp%.*}" != "0" ] && printf '  下载 %s B/s' "${sp%.*}"
      printf '\n'
    else
      printf '  [%-28s] 不可用 (HTTP %s)\n' "$nm" "$code"
    fi
  fi
done

# 排序（按 score 降序）
SORTED=$(printf '%s\n' "${RESULTS[@]}" | awk -F'|' '{
  key = $7 + 0
  printf "%012d\t%s\n", key, $0
}' | sort -rn | cut -f2-)

AVAILABLE=$(printf '%s\n' "$SORTED" | awk -F'|' '$2==1' | wc -l | tr -dc '0-9')

if [ "$OUTPUT" = "json" ]; then
  printf '{\n  "mode": "%s",\n  "probe": "%s:%s",\n  "available_count": %s,\n  "results": [\n' \
    "$MODE" "$PROBE_REPO" "$PROBE_TAG" "${AVAILABLE:-0}"
  first=1
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    IFS='|' read -r nm reach code tc tt sp sc url <<<"$line"
    [ $first = 0 ] && printf ',\n'
    first=0
    printf '    {"mirror": "%s", "reachable": %s, "http_code": "%s", "connect_s": %s, "total_s": %s, "speed_Bps": %s, "score": %s}' \
      "$url" "$([ "$reach" = 1 ] && echo true || echo false)" "$code" "${tc:-0}" "${tt:-0}" "${sp:-0}" "${sc:-0}"
  done <<<"$SORTED"
  printf '\n  ]\n}\n'
else
  echo
  echo "------------------------------------------"
  echo " 排序结果（最快 → 最慢，可用源 ${AVAILABLE:-0} 个）"
  echo "------------------------------------------"
  rank=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    IFS='|' read -r nm reach code tc tt sp sc url <<<"$line"
    rank=$((rank+1))
    mark="  "
    [ "$reach" = "1" ] && mark="ok"
    printf '  #%-2s %-3s %-30s score=%-12s %s\n' \
      "$rank" "$mark" "$nm" "$sc" "$([ "$reach" = 1 ] && echo '可用' || echo '不可用')"
  done <<<"$SORTED"

  BEST=$(printf '%s\n' "$SORTED" | awk -F'|' '$2==1{print $8; exit}')
  if [ -n "$BEST" ]; then
    echo
    echo "推荐首选: $BEST"
  else
    echo
    echo "[X] 没有可用镜像源。可尝试："
    echo "    - 检查服务器出网 / DNS"
    echo "    - 使用内网 registry 或自建 harbor"
    echo "    - 离线环境走 docker load 导入"
  fi
fi

[ "${AVAILABLE:-0}" -gt 0 ] && exit 0
exit 1

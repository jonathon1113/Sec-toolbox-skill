#!/usr/bin/env bash
# install_arl_plus.sh - 安装 ARL-plus-docker（资产侦察与漏洞扫描平台）
#
# 官方来源: https://github.com/ki9mu/ARL-plus-docker
#   README「安装方式」:
#     docker volume create arl_db     # ← 必须先建外部卷
#     docker-compose up -d
#
# 组成（5 个容器）:
#   arl_web        ki9mu/arl-ki9mu:v3.0.1     Web UI 5003(HTTPS)
#   arl_worker     ki9mu/arl-ki9mu:v3.0.1     Celery 任务 worker
#   arl_scheduler  ki9mu/arl-ki9mu:v3.0.1     调度器
#   arl_mongodb    mongo:4.0.27               数据库
#   arl_rabbitmq   ki9mu/shadow-rabbitmq      消息队列
#
# 用法: bash install_arl_plus.sh [--dir /opt/arl-plus] [--proxy host:port]
set -uo pipefail

INSTALL_DIR="/opt/arl-plus"
PROXY=""
REPO_RAW="https://raw.githubusercontent.com/ki9mu/ARL-plus-docker/main"
# 用 API 取文件更稳（raw 经常被重置）：优先 raw，失败回退 GitHub API
API_RAW="https://api.github.com/repos/ki9mu/ARL-plus-docker/contents"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --dir=*) INSTALL_DIR="${1#--dir=}"; shift ;;
    --proxy) PROXY="${2:-}"; shift 2 ;;
    --proxy=*) PROXY="${1#--proxy=}"; shift ;;
    *) echo "[!] 未知参数: $1"; shift ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] ARL-plus 安装需要 root 权限，请用 sudo 运行本脚本。"
  exit 1
fi

# 代理仅本次生效（不落盘、不写进 skill）
if [ -n "$PROXY" ]; then
  export http_proxy="http://${PROXY}" https_proxy="http://${PROXY}"
  export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy"
  echo "[*] 本次使用代理: ${PROXY}"
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "[X] Docker 未就绪。请先执行 linux-docker-env/scripts/install_docker.sh"
  exit 10
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "[X] 未检测到 Docker Compose v2。"; exit 10
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || exit 1

# ---------- 取官方文件 ----------
fetch_file() {
  local name="$1"
  [ -s "$name" ] && { echo "[*] 复用已有 $name"; return 0; }
  echo "    下载 $name ..."
  if curl -fsSL --max-time 90 -o "$name" "${REPO_RAW}/${name}"; then
    return 0
  fi
  # 回退：GitHub API（base64）
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$name" "${API_RAW}/${name}" <<'PYEOF'
import base64, json, sys, urllib.request
name, url = sys.argv[1], sys.argv[2]
try:
    d = json.load(urllib.request.urlopen(url, timeout=90))
    open(name, "wb").write(base64.b64decode(d["content"]))
except Exception as e:
    sys.exit(1)
PYEOF
    [ -s "$name" ] && return 0
  fi
  echo "[X] $name 下载失败"
  return 1
}

echo "==> 获取官方文件"
for f in docker-compose.yml config-docker.yaml mongo-init.js; do
  fetch_file "$f" || {
    echo "[X] 缺少 $f，无法继续。可手动下载后放到 $INSTALL_DIR 再执行本脚本。"
    exit 1
  }
done

# compose 里 bind-mount 的日志文件必须存在，否则 docker 会创建成目录
: > arl_web.log
: > arl_worker.log
mkdir -p image poc

# ---------- 外部卷（compose 里声明为 external，必须先建） ----------
echo "==> 创建外部数据卷 arl_db"
docker volume create arl_db >/dev/null 2>&1 || true
docker volume inspect arl_db >/dev/null 2>&1 && echo "[+] arl_db 卷就绪"

# ---------- 拉镜像（逐个拉，失败/超时不阻塞） ----------
echo
echo "==> 拉取镜像（逐个拉，失败可单独重试）"
PULL_FAILED=""
for IMG in $(docker compose -f docker-compose.yml config --images 2>/dev/null | sort -u); do
  if docker image inspect "$IMG" >/dev/null 2>&1; then
    echo "    [已有] $IMG"; continue
  fi
  echo "    拉取 $IMG ..."
  if ! timeout "${ARL_PULL_TIMEOUT:-900}" docker pull "$IMG"; then
    echo "[!] $IMG 拉取失败或超时，可单独重试: docker pull $IMG"
    PULL_FAILED="$PULL_FAILED $IMG"
  fi
done

# ---------- 启动 ----------
echo
echo "==> 启动 5 个容器（web / worker / scheduler / mongodb / rabbitmq）"
docker compose -f docker-compose.yml up -d || {
  echo
  echo "[X] 启动失败。排查："
  echo "    1) docker compose -f docker-compose.yml ps"
  echo "    2) docker compose -f docker-compose.yml logs --tail 50 arl_web"
  echo "    3) 若是 arl_db 卷报错 → docker volume create arl_db"
  exit 1
}

# ---------- 重启策略规范化 ----------
# 官方 compose: web/worker/scheduler 用 unless-stopped，但 mongodb/rabbitmq 用 always
# → always 会让「手动 stop 后机器重启又被拉起」，统一规范为 unless-stopped
echo
echo "==> 规范化重启策略为 unless-stopped"
bash "$(dirname "${BASH_SOURCE[0]}")/set_restart_policy.sh" --compose "$INSTALL_DIR/docker-compose.yml" || true

echo
echo "==> 等待 Web 就绪（最多 240 秒）..."
for i in $(seq 1 120); do
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'arl_web'; then
    CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://127.0.0.1:5003/ 2>/dev/null)"
    [ "$CODE" = "200" ] && { echo "[+] Web 已就绪 (HTTP $CODE)"; break; }
  fi
  sleep 2
done

if [ -n "$PULL_FAILED" ]; then
  echo
  echo "[!] 以下镜像未拉取成功（相关服务可能未启动）:$PULL_FAILED"
fi

echo
echo "==> 容器状态："
docker compose -f docker-compose.yml ps 2>/dev/null | sed 's/^/  /'
echo
echo "==> 访问信息："
echo "    Web UI: https://<服务器IP>:5003/   (HTTPS 自签证书，浏览器需手动接受告警)"
echo "    默认账号: admin / arlpass"
echo "    ↑ 这是 ARL 官方默认密码，**登录后请立刻修改**（系统设置 → 用户管理）"
echo
echo "==> 下一步："
echo "    1) 自检: bash scripts/verify.sh --app arl-plus"
echo "    2) GeoIP 数据库默认没有，资产归属地/ASN 相关功能不可用（见 references/arl-plus.md）"

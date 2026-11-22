#!/usr/bin/env bash
# install_scopesentry.sh - 安装 ScopeSentry（子域名/端口/敏感信息/漏洞 扫描平台）
#
# 官方来源: https://github.com/Autumn-27/ScopeSentry
#   README_CN「安装」章节:
#     git clone https://github.com/Autumn-27/ScopeSentry.git
#     cd ScopeSentry
#     # 修改 .env 文件中的 mongodb、redis 账号密码
#     docker-compose -f single-host-deployment.yml up -d
#
# 优化点: 部署只需要 single-host-deployment.yml 与 .env 两个文件，
#         没必要 clone 整个仓库（90MB+），直接下载这两个文件即可。
#
# 组成（4 个容器）:
#   scopesentry-mongodb  mongo:7.0.28
#   scopesentry-redis     redis:7.0.11（带密码）
#   scope-sentry          autumn27/scopesentry:latest      Web UI 8082
#   scopesentry-scan      autumn27/scopesentry-scan:latest  扫描节点（host 网络）
#
# 用法: bash install_scopesentry.sh [--dir /opt/scopesentry] [--proxy host:port]
set -uo pipefail

INSTALL_DIR="/opt/scopesentry"
PROXY=""
REPO_RAW="https://raw.githubusercontent.com/Autumn-27/ScopeSentry/main"
COMPOSE_FILE="single-host-deployment.yml"

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
  echo "[!] ScopeSentry 安装需要 root 权限，请用 sudo 运行本脚本。"
  exit 1
fi

# 代理仅本次生效（不写文件、不写进 skill）
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
  echo "[X] 未检测到 Docker Compose v2。ScopeSentry 的 compose 文件需要 v2。"
  exit 10
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || exit 1

# ---------- 取官方 compose 文件与 .env ----------
fetch() {
  local url="$1" out="$2"
  for i in 1 2 3; do
    if curl -fsSL --max-time 60 -o "$out" "$url"; then return 0; fi
    echo "    重试 $i/3 ..."
    sleep 3
  done
  return 1
}

if [ -f "$COMPOSE_FILE" ]; then
  echo "[*] 复用已有 $COMPOSE_FILE"
else
  echo "==> 下载官方 $COMPOSE_FILE"
  fetch "${REPO_RAW}/${COMPOSE_FILE}" "$COMPOSE_FILE" || {
    echo "[X] 下载失败。可能是到 GitHub 的链路不通："
    echo "    ① 用代理重跑: bash install_scopesentry.sh --proxy <host:port>"
    echo "    ② 或先在本地下载好 $COMPOSE_FILE 与 .env，放到 $INSTALL_DIR 后再执行本脚本"
    exit 1
  }
fi

if [ -f .env ]; then
  echo "[*] 复用已有 .env"
else
  echo "==> 下载官方 .env"
  fetch "${REPO_RAW}/.env" .env || {
    echo "[X] .env 下载失败（同样可手动放置或加 --proxy 重跑）"
    exit 1
  }
fi

# ---------- 密码 ----------
# 官方 .env 里是弱默认密码，必须改成随机强密码
random_pw() { head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24; }

if grep -qE '^MONGO_INITDB_ROOT_PASSWORD=(mongodb_password|password|change-me-please|changeme|)$' .env; then
  MPW="$(random_pw)"
  sed -i "s|^MONGO_INITDB_ROOT_PASSWORD=.*|MONGO_INITDB_ROOT_PASSWORD=${MPW}|" .env
  echo "[+] 已生成随机 MONGO_INITDB_ROOT_PASSWORD（仅写入 .env）"
else
  echo "[*] 复用 .env 中已有的 MONGO_INITDB_ROOT_PASSWORD"
fi
if grep -qE '^REDIS_PASSWORD=(redis_password|password|change-me-please|changeme|)$' .env; then
  RPW="$(random_pw)"
  sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=${RPW}|" .env
  echo "[+] 已生成随机 REDIS_PASSWORD（仅写入 .env）"
else
  echo "[*] 复用 .env 中已有的 REDIS_PASSWORD"
fi

# ---------- 低配 CPU 适配（MongoDB 5+ 需要 AVX） ----------
# 官方 compose 用 mongo:7.0.28，MongoDB 5.0+ 强制要求 CPU 支持 AVX；
# 没有 AVX 的机器（如 QEMU 老 vCPU）会 Illegal instruction（退出码 132）反复崩溃。
# 此时降级到 mongo:4.4（不需要 AVX），并把 healthcheck 换成带认证的 mongo shell 探活。
AVX=1
if command -v lscpu >/dev/null 2>&1; then
  lscpu 2>/dev/null | grep -qw avx || AVX=0
fi
if [ "$AVX" = "0" ] && grep -q 'image: mongo:7' "$COMPOSE_FILE"; then
  echo
  echo "==> 检测到 CPU 不支持 AVX，MongoDB 5+ 会崩溃，改为 mongo:4.4"
  bash "$(dirname "${BASH_SOURCE[0]}")/patch_mongo_legacy.sh" "$COMPOSE_FILE"
  echo "    注意：mongo:4.4 是降级方案，换到支持 AVX 的机器后可改回 7.0.28"
fi

# ---------- 启动 ----------
echo
echo "==> 启动 4 个容器（mongodb / redis / scope-sentry / scopesentry-scan）"
echo "    镜像较大，首次拉取需要几分钟。"
docker compose -f "$COMPOSE_FILE" up -d || {
  echo
  echo "[X] 启动失败。排查："
  echo "    1) docker compose -f $COMPOSE_FILE ps"
  echo "    2) docker compose -f $COMPOSE_FILE logs --tail 50 scope-sentry"
  echo "    3) 若是拉镜像超时 → 配镜像加速源（见 SKILL.md 第 2.5 步）"
  exit 1
}

echo
echo "==> 等待服务就绪（最多 240 秒）..."
for i in $(seq 1 120); do
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^scope-sentry$' \
     && docker ps --format '{{.Status}}' 2>/dev/null | grep -qi 'healthy'; then
    echo "[+] scope-sentry 已 healthy"
    break
  fi
  sleep 2
done

echo
echo "==> 容器状态："
docker compose -f "$COMPOSE_FILE" ps 2>/dev/null | sed 's/^/  /'
echo
echo "==> 初始用户密码（仅本次输出，请立刻保存）："
docker logs scope-sentry 2>&1 | grep -aiE 'password|密码|passwd' | tail -6
echo
echo "==> 下一步："
echo "    1) Web UI: http://<服务器IP>:8082/"
echo "    2) 插件二次验证密码: docker logs scope-sentry | grep -i 验证"
echo "    3) 自检:   bash scripts/verify.sh --app scopesentry"

# 重启策略规范化：官方 compose 用 restart: always（手动 stop 后开机仍会被拉起），
# 改成 unless-stopped —— 手动 stop 的不再开机自启，崩溃/daemon 重启仍自动恢复。
echo
echo "==> 规范化重启策略为 unless-stopped"
bash "$(dirname "${BASH_SOURCE[0]}")/set_restart_policy.sh" --compose "$INSTALL_DIR/$COMPOSE_FILE" || true

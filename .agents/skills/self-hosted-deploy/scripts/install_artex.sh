#!/usr/bin/env bash
# install_artex.sh - 安装 ARTEX（AI 自主渗透测试系统）
#
# 官方来源: https://github.com/BaaRai/ARTEX  README "Installation" 章节
#   Option 2 (manual Docker Compose)：clone → .env → docker compose up -d --build
#   Option 3 (prebuilt binaries)   ：Releases zip → config.json → ./start.sh
#
# 用法: bash install_artex.sh [--method compose|binary] [--dir /opt/artex] [--bind 0.0.0.0] [--force]
#   --method compose  官方推荐的 compose 构建路径（内存 >= 4GB）
#   --method binary   预编译二进制路径（小内存机器首选）
#   --bind            compose 模式下的监听地址，默认 0.0.0.0（远程可访问）
#
# 说明: ARTEX 没有可拉的预构建镜像，compose 模式必然本地构建。
#       密码只写入 .env（该文件不进仓库），交付时再单独告知用户。
set -uo pipefail

METHOD="compose"
INSTALL_DIR="/opt/artex"
BIND_ADDR="0.0.0.0"
FORCE=0
REPO="https://github.com/BaaRai/ARTEX.git"

while [ $# -gt 0 ]; do
  case "$1" in
    --method) METHOD="${2:-}"; shift 2 ;;
    --method=*) METHOD="${1#--method=}"; shift ;;
    --dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --dir=*) INSTALL_DIR="${1#--dir=}"; shift ;;
    --bind) BIND_ADDR="${2:-}"; shift 2 ;;
    --bind=*) BIND_ADDR="${1#--bind=}"; shift ;;
    --force) FORCE=1; shift ;;
    *) echo "[!] 未知参数: $1"; shift ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] ARTEX 安装需要 root 权限，请用 sudo 运行本脚本。"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "[X] Docker 未就绪。请先执行 linux-docker-env/scripts/install_docker.sh"
  exit 10
fi
if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
  echo "[X] 未检测到 Docker Compose v2（ARTEX 的 compose 文件需要 v2）。"
  exit 10
fi

# ── compose 模式 ─────────────────────────────────────────
install_compose() {
  if [ -d "$INSTALL_DIR/.git" ] && [ "$FORCE" = "0" ]; then
    echo "[*] 检测到已存在 $INSTALL_DIR，尝试更新代码"
    git -C "$INSTALL_DIR" pull --ff-only || {
      echo "[!] git pull 失败（本地有改动？）"; exit 1; }
  else
    echo "==> 克隆代码到 $INSTALL_DIR"
    git clone --depth 1 "$REPO" "$INSTALL_DIR" || { echo "[X] clone 失败（网络不通？）"; exit 1; }
  fi

  cd "$INSTALL_DIR" || exit 1

  if [ ! -f .env ]; then
    echo "==> 生成 .env（基于官方 .env.example）"
    cp .env.example .env
  else
    echo "[*] 复用已有 .env"
  fi

  # POSTGRES_PASSWORD 是 compose 里 :? 强制校验项，空则启动失败
  if ! grep -qE '^POSTGRES_PASSWORD=.+' .env; then
    PW="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${PW}|" .env
    echo "[+] 已生成随机 POSTGRES_PASSWORD（仅写入 .env，不打印）"
  fi

  # 监听地址：默认 127.0.0.1 只允许本机访问，远程部署必须放开
  if [ "$BIND_ADDR" != "127.0.0.1" ]; then
    sed -i "s|^ARTEX_BIND_ADDR=.*|ARTEX_BIND_ADDR=${BIND_ADDR}|" .env
    echo "[+] ARTEX_BIND_ADDR=${BIND_ADDR}"
  fi

  echo "==> 构建并启动（首次构建需下载依赖并编译，可能 10~30 分钟）"
  docker compose up -d --build || { echo "[X] 构建或启动失败，详见 docker compose logs"; exit 1; }

  echo
  echo "==> 启动完成。取一次性 setup token："
  docker compose logs artex 2>/dev/null | grep -i "setup token" | tail -3
  echo
  echo "==> 浏览器打开 http://<服务器IP>:$( [ "$BIND_ADDR" = "127.0.0.1" ] && echo 8787 || echo 8787 )/setup 输入上面的 token 完成首次认领"
  echo "==> 注意: 未配置 ANTHROPIC_API_KEY / OPENAI_API_KEY 时，扫描与探索任务无法执行（可在 UI 里补配）"
}

# ── 预编译二进制模式 ─────────────────────────────────────
install_binary() {
  echo "==> 预编译二进制模式"
  if ! command -v unzip >/dev/null 2>&1; then
    echo "[X] 缺少 unzip，请先安装（apt install -y unzip / yum install -y unzip）"; exit 1
  fi
  echo "[!] 需要从 https://github.com/BaaRai/ARTEX/releases 下载对应平台 zip 后放到 $INSTALL_DIR"
  echo "    下载后再次执行: bash install_artex.sh --method binary --dir $INSTALL_DIR"
  echo "    官方提供 SHA256SUMS 校验: sha256sum -c SHA256SUMS"
  echo "    放好后本脚本会继续解压并生成 config.json"
  ZIP="$(ls "$INSTALL_DIR"/*.zip 2>/dev/null | head -1)"
  [ -z "$ZIP" ] && { echo "[X] $INSTALL_DIR 下没有找到 zip，请先下载"; exit 1; }

  cd "$INSTALL_DIR" || exit 1
  unzip -o "$(basename "$ZIP")" >/dev/null || { echo "[X] 解压失败"; exit 1; }
  chmod +x artex start.sh 2>/dev/null
  if [ ! -f config.json ] && [ -f config.example.json ]; then
    cp config.example.json config.json
    echo "[+] 已从 config.example.json 生成 config.json —— 请填入 database 段（host/user/password/dbname）"
    echo "    没有现成 PostgreSQL 时，可先起一个："
    echo "    docker run -d --name artex-pg -p 5432:5432 -e POSTGRES_USER=artex -e POSTGRES_PASSWORD=<pw> -e POSTGRES_DB=artex -v artex-pg:/var/lib/postgresql/data postgres:16-alpine"
  fi
  echo "==> 启动: cd $INSTALL_DIR && nohup ./start.sh >artex.log 2>&1 &"
  echo "    注意 start.sh 是守护脚本，不要直接运行 ./artex"
}

case "$METHOD" in
  compose) install_compose ;;
  binary)  install_binary ;;
  *) echo "[X] 未知 --method: $METHOD（可选 compose | binary）"; exit 1 ;;
esac

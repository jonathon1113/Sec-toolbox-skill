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
#   --proxy           本次运行使用的代理 host:port（仅本次生效，不落盘、不写进 skill；
#                     直连 GitHub 超时/404/连接中断时，先问用户有没有可用代理再带上它重跑）
#   --systemd         安装完成后注册 systemd 服务（开机自启 + 崩溃自动重启），日常用 systemctl 管理
#
# 说明: ARTEX 没有可拉的预构建镜像，compose 模式必然本地构建。
#       密码只写入 .env（该文件不进仓库），交付时再单独告知用户。
set -uo pipefail

METHOD="compose"
INSTALL_DIR="/opt/artex"
BIND_ADDR="0.0.0.0"
PROXY=""
USE_SYSTEMD=0
FORCE=0
REPO="https://github.com/BaaRai/ARTEX.git"

# 代理仅本次生效（不写入任何文件，也不硬编码在 skill 里）
if [ -n "$PROXY" ]; then
  export http_proxy="http://${PROXY}" https_proxy="http://${PROXY}"
  export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy"
  echo "[*] 本次使用代理: ${PROXY}"
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --method) METHOD="${2:-}"; shift 2 ;;
    --method=*) METHOD="${1#--method=}"; shift ;;
    --dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --dir=*) INSTALL_DIR="${1#--dir=}"; shift ;;
    --bind) BIND_ADDR="${2:-}"; shift 2 ;;
    --bind=*) BIND_ADDR="${1#--bind=}"; shift ;;
    --proxy) PROXY="${2:-}"; shift 2 ;;
    --proxy=*) PROXY="${1#--proxy=}"; shift ;;
    --systemd) USE_SYSTEMD=1; shift ;;
    --no-systemd) USE_SYSTEMD=0; shift ;;
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

  # POSTGRES_PASSWORD 是 compose 里 :? 强制校验项，空则启动失败。
  # 官方 .env.example 里是占位符 change-me-please —— 它“非空”，但绝不能直接用，必须当未设置处理。
  if grep -qiE '^POSTGRES_PASSWORD=(change-me-please|changeme|change_me|change-me|password|your[-_]?password|)$' .env; then
    PW="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${PW}|" .env
    echo "[+] 已生成随机 POSTGRES_PASSWORD（仅写入 .env，不打印；需要时请自行 cat .env 查看）"
  else
    echo "[*] 复用 .env 中已有的 POSTGRES_PASSWORD"
  fi

  # 监听地址：默认 127.0.0.1 只允许本机访问，远程部署必须放开
  if [ "$BIND_ADDR" != "127.0.0.1" ]; then
    sed -i "s|^ARTEX_BIND_ADDR=.*|ARTEX_BIND_ADDR=${BIND_ADDR}|" .env
    echo "[+] ARTEX_BIND_ADDR=${BIND_ADDR}"
  fi

  echo "==> 构建并启动（首次构建需下载依赖并编译，可能 10~30 分钟）"
  # 注意：BuildKit **不读**客户端的 http_proxy 环境变量，构建阶段拉不到外网时必须用 --build-arg 显式传代理
  local BUILD_ARGS=()
  if [ -n "$PROXY" ]; then
    BUILD_ARGS=(--build-arg "HTTP_PROXY=http://${PROXY}" --build-arg "HTTPS_PROXY=http://${PROXY}"
                --build-arg "http_proxy=http://${PROXY}" --build-arg "https_proxy=http://${PROXY}")
    echo "    构建阶段使用代理: ${PROXY}"
  fi
  if ! docker compose build "${BUILD_ARGS[@]}"; then
    echo
    echo "[X] 镜像构建失败。处置顺序（先解决问题，再考虑降级）："
    echo "    1) 看具体报错: cd $INSTALL_DIR && docker compose build 2>&1 | tail -30"
    echo "    2) 若是 go mod download 超时 → 构建阶段没走代理，用 --proxy <host:port> 重跑"
    echo "       （BuildKit 不读宿主机的 http_proxy 环境变量，必须由脚本用 --build-arg 传入）"
    echo "    3) 若是 OOM/被 kill → 加内存（>=4GB）或加 swap: fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
    echo "    4) 若是拉基础镜像失败 → 配镜像加速源（见 SKILL.md 第 2.5 步）"
    echo "    5) 以上都解决不了再降级: bash install_artex.sh --method binary --dir $INSTALL_DIR ${PROXY:+--proxy $PROXY}"
    echo "       （降级后 ARTEX 变成宿主机进程，docker ps 里不再有 artex 容器，交付时必须说明）"
    exit 1
  fi
  if ! docker compose up -d; then
    echo
    echo "[X] 容器启动失败。排查: cd $INSTALL_DIR && docker compose logs --tail 50 artex"
    exit 1
  fi

  echo
  
  # 重启策略规范化（官方 compose 已是 unless-stopped，这里统一保证）
  bash "$(dirname "${BASH_SOURCE[0]}")/set_restart_policy.sh" --compose "$INSTALL_DIR/docker-compose.yml" 2>/dev/null || true

  # 生成统一启停入口: <安装目录>/ctl.sh
  bash "$(dirname "${BASH_SOURCE[0]}")/make_ctl.sh" compose ARTEX "$INSTALL_DIR" docker-compose.yml 2>/dev/null || true
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

  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR" || exit 1

  ZIP=""
  if ls ./*.zip >/dev/null 2>&1; then
    ZIP="$(ls ./*.zip | head -1)"
    echo "[*] 使用已有压缩包: $ZIP"
  else
    echo "==> 从 GitHub Releases 获取最新版本"
    local arch
    case "$(uname -m)" in
      x86_64) arch="amd64" ;;
      aarch64|arm64) arch="arm64" ;;
      *) echo "[X] 不支持的架构: $(uname -m)"; exit 1 ;;
    esac
    if ! command -v python3 >/dev/null 2>&1; then
      echo "[X] 需要 python3 来查询 GitHub Releases"; exit 1
    fi
    # 用 API 的 assets 列表取**真实**资产名与下载 URL（命名规则会变，猜名字会 404）
    local ASSET_URL ASSET_NAME
    ASSET_URL=$(python3 - "$arch" <<'PYEOF' 2>/dev/null
import json, sys, urllib.request
arch = sys.argv[1]
try:
    d = json.load(urllib.request.urlopen(
        'https://api.github.com/repos/BaaRai/ARTEX/releases/latest', timeout=30))
except Exception:
    sys.exit(0)
for a in d.get('assets', []):
    n = a.get('name', '')
    if n.endswith('-linux-%s.zip' % arch):
        print(a.get('browser_download_url', ''))
        break
PYEOF
)
    if [ -z "$ASSET_URL" ]; then
      echo "[X] 未能从 GitHub API 解析出 linux-${arch} 的资产（可能触发了 API 限流）。"
      echo "    处理：稍后重试；或手动到 https://github.com/BaaRai/ARTEX/releases 下载"
      echo "    对应平台的 zip，放到 $INSTALL_DIR 后再执行本脚本（脚本会直接用已有 zip）。"
      exit 1
    fi
    ASSET_NAME="$(basename "$ASSET_URL")"
    TAG="$(python3 -c "
import json,urllib.request
try:
    d=json.load(urllib.request.urlopen('https://api.github.com/repos/BaaRai/ARTEX/releases/latest',timeout=20))
    print(d.get('tag_name',''))
except Exception:
    print('')
" 2>/dev/null)"
    echo "[+] 最新版本: ${TAG:-未知}   资产: $ASSET_NAME"
    echo "==> 下载 $ASSET_URL"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --retry 3 --retry-delay 2 -C - -o "$ASSET_NAME" "$ASSET_URL" || {
        echo "[X] 下载失败。若为超时/连接中断，说明到 GitHub 的网络不通："
        echo "    先重试；仍失败则**向用户询问是否有可用代理**，再用 --proxy <host:port> 重跑本脚本。"
        exit 1; }
    else
      echo "[X] 需要 curl 才能下载"; exit 1
    fi
    ZIP="$ASSET_NAME"
    # 官方提供 SHA256SUMS，一并下载校验
    SUM_URL="https://github.com/BaaRai/ARTEX/releases/download/${TAG}/SHA256SUMS"
    if [ -n "$TAG" ] && curl -fsSL --max-time 60 -o SHA256SUMS "$SUM_URL" 2>/dev/null; then
      # 注意：CentOS 7 的 coreutils 不支持 sha256sum --ignore-missing，用 grep 过滤目标行代替
      if grep -F " $ASSET_NAME" SHA256SUMS > .sha_line 2>/dev/null && [ -s .sha_line ]; then
        if sha256sum -c .sha_line >/dev/null 2>&1; then
          echo "[+] SHA256 校验通过"
        else
          echo "[X] SHA256 校验不通过！文件可能已损坏或被篡改，停止安装。"
          rm -f .sha_line
          exit 1
        fi
        rm -f .sha_line
      else
        echo "[!] SHA256SUMS 里没有 $ASSET_NAME 的条目，未校验（请人工确认来源）"
      fi
    else
      echo "[!] 未取到 SHA256SUMS，未做完整性校验（请人工确认来源）"
    fi
  fi

  echo "==> 解压"
  unzip -o "$ZIP" >/dev/null || { echo "[X] 解压失败"; exit 1; }
  # 官方 zip 解压后是一个同名子目录（如 artex-0.7.0-linux-amd64/），需进入它
  SUBDIR=""
  for d in */; do
    if [ -f "$d/start.sh" ] || [ -f "$d/artex" ]; then SUBDIR="${d%/}"; break; fi
  done
  if [ -n "$SUBDIR" ]; then
    APP_DIR="$INSTALL_DIR/$SUBDIR"
    echo "[+] 程序位于 $APP_DIR"
  else
    APP_DIR="$INSTALL_DIR"
  fi
  cd "$APP_DIR" || exit 1
  chmod +x artex start.sh 2>/dev/null
  if [ ! -f config.json ] && [ -f config.example.json ]; then
    cp config.example.json config.json
    echo "[+] 已生成 config.json —— 请填入 database 段（host/user/password/dbname）"
    echo "    没有现成 PostgreSQL 时，可先起一个："
    echo "    docker run -d --name artex-pg -p 5432:5432 -e POSTGRES_USER=artex -e POSTGRES_PASSWORD=<pw> -e POSTGRES_DB=artex -v artex-pg:/var/lib/postgresql/data postgres:16-alpine"
  fi
  if [ "$USE_SYSTEMD" = "1" ]; then
    echo "==> 注册 systemd 服务（开机自启 + 自动重启）"
    local unit=/etc/systemd/system/artex.service
    cat > "$unit" <<UNIT
[Unit]
Description=ARTEX - AI autonomous penetration testing console
Documentation=https://github.com/BaaRai/ARTEX
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/artex -addr 0.0.0.0:8787
Environment=ARTEX_CONFIG=${APP_DIR}/config.json
Restart=always
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=30
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable artex >/dev/null 2>&1 && echo "[+] 已 enable，开机自启"
    systemctl restart artex 2>&1|tail -1
    sleep 8
    systemctl is-active artex
    echo "    日常: systemctl start|stop|restart artex ; journalctl -u artex -f"
  else
    echo "==> 启动（binary 模式的监听地址用 -addr 参数，不是 ARTEX_BIND_ADDR）:"
    echo "    对外可访问: cd $APP_DIR && setsid nohup ./start.sh -addr 0.0.0.0:8787 > artex.log 2>&1 < /dev/null &"
    echo "    仅本机:     cd $APP_DIR && setsid nohup ./start.sh > artex.log 2>&1 < /dev/null &"
    echo "    注意 start.sh 是守护脚本，不要直接运行 ./artex"
    echo "    想开机自启请加 --systemd 参数"
  fi
  echo "APP_DIR=$APP_DIR"
}

case "$METHOD" in
  compose) install_compose ;;
  binary)  install_binary ;;
  *) echo "[X] 未知 --method: $METHOD（可选 compose | binary）"; exit 1 ;;
esac

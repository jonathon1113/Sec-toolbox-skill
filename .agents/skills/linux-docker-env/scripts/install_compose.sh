#!/usr/bin/env bash
# install_compose.sh - 安装 Docker Compose v2（>= 2.0.0）
#
# 依次尝试：
#   1) 已有可用版本 → 直接返回
#   2) 包管理器 (yum/apt) 安装 docker-compose-plugin
#   3) 从国内 RPM 镜像下载 docker-compose-plugin-*.rpm
#   4) 从 GitHub 下载静态二进制（并做段错误检测，失败自动降级版本）
#
# 重要坑：compose v2.29+ 在部分老 CPU（如 QEMU 2.5+ 虚拟 CPU）上会 Segmentation fault，
#        因此每个二进制下载后都会实际执行一次 `version` 验证，段错误则换下一个版本。
#
# 用法: bash install_compose.sh
# 退出码: 0=成功 1=全部方式失败
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIN_MAJOR=2

BIN_DIR=/usr/local/bin
PLUGIN_DIR=/usr/local/lib/docker/cli-plugins

# 静态二进制候选版本，按兼容性从高到低尝试
BIN_VERSIONS="v2.24.6 v2.20.3 v2.17.3 v2.29.7"

have() { command -v "$1" >/dev/null 2>&1; }
have_root() { [ "$(id -u)" -eq 0 ]; }

if have_root; then SUDO=""; else
  if have sudo; then SUDO="sudo"; else echo "[X] 需要 root 权限"; exit 1; fi
fi

# ---------- 检查现有版本 ----------
compose_major() {
  local v=""
  if docker compose version --short >/dev/null 2>&1; then
    v=$(docker compose version --short 2>/dev/null | grep -o -E '^[0-9]+')
  elif have docker-compose && docker-compose version --short >/dev/null 2>&1; then
    v=$(docker-compose version --short 2>/dev/null | grep -o -E '^[0-9]+')
  fi
  echo "$v"
}

cur=$(compose_major)
if [ -n "$cur" ] && [ "$cur" -ge "$MIN_MAJOR" ]; then
  echo "[OK] Docker Compose v$cur 已安装，无需操作。"
  exit 0
fi
echo "[i] 未检测到 Compose v$MIN_MAJOR+，开始安装。"

install_plugin() {
  # $1 = 二进制文件路径
  $SUDO mkdir -p "$PLUGIN_DIR"
  $SUDO cp "$1" "$PLUGIN_DIR/docker-compose"
  $SUDO chmod +x "$PLUGIN_DIR/docker-compose"
  $SUDO cp "$1" "$BIN_DIR/docker-compose"
  $SUDO chmod +x "$BIN_DIR/docker-compose"
}

# 缓存目录：后台预取时先下到这里，避免重复下载
CACHE_DIR=/tmp/docker-compose-cache
mkdir -p "$CACHE_DIR" 2>/dev/null

verify_compose() {
  # 实际执行一次，排除段错误 / 动态库缺失
  local out rc
  out=$("$1" version 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "    版本命令执行失败(rc=$rc): ${out:0:80}"
    return 1
  fi
  echo "$out" | head -1
  return 0
}

# ---------- 方式 1.5：检查预取缓存 ----------
for f in "$CACHE_DIR"/docker-compose-*; do
  [ -f "$f" ] || continue
  chmod +x "$f" 2>/dev/null
  if out=$(verify_compose "$f"); then
    install_plugin "$f"
    echo "[OK] 使用预取缓存安装成功：$out"
    exit 0
  fi
done

# ---------- 方式 2：包管理器 ----------
echo "==> [1/3] 尝试包管理器安装 docker-compose-plugin"
if have yum; then
  timeout 240 yum install -y docker-compose-plugin >/tmp/compose_yum.log 2>&1
elif have apt-get; then
  timeout 240 bash -c 'apt-get update && apt-get install -y docker-compose-plugin' >/tmp/compose_yum.log 2>&1
fi
cur=$(compose_major)
if [ -n "$cur" ] && [ "$cur" -ge "$MIN_MAJOR" ]; then
  echo "[OK] 包管理器安装成功：Compose v$cur"
  exit 0
fi
echo "    包管理器方式未成功（详见 /tmp/compose_yum.log）"

# ---------- 方式 3：国内 RPM 镜像 ----------
echo "==> [2/3] 尝试国内 RPM 镜像"
RPM_URLS=(
  "https://mirrors.tencent.com/docker-ce/linux/centos/7/x86_64/stable/Packages"
  "https://mirrors.aliyun.com/docker-ce/linux/centos/7/x86_64/stable/Packages"
)
for base in "${RPM_URLS[@]}"; do
  pkg=$(curl -fsSL --max-time 25 "$base/" 2>/dev/null \
        | grep -o -E 'docker-compose-plugin-[0-9a-zA-Z._-]+\.rpm' | sort -uV | tail -1)
  [ -z "$pkg" ] && continue
  echo "    找到 $pkg"
  if curl -fsSL --max-time 90 -o /tmp/dcp.rpm "$base/$pkg" && [ -s /tmp/dcp.rpm ] \
     && rpm -qip /tmp/dcp.rpm >/dev/null 2>&1; then
    $SUDO rpm -ivh --nodeps /tmp/dcp.rpm >/tmp/compose_rpm.log 2>&1
    cur=$(compose_major)
    if [ -n "$cur" ] && [ "$cur" -ge "$MIN_MAJOR" ]; then
      echo "[OK] RPM 安装成功：Compose v$cur"
      exit 0
    fi
  fi
  echo "    RPM 方式未成功"
done

# ---------- 方式 4：静态二进制（含段错误降级） ----------
echo "==> [3/3] 尝试 GitHub 静态二进制"
for v in $BIN_VERSIONS; do
  url="https://github.com/docker/compose/releases/download/${v}/docker-compose-linux-x86_64"
  dest="$CACHE_DIR/docker-compose-$v"
  [ -s "$dest" ] || {
    echo "    下载 $v ..."
    curl -fsSL --max-time 600 -o "$dest" "$url" || { echo "    $v 下载失败"; continue; }
  }
  chmod +x "$dest"
  echo -n "    验证 $v : "
  if out=$(verify_compose "$dest"); then
    install_plugin "$dest"
    echo "[OK] 静态二进制安装成功：$out"
    exit 0
  else
    echo "    $v 不可用（可能段错误），尝试更低版本"
  fi
done

echo
echo "[X] 所有方式均失败。请手工安装 Compose v2。"
exit 1

#!/usr/bin/env bash
# check_env.sh - 只读检查 Linux 主机上的 Docker / Docker Compose 环境
# 用法: bash check_env.sh [--registry]
# 退出码: 0=就绪 10=Docker缺失 11=版本过低 12=缺Compose
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIN_DOCKER="20.10.14"
MIN_COMPOSE="2.0.0"
CHECK_REGISTRY=0
[ "${1:-}" = "--registry" ] && CHECK_REGISTRY=1

# ---------- 通用工具 ----------
have() { command -v "$1" >/dev/null 2>&1; }

ver_ge() {  # ver_ge 20.10.14 20.10.9 -> 0 (true)
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# ---------- 系统信息 ----------
echo "=========================================="
echo " 主机环境检查"
echo "=========================================="
OS="unknown"
if [ -r /etc/os-release ]; then
  . /etc/os-release
  OS="${ID:-unknown} ${VERSION_ID:-} ${PRETTY_NAME:-}"
fi
ARCH="$(uname -m 2>/dev/null || echo unknown)"
KERNEL="$(uname -r 2>/dev/null || echo unknown)"

echo "发行版      : $OS"
echo "架构        : $ARCH"
echo "内核        : $KERNEL"

# ---------- CPU 指令集 ----------
CPU_FLAGS=""
if have lscpu; then
  CPU_FLAGS="$(lscpu 2>/dev/null | grep -o -E 'ssse3|avx2' | sort -u | tr '\n' ' ')"
fi
HAS_SSSE3=0; HAS_AVX2=0
case " $CPU_FLAGS " in *" ssse3 "*) HAS_SSSE3=1;; esac
case " $CPU_FLAGS " in *" avx2 "*) HAS_AVX2=1;; esac
echo "CPU 指令集  : ssse3=$HAS_SSSE3 avx2=$HAS_AVX2 ${CPU_FLAGS}"

# ---------- 内存 / 磁盘 ----------
MEM_MB=0
if have free; then
  MEM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
fi
DISK_FREE_GB=""
if have df; then
  DISK_FREE_GB=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
  [ -z "$DISK_FREE_GB" ] && DISK_FREE_GB=$(df -h / 2>/dev/null | awk 'NR==2{print $4}')
fi
echo "内存        : ${MEM_MB} MB"
echo "根分区可用  : ${DISK_FREE_GB}"

# ---------- Docker ----------
DOCKER_PRESENT=0; DOCKER_OK=0; DOCKER_VER=""
if have docker; then
  DOCKER_PRESENT=1
  if docker info >/dev/null 2>&1; then
    DOCKER_OK=1
    DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
    [ -z "$DOCKER_VER" ] && DOCKER_VER=$(docker --version 2>/dev/null | grep -o -E '[0-9]+\.[0-9]+\.[0-9]+')
  fi
fi

COMPOSE_PRESENT=0; COMPOSE_OK=0; COMPOSE_VER=""
if have docker && docker compose version >/dev/null 2>&1; then
  COMPOSE_PRESENT=1; COMPOSE_OK=1
  COMPOSE_VER=$(docker compose version --short 2>/dev/null)
fi
if [ "$COMPOSE_PRESENT" -eq 0 ] && have docker-compose; then
  COMPOSE_PRESENT=1
  COMPOSE_VER=$(docker-compose --version 2>/dev/null | grep -o -E '[0-9]+\.[0-9]+\.[0-9]+')
  [ -n "$COMPOSE_VER" ] && COMPOSE_OK=1
fi

echo "Docker      : $([ "$DOCKER_OK" = 1 ] && echo "已安装 v$DOCKER_VER (可运行)" || echo "未安装或不可用")"
echo "Compose     : $([ "$COMPOSE_OK" = 1 ] && echo "已安装 v$COMPOSE_VER" || echo "未安装")"

# ---------- 镜像加速 ----------
if [ "$CHECK_REGISTRY" = "1" ]; then
  echo "------------------------------------------"
  echo " 镜像加速配置 (/etc/docker/daemon.json)"
  echo "------------------------------------------"
  if [ -r /etc/docker/daemon.json ]; then
    grep -i "registry-mirrors" /etc/docker/daemon.json || echo "(未配置 registry-mirrors)"
  else
    echo "(daemon.json 不存在或不可读)"
  fi
  if [ "$DOCKER_OK" = 1 ]; then
    echo "--- 拉取测试 (hello-world) ---"
    timeout 90 docker pull hello-world >/dev/null 2>&1 && echo "拉取测试: 成功" || echo "拉取测试: 失败（可能需要配置镜像加速）"
    echo "--- 镜像源健康检查 ---"
    bash "$SCRIPT_DIR/test_mirrors.sh" 2>/dev/null || echo "(镜像源测速不可用)"
  fi
fi

# ---------- 结论 ----------
echo "=========================================="
EXIT=0
if [ "$DOCKER_OK" -eq 0 ]; then
  echo "结论: Docker 未就绪 -> 请执行 install_docker.sh"
  EXIT=10
else
  if ! ver_ge "$DOCKER_VER" "$MIN_DOCKER"; then
    echo "结论: Docker 版本过低 (需 >= $MIN_DOCKER) -> 请执行 install_docker.sh 升级"
    EXIT=11
  elif [ "$COMPOSE_OK" -eq 0 ] || ! ver_ge "$COMPOSE_VER" "$MIN_COMPOSE"; then
    echo "结论: 缺少 Docker Compose (需 >= $MIN_COMPOSE) -> 请执行 install_docker.sh 补装"
    EXIT=12
  else
    echo "结论: Docker 环境就绪"
    EXIT=0
  fi
fi

# ---------- 机器可读输出 ----------
echo "----- MACHINE READABLE -----"
echo "OS=$OS"
echo "ARCH=$ARCH"
echo "HAS_SSSE3=$HAS_SSSE3"
echo "HAS_AVX2=$HAS_AVX2"
echo "MEM_MB=$MEM_MB"
echo "DISK_FREE_GB=$DISK_FREE_GB"
echo "DOCKER_PRESENT=$DOCKER_PRESENT"
echo "DOCKER_OK=$DOCKER_OK"
echo "DOCKER_VER=$DOCKER_VER"
echo "COMPOSE_OK=$COMPOSE_OK"
echo "COMPOSE_VER=$COMPOSE_VER"
echo "READY=$([ "$EXIT" = 0 ] && echo 1 || echo 0)"
echo "EXIT_CODE=$EXIT"

exit $EXIT

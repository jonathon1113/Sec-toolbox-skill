#!/usr/bin/env bash
# init_admin.sh - 初始化 / 重置服务凭据
# 用法: bash init_admin.sh --app <safeline|artex>
# 密码 / token 只在终端打印一次，不写入任何文件。
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
  echo "用法: bash init_admin.sh --app <safeline|artex|cyberstrike>"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "[X] 未找到 docker"; exit 1
fi

case "$APP" in
  safeline)
    if ! docker ps -a --format '{{.Names}}' | grep -q '^safeline-mgt'; then
      echo "[X] 未找到 safeline-mgt 容器，雷池似乎未安装。"; exit 1
    fi
    echo "==> 重置 admin 密码（密码仅本次输出，请立刻保存）："
    echo "    注意：旧密码会立即失效。"
    echo
    docker exec safeline-mgt resetadmin
    ;;

  artex)
    # 两种运行形态：
    #   compose 模式 → token 在容器日志里
    #   binary  模式 → token 在进程 stderr / artex.log 里
    # compose 的容器名是 <项目>-<服务>-<序号>（如 artex-artex-1），不能写死服务名
    ARTEX_C="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i artex | grep -v postgres | head -1)"
    if [ -n "$ARTEX_C" ]; then
      echo "==> 取一次性 setup token（compose 模式，仅本次输出，请立刻保存）："
      echo "    用于首次访问 /setup 完成认领；认领后失效。"
      echo "    注意：容器每次启动/重建都会生成新 token，这里取的是**最新一条**。"
      echo
      # 日志里每次启动都有一条 token，必须取最后一条（tail -1），取旧的会报 Invalid setup token
      docker logs "$ARTEX_C" 2>&1 | grep -oE "Setup token for the /setup page: [0-9a-f]+" | tail -1 | awk '{print $NF}'
    else
      APP_DIR="${ARTEX_DIR:-/opt/artex}"
      FOUND=0
      for d in "$APP_DIR" "$APP_DIR"/*/; do
        [ -f "$d/artex.log" ] || continue
        TOK="$(grep -aioE "setup token for the /setup page: [0-9a-f]+" "$d/artex.log" 2>/dev/null | tail -1 | grep -oE "[0-9a-f]{16,}$")"
        if [ -n "$TOK" ]; then
          echo "==> 取一次性 setup token（binary 模式，仅本次输出，请立刻保存）："
          echo "    用于首次访问 /setup 完成认领；认领后失效。"
          echo
          echo "$TOK"
          FOUND=1
          break
        fi
      done
      if [ "$FOUND" = "0" ]; then
        echo "[!] 未在 artex.log 里找到 setup token。"
        echo "    排查：ps aux | grep artex；日志一般在 <安装目录>/artex.log"
        echo "    若容器重启过，token 会重新生成，请重新查看日志。"
        exit 1
      fi
    fi
    ;;

  cyberstrike)
    DIR="${CYBERSTRIKE_DIR:-/opt/cyberstrike}"
    LOGF=""
    for f in /var/log/cyberstrike.log "$DIR/run.log" "$DIR/cyberstrike.log"; do
      [ -f "$f" ] && { LOGF="$f"; break; }
    done
    echo "==> 取 admin 密码（仅本次输出，请立刻保存）："
    echo "    首次启动时生成；需要重置用: cd $DIR && ./run.sh --reset-admin-password"
    echo
    if [ -n "$LOGF" ]; then
      grep -aiA6 'ADMIN SETUP REQUIRED' "$LOGF" 2>/dev/null | grep -aiE 'password|密码' | head -3
    fi
    if [ -z "$LOGF" ]; then
      echo "[!] 未找到日志（尝试过 /var/log/cyberstrike.log 与 $DIR/*.log）"
      echo "    提示：run.sh 是前台程序，用 nohup 启动时日志请自己指定路径。"
    fi
    ;;

  *)
    echo "[X] 未知 --app: $APP（可选 safeline | artex | cyberstrike）"; exit 1 ;;
esac

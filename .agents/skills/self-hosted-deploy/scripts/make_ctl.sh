#!/usr/bin/env bash
# make_ctl.sh - 在应用安装目录生成统一的启停入口 ctl.sh
#
# 用法:
#   bash make_ctl.sh compose  <app名> <安装目录> [compose文件名]
#   bash make_ctl.sh systemd  <app名> <安装目录> [systemd服务名]
#
# 生成的 ctl.sh 提供: start / stop / down / restart / status / logs / update
#   stop = docker compose stop（保留容器与数据，且配合 unless-stopped 手动停止后不再开机自启）
#   down = docker compose down（删除容器，保留数据卷）
set -uo pipefail

MODE="${1:?用法: make_ctl.sh <compose|systemd> <app名> <安装目录> [参数]}"
APP="${2:?缺少 app 名}"
DIR="${3:?缺少安装目录}"
ARG="${4:-}"

if [ "$MODE" = "compose" ]; then
  COMPOSE="${ARG:-docker-compose.yml}"
  case "$COMPOSE" in
    /*) : ;;                       # 绝对路径：compose 文件在别处（如雷池的 /data/safeline）
    *) COMPOSE="$COMPOSE" ;;
  esac
  cat > "$DIR/ctl.sh" <<EOF
#!/usr/bin/env bash
# ctl.sh - ${APP} 统一管理入口
# 用法: ./ctl.sh {start|stop|down|restart|status|logs|update}
set -uo pipefail
DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="\$DIR/${COMPOSE}"
cd "\$DIR" || exit 1
case "\${1:-status}" in
  start)   docker compose -f "\$COMPOSE" up -d ;;
  stop)    echo "[i] 停止服务（保留容器与数据；手动停止后开机不会自启）"; docker compose -f "\$COMPOSE" stop ;;
  down)    echo "[i] 停止并删除容器（保留数据）"; docker compose -f "\$COMPOSE" down ;;
  restart) docker compose -f "\$COMPOSE" restart ;;
  status)  docker compose -f "\$COMPOSE" ps ;;
  logs)    docker compose -f "\$COMPOSE" logs -f ;;
  update)  docker compose -f "\$COMPOSE" pull; docker compose -f "\$COMPOSE" up -d ;;
  *) echo "用法: ./ctl.sh {start|stop|down|restart|status|logs|update}"; exit 1 ;;
esac
EOF

elif [ "$MODE" = "systemd" ]; then
  UNIT="${ARG:-$(echo "$APP" | tr '[:upper:]' '[:lower:]')}"
  cat > "$DIR/ctl.sh" <<EOF
#!/usr/bin/env bash
# ctl.sh - ${APP} 统一管理入口（systemd 托管）
# 用法: ./ctl.sh {start|stop|restart|status|logs|enable|disable}
set -uo pipefail
UNIT="${UNIT}"
case "\${1:-status}" in
  start)   systemctl start "\$UNIT" ;;
  stop)    systemctl stop "\$UNIT" ;;
  restart) systemctl restart "\$UNIT" ;;
  status)  systemctl status "\$UNIT" --no-pager ;;
  logs)    journalctl -u "\$UNIT" -f ;;
  enable)  systemctl enable "\$UNIT" ;;
  disable) systemctl disable "\$UNIT" ;;
  *) echo "用法: ./ctl.sh {start|stop|restart|status|logs|enable|disable}"; exit 1 ;;
esac
EOF

else
  echo "[X] 未知模式: $MODE（compose | systemd）"; exit 1
fi

chmod +x "$DIR/ctl.sh"
echo "[+] 已生成 $DIR/ctl.sh"

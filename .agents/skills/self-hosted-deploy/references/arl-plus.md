# ARL-plus-docker 安装（资产侦察与漏洞扫描平台）

仓库：<https://github.com/ki9mu/ARL-plus-docker>（基于 ARL-V2.6.2 修改版，1k stars）

## 它是什么

ARL（Asset Reconnaissance Lighthouse，灯塔）国产化资产侦察 + 漏洞扫描平台：
子域名/IP/端口收集、指纹识别、漏洞扫描（nuclei）、弱口令、钓鱼 PoC 等，
带 Web 管理端与 Celery 任务队列。

## 部署方式（官方即 Docker Compose，Docker 优先 ✓）

官方 README「安装方式」：

```bash
docker volume create arl_db      # ← 必须先建！compose 里 arl_db 声明为 external
docker-compose up -d
```

⚠️ **漏掉 `docker volume create arl_db` 会直接启动失败**（external 卷不存在）。
安装脚本已自动创建。

## 组成（5 个容器）

| 容器 | 镜像 | 说明 |
|---|---|---|
| `arl_web` | `ki9mu/arl-ki9mu:v3.0.1` | **Web UI，端口 5003（HTTPS）** |
| `arl_worker` | 同上 | Celery worker（arlgithub / arltask 队列） |
| `arl_scheduler` | 同上 | 调度器（定时任务） |
| `arl_mongodb` | `mongo:4.0.27` | 数据库，卷 `arl_db` |
| `arl_rabbitmq` | `ki9mu/shadow-rabbitmq` | 消息队列 |

## 访问与凭据

- 地址：**https://<服务器IP>:5003/**（HTTPS，**自签证书**，浏览器首次需手动接受告警）
- 默认账号：**`admin` / `arlpass`**
  （这是 ARL 官方公开的默认密码，**登录后请立刻在「系统设置 → 用户管理」修改**）

数据库里的账号由 `mongo-init.js` 初始化：`hex_md5('arlsalt!@#' + 'arlpass')`。

## 需要的文件

compose 会 bind-mount 这些文件/目录，**缺一个就会出问题**：

| 路径 | 类型 | 说明 |
|---|---|---|
| `docker-compose.yml` | 文件 | 编排定义 |
| `config-docker.yaml` | 文件 | 主配置（挂载到容器 `/code/app/config.yaml`） |
| `mongo-init.js` | 文件 | 初始化 admin 用户 |
| `arl_web.log` / `arl_worker.log` | 文件 | 日志（**必须是空文件**，docker bind-mount 的文件不存在会变成目录） |
| `image/` / `poc/` | 目录 | 截图与上传的 PoC |

安装脚本会自动下载前三个并创建后两个。

## 配置要点（config-docker.yaml）

```yaml
CELERY:
  BROKER_URL : "amqp://arl:arlpassword@rabbitmq:5672/arlv2host"
MONGO:
  URI : 'mongodb://admin:admin@mongodb:27017/'
  DB : 'arl'
GEOIP:
  CITY: '/data/GeoLite2/GeoLite2-City.mmdb'
  ASN: '/data/GeoLite2/GeoLite2-ASN.mmdb'
```

- **GeoIP 数据库默认没有** → 资产归属地 / ASN 相关功能不可用，需要自己把
  `GeoLite2-City.mmdb` 与 `GeoLite2-ASN.mmdb` 放到镜像内 `/data/GeoLite2/`
  （官方提供下载：MaxMind 官网注册后下载 GeoLite2）
- FOFA / hunter / quake / zoomeye 等 API key 默认留空，对应插件不可用
- `center_option` 默认 false（不向中心节点上传数据），要联网上报需改 true 并重启

## 日常使用

```bash
cd /opt/arl-plus
docker compose up -d          # 启动
docker compose ps             # 状态
docker compose stop           # 停止（保留容器与数据）
docker compose down           # 停止并删容器
docker compose logs -f arl_web
```

重启策略已统一为 `unless-stopped`（手动 stop 后开机不会自启；崩溃/daemon 重启仍自动恢复）。

## 资源要求

官方建议 **4C / 8G**（worker 并发跑 nuclei 等扫描很吃内存）。
内存不足时表现为 worker 反复 OOM、任务无结果。

## 排障

| 现象 | 原因 | 处理 |
|---|---|---|
| 启动报 `external volume arl_db not found` | 忘了建外部卷 | `docker volume create arl_db` 后重新 `up -d` |
| `arl_web.log` 变成目录 | bind-mount 的文件不存在 | `rm -rf arl_web.log && touch arl_web.log` |
| Web 打不开 / 502 | 容器没起或证书问题 | `docker compose logs arl_web`；浏览器接受自签证书告警 |
| 登录提示密码错 | 首次初始化未执行 | `docker compose logs arl_mongodb`；确认 `mongo-init.js` 已挂载到 `/docker-entrypoint-initdb.d/` |
| 任务一直排队不执行 | rabbitmq/worker 异常 | `docker compose logs arl_worker arl_rabbitmq` |
| 资产归属地为空 | 缺 GeoIP mmdb | 见上文「配置要点」 |
| worker 反复重启 / OOM | 内存不足（官方建议 8G） | 加内存；或减少 `docker-compose.yml` 里 celery 的并发数 `-c 2` |
| 拉镜像很慢 / 拉不完 | Docker Hub 链路问题，ARL 镜像有 1.69GB | 按 SKILL.md 第 2.5 步真实 pull 测速后配镜像加速源 |
| `ki9mu/arl-ki9mu` 拉了 15 分钟还没完 | 加速源只有 2 个且都不通该镜像的大层 | **补多个加速源让 Docker 自动 fallback**（实测有效）：`daocloud` + `1panel` + `dockerproxy.net` + `docker.1ms.run` + `hub.rat.dev`，改完 `systemctl restart docker` 再 pull |
| 某个镜像拉失败导致整体装不上 | —— | 脚本会跳过失败镜像继续拉其余的；**镜像补齐后直接重跑安装脚本**即可（幂等：复用已有文件、外部卷、镜像） |

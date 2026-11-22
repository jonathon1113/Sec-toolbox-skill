# ScopeSentry 安装

仓库：<https://github.com/Autumn-27/ScopeSentry>（Go 后端 + React 前端，2.6k stars）
官网与教程：<https://www.scope-sentry.top>

## 它是什么

 cyberspace 测绘平台：子域名枚举、端口扫描、敏感信息发现、漏洞扫描，支持**分布式扫描节点**。
前端 React + Go 后端，数据存 MongoDB，任务队列用 Redis。

## 部署方式（官方即 Docker Compose，Docker 优先 ✓）

官方 README_CN「安装」：

```bash
git clone https://github.com/Autumn-27/ScopeSentry.git
cd ScopeSentry
# 修改 .env 文件中的 mongodb、redis 账号密码
docker-compose -f single-host-deployment.yml up -d
```

**本 skill 的优化**：部署只需要 `single-host-deployment.yml` 与 `.env` **两个文件**，
没必要 clone 整个仓库（90MB+），脚本直接下载这两个文件。

## 组成（4 个容器）

| 容器 | 镜像 | 说明 |
|---|---|---|
| `scopesentry-mongodb` | `mongo:7.0.28` | 数据库，账号密码来自 `.env` |
| `scopesentry-redis` | `redis:7.0.11` | 任务队列，`--requirepass ${REDIS_PASSWORD}` |
| `scope-sentry` | `autumn27/scopesentry:latest` | **Web UI，端口 8082** |
| `scopesentry-scan` | `autumn27/scopesentry-scan:latest` | 扫描节点（**host 网络**），单机部署默认带一个 |

数据持久化在 compose 文件所在目录的 `./data/`：`mongodb/` `redis/` `files/` `images/` `uploads/`。

## 前置要求

| 项 | 要求 | 不满足时 |
|---|---|---|
| Docker + Compose v2 | 必需 | 用 `linux-docker-env` skill 补装 |
| 端口 | **8082** 空闲（Web UI） | 先查占用方 |
| 内存 | ≥ 2 GB 建议（4 个容器 + 扫描任务很吃内存） | 不足：加内存/swap，或不部署扫描节点 |
| 磁盘 | ≥ 5 GB | 中止 |
| GitHub 链路 | 下载 compose/.env 用 | 不通则加 `--proxy`（向用户询问代理地址） |
| **CPU AVX** | **MongoDB 5.0+ 强制要求 AVX** | 无 AVX 的机器（QEMU 老 vCPU）上 `mongo:7.0.28` 会 `Illegal instruction`（退出码 132）反复崩溃。**安装脚本会自动检测并降级到 mongo:4.4**；根治办法是换支持 AVX 的 CPU/虚拟机型号 |

> 扫描节点用 `network_mode: host`，会直接占用宿主机端口；机器上已有服务多时要注意。

## 配置（.env）

官方默认是**弱密码**，脚本会自动替换成随机强密码：

```
MONGO_INITDB_ROOT_USERNAME=admin
MONGO_INITDB_ROOT_PASSWORD=<随机>
REDIS_PASSWORD=<随机>
```

`.env` 属于敏感文件（数据库密码），**不要提交到仓库**。

## 低配 CPU 适配（无 AVX）

官方 compose 用 `mongo:7.0.28`，而 **MongoDB 5.0+ 强制要求 CPU 支持 AVX**。在没有 AVX 的机器上
（如 `QEMU Virtual CPU version 2.5+`），容器会：

```
WARNING: MongoDB 5.0+ requires a CPU with AVX support, and your current system does not appear to have that!
/usr/local/bin/docker-entrypoint.sh: line 416: 26 Illegal instruction
```

表现为 `scopesentry-mongodb` 反复 `Restarting (132)`，然后 `scope-sentry` 因依赖不 healthy 起不来。

**处理（安装脚本已自动完成）**：

1. 检测无 AVX → compose 的 `image: mongo:7.0.28` 改为 `mongo:4.4`（不需要 AVX）；
2. healthcheck 从 `mongosh` 换成**带认证**的 `mongo` 探活
   （4.4 没有 `mongosh`；且开了认证后不带用户名密码的 ping 会失败）：

```yaml
test: ["CMD-SHELL", "mongo --quiet -u \"$$MONGO_INITDB_ROOT_USERNAME\" -p \"$$MONGO_INITDB_ROOT_PASSWORD\" --authenticationDatabase admin --eval \"db.runCommand({ping:1}).ok\" | grep -q 1"]
```

> 这是**降级方案**。换到支持 AVX 的机器（或虚拟机 CPU 型号换成带 AVX 的）后，可把 compose 改回 `mongo:7.0.28`，
> 但要先清空 `data/mongodb/`（4.4 与 7.x 的数据格式不完全兼容）。

## 初始化凭据

首次启动后从容器日志取**初始用户密码**与**插件二次验证密码**：

```bash
docker logs scope-sentry | grep -i password
docker logs scope-sentry | grep -i 验证
```

密码只输出一次，立刻保存。

## 重置密码（官方没有重置命令）

ScopeSentry **没有提供改密码的命令**，密码只在首次初始化时打印一次。两种办法：

**办法一：改数据库（推荐，保留数据）**

密码存的是 **sha256(明文)**（无 salt），用户名 `ScopeSentry`：

```bash
cd /opt/scopesentry
MP=$(grep '^MONGO_INITDB_ROOT_PASSWORD=' .env | cut -d= -f2)
NEWHASH=$(printf '%s' '你的新密码' | sha256sum | cut -d' ' -f1)
docker exec scopesentry-mongodb mongo -u admin -p "$MP" --authenticationDatabase admin --quiet   --eval "db.getSiblingDB('ScopeSentry').user.update({username:'ScopeSentry'},{\$set:{password:'$NEWHASH'}})"
```

改完直接用新密码登录。

**办法二：重建数据库（会清空所有资产/任务数据）**

```bash
cd /opt/scopesentry
MP=$(grep '^MONGO_INITDB_ROOT_PASSWORD=' .env | cut -d= -f2)
docker exec scopesentry-mongodb mongo -u admin -p "$MP" --authenticationDatabase admin --quiet   --eval "db.getSiblingDB('ScopeSentry').dropDatabase()"
docker restart scope-sentry
docker logs scope-sentry | grep -a 'User/Password'   # 会打印新的初始密码
```

> ⚠️ 官方密码**可能以 `/` 开头**（形如 `ScopeSentry//xxxx`），也可能含 `$ ( ) [ ]` 等特殊字符。
> 复制时容易丢字符 —— 建议用上面的办法一改成一个简单的密码。

## 重启策略

官方 compose 用 `restart: always` —— 手动 stop 后机器重启仍会被拉起。
本 skill 安装脚本会自动规范化为 `unless-stopped`。

```bash
bash scripts/set_restart_policy.sh --compose /opt/scopesentry/single-host-deployment.yml
```

## 启动与停止

官方 compose 文件名是 `single-host-deployment.yml`（不是默认名），安装脚本已建好软链，
所以标准命令直接可用：

```bash
cd /opt/scopesentry
docker compose up -d       # 启动
docker compose ps          # 状态
docker compose stop        # 停止（保留容器与数据）
docker compose down        # 停止并删容器
docker compose logs -f     # 日志
```

也可以用统一入口：`./ctl.sh start|stop|status|logs`（等价，省记 compose 文件名）。

## 大镜像拉取与可选扫描节点

`autumn27/scopesentry-scan:latest` 是**可选**的扫描节点，镜像层多、体积大，
在网络较慢的机器上可能拉很久（实测有一台拉了 30 分钟仍未完成，进度条在非 TTY 下不刷新）。

安装脚本的处理：

1. **逐个** `docker pull`（不并发），进度可见、失败可单独重试，单镜像超时默认 600 秒；
2. 超时的镜像**不阻塞**核心服务 —— 先起 `mongodb` / `redis` / `scope-sentry` 三件套，Web UI 立刻可用；
3. 扫描节点镜像就绪后再补：`cd /opt/scopesentry && docker compose up -d scopesentry-scan`。

> 扫描节点是**可选**的：官方支持另建独立节点仓库（ScopeSentry-Scan），
> 核心功能（资产、任务、结果管理）不依赖它。

## 日常使用

- Web UI：<http://<服务器IP>:8082/>
- 登录后：添加资产/根域名 → 建任务 → 节点执行 → 结果在资产面板查看
- 任务与结果类型：子域名、端口、敏感信息、漏洞、指纹识别等

## 添加更多扫描节点（可选）

节点是独立仓库 <https://github.com/Autumn-27/ScopeSentry-Scan>：

```bash
git clone https://github.com/Autumn-27/ScopeSentry-Scan.git
cd ScopeSentry-Scan/build
# 编辑 .env：MongoDB / Redis 连接信息 + NodeName（节点名必须唯一）
docker-compose -f scan-docker-compose.yml up -d
```

节点上的 `NodeName` 建议显式指定（留空会随机生成，之后可在 Web 界面改名）。

## 排障

| 现象 | 原因 | 处理 |
|---|---|---|
| `scope-sentry` 一直不 healthy | 依赖 mongo/redis healthy 才启动 | `docker compose ps` 看依赖；`docker compose logs mongodb redis` |
| 拉镜像超时 | 上游污染/没配加速源 | 按 SKILL.md 第 2.5 步真实 pull 测速后配 `daemon.json` |
| 容器起不来：端口冲突 | 8082 被占 | 改 compose 的 `ports` 映射，或先释放端口 |
| `scopesentry-mongodb` 反复 Restarting (132) | CPU 无 AVX，MongoDB 5+ 崩溃 | 见上文「低配 CPU 适配」 |
| `scope-sentry` 起不来，提示依赖 unhealthy | mongo/redis 没 healthy | 先看 `docker compose logs mongodb redis`；mongo 常见原因是无 AVX |
| 扫描任务无结果 | 扫描节点异常 | `docker logs scopesentry-scan`；节点是 host 网络，注意与宿主端口冲突 |
| `docker compose up -d` 报 "no configuration file provided" | 官方 compose 文件名是 `single-host-deployment.yml`（非默认名） | 安装脚本会建 `docker-compose.yml` 软链；没有就手动 `ln -sf single-host-deployment.yml docker-compose.yml` |
| 拉镜像长时间无输出 | 大镜像 + 非 TTY 进度条不刷新 | 单独 `docker pull <镜像>` 观察；慢就等，或先起核心三件套 |
| verify 报 `scopesentry-scan 未运行` | 扫描节点是**可选**的 | 已改为警告；需要时再 `docker compose up -d scopesentry-scan` |
| 登录提示密码错误 | 用了旧的初始密码 | `docker logs scope-sentry | grep -i password` 取最新；数据库首次初始化后不会重复打印 |
| 数据库连不上 | `.env` 密码改了但容器没重建 | `docker compose -f single-host-deployment.yml up -d --force-recreate` |
| 磁盘增长快 | `./data/` 存了扫描结果与文件 | 定期清理 `./data/files` `./data/images` `./data/uploads` |

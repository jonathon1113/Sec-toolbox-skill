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

> 扫描节点用 `network_mode: host`，会直接占用宿主机端口；机器上已有服务多时要注意。

## 配置（.env）

官方默认是**弱密码**，脚本会自动替换成随机强密码：

```
MONGO_INITDB_ROOT_USERNAME=admin
MONGO_INITDB_ROOT_PASSWORD=<随机>
REDIS_PASSWORD=<随机>
```

`.env` 属于敏感文件（数据库密码），**不要提交到仓库**。

## 初始化凭据

首次启动后从容器日志取**初始用户密码**与**插件二次验证密码**：

```bash
docker logs scope-sentry | grep -i password
docker logs scope-sentry | grep -i 验证
```

密码只输出一次，立刻保存。

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
| 扫描任务无结果 | 扫描节点异常 | `docker logs scopesentry-scan`；节点是 host 网络，注意与宿主端口冲突 |
| 登录提示密码错误 | 用了旧的初始密码 | `docker logs scope-sentry | grep -i password` 取最新；数据库首次初始化后不会重复打印 |
| 数据库连不上 | `.env` 密码改了但容器没重建 | `docker compose -f single-host-deployment.yml up -d --force-recreate` |
| 磁盘增长快 | `./data/` 存了扫描结果与文件 | 定期清理 `./data/files` `./data/images` `./data/uploads` |

# ARTEX 安装（AI 自主渗透测试系统）

仓库：<https://github.com/BaaRai/ARTEX>（上游 Autumn-27/ARTEX，AGPL-3.0，Go + Next.js + PostgreSQL）
上游 README 原文：`references/artex/README.md`（可按需更新：`curl -fsSL https://raw.githubusercontent.com/BaaRai/ARTEX/main/README.md`）

## 它是什么

AI 驱动的自主渗透测试平台：双图架构（探索图 + 资产图）、持久化攻击链、多 LLM provider worker。
镜像内自带扫描器工具链：`nmap` `nuclei` `httpx` `katana` `ffuf` `dalfox` `sqlmap` `ripgrep` `curl` `npm` 等。

**没有预构建镜像可拉** —— 镜像永远从你的 checkout 构建（`docker compose build`）。这是选型时最大的成本项。

## 整体流程

```
0. 读需求：全 Docker（compose 构建）还是 release 预编译二进制
1. 前置检查（--app artex）：端口 8787、内存、磁盘、git
2. Docker + Compose v2 就绪
3. 拉代码 → 配 .env → 起服务
4. 取一次性 setup token（不是密码，是首启认领码）
5. 自检：postgres healthy / artex 容器 Up / 8787 返回 HTTP
6. 交付：地址 + setup token + LLM key 配置提示
```

## 关键决策：构建 vs 预编译二进制

| 路径 | 内存需求 | 耗时 | 适用 |
|---|---|---|---|
| **A. `docker compose up -d --build`**（README Option 2，官方推荐） | **≥ 4 GB 建议**（前端 `npm ci` + Go 编译同时吃内存） | 10~30 分钟 | 机器内存 ≥ 4GB 的常规场景 |
| **B. release 预编译二进制**（README Option 3） | ≥ 2 GB | 5 分钟 | **小内存机器（2GB 级）首选** |
| C. 源码构建单二进制（Option 4） | ≥ 4 GB | 20+ 分钟 | 需要改代码时 |

> ⚠️ **实测教训类推**：2 GB 物理内存的机器上，`npm ci` + `go build` 极易 OOM。
> 内存 < 4 GB 时优先走路径 B，或让用户加内存后再走 A。

## 路径 A：全 Docker（官方推荐）

```bash
git clone https://github.com/BaaRai/ARTEX.git /opt/artex
cd /opt/artex
cp .env.example .env
# 必改：POSTGRES_PASSWORD；远程访问还要改 ARTEX_BIND_ADDR
docker compose up -d --build
```

`.env` 关键项：

| 变量 | 说明 |
|---|---|
| `POSTGRES_PASSWORD` | **必填**，compose 里 `:?` 强制校验，留空直接报错 |
| `ARTEX_BIND_ADDR` | 默认 `127.0.0.1`（仅本机）。**要从别的机器访问必须改成 `0.0.0.0`** |
| `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` | LLM 密钥，可在 UI 里再配；**探索任务必须有 LLM 才能跑** |
| `ARTEX_TRUSTED_PROXIES` | 反代来源 CIDR 逗号分隔，空=忽略 X-Forwarded-For |
| `ARTEX_SECRET_KEY` | 数据库密文密钥（32 字节 base64/hex）。`./keys` 不持久化时必须固定，否则存过的密文解不开 |

端口映射由 compose 决定：`${ARTEX_BIND_ADDR:-127.0.0.1}:8787:8787`。

持久化：`./skills` 与 `./data` 用 bind mount 挂在宿主机上，**别删这两个目录**。

## 路径 B：预编译二进制（小内存机器）

```bash
cd /opt
# 从 Releases 下载对应平台 zip（linux/amd64 或 arm64），校验 SHA256SUMS
unzip artex-<version>-linux-amd64.zip -d /opt/artex
cd /opt/artex
cp config.example.json config.json   # 填 database 段
./start.sh                            # 或 nohup ./start.sh >artex.log 2>&1 &
```

zip 内含 `artex`、`start.sh`、`skills/`、`config.example.json`。
`start.sh` 是守护脚本（带退避重启），**不要直接跑 `./artex`**。
用 `start.sh` 启动还需要 PostgreSQL：可只起一个 postgres 容器，或复用 compose 的 postgres 服务。

校验（官方提供）：

```bash
sha256sum -c SHA256SUMS                                    # 校验完整性
gh attestation verify <zip> --repo BaaRai/ARTEX             # 校验构建来源（有 gh 时）
```

`config.json` 里的 database 段（官方 install.sh 的写法）：

```json
{
  "database": {
    "host": "127.0.0.1", "port": 5432,
    "user": "artex", "password": "...",
    "dbname": "artex", "sslmode": "disable"
  }
}
```

## 第 4 步：取一次性 setup token

首次访问 `/setup` 需要 **setup token**（不是登录密码）：

```bash
cd /opt/artex && docker compose logs artex | grep "Setup token"
```

浏览器打开 `http://<IP>:8787/setup` 输入 token 完成首次认领，随后才能创建管理员账号。

token 同样**只输出一次，不写文件**。

## 第 5 步：自检

```bash
bash scripts/verify.sh --app artex
```

- `postgres` 容器 healthy；
- `artex` 容器 Up；
- `curl -I http://127.0.0.1:8787/` 返回 200/302；
- 能从日志里取到 "Setup token"。

## 第 6 步：交付说明

给用户：

- 访问地址 `http://<IP>:8787/`（**先确认 `ARTEX_BIND_ADDR=0.0.0.0`，否则远程打不开**）
- 首次访问 `/setup` 用 setup token 认领
- LLM key 未配置 → **扫描/探索任务无法执行**，提醒在 UI 里配 `ANTHROPIC_API_KEY` 或 `OPENAI_API_KEY`
- 数据持久化位置：`/opt/artex/skills`、`/opt/artex/data`、postgres volume
- 内存紧张提醒（构建期与运行期）

## 官方一键脚本（可选）

仓库自带 `install.sh`（交互式）：检测/安装 Docker → 选 ①全 Docker ②本地 go build。
交互提示形如 `Choose [1]:`、`Postgres password (press Enter to generate randomly)`。
要用它就跑 `pty_runner.py` 包裹；**但手动 compose 更可控**，默认推荐路径 A。

## 排障

| 现象 | 原因 | 处理 |
|---|---|---|
| compose 报 `Please set POSTGRES_PASSWORD` | `.env` 没填密码 | 填 `POSTGRES_PASSWORD` |
| 远程打不开 8787 | `ARTEX_BIND_ADDR` 还是 127.0.0.1 | 改成 `0.0.0.0` 后 `docker compose up -d` 重建 |
| 构建 OOM / 被 kill | 内存 < 4GB | 走路径 B，或加内存加 swap |
| 构建时拉不动基础镜像 | 上游被污染 / 没配加速源 | 按 SKILL.md 第 2.5 步真实 pull 测速后配 `daemon.json` |
| `/setup` 提示 token 无效 | 容器重启过，token 已变 | 重新 `docker compose logs artex \| grep "Setup token"` |
| 任务跑不动 / 报模型错误 | 没配 LLM key | UI 里配 `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` |
| 数据库连不上 | DSN 里密码与 `.env` 不一致 | 核对 `ARTEX_PG_DSN` 与 `POSTGRES_PASSWORD` |

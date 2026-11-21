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

## 关键决策：Docker 优先（构建 vs 预编译二进制）

**默认走 A（Docker Compose）。** 只有在 A 确实跑不通时才降级到 B。

| 路径 | 优先级 | 内存需求 | 耗时 | 形态 |
|---|---|---|---|---|
| **A. `docker compose up -d --build`**（README Option 2，官方推荐） | **首选** | 建议 ≥ 4 GB（前端 `npm ci` + Go 编译同时吃内存） | 10~30 分钟 | 容器：`artex` + `postgres`，`docker ps` 可见 |
| B. release 预编译二进制（README Option 3） | 降级 | ≥ 2 GB | 5 分钟 | 宿主机进程 + postgres 容器 |
| C. 源码构建单二进制（Option 4） | 最后兜底 | ≥ 4 GB | 20+ 分钟 | 宿主机进程 |

### 构建耗时预期（实测：全新构建 ≈ 30~45 分钟）

ARTEX **没有预构建镜像**，compose 路径必然本地构建。各阶段实测耗时：

| 阶段 | 耗时 | 说明 |
|---|---|---|
| 拉基础镜像（node:22 / golang:1.26 / debian） | 3~8 分钟 | 走加速源/代理 |
| `npm ci` + `npm run build:static` | 2~3 分钟 | 前端静态构建，最吃内存 |
| `go mod download` + `go build` | 3~5 分钟 | **需要 proxy.golang.org，走代理** |
| **Ansible 装 20+ 扫描器工具链** | **10~15 分钟** | nmap/nuclei/httpx/katana/sqlmap/playwright… **最慢的一段** |
| 导出镜像层 | 2~5 分钟 | 镜像数 GB |

> 对比：官方预编译二进制只有 **17MB**（工具链已打包进去），下载即用，5 分钟搞定。
> **Docker 优先的价值在于形态与运维，不在于速度。**

### 部署多台机器：复用构建产物，别每次重编

首次构建后把镜像导出，后续机器直接导入（几分钟 vs 半小时）：

```bash
# 构建机
docker save artex:local -o artex-image.tar        # 或 docker save <compose 生成的镜像名>
gzip artex-image.tar                              # 体积小很多

# 目标机
gunzip -c artex-image.tar | docker load
cd /opt/artex && docker compose up -d             # 已有镜像则不再 build
```

或者推到私有 registry，之后 `docker compose pull` + `up -d`。

> 目标机要跳过构建：把 compose 里的 `build:` 段注释掉，或用 `docker compose up -d --no-build`。

### A 跑不通时，先解决问题，再降级

**不要一看到内存不足就直接用二进制** —— 正确顺序是：

1. **加内存**（首选）：机器加到 4GB+；
2. **加 swap**：`fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`，并写入 `/etc/fstab`；
3. **降低构建并发**：`npm config set maxsockets 3`、`COMPOSE_PARALLEL_LIMIT=1 docker compose build`；
4. 以上都做不到，**再降级到 B**，并在交付时写清楚"为什么没用 Docker"。

> 降级到 B 的代价：ARTEX 变成**宿主机进程**（`docker ps` 里只有 postgres，看不到 artex），
> 卸载/升级/开机自启/备份方式都与 Docker 不同，交付说明里必须写明。

> ⚠️ 实测：2 GB 物理内存的机器上，`npm ci` + `go build` 极易 OOM；
> 当时 .3 有 2GB swap 兼底，才改走 B（实测记录，详见文末踩坑表）。

## 路径 A：全 Docker（首选，官方推荐）

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

## 路径 B：预编译二进制（降级方案，仅在 A 跑不通时用）

```bash
cd /opt
# 从 Releases 下载对应平台 zip（linux/amd64 或 arm64），校验 SHA256SUMS
unzip artex-<version>-linux-amd64.zip -d /opt/artex
cd /opt/artex
cp config.example.json config.json   # 填 database 段
./start.sh                            # 或 nohup ./start.sh >artex.log 2>&1 &
```

zip 内含 `artex`、`start.sh`、`skills/`、`config.example.json`。
**解压后会得到一个同名子目录**（如 `artex-0.7.0-linux-amd64/`），程序在该子目录里，别以为解压失败。
`start.sh` 是守护脚本（带退避重启），**不要直接跑 `./artex`**。
用 `start.sh` 启动还需要 PostgreSQL：可只起一个 postgres 容器，或复用 compose 的 postgres 服务。

> ⚠️ **binary 模式的监听地址用 `-addr` 参数，不是环境变量**（实测）：
> ```bash
> # 远程可访问（0.0.0.0）
> nohup ./start.sh -addr 0.0.0.0:8787 > artex.log 2>&1 &
> # 仅本机（默认）
> nohup ./start.sh > artex.log 2>&1 &
> ```
> `ARTEX_BIND_ADDR` 是 **compose 模式**的 `.env` 变量，binary 模式下**设了也不生效**（实测仍监听 127.0.0.1）。

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


---

## 实测踩坑（192.168.99.3 / CentOS 7.9 / ARTEX v0.7.0 跑通）

| 现象 | 真因 | 处理 |
|---|---|---|
| release 下载一直 0 字节 / `curl: (35) Encountered end of file` | 到 GitHub release 的链路被阻断（api/raw 通、release 不通） | **向用户询问是否有可用代理**，用 `--proxy <host:port>` 重跑；代理仅本次生效，不写文件、不写进 skill |
| 下载返回 404 | **资产名不能猜**：tag 是 `v0.7.0`，资产却是 `artex-0.7.0-linux-amd64.zip`（无 v） | 用 GitHub API 的 assets 列表取真实 `browser_download_url` |
| `sha256sum -c --ignore-missing` 报 unrecognized option | CentOS 7 的 coreutils 老，没有该选项（hash 本身是对的） | `grep -F " <文件名>" SHA256SUMS > .sha_line && sha256sum -c .sha_line` |
| 解压后目录里找不到 `artex` | zip 解压出的是**同名子目录** | 进入子目录再启动 |
| 远程访问 8787 不通 | binary 模式只听 `127.0.0.1`；`ARTEX_BIND_ADDR` 在 binary 模式无效 | `./start.sh -addr 0.0.0.0:8787` |
| 找不到 setup token | token 打在 **stderr**，日志里有 `setup token for the /setup page: <hex>` | `grep -a "setup token" artex.log` |
| 启动了但任务不动 | 没配 LLM，engine idle（日志 `no LLM provider configured`） | UI 或 `.env` 里配 `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` |
| `config.json` 里 port 默认 5433 | 官方示例端口是 5433 | 与实际 postgres 映射端口对齐（本例映射 5432） |
| `pkill -f start.sh` 把自己的会话也杀了 | `-f` 匹配到包含该字符串的当前 shell 命令行 | 用 `pkill -x artex`（精确匹配进程名） |
| 本机能开、别的机器连不上 | **firewalld 默认只放行 ssh 等默认端口**；ARTEX 是宿主机进程，没有 Docker NAT 兜底 | `firewall-cmd --permanent --add-port=8787/tcp && firewall-cmd --reload`，放行后**从另一台机器实测**确认 |
| 放行了仍不通 | 绑定了 `127.0.0.1`（binary 模式默认） | `./start.sh -addr 0.0.0.0:8787` |

### 防火墙（binary 模式必做）

ARTEX 以宿主机进程运行，**不像 Docker 映射端口那样有 NAT 兜底**，firewalld 开着就必须显式放行：

```bash
firewall-cmd --permanent --add-port=8787/tcp
firewall-cmd --reload
firewall-cmd --list-ports        # 确认已放行
```

放行后务必**从另一台机器**实测一次（`curl -sI http://<目标IP>:8787/`），本机 curl 通不代表外部通。

### 日常运维（binary 模式 + systemd，推荐）

binary 模式是**宿主机进程**，所以 `docker ps` 里**看不到 artex 本身**（只有配套的 postgres 容器）。
要开机自启与崩溃自愈，注册 systemd 服务（`install_artex.sh --systemd` 会自动写好）：

```bash
systemctl status artex              # 状态
systemctl restart artex             # 重启
journalctl -u artex -f              # 实时日志
systemctl stop / start artex
```

systemd 下直接跑 `artex` 二进制，**不要用 `start.sh`** —— start.sh 自带退避重启守护，
和 systemd 的 Restart 叠加会打架。`start.sh` 留给手动前台/无 systemd 的场景。

> 想让 `docker ps` 里能看到 `artex` 容器 → 用 **compose 模式**（Option 2）：
> ```bash
> cd /opt/artex && docker compose up -d --build
> ```
> 但要本地构建（无预构建镜像），内存 < 4GB 有 OOM 风险，且会与 binary 模式抢 8787 端口（先停 systemd 服务）。

### 实测可用的一条命令链（binary 模式）

```bash
# 1. 下载解压（带代理、真实资产名、SHA256 校验）
bash scripts/install_artex.sh --method binary --dir /opt/artex --proxy <用户提供的代理>

# 2. 准备 PostgreSQL（复用本机已有镜像，避免再拉）
docker run -d --name artex-pg -p 5432:5432   -e POSTGRES_USER=artex -e POSTGRES_PASSWORD=<pw> -e POSTGRES_DB=artex   -v artex-pg:/var/lib/postgresql/data postgres:16-alpine

# 3. 填 config.json 的 database 段（host/port/user/password/dbname/sslmode）

# 4. 启动（对外可访问）
cd /opt/artex/<版本子目录> && setsid nohup ./start.sh -addr 0.0.0.0:8787 > artex.log 2>&1 < /dev/null &

# 5. 取一次性 setup token
bash scripts/init_admin.sh --app artex

# 6. 自检
bash scripts/verify.sh --app artex
```

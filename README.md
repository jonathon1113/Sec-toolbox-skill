# Skills 总仓库

一个用于**在 Linux 上部署自托管服务 / 安全工具 / 搭建容器环境**的 Agent Skill 集合。

目标是把"官方文档里没写、但你一定会踩的坑"沉淀成可复用、可执行的脚本，让每次部署都不走弯路。
所有脚本都经过**真机实测**（CentOS 7.9 / Debian 13）。

## 目录结构

```
.
├── .agents/skills/                 # 所有 skill（pi / Claude Code 等遵循 Agent Skills 规范的 Agent 均可发现）
│   ├── linux-docker-env/           # 容器底座：检查/安装 Docker + Compose、配置国内镜像加速
│   ├── self-hosted-deploy/         # 自托管服务/安全工具统一部署（5 个软件）
│   └── skill-authoring/            # 新增 skill 的规范（含"一个 skill 管多个软件"的组织方式）
├── templates/skill-template/       # 复制即用的新 skill 骨架
├── AGENTS.md
└── README.md
```

## 现有 skill

| Skill | 作用 | 触发场景 |
|---|---|---|
| `linux-docker-env` | 检查并安装 Docker / Compose，配置国内镜像加速源 | 搭建容器环境、"docker not found"、"docker compose 不存在"、拉镜像超时 |
| `self-hosted-deploy` | 自托管服务 / 安全工具统一部署（当前支持 5 个软件，见下表） | 装雷池、部署 WAF、装 ARTEX、装 CyberStrikeAI、装 ScopeSentry、装 ARL-plus、部署某个 Docker 化开源安全工具 |
| `skill-authoring` | 新增部署类 skill 的规范 | "再加一个 XX 工具的部署 skill"、"这个 skill 能不能装别的软件" |

### `self-hosted-deploy` 支持的软件

| 软件 | 部署形态 | 安装目录 | 启动方式 |
|---|---|---|---|
| **长亭雷池 SafeLine CE**（WAF） | Docker Compose（7 容器） | `/data/safeline`（官方固定路径） | `cd /data/safeline && docker compose up -d` |
| **ARTEX**（AI 自主渗透测试系统） | Docker Compose（2 容器） | `/opt/artex` | `cd /opt/artex && docker compose up -d` |
| **ScopeSentry**（子域名/端口/敏感信息/漏洞 测绘） | Docker Compose（4 容器） | `/opt/scopesentry` | `cd /opt/scopesentry && docker compose up -d` |
| **ARL-plus**（灯塔，资产侦察与漏洞扫描） | Docker Compose（5 容器） | `/opt/arl-plus` | `cd /opt/arl-plus && docker compose up -d` |
| **CyberStrikeAI**（AI 原生渗透测试平台） | 源码构建 + systemd（上游无容器方案） | `/opt/cyberstrike` | `systemctl start cyberstrike` |

每个软件的专有细节（配置项、坑位、排障）都在 `references/<app>.md`。

## 核心思路

每个部署类 skill 都遵循同一套模式：

```
前置检查（只读） → 依赖检查（Docker） → 安装（官方方式） → 初始化凭据 → 自检 → 交付说明
```

`self-hosted-deploy` 采用**一个 skill 管多个软件**的结构：SKILL.md 只放通用流程与路由表，
每个软件一份 `references/<app>.md`（专有坑位）+ 一个 `scripts/install_<app>.sh`（官方安装方式），
`precheck.sh` / `init_admin.sh` / `verify.sh` 用 `--app <name>` 分支。

### 统一约定

1. **Docker 优先** —— 官方有 Docker/Compose 方案就首选；**上游只有源码构建的**（如 CyberStrikeAI）
   按官方方式部署（systemd），**不为了统一而自造 Dockerfile**（会偏离上游、让升级路径分叉）。
2. **安装目录统一 `/opt/<软件名>/`** —— 例外只有雷池（官方固定 `/data/safeline`）。
3. **启动方式统一 `docker compose up -d`** —— 进入安装目录就能用；compose 文件名不是默认名的
   （如 ScopeSentry 的 `single-host-deployment.yml`）安装时建 `docker-compose.yml` 软链。
4. **重启策略统一 `unless-stopped`** —— Docker 的 `always` 会让**手动 stop 的容器在机器重启后被拉起**；
   `unless-stopped` 只记住手动停止，崩溃/daemon 重启仍自动恢复。安装脚本自动规范化
   （含改 compose 文件里的 `restart:` 字段，避免下次 recreate 回退）。
5. **先检查再动手** —— 检查脚本绝不修改系统状态，退出码语义化（`0/10/20/21`）。
6. **依赖复用底座** —— 需要 Docker 的统一走 `linux-docker-env`，不重复造轮子。
7. **只用官方安装方式** —— 官方命令写进脚本并注明出处与文档链接。
8. **敏感信息不落盘** —— 密码/token 只在终端打印一次，不写进任何文件或日志。
9. **网络受阻先解决前置条件** —— 直连不通先加镜像加速源；仍不行则**向用户询问代理地址**，
   代理仅本次生效（`--proxy`），不写文件、不写进 skill。

### 脚本速查

```bash
S=.agents/skills/self-hosted-deploy/scripts

bash $S/precheck.sh     --app <safeline|artex|cyberstrike|scopesentry|arl-plus> [--docker]
bash $S/install_<app>.sh                       # 安装（默认用官方方式）
bash $S/init_admin.sh   --app <app>            # 取/重置凭据（一次性输出）
bash $S/verify.sh       --app <app>            # 自检（独立判断成功/失败）
bash $S/set_restart_policy.sh --compose <文件>  # 重启策略统一为 unless-stopped
```

## 使用方式

### 在 pi 中使用

仓库克隆到任意位置后，`.agents/skills/` 会被 pi 自动发现；也可复制到用户级目录全局生效：

```bash
mkdir -p ~/.agents/skills && cp -r .agents/skills/* ~/.agents/skills/
```

之后在 pi 里：

```
/skill:self-hosted-deploy
```

或直接描述需求（"帮我在这台服务器上装雷池 WAF"、"装一下 ARL-plus"），模型会自动加载对应 skill
并按"检查 → 安装 → 初始化 → 自检 → 交付"走完。

### 手动使用脚本

所有脚本都能脱离 Agent 直接跑：

```bash
bash .agents/skills/self-hosted-deploy/scripts/precheck.sh --app safeline --docker
bash .agents/skills/linux-docker-env/scripts/check_env.sh
```

## 新增一个软件

在 `self-hosted-deploy` 里加一个软件需要动四处：

1. `references/<app>.md` —— 专有细节、官方安装方式、配置项、专属排障；
2. `scripts/install_<app>.sh` —— 官方安装命令写进脚本并注明出处，末尾调用
   `set_restart_policy.sh` 规范化重启策略；
3. `precheck.sh` / `init_admin.sh` / `verify.sh` —— 加该 app 的 `--app` 分支；
4. `SKILL.md` —— "支持的软件"表加一行 + `metadata.supported_apps` 补上。

详见 `.agents/skills/skill-authoring/SKILL.md`。

若要新增**独立** skill：

```bash
cp -r templates/skill-template .agents/skills/<new-skill>
```

## 已验证的上游资料

| 用途 | 地址 |
|---|---|
| 雷池免费安装（官方） | https://help.waf-ce.chaitin.cn/node/01973fc6-df0f-7650-bafa-8ed8d2fc2bc1 |
| 雷池离线安装 | https://help.waf-ce.chaitin.cn/node/01973fc6-e046-7489-bcd7-7b1554393895 |
| 雷池版本升级 | https://help.waf-ce.chaitin.cn/node/0197400a-369e-78dd-93a7-f087d9a962f7 |
| 雷池添加应用 | https://help.waf-ce.chaitin.cn/node/01973fc6-e14a-7234-8acd-bdba21c8b3f3 |
| 雷池常见问题排查 | https://help.waf-ce.chaitin.cn/node/01975855-cd7b-78fb-a354-d2aa65a53cce |
| ARTEX（AI 自主渗透测试系统） | https://github.com/BaaRai/ARTEX |
| CyberStrikeAI（AI 原生渗透测试平台） | https://github.com/AIPentest/CyberStrikeAI |
| ScopeSentry（测绘/扫描平台） | https://github.com/Autumn-27/ScopeSentry |
| ARL-plus（灯塔，资产侦察与漏洞扫描） | https://github.com/ki9mu/ARL-plus-docker |
| 轩辕镜像 Docker 一键安装 | https://xuanyuan.cloud/install/linux |

> 官方文档会更新。使用前建议核对上游链接的最新内容，skill 内脚本中的命令以官方为准。

## 实测环境

| 主机 | 系统 | 规格 | 用途 |
|---|---|---|---|
| 192.168.99.3 | CentOS Linux 7.9 | 4C / 3.8G / 17G | 老系统兼容性验证（glibc 2.17、无 AVX、无 python3.10+） |
| 192.168.99.5 | Debian 13 (trixie) | 4C / 3.9G / 47G | 常规环境验证 |

实测沉淀的典型坑位（均已写进对应 `references/`）：

- **MongoDB 5+ 强制要求 CPU AVX** —— 无 AVX 的机器上 `mongo:7.0.28` 会 `Illegal instruction`（退出码 132）反复崩溃；
  ScopeSentry 安装脚本会自动降级 `mongo:4.4` 并修正 healthcheck。
- **大镜像（>1GB）仅靠加速源常拉不动** —— 某一层反复 `Retrying`；有效解法是给 **dockerd** 配代理
  （`/etc/docker/daemon.json` 的 `proxies` 段 + 重启 docker），代理地址由用户提供，不写进 skill。
- **`restart: always` 会让手动 stop 的容器开机自启** —— 统一改 `unless-stopped`。
- **Windows 上编辑的 `.sh` 是 CRLF 行尾** —— 传到 Linux 直接语法崩溃；仓库用
  `.gitattributes` 的 `* text=auto eol=lf` 强制 LF，手工上传后仍建议 `sed -i 's/\r$//'`。
- **compose 里 `external: true` 的卷必须先建** —— ARL-plus 的 `arl_db` 漏建直接启动失败。
- **bind-mount 的文件必须存在** —— 不存在会被 docker 创建成目录（ARL-plus 的 `arl_web.log`）。
- **源码构建型软件需要 C 编译器** —— 无 gcc 时 Go 自动 `CGO_ENABLED=0`，SQLite 相关功能直接崩
  （CyberStrikeAI 的 `go-sqlite3 requires cgo`）。

## License

MIT

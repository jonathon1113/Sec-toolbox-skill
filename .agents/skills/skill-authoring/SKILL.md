---
name: skill-authoring
description: 在本仓库中新增"Linux 安全工具/环境部署"skill 的标准流程与规范。当用户要求"再加一个 XX 工具的部署 skill"、"照着雷池写一个新的"、"新建 skill 模板"、"这个 skill 能不能装别的软件"时使用。规定了目录结构、SKILL.md frontmatter 写法、检查-安装-自检三段式脚本规范、引用文档规范，以及一个 skill 管多个软件时的组织方式。
metadata:
  version: 1.1.0
---

# 新增部署类 skill 的规范

本仓库的每个 skill 都遵循同一套模式：**前置检查 → 安装 → 初始化 → 自检 → 交付说明**。

## 目录结构

### 单软件 skill

```
.agents/skills/<skill-name>/
├── SKILL.md                 # 入口，含 frontmatter
├── scripts/
│   ├── precheck.sh          # 只读检查，退出码区分失败原因
│   ├── install_<tool>.sh    # 安装，调用官方方式
│   ├── init_admin.sh        # 初始化凭据（可选）
│   └── verify.sh            # 自检
└── references/
    ├── 故障排查.md          # 排障手册
    ├── 运维速查.md          # 日常运维命令
    └── 离线安装.md          # 离线/内网场景（可选）
```

### 一个 skill 管多个软件（本仓库 `self-hosted-deploy` 采用）

当用户希望"这个 skill 能装很多种软件"时，**不要拆成 N 个 skill**，而是在一个 skill 内按 app 分支：

```
.agents/skills/<skill-name>/
├── SKILL.md                 # 通用流程 + 路由表 + 支持软件清单
├── scripts/
│   ├── precheck.sh          # --app <app>，按 app 加专属检查项
│   ├── install_<app1>.sh    # 每个软件一个安装脚本
│   ├── install_<app2>.sh
│   ├── init_admin.sh        # --app <app>，凭据获取方式不同
│   └── verify.sh            # --app <app>，自检项不同
└── references/
    ├── <app1>.md            # 每个软件一个专有文档（坑位、配置项、官方链接）
    ├── <app2>.md
    ├── 故障排查.md          # 通用排障 + 各软件专属小节
    ├── 运维速查.md
    └── 离线安装.md
```

> 上游没有容器方案时（如 CyberStrikeAI 只提供 `run.sh` 源码构建），就用上游唯一官方路径，
> 并在参考文档里说明"这是官方方案，不是跳过 Docker 的降级"。

**新增一个软件只需要动三处**：

1. `references/<app>.md`：专有细节、官方安装方式、配置项、专属排障；
2. `scripts/install_<app>.sh`：把官方安装命令写进脚本并注明出处；
3. `SKILL.md` 的"支持的软件"表加一行 + `precheck.sh` / `init_admin.sh` / `verify.sh` 里加该 app 的分支。

## 命名

- 目录名、frontmatter `name` 必须一致，小写字母 + 连字符，如 `self-hosted-deploy`。
- 描述（`description`）必须写清 **做什么 + 什么时候用**，并把各软件的触发词都列进去，否则模型无法正确路由。
- 一个 skill 管多软件时，name 用**能力名**（`self-hosted-deploy`）而不是某个软件名（`safeline-waf-install`）。

## SKILL.md 写法

```markdown
---
name: <name>
description: <做什么>。当用户提到 <触发词1>、"<触发词2>"、需要 <场景> 时使用。
compatibility: <运行环境要求>
metadata:
  version: 1.0.0
  upstream_doc: <官方文档地址>
  supported_apps: [app1, app2]
---

# 标题

## 支持的软件
（表格：软件 → 触发词 → 专有细节文档）

## 请求路由表（先查这里，决定做到哪一步就停）
（用户要做哪件事 → 执行到第几步 → 不要做什么）

## 1. 前置检查
bash scripts/precheck.sh --app <app>
## 2. 依赖准备
## 3. 安装
bash scripts/install_<app>.sh
## 4. 初始化
bash scripts/init_admin.sh --app <app>
## 5. 自检
bash scripts/verify.sh --app <app>
## 6. 交付说明
## 安全约束
```

**SKILL.md 只放通用流程**，软件的专有细节（配置项、坑位、命令清单）下沉到 `references/<app>.md`，正文控制在 200 行内。

## 脚本规范

1. **shebang** `#!/usr/bin/env bash`，开头 `set -uo pipefail`。
2. **只读脚本绝不能改动系统**，`precheck.sh` / `check_env.sh` 只做检查。
3. **退出码语义化**，`check_env.sh` 用 `0/10/11/12`，`precheck.sh` 用 `0/20/21/10`，
   脚本顶部注释里写清楚。
4. **幂等**：安装脚本先检查、再安装，已安装则跳过（`--force` 可强制重跑）。
5. **优先用官方安装方式**，不要自己造轮子；把官方命令写进脚本并注明出处与文档链接。
6. **输出分两段**：人类可读报告 + `KEY=VALUE` 机器可读段，方便上层 skill 解析。
7. **不记录敏感信息**：密码、token 绝不写入文件，只在终端打印一次。
8. **参数化**：多软件 skill 的公共脚本用 `--app <name>` 分支，未知值要报错退出而不是静默走默认分支。

## 安装方式优先级（Docker 优先）

写安装脚本时按这个顺序选方案，不要跳级：

1. **官方 Docker / Compose 部署**（首选）
2. **官方提供的容器镜像**
3. 官方预编译二进制 / 安装包（仅 1/2 不可行时）
4. 源码编译（最后兜底）

**降级前先尝试解决前置条件**：内存不够 → 加内存或加 swap；缺工具 → 先装；端口冲突 → 换端口。

**Docker 优先 ≠ 每次从零构建**：多机部署时复用构建产物（`docker save`/`load` 或私有 registry + `pull`），
并在参考文档里写明构建耗时预期，让调用方知道要预留多少时间。
用了降级方案时，交付说明里必须写明「为什么没能用 Docker」以及形态差异（宿主机进程 vs 容器、
卸载/开机自启/备份方式的不同）。

## 依赖底座

任何需要 Docker 的工具：

1. 先调用 `linux-docker-env` skill 的 `check_env.sh`；
2. 退出码非 0 → 调 `install_docker.sh`（轩辕镜像一键脚本）；
3. 再回到本工具的安装流程。

## 路由表与执行边界（多软件 skill 必备）

用户只想做子项请求时（"拉镜像慢"、"忘了密码"、"够不够条件装"），**不能顺手跑完整流程**。
路由表要写清"执行到第几步就停"和"不要做什么"。

再加一条通用硬约束：**只做用户要求的动作，不多做一步**；现场状态与请求不符时按用户问的问题回答。
（这是实测踩过的坑 —— agent 在"只做评估"的请求里擅自重置了管理员口令。）

## 自检清单

新增 skill 后逐条核对：

- [ ] `SKILL.md` frontmatter 完整，`name` 与目录名一致
- [ ] 所有 `bash scripts/xxx.sh` 路径真实存在
- [ ] `precheck.sh` 不改动任何系统状态
- [ ] `verify.sh` 能独立判断成功/失败
- [ ] 多软件：每个 app 都有 `references/<app>.md` + `install_<app>.sh` + 三处 `--app` 分支
- [ ] 故障排查文档覆盖：拉镜像失败、端口冲突、忘记密码、访问不通
- [ ] 没有硬编码密码/token

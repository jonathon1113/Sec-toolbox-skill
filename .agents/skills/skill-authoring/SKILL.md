---
name: skill-authoring
description: 在本仓库中新增一个"Linux 安全工具/环境部署"skill 的标准流程与规范。当用户要求"再加一个 XX 工具的部署 skill"、"照着雷池写一个新的"、"新建 skill 模板"时使用。规定了目录结构、SKILL.md frontmatter 写法、检查-安装-自检三段式脚本规范、引用文档规范。
metadata:
  version: 1.0.0
---

# 新增部署类 skill 的规范

本仓库的每个 skill 都遵循同一套模式：**前置检查 → 安装 → 初始化 → 自检 → 交付说明**。

## 目录结构

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

## 命名

- 目录名、frontmatter `name` 必须一致，小写字母 + 连字符，如 `safeline-waf-install`。
- 描述（`description`）必须写清 **做什么 + 什么时候用**，否则模型无法正确路由。

## SKILL.md 写法

```markdown
---
name: <name>
description: <做什么>。当用户提到 <触发词1>、"<触发词2>"、需要 <场景> 时使用。
compatibility: <运行环境要求>
metadata:
  version: 1.0.0
  upstream_doc: <官方文档地址>
---

# 标题

<官方文档链接>

## 整体流程
（用流程图列出步骤）

## 1. 前置检查
bash scripts/precheck.sh
（列出校验项表格）

## 2. 依赖检查
（若依赖 Docker，指向 linux-docker-env skill）

## 3. 安装
bash scripts/install_<tool>.sh

## 4. 初始化
## 5. 自检
## 6. 交付说明
## 安全约束
```

## 脚本规范

1. **shebang** `#!/usr/bin/env bash`，开头 `set -uo pipefail`。
2. **只读脚本绝不能改动系统**，`precheck.sh` / `check_env.sh` 只做检查。
3. **退出码语义化**，`check_env.sh` 用 `0/10/11/12`，`precheck.sh` 用 `0/20/21/10`，
   脚本顶部注释里写清楚。
4. **幂等**：安装脚本先检查、再安装，已安装则跳过（`--force` 可强制重跑）。
5. **优先用官方安装方式**，不要自己造轮子；把官方命令写进脚本并注明出处。
6. **输出分两段**：人类可读报告 + `KEY=VALUE` 机器可读段，方便上层 skill 解析。
7. **不记录敏感信息**：密码、token 绝不写入文件，只在终端打印一次。

## 依赖底座

任何需要 Docker 的工具：

1. 先调用 `linux-docker-env` skill 的 `check_env.sh`；
2. 退出码非 0 → 调 `install_docker.sh`（轩辕镜像一键脚本）；
3. 再回到本工具的安装流程。

## 自检清单

新增 skill 后逐条核对：

- [ ] `SKILL.md` frontmatter 完整，`name` 与目录名一致
- [ ] 所有 `bash scripts/xxx.sh` 路径真实存在
- [ ] `precheck.sh` 不改动任何系统状态
- [ ] `verify.sh` 能独立判断成功/失败
- [ ] 故障排查文档覆盖：拉镜像失败、端口冲突、忘记密码、访问不通
- [ ] 没有硬编码密码/token

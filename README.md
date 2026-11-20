# Skills 总仓库

一个用于**在 Linux 上部署安全工具 / 搭建环境**的 Agent Skill 集合。目标是把"官方文档里的坑"沉淀成可复用、可执行的脚本，让每次部署都不走弯路。

## 目录结构

```
.
├── .agents/skills/               # 所有 skill（pi / Claude Code 等遵循 Agent Skills 规范的 Agent 均可发现）
│   ├── linux-docker-env/         # 容器底座：检查/安装 Docker + Compose
│   ├── safeline-waf-install/     # 雷池 SafeLine CE WAF 部署
│   └── skill-authoring/          # 新增 skill 的规范
├── templates/skill-template/     # 复制即用的新 skill 骨架
├── AGENTS.md
└── README.md
```

## 现有 skill

| Skill | 作用 | 触发场景 |
|---|---|---|
| `linux-docker-env` | 检查并安装 Docker / Docker Compose，配置国内镜像加速 | 搭建容器环境、"docker not found"、拉镜像超时 |
| `safeline-waf-install` | 雷池 SafeLine 社区版 WAF 全流程部署 | 装雷池、部署 WAF、反代防护网站、重置管理员密码 |
| `skill-authoring` | 新增部署类 skill 的规范 | "再加一个 XX 工具的部署 skill" |

## 核心思路

每个部署类 skill 都遵循同一套模式：

```
前置检查（只读） → 依赖检查（Docker） → 安装（官方方式） → 初始化 → 自检 → 交付说明
```

关键约束：

1. **先检查再动手** — 检查脚本绝不修改系统状态；
2. **依赖复用底座** — 需要 Docker 的工具统一走 `linux-docker-env`，不重复造轮子；
3. **只用官方安装方式** — 官方命令写进脚本并注明出处；
4. **脚本可被机器解析** — 输出人类可读报告 + `KEY=VALUE` 段，退出码语义化；
5. **敏感信息不落盘** — 密码/token 只在终端打印一次。

## 使用方式

### 在 pi 中使用

把仓库克隆到任意位置，然后把 skill 目录暴露给 pi：

```bash
# 项目级（当前仓库内直接生效）
# .agents/skills/ 会被自动发现

# 或用户级（全局生效）
mkdir -p ~/.agents/skills
cp -r .agents/skills/* ~/.agents/skills/
```

之后在 pi 里：

```
/skill:safeline-waf-install
```

或直接描述需求（"帮我在这台服务器上装雷池 WAF"），模型会自动加载对应 skill。

### 手动使用脚本

所有脚本都可以脱离 Agent 直接跑：

```bash
bash .agents/skills/safeline-waf-install/scripts/precheck.sh
bash .agents/skills/linux-docker-env/scripts/check_env.sh
```

## 新增一个工具

```bash
cp -r templates/skill-template .agents/skills/<new-skill>
```

然后按 `.agents/skills/skill-authoring/SKILL.md` 的规范填写。

## 已验证的上游资料

| 用途 | 地址 |
|---|---|
| 雷池免费安装（官方） | https://help.waf-ce.chaitin.cn/node/01973fc6-df0f-7650-bafa-8ed8d2fc2bc1 |
| 雷池离线安装 | https://help.waf-ce.chaitin.cn/node/01973fc6-e046-7489-bcd7-7b1554393895 |
| 雷池版本升级 | https://help.waf-ce.chaitin.cn/node/0197400a-369e-78dd-93a7-f087d9a962f7 |
| 雷池添加应用 | https://help.waf-ce.chaitin.cn/node/01973fc6-e14a-7234-8acd-bdba21c8b3f3 |
| 雷池常见问题排查 | https://help.waf-ce.chaitin.cn/node/01975855-cd7b-78fb-a354-d2aa65a53cce |
| 轩辕镜像 Docker 一键安装 | https://xuanyuan.cloud/install/linux |

> 官方文档会更新。使用前建议核对上游链接的最新内容，skill 内脚本中的命令以官方为准。

## License

MIT

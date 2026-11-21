---
name: self-hosted-deploy
description: 在 Linux 主机上部署自托管服务与安全工具（长亭雷池 SafeLine WAF、ARTEX AI 渗透测试平台等 Docker 化开源软件）。当用户提到"装雷池"、"部署 WAF"、"SafeLine"、"装 ARTEX"、"AI 渗透测试平台"、"在这台机器上部署 XX 服务"、或需要安装某个开源安全工具时使用。先检查 Docker 与硬件条件，再按该软件的官方方式安装，并完成初始化与自检。
compatibility: Linux (x86_64/arm64)，多数部署需要 root 权限、Docker + Compose v2、可访问 GitHub 与镜像仓库
metadata:
  version: 2.0.0
  supported_apps: [safeline, artex]
---

# Linux 自托管服务 / 安全工具部署

## 支持的软件

| 软件 | 触发词 | 专有细节 |
|---|---|---|
| **长亭雷池 SafeLine CE** | 装雷池 / 部署 WAF / SafeLine / 下一代 WAF / 反代防护 | `references/safeline.md` |
| **ARTEX**（AI 自主渗透测试系统） | 装 ARTEX / AI 渗透测试平台 / 自动化渗透 / 红队平台 | `references/artex.md` |

**装新软件时**：先读该软件的官方 README，把安装命令写进 `scripts/install_<app>.sh`、把专有坑位写进 `references/<app>.md`，然后在上表加一行、在 `scripts/precheck.sh` 与 `scripts/verify.sh` 里加上它的专属检查项。不要凭印象写安装命令。

## 请求路由表（先查这里，决定做到哪一步就停）

| 用户请求 | 执行到 | 不要做 |
|---|---|---|
| 装 XX 服务 / 部署 XX | 全部步骤 | — |
| 环境够不够装 XX | 只做第 1 步 | 不安装、不初始化、不改配置 |
| 忘了密码 / 重置凭据 | 只做第 4 步 | 不重装 |
| 拉镜像慢 / 换镜像源 | 只做第 2.5 步 | 不重装服务 |
| 卸载 / 清干净重装 | 只做第 5 步 | 删数据前必须确认 |

> 已装过的环境遇到子项请求时，不要重装服务。例：用户说"雷池拉镜像慢"，若主机上已有雷池容器，只换镜像源并验证，不重跑安装脚本。

> **只做用户要求的动作，不多做一步。** 用户没说"安装 / 重置密码 / 重启 / 改配置 / 卸载"时，只做只读检查并直接回答问题，不执行任何会改变目标主机状态的操作。现场状态与请求不符时（服务已装好，但用户问的是"够不够条件装"），按用户问的问题回答，不要顺手做别的。

## 第 1 步：前置检查（只读）

```bash
bash scripts/precheck.sh --app <app> [--docker]
```

`--app` 取 `safeline` / `artex`。退出码：`0` 通过 / `20` 硬件或依赖不满足 / `21` 端口冲突 / `10` Docker 未就绪。

通用项：系统架构、内存、磁盘、git、curl、Docker + Compose v2。
`--docker` 才会真正连 Docker daemon 探活。

**内存不足不阻断但必须报告**：装完运行时内存不够会 OOM；有 swap 就继续并提示用户加内存。

## 第 2 步：依赖准备

Docker 缺失或 Compose 不存在 → 用 `linux-docker-env` skill 处理（先 `check_env.sh`，再 `install_docker.sh`），不要自己另写一套。

## 第 2.5 步：镜像源（只在拉镜像慢时做）

先判断是不是上游被污染：`curl -m 15 https://registry-1.docker.io/v2/` 超时多半是 DNS 污染。

**探测通过 ≠ 能拉镜像。** 存活探测（`/v2/` 返回 200）会漏掉被污染的源，必须对存活候选做一次真实 `docker pull hello-world` 复测，按实测耗时排序后再写进 `/etc/docker/daemon.json`，只留实测能拉动的源。改完必须 `systemctl restart docker` 才生效（daemon 不会热加载）。

## 第 3 步：安装

```bash
bash scripts/install_<app>.sh
```

各软件的官方安装方式不同，见对应 `references/<app>.md`。**优先官方方式，不要造轮子。**

## 第 4 步：初始化凭据

```bash
bash scripts/init_admin.sh --app <app>
```

**密码 / token 只在终端输出一次，交付时直接给用户，不写进任何文件。**

## 第 5 步：自检

```bash
bash scripts/verify.sh --app <app>
```

独立判断成功/失败，输出人类可读报告 + `KEY=VALUE` 机器可读段。

## 第 6 步：交付说明

给出：访问地址、账号、密码（一次性）、容器/服务状态、后续建议（改默认密码、加固、加内存等）。

## 安全约束

- 🔴 生产环境、有业务的机器上安装前，先与用户确认；装 Docker 会重启 daemon、打断既有容器。
- 🔴 卸载类操作（`down -v`、删数据目录）必须先确认，禁止顺手执行。
- 密码、API Key、setup token 绝不写入仓库任何文件或日志，只在终端打印一次。
- 不要为了"顺手"改用户没要求改的配置（端口、绑定地址、镜像源、鉴权策略）。
- 目标主机若已有同名服务，先报告再动手，不要直接覆盖。

## 参考

- `references/safeline.md` —— 雷池 SafeLine CE 安装细节
- `references/artex.md` —— ARTEX 安装细节
- `references/故障排查.md` —— 通用排障手册
- `references/运维速查.md` —— 日常运维命令
- `references/离线安装.md` —— 无外网 / 内网场景

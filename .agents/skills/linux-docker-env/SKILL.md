---
name: linux-docker-env
description: 检查并在 Linux 主机上安装/修复 Docker 与 Docker Compose 环境，并自动测速优选最快的镜像加速源。当用户要求搭建容器环境、部署需要 Docker 的安全工具（如雷池 WAF、AWX、蜜罐）、或反馈 "docker not found / docker compose 不存在 / 拉镜像超时 / 换镜像源" 时使用。安装走轩辕镜像（xuanyuan.cloud）一键脚本，镜像加速源实测优选而非硬编码。
compatibility: Linux (x86_64 / arm64)，需 root 或 sudo 权限
metadata:
  version: 1.2.0
  upstream: https://xuanyuan.cloud/install/linux
---

# Linux Docker 环境检查、安装与镜像加速

为其他部署类 skill 提供统一的容器底座。**任何需要 Docker 的工具部署，第一步都应先调用本 skill。**

## 核心原则

**镜像加速源不硬编码。** 公共加速源随时会限流、限速甚至下线，因此：

1. 每次都要**先测速**，再决定用哪个源；
2. 源失效时**自动切换**到实测最快的可用源；
3. 测速与切换都有独立脚本，用户随时可以手动重跑。

## 使用流程

### 1. 先检查，再决定是否安装

```bash
bash scripts/check_env.sh
```

只读脚本，不改动系统。输出人类可读报告 + `KEY=VALUE` 机器可读段。退出码：

| 退出码 | 含义 | 后续动作 |
|---|---|---|
| 0 | Docker 与 Compose 均可用 | 进入目标工具的安装步骤 |
| 10 | Docker 缺失或不可用 | 转到第 2 步安装 |
| 11 | Docker 可用但版本过低 | 转到第 2 步升级 |
| 12 | 缺少 Docker Compose 插件 | 转到第 2 步补装 |

### 2. 安装 / 修复 Docker

```bash
bash scripts/install_docker.sh
```

六个阶段（幂等，已安装则跳过）：

| 阶段 | 动作 |
|---|---|
| 1/6 | 预检查 |
| 2/6 | 确保 `python3` 可用（CentOS 7 默认只有 python2.7，很多工具强依赖） |
| 3/6 | 轩辕镜像一键安装脚本（**自动应答交互菜单**） |
| 4/6 | 确保 Docker Compose v2 可用（`install_compose.sh`） |
| 5/6 | 校验（版本、服务、拉取） |
| 6/6 | 实测优选镜像加速源 |

如果目标主机不能访问外网（离线环境），不要执行一键脚本，改走 `references/离线安装.md`。

### 3. 镜像加速源测速与切换

```bash
# 只测速，看当前排名（不修改任何东西）
bash scripts/test_mirrors.sh

# 真实拉取测速（拉 alpine manifest，更准但更慢）
bash scripts/test_mirrors.sh --full

# 当前源不可用才切（默认行为）
bash scripts/switch_mirror.sh

# 无条件切到当前最快的源
bash scripts/switch_mirror.sh --force

# 只测速并预览将要写入的内容
bash scripts/switch_mirror.sh --test

# 只检查当前配置的源是否还活着
bash scripts/configure_mirrors.sh --check
```

**测速原理**：对每个源的 `/v2/` registry 端点做 HTTP 探测（跟随重定向），返回 `200`/`401` 即视为在线；`--full` 模式进一步从**各加速源自己的 token 服务**取匿名 token 真实拉取 manifest，用实际下载速度排序。

**耗时**：快速模式约 20 秒，真实拉取模式约 60 秒。脚本内置超时（单源 8s / 总预算 60s），不会长时间卡住，可用 `--timeout` / `--budget` 调整。

**写入策略**：
- 默认只写**最快的 1 个**源（`--top N` 可改），避免多个源互相拖累；
- 写入前自动备份 `daemon.json`（带时间戳），保留其中的其它字段；
- 写入后 `systemctl restart docker` 生效，并做一次 `hello-world` 拉取验证；
- JSON 合法性用 `python3` 校验，生成非法则放弃修改。

### 4. 候选镜像源清单

| 镜像源 | 说明 |
|---|---|
| `https://docker.1ms.run` | 首选，速度快 |
| `https://hub.rat.dev` | 速度快（会 302 到真实源） |
| `https://ccr.ccs.tencentyun.com` | 腾讯云，速度快 |
| `https://docker.1panel.live` | 速度较慢但可用 |
| `https://docker.shootchat.top` | 可加载但较慢 |
| `https://docker.xuanyuan.me` | 免费，但有限流限速，偶尔不可用 |
| `https://xuanyuan.me` | 轩辕站点，通常不作为 registry 使用 |

清单可在 `scripts/test_mirrors.sh` 的 `DEFAULT_MIRRORS` 中增删，也可用 `--extra <url>` 临时追加、用 `--mirror <url>` 单独测试。

## 最低要求

- Docker ≥ 20.10.14
- Docker Compose ≥ 2.0.0（`docker compose` 子命令形式）
- 1 核 CPU / 2 GB 内存 / 5 GB 磁盘（仅为 Docker 本身）

## 脚本一览

| 脚本 | 作用 |
|---|---|
| `check_env.sh` | 只读体检（系统/CPU/内存/磁盘/Docker/Compose/镜像源） |
| `install_docker.sh` | 一键装齐 Docker + python3 + Compose，并优选镜像源 |
| `install_compose.sh` | 单独安装 Compose v2（包管理器 → 国内 RPM → 静态二进制，含段错误降级） |
| `test_mirrors.sh` | 镜像源测速排序（快速 / 真实拉取两种模式） |
| `configure_mirrors.sh` | 把最优源写入 `daemon.json`（备份+校验+重启+验证） |
| `switch_mirror.sh` | 换源快捷入口（失效才切 / `--force` 无条件切） |
| `pty_runner.py` | 伪终端应答器（轩辕脚本是交互式的，直接跑会死循环） |

## 注意事项

- 一键安装脚本会写入 `/etc/docker/daemon.json` 并重启 docker 服务，**会中断该主机上正在运行的容器**。生产环境请先确认影响。
- 修改 `registry-mirrors` 同样需要重启 Docker，同样会中断容器。
- 轩辕脚本是**交互式**的，主菜单需要选 `1`。本 skill 用 `pty_runner.py` 分配伪终端自动应答；若机器没有 python3，则退化为 `yes 1 |` 管道喂入。
- 脚本支持 Ubuntu/Debian/CentOS/RHEL/Rocky/Alma/Fedora/openEuler/Anolis/UOS/麒麟/Deepin/openSUSE 等 19 种发行版；**CentOS 7 走归档源**，安装较慢。
- **Compose 版本坑**：v2.29+ 在部分老 CPU（如 QEMU 2.5+ 虚拟 CPU）上会 Segmentation fault，`install_compose.sh` 会实测验证并自动降级到 v2.24.6。
- 全部操作需要 root 或可用的 sudo；脚本内已做 sudo 探测。

## 参考资料

- 轩辕镜像 Docker 一键安装教程：https://xuanyuan.cloud/install/linux
- 镜像源与切换：见 `references/镜像加速源.md`

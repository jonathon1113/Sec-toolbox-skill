---
name: linux-docker-env
description: 检查并在 Linux 主机上安装/修复 Docker 与 Docker Compose 环境。当用户要求搭建容器环境、部署需要 Docker 的安全工具（如雷池 WAF、AWX、蜜罐）、或反馈 "docker not found / docker compose 不存在 / 拉镜像超时" 时使用。优先调用轩辕镜像（xuanyuan.cloud）一键脚本完成 Docker 安装与镜像加速配置。
compatibility: Linux (x86_64 / arm64)，需 root 或 sudo 权限
metadata:
  version: 1.0.0
  upstream: https://xuanyuan.cloud/install/linux
---

# Linux Docker 环境检查与安装

为其他部署类 skill 提供统一的容器底座。**任何需要 Docker 的工具部署，第一步都应先调用本 skill。**

## 使用流程

### 1. 先检查，再决定是否安装

```bash
bash scripts/check_env.sh
```

该脚本只读、不改动系统，输出人类可读报告 + 机器可读的 `KEY=VALUE` 行。退出码：

| 退出码 | 含义 | 后续动作 |
|---|---|---|
| 0 | Docker 与 Compose 均可用 | 直接进入目标工具的安装步骤 |
| 10 | Docker 缺失或不可用 | 转到第 2 步安装 |
| 11 | Docker 可用但版本过低 | 转到第 2 步升级 |
| 12 | 缺少 Docker Compose 插件 | 转到第 2 步补装 |

### 2. 安装 / 修复 Docker

```bash
bash scripts/install_docker.sh
```

脚本内部逻辑：

1. 再次确认环境（幂等，已安装则跳过）；
2. 用官方一键脚本安装，自动配置轩辕镜像加速源：
   - 主源：`https://get.xuanyuan.cloud/docker.sh`
   - 备用源：`https://get.xuanyuan.me/docker.sh`
3. 安装完成后**重新执行 `check_env.sh` 验证**，只有校验通过才算成功。

如果目标主机不能访问外网（离线环境），不要执行一键脚本，改为在有网机器上下载 RPM/DEB/tar 包后离线导入，参考 `references/离线安装.md`。

### 3. 校验镜像加速是否生效

```bash
bash scripts/check_env.sh --registry
```

会打印 `/etc/docker/daemon.json` 中的 `registry-mirrors` 并做一次拉取测试。

## 最低要求

- Docker ≥ 20.10.14
- Docker Compose ≥ 2.0.0（`docker compose` 子命令形式）
- 1 核 CPU / 2 GB 内存 / 5 GB 磁盘（仅为 Docker 本身）

## 注意事项

- 一键安装脚本会写入 `/etc/docker/daemon.json` 并重启 docker 服务，**会中断该主机上正在运行的容器**。生产环境请先确认影响。
- 脚本支持 Ubuntu/Debian/CentOS/RHEL/Rocky/Alma/Fedora/openEuler/Anolis/UOS/麒麟/Deepin/openSUSE 等 19 种发行版；**不支持 CentOS 7**。
- 全部操作需要 root 或可用的 sudo；脚本内已做 sudo 探测。

## 参考资料

- 轩辕镜像 Docker 一键安装教程：https://xuanyuan.cloud/install/linux

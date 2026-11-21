# 长亭雷池 SafeLine CE 安装

官方文档：<https://help.waf-ce.chaitin.cn/node/01973fc6-df0f-7650-bafa-8ed8d2fc2bc1>
社区版安装脚本：`https://waf-ce.chaitin.cn/release/latest/manager.sh`

## 整体流程

```
0. 确认目标主机信息（IP、架构、是否为生产）
1. 前置检查：架构 / CPU 指令集 / 内存磁盘 / 端口占用
2. Docker 环境检查  →  缺失则安装（linux-docker-env skill）
3. 执行官方一键安装脚本（需 TTY）
4. 初始化管理员账号
5. 自检：容器状态 / 9443 端口 / 控制台可访问
6. 输出交付说明（控制台地址、端口、防火墙放行提示）
```

## 1. 前置检查

```bash
bash scripts/precheck.sh --app safeline
```

| 项 | 要求 | 不满足时 |
|---|---|---|
| 操作系统 | Linux | 中止 |
| 架构 | x86_64（**必须支持 ssse3**，推荐 avx2）或 arm64 | 中止 |
| 内存 | ≥ 2 GB | 不足：报告并继续（有 swap 时），提示用户加内存 |
| 磁盘 | ≥ 5 GB 可用 | 中止 |
| 端口 | 9443 未被占用（控制台默认端口） | 中止，先查占用方 |

avx2 缺失不阻断，只是检测引擎吞吐下降。

## 2. Docker 环境检查

```bash
bash scripts/precheck.sh --app safeline --docker
```

退出码非 0 → **不要直接装雷池**，先调用 `linux-docker-env` skill 完成 Docker 安装：

```bash
bash <linux-docker-env>/scripts/install_docker.sh
```

装完再回到第 3 步。

## 3. 安装雷池

```bash
bash scripts/install_safeline.sh
```

脚本执行官方一键安装命令：

```bash
bash -c "$(curl -fsSLk https://waf-ce.chaitin.cn/release/latest/manager.sh)"
```

> ⚠️ **关键**：官方 `manager.py` 要求 **STDIN 是标准 TTY**，否则报 `运行脚本的方式不对, STDIN 不是标准的 TTY` 并直接退出。
> 本 skill 自带 `scripts/pty_runner.py`，用伪终端执行并自动应答菜单（选择动作=`1`、安装目录=回车用默认 `/data/safeline`）。
> 手工执行时可用 `script -qec '...' /dev/null`。

要点：
- 需要 root；脚本会自动检查并按需安装 `python3`（CentOS 7 默认只有 python2.7，必须手动装）。
- 会自动拉取镜像并启动容器（镜像托管在华为云 SWR `swr.cn-east-3.myhuaweicloud.com/chaitin-safeline/*`，速度较快），耗时几分钟属正常。
- **安装目录默认 `/data/safeline`**（官方默认，不是 `/opt/safeline`）。
- 容器名：`safeline-mgt` / `safeline-detector` / `safeline-pg` / `safeline-tengine` / `safeline-fvm` / `safeline-luigi` / `safeline-chaos`。
- 官方脚本用 `curl` 下载自己，**目标机必须先有 curl**（Debian 最小化安装常常没有：`apt install -y curl`）。
- 离线环境请改用官方「离线安装」方案，见 `references/离线安装.md`。

## 4. 初始化管理员账号

安装完成会自动生成管理员账号密码并打印。若没找到或需要重置：

```bash
bash scripts/init_admin.sh --app safeline
```

底层命令：

```bash
docker exec safeline-mgt resetadmin
```

输出：

```
[SafeLine] Initial username：admin
[SafeLine] Initial password：**********
[SafeLine] Done
```

**密码只在此刻输出一次**，必须立刻抄给用户，不要写进任何仓库文件。
`resetadmin` 会让旧密码立即失效 —— 重置前告知用户。

## 5. 自检

```bash
bash scripts/verify.sh --app safeline
```

检查项：
- 7 个 `safeline-*` 容器均为 Up（mgt / detector / pg 为 healthy）；
- 9443 端口处于监听状态；
- `curl -k https://127.0.0.1:9443/` 返回 HTTP 200；
- `/data/safeline` 目录存在（含 docker-compose.yaml / logs / resources）。

任一项失败 → 读 `references/故障排查.md` 对应小节。

## 6. 交付说明

向用户输出：

- 控制台地址：`https://<服务器IP>:9443/`
- 账号 `admin` + 一次性密码
- 提醒放行防火墙 9443 端口（若前面挂了 Nginx/LB 则说明走 LB 的方式）
- 提醒下一步「添加应用」把站点反代进来
- 常用运维命令（见 `references/运维速查.md`）

## 已知环境坑（实测）

| 环境 | 问题 | 处理 |
|---|---|---|
| CentOS 7 | 默认只有 python2.7 | `yum install -y python3` |
| CentOS 7 | 轩辕 Docker 脚本走归档源，compose 下载可能失败 | 手动装 compose（见故障排查） |
| Debian 最小化 | 没有 curl / git | `apt install -y curl git` |
| Debian 13 | 没有 `docker-compose-v2` 包 | 装 `docker-compose`（即 v2.x） |
| 老 CPU（QEMU 2.5+） | compose v2.29.x 段错误 | 降到 v2.24.6 |
| 任意 | 镜像源探测通过但拉不动镜像 | 真实 `docker pull hello-world` 复测后排序 |
| 任意 | 官方脚本要求 TTY | 用 `pty_runner.py` / `script -qec` |
| 任意 | 改了 daemon.json 但镜像源没生效 | `systemctl restart docker`（daemon 不热加载） |
| 任意 | 内存 2GB 以下 | 运行时 OOM 风险，建议加内存（swap 只是兜底） |

# CyberStrikeAI 安装

仓库：<https://github.com/AIPentest/CyberStrikeAI>（Apache-2.0，Go + Python，前端内置）
官方文档：`docs/zh-CN/deployment.md`（中文）、`docs/en-US/deployment.md`（英文）

## 它是什么

AI 原生渗透测试平台：多 Agent 编排（recon / penetration / privilege-escalation / lateral-movement /
exfiltration / persistence 等），带 MCP 集成、审计与治理、资产与漏洞管理。
内置工具生态在 `tools/`（每个工具一个 yaml），底层调用 nmap / sqlmap / nuclei / ffuf / hydra 等。

## 安装方式说明（重要）

**上游没有提供 Dockerfile / docker-compose。** 仓库里只有 `run.sh`（源码构建 + 本地运行），
所以本 skill 走的就是**官方唯一路径**，不是"跳过 Docker 的降级"。

> 如果将来上游补了容器方案，本 skill 应改走 compose；在此之前不要自造 Dockerfile
> ——那既不是官方方式，也会让升级路径与上游分叉。

## 官方一键部署

```bash
git clone https://github.com/AIPentest/CyberStrikeAI.git
cd CyberStrikeAI
chmod +x run.sh && ./run.sh
```

`run.sh` 会自动：校验 Go/Python → 建 venv → 装 Python 依赖 → 拉 Go 依赖 → `go build` → 启动服务。

**注意它的国内镜像默认值**（实测友好，不需要代理）：

```bash
PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
GOPROXY=https://goproxy.cn,direct
```

## 前置要求

| 项 | 要求 | 不满足时 |
|---|---|---|
| Go | **1.25+**（`go.mod` 要求） | 装：官方 go.dev/dl；或 `yum install golang` / `apt install golang-go` |
| Python | **3.10+**，且带 `venv` 模块 | `yum install -y python3 python3-pip` / `apt install -y python3 python3-venv` |
| 端口 | 8080 空闲（`config.yaml` 的 `server.port`） | 先查占用方 |
| 磁盘 | ≥ 5 GB | 中止 |
| 内存 | ≥ 2 GB | 报告 |

Debian/Ubuntu 缺 venv 时：`apt install -y python3-venv`（否则 `python3 -m venv` 会失败）。

## 配置要点（config.yaml）

首次启动时二进制会**自动从 `config.example.yaml` 生成 `config.yaml`**。

```yaml
server:
  host: 0.0.0.0        # 监听所有网卡
  port: 8080
  tls_enabled: true        # 默认开 TLS
  tls_auto_self_sign: true # 自签证书（SAN 含 localhost/127.0.0.1）
auth: ...
ai:
  default_channel: openai-main
  channels:
    openai-main:
      provider: openai_compatible
      api_key: "${OPENAI_API_KEY}"
      base_url: "https://api.openai.com/v1"
      model: "gpt-4o"
```

**默认是 HTTPS（自签证书）**，浏览器首次访问要手动接受一次证书警告。
用 `http://` 访问同一端口会自动 **308 跳转到 HTTPS**。

> ⚠️ 自签证书的 SAN 只含 `localhost` / `127.0.0.1`，用**服务器 IP** 访问会证书不匹配。
> 生产环境请配 `server.tls_cert_path` / `server.tls_key_path` 换成正式证书。

### AI 渠道（必需）

不配 AI 渠道，界面能开但**任何任务都跑不了**。两种配法：

1. 启动后进 `System Settings → Basic Settings → AI Channel Configuration` 填 provider / Base URL / API key / model；
2. 直接改 `config.yaml` 的 `ai:` 段。

provider 用 `openai_compatible` 时，DeepSeek / Qwen / Kimi 等 OpenAI 兼容接口都能接（换 `base_url` 与 `model` 即可）。

## 初始化管理员

首次启动时控制台会打印一次性 admin 密码（在 `ADMIN SETUP REQUIRED` 段下）：

```
ADMIN SETUP REQUIRED
  admin password: xxxxxxxx
```

**密码只输出一次，立刻保存**（skill 约定：不写进任何文件）。

需要重置：

```bash
cd /opt/cyberstrike && ./run.sh --reset-admin-password
```

## 日常运行

`run.sh` 是**前台**运行的（最后 `exec` 到二进制），后台跑要自己 nohup 或交给 systemd：

```bash
cd /opt/cyberstrike
nohup ./run.sh > /var/log/cyberstrike.log 2>&1 &
```

开机自启用 systemd（**直接跑二进制，不要用 run.sh**，run.sh 自带构建流程不适合 systemd）：

```ini
[Service]
WorkingDirectory=/opt/cyberstrike
ExecStart=/opt/cyberstrike/cyberstrike-ai -config /opt/cyberstrike/config.yaml --https
Restart=always
RestartSec=5
```

二进制名：`run.sh` 构建产物是 `cyberstrike-ai`（仓库根目录）。

## 选装安全工具（可选）

平台自带工具编排，但底层扫描器要在系统里装好，缺了就跳过或运行时替代：

```bash
sudo apt update
sudo apt install -y nmap masscan sqlmap nikto gobuster hydra hashcat john binwalk
# ffuf / nuclei / subfinder 建议用 go install 或各自官方方式
```

完整清单见仓库 `tools/` 目录（每个工具一个 yaml）。

## 排障

| 现象 | 原因 | 处理 |
|---|---|---|
| `client sent an HTTP request to an HTTPS server` | 客户端用 http:// 连 TLS 端口 | 改用 `https://`，或启动加 `--http` |
| 浏览器证书告警 | 自签证书 | 接受一次；或换正式证书 |
| 用 IP 访问证书不匹配 | 自签 SAN 只有 localhost/127.0.0.1 | 配 `tls_cert_path`/`tls_key_path`，或用 `--http` |
| `python3 -m venv` 失败 | 缺 python3-venv | `apt install -y python3-venv` |
| go build 拉依赖超时 | GOPROXY 不通 | run.sh 默认已用 goproxy.cn；不通则 `export GOPROXY=https://goproxy.cn,direct` |
| pip 安装慢/超时 | pip 源不通 | run.sh 默认已用清华源；不通则 `export PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple` |
| 端口 8080 被占用 | 其它服务 | 改 `config.yaml` 的 `server.port` |
| 界面能开但任务不动 | 没配 AI 渠道 | 见上文「AI 渠道（必需）」 |

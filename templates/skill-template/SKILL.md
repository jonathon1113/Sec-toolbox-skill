---
name: <skill-name>
description: <一句话说明做什么>。当用户提到 <触发关键词>、需要 <具体场景> 时使用。
compatibility: <环境要求，如 Linux x86_64/arm64，需 root>
metadata:
  version: 1.0.0
  upstream_doc: <官方文档链接>
---

# <工具名> 部署

官方文档：<链接>

## 整体流程

```
1. 前置检查
2. 依赖检查（Docker）
3. 安装
4. 初始化
5. 自检
6. 交付说明
```

## 1. 前置检查

```bash
bash scripts/precheck.sh
```

| 项 | 要求 |
|---|---|
|  |  |

## 2. 依赖检查

```bash
bash scripts/precheck.sh --docker
```

退出码非 0 时，先执行 `linux-docker-env/scripts/install_docker.sh`，完成后再继续。

## 3. 安装

```bash
bash scripts/install_<tool>.sh
```

## 4. 初始化

```bash
bash scripts/init_admin.sh
```

## 5. 自检

```bash
bash scripts/verify.sh
```

## 6. 交付说明

- 访问地址：`<url>`
- 需要放行的端口：`<ports>`
- 常用运维命令：见 `references/运维速查.md`

## 安全约束

- 不要把密码/token 写入仓库文件或日志。
- 生产环境执行前先与用户确认。

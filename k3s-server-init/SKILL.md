---
name: k3s-server-init
description: >-
  通过 SSH 将远端 Linux 服务器初始化为 K3s + Flux GitOps 集群。
  部署 cert-manager (Let's Encrypt)、PostgreSQL 18 (pgVector)、pg_dump 定时备份，
  并生成本地 kubeconfig。
  触发词：服务器初始化、k3s 安装、集群部署、k3s setup、server init。
---

# K3s 服务器初始化

通过 SSH 一键将远端 Linux 服务器初始化为 **K3s + Flux GitOps** 生产集群，自动部署 cert-manager（Let's Encrypt 自动签发）、PostgreSQL 18 + pgVector、pg_dump 定时备份，并拉取 kubeconfig 供 Lens 连接。

## 环境要求

- **本地 Mac**：仅需 `ssh` + `git`（macOS 自带）。`kubectl`/`flux` 在远端执行，无需本地安装
- **远端服务器**：Linux（推荐 Ubuntu 22.04+ / Debian 12+），root 或 sudo 权限
- **开放端口**：22（SSH）、6443（K3s API）、80 / 443（HTTP/HTTPS）

## 脚本入口

```bash
bash .agents/skills/k3s-server-init/scripts/server_init.sh [OPTIONS]
```

## 参数

### 必填

| 参数 | 说明 | 示例 |
|------|------|------|
| `--host` | 服务器 IP 或域名 | `203.0.113.10` |
| `--user` | SSH 用户名 | `root` |
| `--tls-san` | K3s API Server 额外 TLS SAN（外网 IP / 域名） | `203.0.113.10` |
| `--github-owner` | GitHub 用户名或组织名 | `myuser` |
| `--github-repo` | GitOps 仓库名 | `gitops-infra` |
| `--github-token` | GitHub PAT（需 `repo` scope） | `ghp_xxx` |
| `--flux-path` | 集群目录路径（per-cluster Kustomization） | `clusters/oracle` |
| `--pg-password` | PostgreSQL 密码（含特殊字符需引号包裹） | `"MyP@ss123!"` |
| `--le-email` | Let's Encrypt 注册邮箱 | `admin@example.com` |
| `--domain` | 证书签发域名 | `example.com` |

### 可选

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--ssh-key` | `~/.ssh/id_rsa` | SSH 私钥路径 |
| `--ssh-port` | `22` | SSH 端口 |
| `--pg-db` | `appdb` | 数据库名 |
| `--pg-user` | `appuser` | 数据库用户名 |
| `--pg-storage` | `10Gi` | PVC 存储大小 |
| `--kubeconfig-output` | `~/.kube/config-<host>` | kubeconfig 输出路径 |
| `--backup-schedule` | `0 2 * * *` | pg_dump cron 表达式 |
| `--backup-retain-days` | `7` | 备份保留天数 |

## 执行流程

脚本按 8 个阶段顺序执行，每个阶段**幂等**（已完成自动跳过）：

1. **检查先决条件** — 验证本地 `ssh`/`git`，测试 SSH 连接
2. **安装 K3s** — SSH 远端安装最新稳定版，`--tls-san` 将外网 IP/域名写入 API Server TLS 证书的 SAN，使外部客户端（kubectl、Lens）可正常建立受信任连接；保留内置 Traefik + metrics-server
3. **拉取 Kubeconfig** — 复制远端 `k3s.yaml`，替换 `127.0.0.1` 为实际地址，验证连接
4. **Bootstrap Flux** — SSH 安装 Flux CLI 并执行 `flux bootstrap github`
5. **生成 Manifests** — 共享模板原样复制，仅对 `cluster-vars.yaml` 做 `sed` 注入实际值
6. **Git 推送** — 共享 base → 仓库根目录，per-cluster → `<flux-path>/`，commit + push
7. **等待 Flux 同步** — 轮询 Kustomization Ready + Pod Running，超时 10 分钟
8. **验证 & 报告** — 检查节点/Pod/Flux 状态，测试 PG + pgVector 连通性，输出总结

## GitOps 仓库结构

采用 Flux 推荐的 **共享 base + per-cluster overlay** 模式：

```
<repo>/
├── infrastructure/                     # 全局共享 base
│   ├── controllers/
│   │   ├── kustomization.yaml
│   │   └── cert-manager.yaml           # HelmRepository + HelmRelease
│   └── configs/
│       ├── kustomization.yaml
│       └── clusterissuer.yaml          # Let's Encrypt（${LE_EMAIL}）
├── apps/                               # 全局共享 base
│   └── database/
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       ├── pg-secret.yaml              # ${POSTGRES_*}
│       ├── postgresql.yaml             # ${PG_STORAGE}
│       └── pg-backup-cronjob.yaml      # ${BACKUP_*}
└── clusters/
    └── <vendor>/                       # Per-cluster overlay（脚本生成）
        ├── flux-system/                # Flux bootstrap 自动生成
        ├── infrastructure.yaml         # Kustomization → ../../infrastructure/controllers
        ├── infrastructure-configs.yaml # Kustomization + postBuild
        ├── apps.yaml                   # Kustomization + postBuild
        └── cluster-vars.yaml           # Secret：所有 ${VAR} 的实际值
```

> 新增服务器只需用不同 `--flux-path`（如 `clusters/aws`）再次运行脚本。

### 变量替换

模板中的 `${VAR}` **不在脚本阶段替换**，由 Flux `postBuild.substituteFrom` 在 apply 时从 `cluster-vars` Secret 注入：

| 变量 | 来源参数 | 用于 |
|------|----------|------|
| `${POSTGRES_DB}` | `--pg-db` | pg-secret.yaml |
| `${POSTGRES_USER}` | `--pg-user` | pg-secret.yaml |
| `${POSTGRES_PASSWORD}` | `--pg-password` | pg-secret.yaml |
| `${PG_STORAGE}` | `--pg-storage` | postgresql.yaml |
| `${BACKUP_SCHEDULE}` | `--backup-schedule` | pg-backup-cronjob.yaml |
| `${BACKUP_RETAIN_DAYS}` | `--backup-retain-days` | pg-backup-cronjob.yaml |
| `${LE_EMAIL}` | `--le-email` | clusterissuer.yaml |
| `${DOMAIN}` | `--domain` | 预留给 Ingress/Certificate |

## 故障排查

| 现象 | 排查方向 |
|------|----------|
| Flux bootstrap 失败 | 确认 PAT 拥有 `repo` scope |
| kubectl / Lens 连接超时 | 检查防火墙 6443 端口 |
| kubectl 证书错误 | 确认 `--tls-san` 与实际连接地址一致 |
| PG 密码解析异常 | 用引号包裹：`--pg-password "MyP@ss!"` |

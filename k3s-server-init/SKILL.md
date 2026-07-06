---
name: k3s-server-init
description: >-
  通过 SSH 将远端 Linux 服务器初始化为 K3s + Flux GitOps 集群。
  部署 cert-manager (Let's Encrypt)、PostgreSQL 18 (pgVector)、pg_dump 定时备份，
  并生成本地 kubeconfig。
  触发词：服务器初始化、k3s 安装、集群部署、k3s setup、server init。
---

# K3s 服务器初始化

通过 SSH 将远端 Linux 服务器初始化为 **K3s + Flux GitOps** 生产集群。

**部署组件**：K3s（含 Traefik + metrics-server）、Flux CD、cert-manager（Let's Encrypt 自动签发）、PostgreSQL 18 + pgVector、pg_dump 定时备份。

---

## 1. 执行入口

```bash
bash .agents/skills/k3s-server-init/scripts/server_init.sh [OPTIONS]
```

> 脚本位于 `scripts/server_init.sh`，模板文件位于 `resources/manifests/`。
> AI 执行时**直接调用脚本**，无需手动操作中间步骤。

---

## 2. 环境要求

| 条件 | 要求 |
|------|------|
| **本地** | macOS，仅需 `ssh` + `git`（系统自带）。`kubectl` / `flux` 仅在远端执行，无需本地安装 |
| **远端** | Linux（Ubuntu 22.04+ / Debian 12+ 推荐），root 或 sudo 权限 |
| **端口** | 22（SSH）、6443（K3s API）、80 / 443（HTTP/HTTPS） |

---

## 3. 参数说明

### 3.1 必填参数

| 参数 | 说明 | 示例 |
|------|------|------|
| `--host` | 服务器 IP 或域名 | `203.0.113.10` |
| `--user` | SSH 用户名 | `root` |
| `--tls-san` | K3s API Server 的额外 TLS SAN（外网 IP 或域名），供 kubectl / Lens 远程连接 | `203.0.113.10` |
| `--github-owner` | GitHub 用户名或组织名 | `myuser` |
| `--github-repo` | GitOps 仓库名 | `gitops-infra` |
| `--github-token` | GitHub PAT（需 `repo` scope） | `ghp_xxx` |
| `--flux-path` | 集群目录路径（per-cluster Kustomization） | `clusters/oracle` |
| `--pg-password` | PostgreSQL 密码（含特殊字符需**引号包裹**） | `"MyP@ss123!"` |
| `--le-email` | Let's Encrypt 注册邮箱 | `admin@example.com` |
| `--domain` | 证书签发域名 | `example.com` |

### 3.2 可选参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--ssh-key` | `~/.ssh/id_rsa` | SSH 私钥路径 |
| `--ssh-port` | `22` | SSH 端口 |
| `--pg-db` | `appdb` | 数据库名 |
| `--pg-user` | `appuser` | 数据库用户名 |
| `--pg-storage` | `10Gi` | PVC 存储大小 |
| `--kubeconfig-output` | `~/.kube/config-<host>` | kubeconfig 输出路径 |
| `--backup-schedule` | `0 2 * * *` | pg_dump cron 表达式（UTC） |
| `--backup-retain-days` | `7` | 备份保留天数 |

---

## 4. 执行流程（8 阶段，均幂等）

脚本按以下 8 个阶段**顺序执行**，每个阶段已完成时自动跳过：

| 阶段 | 名称 | 动作 |
|:----:|------|------|
| 1 | 检查先决条件 | 验证本地 `ssh`/`git`，测试 SSH 连通性 |
| 2 | 安装 K3s | SSH 远端安装最新稳定版，`--tls-san` 写入 API Server TLS 证书 SAN；已安装则跳过，仅确保服务运行并配置防火墙 |
| 3 | 拉取 Kubeconfig | 复制远端 `k3s.yaml`，替换 `127.0.0.1` → 实际 TLS SAN 地址，验证连接 |
| 4 | Bootstrap Flux | SSH 安装 Flux CLI 并执行 `flux bootstrap github`；已安装则跳过 |
| 5 | 生成 Manifests | 共享模板原样复制，仅对 `cluster-vars.yaml` 做 `sed` 注入实际参数值 |
| 6 | Git 推送 | 共享 base → 仓库根目录，per-cluster → `<flux-path>/`，commit + push |
| 7 | 等待 Flux 同步 | 轮询 Kustomization Ready，超时 10 分钟；检测到 Failed/Stalled 立即退出并输出诊断信息 |
| 8 | 验证与报告 | 检查节点/Pod/Flux 状态，测试 PG + pgVector 连通性，输出总结 |

---

## 5. GitOps 仓库结构

采用 Flux 推荐的 **共享 base + per-cluster overlay** 模式：

```
<repo>/
├── infrastructure/                     # 共享 base（脚本原样复制）
│   ├── controllers/
│   │   ├── kustomization.yaml
│   │   └── cert-manager.yaml           # HelmRepository + HelmRelease
│   └── configs/
│       ├── kustomization.yaml
│       └── clusterissuer.yaml          # Let's Encrypt（${LE_EMAIL}）
├── apps/                               # 共享 base（脚本原样复制）
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

> **扩展新集群**：用不同 `--flux-path`（如 `clusters/aws`）再次运行脚本即可。

### 5.1 变量替换机制

模板中的 `${VAR}` **不在脚本阶段替换**。Flux 通过 `postBuild.substituteFrom` 在 apply 时从 `cluster-vars` Secret 注入：

| 变量 | 来源参数 | 用于 |
|------|----------|------|
| `${POSTGRES_DB}` | `--pg-db` | pg-secret.yaml |
| `${POSTGRES_USER}` | `--pg-user` | pg-secret.yaml |
| `${POSTGRES_PASSWORD}` | `--pg-password` | pg-secret.yaml |
| `${PG_STORAGE}` | `--pg-storage` | postgresql.yaml |
| `${BACKUP_SCHEDULE}` | `--backup-schedule` | pg-backup-cronjob.yaml |
| `${BACKUP_RETAIN_DAYS}` | `--backup-retain-days` | pg-backup-cronjob.yaml |
| `${LE_EMAIL}` | `--le-email` | clusterissuer.yaml |
| `${DOMAIN}` | `--domain` | 预留给 Ingress / Certificate |

---

## 6. 备份策略

| 项目 | 说明 |
|------|------|
| 存储路径 | 服务器本地 `/opt/pg-backups`（hostPath 卷） |
| 不使用独立 PVC | 避免 `local-path` StorageClass 的 `WaitForFirstConsumer` 延迟绑定导致 Flux 健康检查超时 |
| 保留策略 | 默认 7 天，通过 `--backup-retain-days` 调整 |

---

## 7. 故障排查

| 现象 | 原因与解决 |
|------|------------|
| Flux bootstrap 失败 | 确认 GitHub PAT 拥有 `repo` scope；检查仓库是否存在 |
| kubectl / Lens 连接超时 | 检查防火墙 6443 端口是否放通；确认云平台安全组规则 |
| kubectl 证书错误 | 确认 `--tls-san` 与实际连接地址一致 |
| PG 密码解析异常 | 用引号包裹：`--pg-password "MyP@ss!"` |
| PG18 CrashLoopBackOff，日志提示 mount/volume 冲突 | PG18+ 要求 `mountPath: /var/lib/postgresql`（父目录），不能用 `/var/lib/postgresql/data` + `subPath`。参考 [docker-library/postgres#1259](https://github.com/docker-library/postgres/pull/1259) |
| Flux Kustomization 长期 Reconciling / Unknown | 检查是否有 PVC 处于 Pending 状态（`kubectl get pvc -A`）。`local-path` 的 `WaitForFirstConsumer` 要求有 Pod 挂载后才绑定 |
| Flux 变量替换后纯数字值报类型错误 | 模板中 `${VAR}` 用双引号包裹（如 `"${POSTGRES_PASSWORD}"`），否则 `1234` 会被 YAML 解析为整数 |

---

## 8. AI 执行指南

### 8.1 收集参数

在执行脚本前，向用户收集以下必填信息：

1. 服务器 IP（`--host`）和 SSH 用户名（`--user`）
2. 外网连接地址（`--tls-san`），通常与 `--host` 相同
3. GitHub 仓库信息：owner、repo name、PAT
4. `--flux-path`：集群在仓库中的目录，如 `clusters/oracle`
5. PostgreSQL 密码
6. Let's Encrypt 邮箱和域名

> 可选参数仅在用户主动提供时才传入，否则使用默认值。

### 8.2 构造命令

```bash
bash .agents/skills/k3s-server-init/scripts/server_init.sh \
  --host <IP> \
  --user <USER> \
  --tls-san <IP> \
  --github-owner <OWNER> \
  --github-repo <REPO> \
  --github-token <TOKEN> \
  --flux-path <PATH> \
  --pg-password "<PASSWORD>" \
  --le-email <EMAIL> \
  --domain <DOMAIN>
```

### 8.3 执行与监控

1. 使用 `run_command` 执行脚本，设置较大的 `WaitMsBeforeAsync`（如 `500`）后转入后台
2. 脚本总耗时约 5–15 分钟（取决于网络和服务器性能）
3. 脚本会输出彩色日志标注每个阶段的进度
4. 执行完成后，向用户报告：
   - kubeconfig 路径（`~/.kube/config-<host>`）
   - Lens 连接方式
   - GitOps 仓库地址
   - 常用 SSH 管理命令

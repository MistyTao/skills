#!/usr/bin/env bash
# =============================================================================
# K3s Server Init — 远端服务器一键初始化脚本
#
# 通过 SSH 安装 K3s + Flux CD，然后将所有工作负载 manifest 推送到 GitHub，
# 由 Flux 自动同步部署。
#
# 用法: bash server_init.sh --host <IP> --user <USER> --tls-san <IP> \
#         --github-owner <OWNER> --github-repo <REPO> --github-token <TOKEN> \
#         --flux-path <PATH> --pg-password <PASS> --le-email <EMAIL> --domain <DOMAIN>
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Colors & Logging
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2; }

step() {
  echo ""
  echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Phase $1: $2${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
  echo ""
}

# ---------------------------------------------------------------------------
# Default Values
# ---------------------------------------------------------------------------
SSH_KEY="${HOME}/.ssh/id_rsa"
SSH_PORT=22
PG_DB="appdb"
PG_USER="appuser"
PG_STORAGE="10Gi"
BACKUP_SCHEDULE="0 2 * * *"
BACKUP_RETAIN_DAYS=7
KUBECONFIG_OUTPUT=""

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Initialize a remote server with K3s + Flux GitOps stack.

Required:
  --host              Remote server IP or hostname
  --user              SSH username
  --tls-san           K3s API Server TLS SAN (external IP or domain)
  --github-owner      GitHub username or organization
  --github-repo       GitHub repository name
  --github-token      GitHub Personal Access Token (repo scope)
  --flux-path         Per-cluster path in repo (e.g., clusters/oracle)
  --pg-password       PostgreSQL password
  --le-email          Let's Encrypt registration email
  --domain            Domain name for cert-manager

Optional:
  --ssh-key           SSH private key path          (default: ~/.ssh/id_rsa)
  --ssh-port          SSH port                      (default: 22)
  --pg-db             PostgreSQL database name      (default: appdb)
  --pg-user           PostgreSQL username            (default: appuser)
  --pg-storage        PostgreSQL PVC storage size    (default: 10Gi)
  --kubeconfig-output Kubeconfig output path         (default: ~/.kube/config-<host>)
  --backup-schedule   pg_dump cron schedule          (default: "0 2 * * *")
  --backup-retain-days Backup retention days         (default: 7)
  --help              Show this help message

Example:
  $(basename "$0") \\
    --host 203.0.113.10 --user root --tls-san 203.0.113.10 \\
    --github-owner myuser --github-repo gitops-infra --github-token ghp_xxx \\
    --flux-path clusters/oracle --pg-password "MySecurePass!" \\
    --le-email admin@example.com --domain example.com
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Parse Arguments
# ---------------------------------------------------------------------------
parse_args() {
  [[ $# -eq 0 ]] && usage
  while [[ $# -gt 0 ]]; do
    case $1 in
      --host)               HOST="$2";               shift 2;;
      --user)               SSH_USER="$2";            shift 2;;
      --ssh-key)            SSH_KEY="$2";             shift 2;;
      --ssh-port)           SSH_PORT="$2";            shift 2;;
      --tls-san)            TLS_SAN="$2";             shift 2;;
      --github-owner)       GITHUB_OWNER="$2";        shift 2;;
      --github-repo)        GITHUB_REPO="$2";         shift 2;;
      --github-token)       GITHUB_TOKEN="$2";        shift 2;;
      --flux-path)          FLUX_PATH="$2";           shift 2;;
      --pg-db)              PG_DB="$2";               shift 2;;
      --pg-user)            PG_USER="$2";             shift 2;;
      --pg-password)        PG_PASSWORD="$2";         shift 2;;
      --pg-storage)         PG_STORAGE="$2";          shift 2;;
      --le-email)           LE_EMAIL="$2";            shift 2;;
      --domain)             DOMAIN="$2";              shift 2;;
      --kubeconfig-output)  KUBECONFIG_OUTPUT="$2";   shift 2;;
      --backup-schedule)    BACKUP_SCHEDULE="$2";     shift 2;;
      --backup-retain-days) BACKUP_RETAIN_DAYS="$2";  shift 2;;
      --help)               usage;;
      *)                    error "Unknown argument: $1"; exit 1;;
    esac
  done
}

validate_args() {
  local missing=()
  [[ -z "${HOST:-}" ]]          && missing+=("--host")
  [[ -z "${SSH_USER:-}" ]]      && missing+=("--user")
  [[ -z "${TLS_SAN:-}" ]]       && missing+=("--tls-san")
  [[ -z "${GITHUB_OWNER:-}" ]]  && missing+=("--github-owner")
  [[ -z "${GITHUB_REPO:-}" ]]   && missing+=("--github-repo")
  [[ -z "${GITHUB_TOKEN:-}" ]]  && missing+=("--github-token")
  [[ -z "${FLUX_PATH:-}" ]]     && missing+=("--flux-path")
  [[ -z "${PG_PASSWORD:-}" ]]   && missing+=("--pg-password")
  [[ -z "${LE_EMAIL:-}" ]]      && missing+=("--le-email")
  [[ -z "${DOMAIN:-}" ]]        && missing+=("--domain")

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required arguments: ${missing[*]}"
    echo ""
    usage
  fi

  [[ -z "$KUBECONFIG_OUTPUT" ]] && KUBECONFIG_OUTPUT="${HOME}/.kube/config-${HOST}"
}

# ---------------------------------------------------------------------------
# SSH Helpers (ControlMaster for connection reuse)
# ---------------------------------------------------------------------------
SSH_CONTROL_PATH="/tmp/ssh-k3s-init-%r@%h-%p"

ssh_exec() {
  ssh -o StrictHostKeyChecking=accept-new \
      -o ControlMaster=auto \
      -o ControlPath="$SSH_CONTROL_PATH" \
      -o ControlPersist=300 \
      -i "$SSH_KEY" \
      -p "$SSH_PORT" \
      "${SSH_USER}@${HOST}" "$@"
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
WORK_DIR=""
REPO_CLONE_DIR=""

cleanup() {
  # Close SSH ControlMaster
  if [[ -n "${SSH_USER:-}" && -n "${HOST:-}" ]]; then
    ssh -o ControlPath="$SSH_CONTROL_PATH" -O exit "${SSH_USER}@${HOST}" 2>/dev/null || true
  fi
  # Remove temp directories
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]] && rm -rf "$WORK_DIR"
  [[ -n "${REPO_CLONE_DIR:-}" && -d "${REPO_CLONE_DIR:-}" ]] && rm -rf "$REPO_CLONE_DIR"
  true
}
trap cleanup EXIT

# =============================================================================
# Phase 1: Check Prerequisites
# =============================================================================
phase1_prerequisites() {
  step 1 "Checking Prerequisites"

  for cmd in ssh git; do
    if command -v "$cmd" &>/dev/null; then
      success "$cmd found: $(command -v "$cmd")"
    else
      error "$cmd is not installed. Please install it first."
      exit 1
    fi
  done

  info "Testing SSH connection to ${SSH_USER}@${HOST}:${SSH_PORT}..."
  if ssh_exec "echo 'SSH OK'" &>/dev/null; then
    success "SSH connection verified"
  else
    error "Cannot connect to ${HOST} via SSH"
    exit 1
  fi

  info "Remote server info:"
  ssh_exec "uname -a" || true
}

# =============================================================================
# Phase 2: Install K3s
# =============================================================================
phase2_install_k3s() {
  step 2 "Installing K3s"

  if ssh_exec "command -v k3s" &>/dev/null; then
    warn "K3s is already installed"
    ssh_exec "k3s --version"
    # Ensure k3s is running
    if ssh_exec "sudo systemctl is-active k3s" &>/dev/null; then
      success "K3s service is active"
    else
      info "Starting K3s service..."
      ssh_exec "sudo systemctl start k3s"
    fi
    return 0
  fi

  info "Installing K3s (latest stable) with TLS SAN: ${TLS_SAN}..."
  ssh_exec "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server --tls-san=${TLS_SAN}' sh -"

  info "Waiting for K3s to become ready..."
  local retries=30
  for i in $(seq 1 "$retries"); do
    if ssh_exec "sudo k3s kubectl get nodes 2>/dev/null | grep -q ' Ready'" &>/dev/null; then
      success "K3s is ready!"
      ssh_exec "sudo k3s kubectl get nodes"
      return 0
    fi
    echo -ne "\r  Waiting... (${i}/${retries})"
    sleep 5
  done
  echo ""
  error "K3s failed to become ready within $((retries * 5))s"
  exit 1
}

# =============================================================================
# Phase 3: Fetch Kubeconfig
# =============================================================================
phase3_fetch_kubeconfig() {
  step 3 "Fetching Kubeconfig"

  mkdir -p "$(dirname "$KUBECONFIG_OUTPUT")"

  info "Copying kubeconfig from remote server..."
  ssh_exec "sudo cat /etc/rancher/k3s/k3s.yaml" > "$KUBECONFIG_OUTPUT"

  # Build the correct server address
  local server_addr="https://${TLS_SAN}:6443"

  info "Replacing server address → ${server_addr}"
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "s|https://127.0.0.1:6443|${server_addr}|g" "$KUBECONFIG_OUTPUT"
  else
    sed -i "s|https://127.0.0.1:6443|${server_addr}|g" "$KUBECONFIG_OUTPUT"
  fi

  chmod 600 "$KUBECONFIG_OUTPUT"

  info "Verifying cluster connectivity..."
  if ssh_exec "sudo k3s kubectl get nodes"; then
    success "Kubeconfig saved to: ${KUBECONFIG_OUTPUT}"
  else
    error "K3s cluster is not responding"
    exit 1
  fi

  echo ""
  info "📋 Lens connection: Add kubeconfig file → ${KUBECONFIG_OUTPUT}"
  info "   Lens 内置 kubectl，无需本地安装"
}

# =============================================================================
# Phase 4: Bootstrap Flux (远端安装)
# =============================================================================
phase4_install_flux() {
  step 4 "Installing Flux CD (Remote)"

  # Install flux CLI on remote server if not present
  if ssh_exec "command -v flux" &>/dev/null; then
    warn "Flux CLI already installed on server"
    ssh_exec "flux --version"
  else
    info "Installing Flux CLI on remote server..."
    ssh_exec "curl -s https://fluxcd.io/install.sh | sudo bash"
    success "Flux CLI installed on server"
  fi

  # Check if Flux is already bootstrapped in the cluster
  if ssh_exec "sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml flux check" &>/dev/null 2>&1; then
    warn "Flux is already installed in the cluster"
    ssh_exec "sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml flux check"
    return 0
  fi

  info "Bootstrapping Flux → github.com/${GITHUB_OWNER}/${GITHUB_REPO} (path: ${FLUX_PATH})..."

  ssh_exec "sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml GITHUB_TOKEN='${GITHUB_TOKEN}' \
    flux bootstrap github \
      --owner='${GITHUB_OWNER}' \
      --repository='${GITHUB_REPO}' \
      --path='${FLUX_PATH}' \
      --personal"

  success "Flux bootstrap complete"
  ssh_exec "sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml flux check"
}

# =============================================================================
# Phase 5: Generate Manifests from Templates
# =============================================================================
phase5_generate_manifests() {
  step 5 "Generating Kubernetes Manifests"

  # Resolve paths
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SKILL_DIR="$(dirname "$SCRIPT_DIR")"
  MANIFESTS_SRC="${SKILL_DIR}/resources/manifests"

  if [[ ! -d "$MANIFESTS_SRC" ]]; then
    error "Manifest templates not found at: ${MANIFESTS_SRC}"
    exit 1
  fi

  WORK_DIR=$(mktemp -d)
  info "Working directory: ${WORK_DIR}"

  # --- Shared templates (copied as-is, Flux postBuild substitutes variables) ---
  cp -r "${MANIFESTS_SRC}/infrastructure" "${WORK_DIR}/"
  info "Copied infrastructure/ (shared)"
  cp -r "${MANIFESTS_SRC}/apps" "${WORK_DIR}/"
  info "Copied apps/ (shared)"

  # --- Per-cluster templates ---
  mkdir -p "${WORK_DIR}/cluster"
  for f in "${MANIFESTS_SRC}/cluster/"*; do
    [[ ! -f "$f" ]] && continue
    local basename
    basename=$(basename "$f")
    if [[ "$basename" == "cluster-vars.yaml" ]]; then
      # Only cluster-vars.yaml needs sed — inject actual values
      sed \
        -e "s|\${PG_DB}|${PG_DB}|g" \
        -e "s|\${PG_USER}|${PG_USER}|g" \
        -e "s|\${PG_PASSWORD}|${PG_PASSWORD}|g" \
        -e "s|\${PG_STORAGE}|${PG_STORAGE}|g" \
        -e "s|\${BACKUP_SCHEDULE}|${BACKUP_SCHEDULE}|g" \
        -e "s|\${BACKUP_RETAIN_DAYS}|${BACKUP_RETAIN_DAYS}|g" \
        -e "s|\${LE_EMAIL}|${LE_EMAIL}|g" \
        -e "s|\${DOMAIN}|${DOMAIN}|g" \
        "$f" > "${WORK_DIR}/cluster/${basename}"
    else
      cp "$f" "${WORK_DIR}/cluster/"
    fi
  done
  info "Generated cluster/ (per-cluster)"

  success "All manifests generated in ${WORK_DIR}"
}

# =============================================================================
# Phase 6: Git Push Manifests
# =============================================================================
phase6_git_push() {
  step 6 "Pushing Manifests to GitHub"

  REPO_CLONE_DIR=$(mktemp -d)
  local repo_url="https://${GITHUB_TOKEN}@github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git"

  info "Cloning repository..."
  git clone --depth=1 "$repo_url" "$REPO_CLONE_DIR" 2>&1 | tail -1

  info "Copying manifests to repository..."

  # Shared base → repo root (reusable across all clusters)
  cp -r "${WORK_DIR}/infrastructure" "${REPO_CLONE_DIR}/"
  cp -r "${WORK_DIR}/apps" "${REPO_CLONE_DIR}/"

  # Per-cluster → <flux-path>/ (e.g., clusters/oracle/)
  local cluster_dir="${REPO_CLONE_DIR}/${FLUX_PATH}"
  mkdir -p "$cluster_dir"
  cp "${WORK_DIR}/cluster/"*.yaml "$cluster_dir/"

  info "Repository structure:"
  (cd "$REPO_CLONE_DIR" && find . -name '*.yaml' -not -path './.git/*' -not -path "./${FLUX_PATH}/flux-system/*" | sort | head -25)

  # Commit and push
  cd "$REPO_CLONE_DIR"
  git config user.email "k3s-server-init@automated"
  git config user.name "k3s-server-init"
  git add -A

  if git diff --cached --quiet; then
    warn "No changes to commit (manifests may already exist)"
  else
    git commit -m "feat: add infrastructure and database manifests

Shared base (repo root):
- infrastructure/ — cert-manager (HelmRelease via Flux)
- apps/ — PostgreSQL 18 + pgVector, pg_dump backup CronJob

Per-cluster (${FLUX_PATH}):
- Flux Kustomizations with postBuild variable substitution
- cluster-vars Secret (LE_EMAIL, PG credentials, etc.)"

    info "Pushing to GitHub..."
    git push
    success "Manifests pushed to github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
  fi

  cd - >/dev/null
}

# =============================================================================
# Phase 7: Wait for Flux Sync (远端检查)
# =============================================================================
phase7_wait_flux_sync() {
  step 7 "Waiting for Flux Sync"

  local kc="sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml"

  info "Triggering Flux reconciliation..."
  ssh_exec "${kc} flux reconcile source git flux-system" 2>/dev/null || true
  sleep 5

  local timeout=600  # 10 minutes
  local start_time
  start_time=$(date +%s)

  local kustomizations=("infrastructure" "infrastructure-configs" "apps")

  info "Waiting for Kustomizations to become ready (timeout: ${timeout}s)..."
  echo ""

  while true; do
    local elapsed=$(( $(date +%s) - start_time ))
    if [[ $elapsed -ge $timeout ]]; then
      error "Timeout waiting for Flux sync after ${timeout}s"
      warn "Current status:"
      ssh_exec "${kc} flux get kustomizations" 2>/dev/null || true
      exit 1
    fi

    local all_ready=true
    for ks in "${kustomizations[@]}"; do
      local status
      status=$(ssh_exec "${kc} flux get kustomization ${ks}" 2>/dev/null | tail -1 || echo "NotFound")
      if echo "$status" | grep -q "True"; then
        echo -e "  ${GREEN}✓${NC} ${ks}: Ready"
      else
        echo -e "  ${YELLOW}…${NC} ${ks}: Reconciling (${elapsed}s elapsed)"
        all_ready=false
      fi
    done

    if $all_ready; then
      echo ""
      success "All Flux Kustomizations are ready!"
      return 0
    fi

    echo ""
    sleep 15
  done
}

# =============================================================================
# Phase 8: Verify & Report
# =============================================================================
phase8_verify() {
  step 8 "Verification & Summary"

  local kc="sudo k3s kubectl"
  local kc_flux="sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
  local errors=0

  # --- Nodes ---
  info "Checking nodes..."
  ssh_exec "${kc} get nodes -o wide" || ((errors++))
  echo ""

  # --- Flux ---
  info "Checking Flux..."
  ssh_exec "${kc_flux} flux get kustomizations" || ((errors++))
  echo ""

  # --- Pods ---
  info "Checking pods..."
  ssh_exec "${kc} get pods -A" || ((errors++))
  echo ""

  # --- cert-manager ---
  info "Checking cert-manager..."
  if ssh_exec "${kc} get pods -n cert-manager" 2>/dev/null | grep -q "Running"; then
    success "cert-manager is running"
  else
    warn "cert-manager pods not yet running (may still be starting)"
  fi

  if ssh_exec "${kc} get clusterissuer letsencrypt-prod" &>/dev/null; then
    success "ClusterIssuer letsencrypt-prod exists"
  else
    warn "ClusterIssuer not yet available (cert-manager CRDs may still be installing)"
  fi
  echo ""

  # --- PostgreSQL ---
  info "Checking PostgreSQL..."
  if ssh_exec "${kc} get pods -n database" 2>/dev/null | grep -q "postgresql-0.*Running"; then
    success "PostgreSQL is running"

    info "Testing pgVector extension..."
    local pgvector_check
    pgvector_check=$(ssh_exec "${kc} exec -n database postgresql-0 -- \
      psql -U '${PG_USER}' -d '${PG_DB}' -t -c \
      \"SELECT extname FROM pg_extension WHERE extname='vector';\"" 2>/dev/null || echo "")
    if echo "$pgvector_check" | grep -q "vector"; then
      success "pgVector extension is active"
    else
      warn "pgVector extension not yet active (database may still be initializing)"
    fi
  else
    warn "PostgreSQL pod not yet running (Flux may still be syncing)"
  fi
  echo ""

  # --- Backup CronJob ---
  info "Checking backup CronJob..."
  if ssh_exec "${kc} get cronjob pg-backup -n database" &>/dev/null; then
    success "pg-backup CronJob exists"
    ssh_exec "${kc} get cronjob pg-backup -n database"
  else
    warn "pg-backup CronJob not yet created"
  fi
  echo ""

  # --- Summary ---
  echo -e "${CYAN}${BOLD}"
  echo "╔═══════════════════════════════════════════════════════════╗"
  echo "║              🎉 Server Initialization Complete           ║"
  echo "╚═══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  echo -e "${BOLD}Deployed Components:${NC}"
  echo "  • K3s (latest stable) with Traefik ingress"
  echo "  • Flux CD → github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
  echo "  • cert-manager + Let's Encrypt (${DOMAIN})"
  echo "  • PostgreSQL 18 + pgVector"
  echo "  • pg_dump backup CronJob (${BACKUP_SCHEDULE})"
  echo "  • metrics-server (K3s built-in)"
  echo ""

  echo -e "${BOLD}Kubeconfig:${NC}"
  echo "  ${KUBECONFIG_OUTPUT}"
  echo ""

  echo -e "${BOLD}Lens Connection:${NC}"
  echo "  1. Open Lens → File → Add Cluster"
  echo "  2. Select kubeconfig: ${KUBECONFIG_OUTPUT}"
  echo "  3. Or paste content of the file"
  echo ""

  echo -e "${BOLD}GitOps Repository:${NC}"
  echo "  https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
  echo "  Flux path: ${FLUX_PATH}"
  echo ""

  echo -e "${BOLD}Useful Commands (via SSH):${NC}"
  echo "  ssh ${SSH_USER}@${HOST} sudo k3s kubectl get pods -A"
  echo "  ssh ${SSH_USER}@${HOST} sudo k3s kubectl logs -n database postgresql-0"
  echo "  ssh ${SSH_USER}@${HOST} sudo k3s kubectl exec -it -n database postgresql-0 -- psql -U ${PG_USER} -d ${PG_DB}"
  echo ""
  echo -e "${BOLD}Useful Commands (via Lens):${NC}"
  echo "  Kubeconfig: ${KUBECONFIG_OUTPUT}"
  echo "  Lens 内置 kubectl，导入 kubeconfig 即可管理集群"
  echo ""

  if [[ $errors -gt 0 ]]; then
    warn "Some checks had issues. Run the commands above to investigate."
  else
    success "All checks passed!"
  fi
}

# =============================================================================
# Main
# =============================================================================
main() {
  echo -e "${CYAN}${BOLD}"
  echo "╔═══════════════════════════════════════════════════════════╗"
  echo "║         K3s Server Init — GitOps Full Stack Deploy       ║"
  echo "╚═══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  parse_args "$@"
  validate_args

  info "Target: ${SSH_USER}@${HOST}:${SSH_PORT}"
  info "TLS SAN: ${TLS_SAN}"
  info "GitOps: github.com/${GITHUB_OWNER}/${GITHUB_REPO} (path: ${FLUX_PATH})"
  info "PostgreSQL: ${PG_DB} / ${PG_USER} / storage=${PG_STORAGE}"
  info "cert-manager: ${LE_EMAIL} / ${DOMAIN}"
  echo ""

  phase1_prerequisites
  phase2_install_k3s
  phase3_fetch_kubeconfig
  phase4_install_flux
  phase5_generate_manifests
  phase6_git_push
  phase7_wait_flux_sync
  phase8_verify
}

main "$@"

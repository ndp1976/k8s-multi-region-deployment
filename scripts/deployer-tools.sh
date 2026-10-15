#!/usr/bin/env bash
# =============================================================================
# deployer-tools.sh — prepare an Ubuntu 24.04 deployer VSI to run this project
#
# Installs:
#   1. IBM Cloud CLI + plugins used by this deployment
#   2. kubectl
#   3. Helm 3
#   4. Terraform
#   5. jq
#
# Usage (run as a sudo-capable user, not necessarily root):
#   ./scripts/deployer-tools.sh
#
# Optional overrides:
#   KUBECTL_VERSION=v1.32     # kubectl minor version (keep within ±1 of the IKS clusters)
#   HELM_VERSION=v3.16.4      # Helm 3 release; default = latest v3
#   TERRAFORM_VERSION=1.9.8   # exact Terraform version; default = latest from HashiCorp repo
# =============================================================================
set -euo pipefail

KUBECTL_VERSION="${KUBECTL_VERSION:-v1.32}"
HELM_VERSION="${HELM_VERSION:-}"
TERRAFORM_VERSION="${TERRAFORM_VERSION:-}"

# Plugins required by scripts/deploy.sh (ibmcloud ks / ibmcloud cr)
REQUIRED_PLUGINS=(
  container-service      # ibmcloud ks  — cluster config
  container-registry     # ibmcloud cr  — registry login / namespaces
)
# Plugins for the other services provisioned by Terraform (troubleshooting aids).
# A failure to install one of these is reported but does not abort the script.
OPTIONAL_PLUGINS=(
  vpc-infrastructure     # ibmcloud is  — VPC, subnets, VPE
  key-protect            # ibmcloud kp  — Key Protect
  secrets-manager        # ibmcloud secrets-manager
  tg-cli                 # ibmcloud tg  — Transit Gateway
  cloud-databases        # ibmcloud cdb — Databases for Redis
)

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ── 0. Pre-flight ────────────────────────────────────────────────────────────
[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] \
  || die "This script targets Ubuntu 24.04 (detected: ${PRETTY_NAME:-unknown})"

if [[ $EUID -eq 0 ]]; then
  SUDO=""
else
  command -v sudo &>/dev/null || die "Run as root or install sudo"
  SUDO="sudo"
fi

export DEBIAN_FRONTEND=noninteractive
ARCH="$(dpkg --print-architecture)"   # amd64 | arm64

# ── 1. Base packages + jq ────────────────────────────────────────────────────
log "=== Installing base packages and jq ==="
$SUDO apt-get update -y
$SUDO apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg apt-transport-https lsb-release jq
$SUDO install -m 0755 -d /etc/apt/keyrings

# ── 2. IBM Cloud CLI + plugins ───────────────────────────────────────────────
if command -v ibmcloud &>/dev/null; then
  log "=== IBM Cloud CLI already installed: $(ibmcloud --version) ==="
else
  log "=== Installing IBM Cloud CLI ==="
  curl -fsSL https://clis.cloud.ibm.com/install/linux | $SUDO sh
fi

export IBMCLOUD_COLOR=false
export IBMCLOUD_VERSION_CHECK=false

installed_plugins="$(ibmcloud plugin list 2>/dev/null || true)"

for plugin in "${REQUIRED_PLUGINS[@]}"; do
  if grep -qE "(^|[[:space:]])${plugin}([[:space:]]|$)" <<<"$installed_plugins"; then
    log "Plugin already installed: $plugin"
  else
    log "Installing required plugin: $plugin"
    ibmcloud plugin install "$plugin" -r "IBM Cloud" -f
  fi
done

for plugin in "${OPTIONAL_PLUGINS[@]}"; do
  if grep -qE "(^|[[:space:]])${plugin}([[:space:]]|$)" <<<"$installed_plugins"; then
    log "Plugin already installed: $plugin"
  else
    log "Installing optional plugin: $plugin"
    ibmcloud plugin install "$plugin" -r "IBM Cloud" -f \
      || warn "Could not install optional plugin: $plugin"
  fi
done

# ── 3. kubectl (official pkgs.k8s.io apt repo) ───────────────────────────────
log "=== Installing kubectl ${KUBECTL_VERSION} ==="
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBECTL_VERSION}/deb/Release.key" \
  | $SUDO gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBECTL_VERSION}/deb/ /" \
  | $SUDO tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
$SUDO apt-get update -y
$SUDO apt-get install -y kubectl

# ── 4. Helm 3 (official installer script, v3 line) ───────────────────────────
log "=== Installing Helm 3 ==="
helm_installer="$(mktemp)"
trap 'rm -f "$helm_installer"' EXIT
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "$helm_installer"
chmod 700 "$helm_installer"
if [[ -n "$HELM_VERSION" ]]; then
  DESIRED_VERSION="$HELM_VERSION" "$helm_installer"
else
  "$helm_installer"
fi

# ── 5. Terraform (HashiCorp apt repo) ────────────────────────────────────────
log "=== Installing Terraform ==="
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | $SUDO gpg --dearmor --yes -o /etc/apt/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | $SUDO tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
$SUDO apt-get update -y
if [[ -n "$TERRAFORM_VERSION" ]]; then
  $SUDO apt-get install -y "terraform=${TERRAFORM_VERSION}*"
else
  $SUDO apt-get install -y terraform
fi

# ── 6. Verify ────────────────────────────────────────────────────────────────
log "=== Installed versions ==="
ibmcloud --version
ibmcloud plugin list
kubectl version --client
helm version --short
terraform version
jq --version

log "Deployer VSI is ready. Next: export IBMCLOUD_API_KEY and run scripts/deploy.sh"

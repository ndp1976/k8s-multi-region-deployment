#!/usr/bin/env bash
# =============================================================================
# deploy.sh — end-to-end deploy for the k8s-multi-cloud-sample PoC
#
# Prerequisites:
#   ibmcloud CLI, kubectl, helm 3, terraform 1.5+
#   export IBMCLOUD_API_KEY=<your-key>
#   export ICR_NAMESPACE=ndp-demo        # IBM Container Registry namespace
#   export IMAGE_TAG=v1.0.0               # image tag to build/push/deploy
# =============================================================================
set -euo pipefail

REGION_US_SOUTH="us-south"
REGION_US_EAST="us-east"
ICR_REGISTRY="us.icr.io"
ICR_NAMESPACE="${ICR_NAMESPACE:-ndp-demo}"
IMAGE_TAG="${IMAGE_TAG:-v1.0.0}"
NAMESPACE="mydemo"   # common namespace for web-app-a and web-app-b (also hardcoded in k8s/istio/*.yaml and helm values)
TF_DIR="$(cd "$(dirname "$0")/terraform" && pwd)"
HELM_DIR="$(cd "$(dirname "$0")/helm" && pwd)"
K8S_DIR="$(cd "$(dirname "$0")/k8s" && pwd)"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ── 0. Validate prerequisites ───────────────────────────────────────────────
for cmd in ibmcloud kubectl helm terraform; do
  command -v "$cmd" &>/dev/null || die "Required tool not found: $cmd"
done
[[ -z "${IBMCLOUD_API_KEY:-}" ]] && die "IBMCLOUD_API_KEY is not set"

# ── 1. Terraform — provision infrastructure ─────────────────────────────────
log "=== STEP 1: Terraform apply ==="
cd "$TF_DIR"
terraform init -upgrade -input=false
terraform apply \
  -var-file=envs/us-south.tfvars \
  -var-file=envs/us-east.tfvars \
  -auto-approve \
  -input=false

# Capture Terraform outputs
log "Capturing Terraform outputs..."
TF_OUT=$(terraform output -json)

CLUSTER_US_SOUTH=$(echo "$TF_OUT" | jq -r '.cluster_ids.value["us-south"]')
CLUSTER_US_EAST=$(echo  "$TF_OUT" | jq -r '.cluster_ids.value["us-east"]')

REDIS_HOST_US_SOUTH=$(echo "$TF_OUT" | jq -r '.redis_hostnames.value["us-south"]')
REDIS_HOST_US_EAST=$(echo  "$TF_OUT" | jq -r '.redis_hostnames.value["us-east"]')
REDIS_PORT_US_SOUTH=$(echo "$TF_OUT" | jq -r '.redis_ports.value["us-south"]')
REDIS_PORT_US_EAST=$(echo  "$TF_OUT" | jq -r '.redis_ports.value["us-east"]')

# Sensitive outputs require explicit -raw
REDIS_PASS_US_SOUTH=$(terraform output -raw redis_password_us_south 2>/dev/null || echo "")
REDIS_PASS_US_EAST=$(terraform  output -raw redis_password_us_east  2>/dev/null || echo "")
REDIS_CERT_US_SOUTH=$(terraform output -raw redis_cert_us_south     2>/dev/null || echo "")
REDIS_CERT_US_EAST=$(terraform  output -raw redis_cert_us_east      2>/dev/null || echo "")

# ── 2. IBM Cloud login & container registry ──────────────────────────────────
log "=== STEP 2: IBM Cloud login ==="
ibmcloud login --apikey "$IBMCLOUD_API_KEY" -g default -q
ibmcloud cr region-set us-south
ibmcloud cr login
ibmcloud cr namespace-add "$ICR_NAMESPACE" 2>/dev/null || true

# ── 3. Build & push images ───────────────────────────────────────────────────
log "=== STEP 3: Build & push images ==="
cd "$(dirname "$0")"

for app in web-app-a web-app-b; do
  log "Building $app..."
  docker build --platform linux/amd64 -t "${ICR_REGISTRY}/${ICR_NAMESPACE}/${app}:${IMAGE_TAG}" "apps/${app}/"
  docker push "${ICR_REGISTRY}/${ICR_NAMESPACE}/${app}:${IMAGE_TAG}"
done

# ── 4. Configure kubectl contexts ───────────────────────────────────────────
log "=== STEP 4: Configure kubectl ==="
ibmcloud ks cluster config --cluster "$CLUSTER_US_SOUTH" --endpoint private
KUBE_CTX_SOUTH=$(kubectl config current-context)

ibmcloud ks cluster config --cluster "$CLUSTER_US_EAST" --endpoint private
KUBE_CTX_EAST=$(kubectl config current-context)

# ── 5. Deploy to us-south ────────────────────────────────────────────────────
log "=== STEP 5: Deploy to us-south ==="
kubectl config use-context "$KUBE_CTX_SOUTH"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ICR pull secret (us-south)
ibmcloud ks cluster config --cluster "$CLUSTER_US_SOUTH" --endpoint private
ibmcloud cr token-add --description "icr-pull" --non-expiring --readwrite 2>/dev/null || true
kubectl create secret docker-registry icr-pull-secret \
  --docker-server="${ICR_REGISTRY}" \
  --docker-username=iamapikey \
  --docker-password="${IBMCLOUD_API_KEY}" \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Istio mTLS + east-west manifests
kubectl apply -f "$K8S_DIR/istio/peer-authentication.yaml"

# Helm: web-app-b (deploy first — app-a depends on it)
helm upgrade --install web-app-b "$HELM_DIR/web-app-b" \
  --namespace "$NAMESPACE" \
  --set image.repository="${ICR_REGISTRY}/${ICR_NAMESPACE}/web-app-b" \
  --set image.tag="${IMAGE_TAG}" \
  --set secret.REDIS_HOST="${REDIS_HOST_US_SOUTH}" \
  --set secret.REDIS_PASSWORD="${REDIS_PASS_US_SOUTH}" \
  --set secret.REDIS_CERT_B64="${REDIS_CERT_US_SOUTH}" \
  --wait --timeout=5m

# Helm: web-app-a
helm upgrade --install web-app-a "$HELM_DIR/web-app-a" \
  --namespace "$NAMESPACE" \
  -f "$HELM_DIR/web-app-a/us-south-values.yaml" \
  --set image.repository="${ICR_REGISTRY}/${ICR_NAMESPACE}/web-app-a" \
  --set image.tag="${IMAGE_TAG}" \
  --wait --timeout=5m

# Istio east-west (REMOTE_LB_IP patched in after both clusters are up)
REMOTE_LB_IP_SOUTH=$(kubectl get svc -n "$NAMESPACE" web-app-b \
  --context "$KUBE_CTX_EAST" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "0.0.0.0")
sed "s/REMOTE_LB_IP/${REMOTE_LB_IP_SOUTH}/" \
  "$K8S_DIR/istio/web-app-b-east-west.yaml" | kubectl apply -f -

# ── 6. Deploy to us-east ─────────────────────────────────────────────────────
log "=== STEP 6: Deploy to us-east ==="
kubectl config use-context "$KUBE_CTX_EAST"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry icr-pull-secret \
  --docker-server="${ICR_REGISTRY}" \
  --docker-username=iamapikey \
  --docker-password="${IBMCLOUD_API_KEY}" \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$K8S_DIR/istio/peer-authentication.yaml"

helm upgrade --install web-app-b "$HELM_DIR/web-app-b" \
  --namespace "$NAMESPACE" \
  --set image.repository="${ICR_REGISTRY}/${ICR_NAMESPACE}/web-app-b" \
  --set image.tag="${IMAGE_TAG}" \
  --set secret.REDIS_HOST="${REDIS_HOST_US_EAST}" \
  --set secret.REDIS_PASSWORD="${REDIS_PASS_US_EAST}" \
  --set secret.REDIS_CERT_B64="${REDIS_CERT_US_EAST}" \
  --wait --timeout=5m

helm upgrade --install web-app-a "$HELM_DIR/web-app-a" \
  --namespace "$NAMESPACE" \
  -f "$HELM_DIR/web-app-a/us-east-values.yaml" \
  --set image.repository="${ICR_REGISTRY}/${ICR_NAMESPACE}/web-app-a" \
  --set image.tag="${IMAGE_TAG}" \
  --wait --timeout=5m

REMOTE_LB_IP_EAST=$(kubectl get svc -n "$NAMESPACE" web-app-b \
  --context "$KUBE_CTX_SOUTH" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "0.0.0.0")
sed "s/REMOTE_LB_IP/${REMOTE_LB_IP_EAST}/" \
  "$K8S_DIR/istio/web-app-b-east-west.yaml" | kubectl apply -f -

log "=== Deploy complete ==="
log "Web App A (us-south): https://mydemo.cistest-load.com , https://mydemo-us-south.cistest-load.com"
log "Web App A (us-east):  https://mydemo.cistest-load.com , https://mydemo-us-east.cistest-load.com"
log "  GET  /status         (no auth)"
log "  GET  /message?key=<k> (Authorization: <API_SECRET> required)"
log "  POST /spike           (Authorization: <API_SECRET> required)"

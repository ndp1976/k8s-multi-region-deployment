# k8s Multi-Cloud Sample — Applications

Two Python/Flask microservices deployed via Helm to dual-region IKS clusters.

---

## Architecture

```
  User (Internet HTTPS :443)
          │
          ▼
  ┌────────────────────────────────────────────────────────────┐
  │  IBM Cloud Internet Services (CIS / Cloudflare)            │
  │  Global Load Balancer — mydemo.cistest-load.com            │
  │                                                            │
  │  Pool: us-south-web-app-a   Pool: us-east-web-app-a        │
  │    Health check: GET /status  Health check: GET /status    │
  └────────────┬──────────────────────────┬────────────────────┘
               │ us-south origin          │ us-east origin
               ▼                          ▼
  ┌─────────────────────┐    ┌─────────────────────────────────┐
  │  IKS Cluster        │    │  IKS Cluster                    │
  │  us-south           │    │  us-east                        │
  │                     │    │                                 │
  │  Istio Gateway      │    │  Istio Gateway                  │
  │  (edge worker pool) │    │  (edge worker pool)             │
  │         │           │    │           │                     │
  │  ┌──────▼──────────────────────┐  ┌──────────────────────────────────▼──┐
  │  │  Namespace: mydemo          │  │  Namespace: mydemo                  │
  │  │  ┌──────────┐ ┌───────────┐ │  │  ┌──────────┐ ┌───────────────────┐ │
  │  │  │ Web App A│ │ Web App B │ │  │  │ Web App A│ │ Web App B         │ │
  │  │  │ rep: 2   │ │ GET /get  │ │  │  │ rep: 2   │ │ GET /get          │ │
  │  │  │ HPA 2–10 │ │ POST /set │ │  │  │ HPA 2–10 │ │ POST /set         │ │
  │  │  │ /status  │ │ /status   │ │  │  │ /status  │ │ /status           │ │
  │  │  │ /message │ │ AuthzPol  │ │  │  │ /message │ │ AuthzPolicy       │ │
  │  │  │ /spike   │ │ (SA only) │ │  │  │ /spike   │ │ (web-app-a only)  │ │
  │  │  └──────────┘ └─────┬─────┘ │  │  └──────────┘ └────────┬──────────┘ │
  │  │  mTLS STRICT (Istio)│       │  │  mTLS STRICT (Istio)   │            │
  │  └─────────────────────┼───────┘  └────────────────────────┼───────────-┘
  └────────────────────────┼───────────┘  └─────────────────────┼───────────┘
                          │ TLS (private endpoint)               │ TLS (private endpoint)
                          └──────────────────┬───────────────────┘
                          ▼
          ┌───────────────────────────────┐
          │  IBM Cloud Databases (ICD)    │
          │  Redis — demo-poc-redis       │
          │  2 members, KMS encrypted     │
          │  Private endpoint only        │
          └───────────────────────────────┘

          ┌──────────────────────────────────────────────────────────────────┐
          │  Shared IBM Cloud Services (both clusters)                       │
          │                                                                  │
          │  ┌─────────────────────────┐  ┌──────────────────────────┐       │
          │  │  Key Protect (KMS)      │  │  Secrets Manager         │       │
          │  │  K8s secret encryption  │  │  App secrets &           │       │
          │  │  at rest (kms_config)   │  │  TLS certificates        │       │
          │  └─────────────────────────┘  └──────────────────────────┘       │
          │                                                                  │
          │  ┌─────────────────────────┐  ┌──────────────────────────┐       │
          │  │  IBM Cloud Logs         │  │  IBM Cloud Monitoring    │       │
          │  │  Aggregates logs from   │  │  Aggregates metrics from │       │
          │  │  both clusters          │  │  both clusters           │       │
          │  └─────────────────────────┘  └──────────────────────────┘       │
          │                                                                  │
          │  ┌──────────────────────────────────────────────────────────┐    │
          │  │  IBM Container Registry (ICR)  — namespace: ndp-demo     │    │
          │  │  Stores web-app-a and web-app-b images                   │    │
          │  │  Both clusters pull images from this shared registry     │    │
          │  └──────────────────────────────────────────────────────────┘    │
          └──────────────────────────────────────────────────────────────────┘

  CIS GLB performs active/active global load balancing.  If a pool's
  /status health check fails, CIS automatically fails traffic over
  to the healthy pool.

  Both regional Web App B instances connect to the single shared ICD
  Redis instance over its private endpoint.  Key Protect, Secrets
  Manager, IBM Cloud Logs, IBM Cloud Monitoring, and IBM Container
  Registry are global shared services consumed by both clusters.
  Both clusters pull container images from the shared ICR namespace
  (ndp-demo).  Web App A in each region calls its local Web App B;
  Istio DestinationRule retries to the remote cluster via Transit
  Gateway on failure (east-west failover).
```

## Repository layout

```
apps/
  web-app-a/              Flask app + Dockerfile
  web-app-b/              Flask + ICD Redis app + Dockerfile
helm/
  web-app-a/              Helm chart (Deployment, ConfigMap, Secret, HPA,
  │                       Service, ServiceAccount, Istio Gateway/VS)
  web-app-b/              Helm chart (Deployment, ConfigMap, Secret,
                          Service, ServiceAccount, AuthorizationPolicy)
k8s/
  istio/
    peer-authentication.yaml   mTLS STRICT for both namespaces
    web-app-b-east-west.yaml   DestinationRule + VirtualService + ServiceEntry
terraform/
  main.tf                 Root orchestration (7 modules in order)
  variables.tf            All input variables with defaults
  outputs.tf              Cluster IDs, Redis endpoints, Trusted Profile IDs, …
  versions.tf             Provider pins (ibm ≥ 2.5, helm ≥ 3.0); dual-region
                          IBM + Helm providers
  modules/
    governance/           Existing resource group lookup; Service IDs + IAM
                          Access Groups for dev / sre / ops / automation personas
    regional/             VPC (landing-zone-vpc) + single-AZ IKS cluster
                          (base-iks-vpc) + Istio add-on + two Trusted Profiles
                          (apps, logs-agent) — instantiated twice, once per region
    icd-redis/            Single ICD Redis instance (provider-managed encryption,
                          private endpoint only); connection info data source
    transit-gateway/      Global Transit Gateway connecting both regional VPCs
scripts/
  deploy.sh               End-to-end build + infra + deploy script
```

## Prerequisites

| Tool | Purpose |
|------|---------|
| `ibmcloud` CLI | cluster config, ICR login |
| `kubectl` | apply manifests |
| `helm` 3 | chart deployment |
| `terraform` ≥ 1.5 | infrastructure |
| `docker` | image build/push |
| `jq` | parse Terraform JSON output |

## Deploy (full stack)

```bash
export IBMCLOUD_API_KEY="<your-ibm-cloud-api-key>"
export ICR_NAMESPACE="ndp-demo"
export IMAGE_TAG="v1.0.0"

./scripts/deploy.sh
```

The script:
1. Runs `terraform apply` — provisions all infrastructure in this order:
   - **Governance**: looks up existing resource group; creates Service IDs + Access Groups for `dev`, `sre`, `ops`, `automation` personas
   - **Cloud Logs + Cloud Monitoring**: single shared instances in `us-south`
   - **Regional (×2)**: VPC, single-AZ IKS cluster (Ubuntu 24, `bxf.4x16` × 3 workers), Istio add-on, and two Trusted Profiles per cluster
   - **Logs + Monitoring agents**: Helm-deployed to both clusters (logs agent via Trusted Profile; monitoring agent via access key)
   - **ICD Redis**: one shared `standard` instance in `us-south`
   - **Transit Gateway**: global gateway connecting both regional VPCs
   - KMS and Secrets Manager are **pre-existing** — referenced by CRN, not created
2. Builds and pushes both images to **IBM Container Registry** (ICR namespace `ndp-demo`) — shared by both clusters
3. Configures `kubectl` for both clusters
4. Deploys via Helm — web-app-b first, then web-app-a
5. Applies Istio PeerAuthentication + east-west DestinationRule to both clusters

## Testing after deploy

```bash
# Health check (no auth)
curl https://mydemo.cistest-load.com/status

# Static secret (the value stored in web-app-a-secret / API_SECRET)
TOKEN="<your-api-secret>"

# Fetch a key from Redis via web-app-b
curl -H "Authorization: $TOKEN" \
  "https://mydemo.cistest-load.com/message?key=greeting"

# Trigger CPU spike (watch HPA scale up)
curl -X POST -H "Authorization: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"seconds": 30}' \
  https://mydemo.cistest-load.com/spike

# Watch HPA react
kubectl get hpa -n mydemo -w
```

## Seeding Redis

```bash
# Port-forward web-app-b locally to seed initial data
kubectl port-forward -n mydemo svc/web-app-b 8080:8080 \
  --context <us-south-context>

curl -X POST http://localhost:8080/set \
  -H "Content-Type: application/json" \
  -d '{"key": "greeting", "value": "Hello from ICD Redis!", "ttl": 3600}'
```

## ICD Redis — Shared instance

- A **single ICD Redis instance** (`demo-poc-redis`) is shared by both regional clusters.
- Both `us-south` and `us-east` Web App B instances connect to it via its **private endpoint**.
- Because both regions share the same data store, cross-region consistency is automatic — no replication lag or application-level sync needed.
- Ensure the ICD Redis private endpoint is reachable from both VPCs (via Transit Gateway or a shared VPC peering arrangement).

## Governance

The `modules/governance` module enforces a consistent IAM structure across both clusters:

| Persona | IAM Platform roles | IAM Service roles | Access Group name |
|---------|-------------------|-------------------|-------------------|
| `dev` | Viewer | Writer | `{env}-k8s-rbac-dev` |
| `sre` | Operator | Writer | `{env}-k8s-rbac-sre` |
| `ops` | Administrator | Manager | `{env}-k8s-rbac-ops` |
| `automation` | Editor | Writer | `{env}-k8s-rbac-automation` |

- One **Service ID** is created per persona (no API keys provisioned) and automatically added to its Access Group.
- IAM Service roles map directly to Kubernetes RBAC: `Writer` → `edit`, `Manager` → `cluster-admin`.
- The resource group (`niraj-sandbox-nprd` by default) is **pre-existing** — looked up, not created.
- Workload identity for pods uses **Trusted Profiles** (created in `modules/regional`), not Service IDs.

## Trusted Profiles (workload identity)

Each regional cluster gets two Trusted Profiles:

| Profile | Linked service account | IAM permission granted |
|---------|----------------------|------------------------|
| `{env}-{region}-{dc}-tp-apps` | `web-app-a`, `web-app-b` in `mydemo` NS | `SecretsReader` on the shared Secrets Manager instance |
| `{env}-{region}-{dc}-tp-logs-agent` | `logs-agent` in `ibm-observe` NS | `Sender` on the shared Cloud Logs instance |

Pods assume their Trusted Profile automatically via the IKS Compute Resource Token — no long-lived API keys or secrets are mounted.

## Shared observability & security services

| Service | Provisioned by | Instance name pattern | Notes |
|---------|---------------|----------------------|-------|
| **IBM Cloud Logs** | `terraform apply` | `{env}-us-south-{dc}-logs` | Agents in both clusters ship via private ingress endpoint; logs-agent authenticates via Trusted Profile (`Sender` role) |
| **IBM Cloud Monitoring** | `terraform apply` | `{env}-us-south-{dc}-monitoring` | Both monitoring agents use the shared `access_key`; private endpoint only |
| **IBM Key Protect (KMS)** | Pre-existing | — | Root key encrypts Kubernetes secrets at rest on both clusters (`kms_config`); ICD Redis uses provider-managed encryption |
| **IBM Secrets Manager** | Pre-existing | — | Registered as Ingress SM on both clusters; app pods read secrets via `SecretsReader` Trusted Profile |
| **IBM Container Registry (ICR)** | Pre-existing | namespace: `ndp-demo` | Single shared registry; `deploy.sh` builds and pushes both images here; both clusters pull via private endpoint |

## IBM Container Registry (ICR)

- A single **IBM Container Registry** namespace (`ndp-demo`) is shared by both `us-south` and `us-east` clusters.
- `deploy.sh` builds `web-app-a` and `web-app-b` Docker images and pushes them to ICR before Helm deployment.
- Both clusters are configured to pull from ICR via the **private endpoint** (`private.us.icr.io`), keeping image traffic on the IBM private network.
- ICR is a **pre-existing** service — no Terraform provisioning is needed; only the namespace `ndp-demo` must exist before running `deploy.sh`.
- The `ibmcloud cr login` step in `deploy.sh` authenticates Docker to ICR using the `IBMCLOUD_API_KEY`.

## Security posture

| Control | Where |
|---------|-------|
| TLS termination + DDoS / WAF at the edge | IBM Cloud Internet Services (CIS / Cloudflare) |
| Global health-check failover via GLB pool `/status` probe | CIS GLB — pools `us-south-web-app-a`, `us-east-web-app-a` |
| mTLS STRICT between all pods | `k8s/istio/peer-authentication.yaml` |
| Web App B only reachable from web-app-a SA | `helm/web-app-b/templates/authz-policy.yaml` |
| Web App A APIs protected by static secret in the Authorization header (constant-time compare) | `apps/web-app-a/app.py` `auth_required` decorator |
| Container images pulled from shared ICR namespace | IBM Container Registry — `ndp-demo` — private endpoint |
| ICD Redis private endpoint only | `terraform/modules/icd-redis/main.tf` |
| Kubernetes secrets encrypted at rest | KMS (`kms_config` on `base-iks-vpc` module) — both clusters |
| App secrets & TLS certs centrally managed | Shared Secrets Manager — pods read via `SecretsReader` Trusted Profile |
| IAM personas scoped to IKS via Access Groups | `modules/governance` — `dev`, `sre`, `ops`, `automation` |
| No long-lived API keys for workloads | Trusted Profiles on every pod SA (`tp-apps`, `tp-logs-agent`) |
| Containers run as non-root, drop all capabilities | Helm deployment `securityContext` |

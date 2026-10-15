# Terraform – k8s Multi-Cloud PoC

Provisions two single-AZ **IKS-on-VPC** clusters (us-south and us-east) using
[terraform-ibm-modules](https://github.com/terraform-ibm-modules) (TIM) wherever a module exists.  
Naming convention: `{env_type}-{region}-{dc}-{resourcetype}` — e.g. `poc-us-south-3-iks`.

---

## Architecture

```
IBM Cloud Account — Resource Group: niraj-sandbox-nprd (existing)
│
├── Existing, NOT managed here
│   ├── KMS (Key Protect)  us-south   → Kubernetes secret encryption only
│   └── Secrets Manager    us-south   → registered with both clusters
│
├── Governance (global)
│   ├── Access Groups  poc-k8s-rbac-{dev,sre,ops,automation}
│   └── Service IDs    poc-svc-{dev,sre,ops,automation}  (no API keys)
│
├── Common observability (us-south, shared by both clusters)
│   ├── IBM Cloud Logs        poc-us-south-3-logs
│   └── IBM Cloud Monitoring  poc-us-south-3-monitoring
│
├── us-south
│   ├── VPC  poc-us-south-3-vpc
│   │   └── Subnet poc-us-south-3-sn  192.168.0.0/26  (zone us-south-3 only)
│   ├── IKS  poc-us-south-3-iks
│   │   ├── Default worker pool: 3 × bxf.4x16 in us-south-3
│   │   ├── Add-on: Istio
│   │   ├── logs-agent + monitoring-agent (Helm)
│   │   └── Trusted Profiles: poc-us-south-3-tp-apps, poc-us-south-3-tp-logs-agent
│
├── us-east   (mirror: subnet 192.168.0.64/26, zone us-east-3)
│
├── ICD Redis  poc-us-south-3-redis   (common, private endpoint)
└── Transit Gateway  poc-tgw          (us-south VPC <-> us-east VPC)
```

## Module layout

```
terraform/
├── versions.tf      # providers (ibm, helm) + per-cluster helm providers
├── variables.tf     # root inputs
├── main.tf          # orchestration
├── outputs.tf       # outputs consumed by scripts/deploy.sh
├── envs/            # tfvars (identical for both regions — one apply builds both)
└── modules/
    ├── governance/      # TIM resource-group, iam-service-id, iam-access-group
    ├── regional/        # TIM landing-zone-vpc, base-iks-vpc, trusted-profile + Istio add-on
    ├── icd-redis/       # ICD Redis (hand-written; no TIM module used)
    └── transit-gateway/ # Transit Gateway (hand-written)
```

Root-level TIM modules: `cloud-logs`, `cloud-monitoring`, `logs-agent`, `monitoring-agent`.

| Requirement | Implementation |
|-------------|----------------|
| Resource group `niraj-sandbox-nprd` | `resource-group` module, `existing_resource_group_name` |
| Single default pool, one AZ (`-3`) | `base-iks-vpc` with one `default` pool; only zone-3 gets a subnet |
| `bxf.4x16` × 3 | `worker_flavor`, `worker_count` |
| One VPC per region | `landing-zone-vpc` |
| Existing KMS, secrets only | `kms_config` on cluster; worker pool has no boot-volume KMS config |
| Existing Secrets Manager | `enable_secrets_manager_integration` + `existing_secrets_manager_instance_crn` |
| Istio | `ibm_container_addons` (`istio`) — not exposed by `base-iks-vpc` |
| Common logging + monitoring | one `cloud-logs` + one `cloud-monitoring`, agents in both clusters |
| Trusted Profiles | `trusted-profile`: apps (Secrets Manager reader), logs-agent (Logs Sender) |
| Access Groups / Service IDs | `iam-access-group`, `iam-service-id` for dev/sre/ops/automation |

## Prerequisites

| Tool | Min version |
|------|-------------|
| Terraform | 1.5 |
| IBM Cloud provider | 2.5 (required by `landing-zone-vpc`) |
| Helm provider | 3.0 |
| `ibmcloud` CLI, `kubectl`, `jq`, `curl` | used by the TIM modules' local-exec checks |

The clusters are **private-API-only** by default (`disable_public_endpoint = true`).
`terraform apply` installs the agents over the private endpoint, so run it from a
machine/VPN/Schematics workspace that can reach the cluster private service endpoint,
or set `disable_public_endpoint = false` for a first bootstrap.

```bash
export TF_VAR_ibmcloud_api_key="<your-api-key>"
```

## Required input: KMS root key

The existing KMS CRN is the default for `kms_instance_crn`, but a **root key ID is required**:

```bash
ibmcloud ks kms crk ls --instance-id 652971d5-d7cf-48d3-85cf-64d7477134be
# then add to envs/*.tfvars:  kms_root_key_id = "<id>"
```

## Usage

```bash
cd terraform
terraform init
terraform plan  -var-file=envs/us-south.tfvars -var-file=envs/us-east.tfvars
terraform apply -var-file=envs/us-south.tfvars -var-file=envs/us-east.tfvars
```

## Migrating from the previous (`demo-*`) layout

The names, subnets, worker pools and KMS/Secrets Manager ownership all changed, so
`terraform plan` against old state will **destroy and recreate** the clusters, VPCs,
Redis, Transit Gateway and IAM objects, and **destroy the Key Protect and Secrets Manager
instances that the old code created**. Review the plan (or start from a fresh state)
before applying.

## Naming reference

| Resource | Name |
|----------|------|
| VPC | `poc-us-south-3-vpc` |
| Subnet | `poc-us-south-3-sn` |
| IKS cluster | `poc-us-south-3-iks` |
| Cloud Logs / Monitoring | `poc-us-south-3-logs`, `poc-us-south-3-monitoring` |
| Redis | `poc-us-south-3-redis` |
| Transit Gateway | `poc-tgw` |
| Access groups | `poc-k8s-rbac-{dev\|sre\|ops\|automation}` |
| Service IDs | `poc-svc-{dev\|sre\|ops\|automation}` |
| Trusted Profiles | `poc-{region}-3-tp-apps`, `poc-{region}-3-tp-logs-agent` |

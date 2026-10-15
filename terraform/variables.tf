###############################################################################
# Global variables shared across all modules
###############################################################################

variable "ibmcloud_api_key" {
  description = "IBM Cloud API key used by Terraform to provision. Workloads use Trusted Profiles, not API keys."
  type        = string
  sensitive   = true
}

variable "env_type" {
  description = "Environment type used in resource naming (e.g. poc)"
  type        = string
  default     = "poc"
}

variable "dc" {
  description = "AZ number used for the single-AZ clusters and in resource naming (3 => us-south-3 / us-east-3)"
  type        = string
  default     = "3"
}

variable "resource_group_name" {
  description = "Existing resource group that holds all resources"
  type        = string
  default     = "niraj-sandbox-nprd"
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
variable "subnet_cidrs" {
  description = "Worker subnet CIDR per region. Must not overlap (Transit Gateway routes between the VPCs)."
  type        = map(string)
  default = {
    "us-south" = "192.168.0.0/26"  # .0   – .63
    "us-east"  = "192.168.0.64/26" # .64  – .127
  }
}

# ---------------------------------------------------------------------------
# IKS
# ---------------------------------------------------------------------------
variable "worker_flavor" {
  description = "Worker node machine type"
  type        = string
  default     = "bxf.4x16"
}

variable "worker_count" {
  description = "Workers in the single default pool (one zone per cluster)"
  type        = number
  default     = 3
}

variable "operating_system" {
  description = "Worker node operating system"
  type        = string
  default     = "UBUNTU_24_64"
}

variable "kube_version" {
  description = "Kubernetes version; null = IKS default"
  type        = string
  default     = null
}

variable "istio_version" {
  description = "Istio managed add-on version; null = IKS default"
  type        = string
  default     = null
}

variable "disable_public_endpoint" {
  description = "Private-only cluster API. Terraform (agents) and deploy.sh then need private network access."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Existing services (not created by this configuration)
# ---------------------------------------------------------------------------
variable "kms_instance_crn" {
  description = "CRN of the existing KMS instance — Kubernetes secret encryption at rest only"
  type        = string
  default     = "crn:v1:bluemix:public:kms:us-south:a/f0180d9e4d74420198e933a1db8b71e8:652971d5-d7cf-48d3-85cf-64d7477134be::"
}

variable "kms_root_key_id" {
  description = "ID of an existing root key in the KMS instance (used by both clusters)"
  type        = string
}

variable "secrets_manager_instance_crn" {
  description = "CRN of the existing Secrets Manager instance"
  type        = string
  default     = "crn:v1:bluemix:public:secrets-manager:us-south:a/f0180d9e4d74420198e933a1db8b71e8:375c4c2b-1bb1-4aa8-b8a3-ac30de9a62b5::"
}

# ---------------------------------------------------------------------------
# Workload identity (Trusted Profile)
# ---------------------------------------------------------------------------
variable "app_namespace" {
  description = "Kubernetes namespace of the apps allowed to assume the Trusted Profile"
  type        = string
  default     = "mydemo"
}

variable "app_service_accounts" {
  description = "Service accounts in app_namespace linked to the Trusted Profile (Helm default = chart name)"
  type        = list(string)
  default     = ["web-app-a", "web-app-b"]
}

# ---------------------------------------------------------------------------
# Observability (common instances)
# ---------------------------------------------------------------------------
variable "cloud_logs_plan" {
  description = "IBM Cloud Logs plan"
  type        = string
  default     = "standard"
}

variable "monitoring_plan" {
  description = "IBM Cloud Monitoring plan (lite|graduated-tier)"
  type        = string
  default     = "lite"
}

# ---------------------------------------------------------------------------
# Transit Gateway / Redis
# ---------------------------------------------------------------------------
variable "tgw_name" {
  description = "Override name for the Transit Gateway (defaults to naming-convention value)"
  type        = string
  default     = ""
}

variable "redis_plan" {
  description = "ICD Redis service plan (standard)"
  type        = string
  default     = "standard"
}

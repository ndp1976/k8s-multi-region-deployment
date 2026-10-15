variable "env_type" {
  type        = string
  description = "Environment type used in resource naming (e.g. poc)"
}

variable "region" {
  type        = string
  description = "IBM Cloud region (us-south | us-east)"
}

variable "dc" {
  type        = string
  description = "Availability zone number used for the single-AZ cluster (1, 2 or 3)"

  validation {
    condition     = contains(["1", "2", "3"], var.dc)
    error_message = "dc must be 1, 2 or 3."
  }
}

variable "resource_group_id" {
  type        = string
  description = "ID of the resource group for all resources"
}

variable "tags" {
  type        = list(string)
  description = "Tags applied to all resources"
  default     = []
}

variable "subnet_cidr" {
  type        = string
  description = "CIDR of the single worker subnet (also becomes the zone address prefix)"
}

# ── Cluster ──────────────────────────────────────────────────────────────────
variable "worker_flavor" {
  type        = string
  description = "Worker node machine type"
}

variable "worker_count" {
  type        = number
  description = "Number of workers in the default pool (single zone)"
}

variable "operating_system" {
  type        = string
  description = "Worker node operating system"
}

variable "kube_version" {
  type        = string
  description = "Kubernetes version; null = IKS default"
  default     = null
}

variable "disable_public_endpoint" {
  type        = bool
  description = "Disable the public cluster API endpoint (private-only API server)"
}

variable "istio_version" {
  type        = string
  description = "Istio managed add-on version; null = IKS default"
  default     = null
}

# ── Existing services ────────────────────────────────────────────────────────
variable "kms_instance_crn" {
  type        = string
  description = "CRN of the existing KMS (Key Protect) instance — Kubernetes secret encryption only"
}

variable "kms_root_key_id" {
  type        = string
  description = "ID of the existing root key in the KMS instance"
}

variable "secrets_manager_instance_crn" {
  type        = string
  description = "CRN of the existing Secrets Manager instance"
}

# ── Workload identity ────────────────────────────────────────────────────────
variable "app_namespace" {
  type        = string
  description = "Kubernetes namespace of the applications allowed to assume the apps Trusted Profile"
}

variable "app_service_accounts" {
  type        = list(string)
  description = "Kubernetes service accounts (in app_namespace) linked to the apps Trusted Profile"
}

variable "cloud_logs_guid" {
  type        = string
  description = "GUID of the common IBM Cloud Logs instance (logs-agent Trusted Profile policy)"
}

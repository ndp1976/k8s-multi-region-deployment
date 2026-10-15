###############################################################################
# Regional module — one VPC + one single-AZ IKS cluster + workload identities
#
# Built on terraform-ibm-modules:
#   landing-zone-vpc/ibm, base-iks-vpc/ibm, trusted-profile/ibm
#
# Naming: {env_type}-{region}-{dc}-{resourcetype}
###############################################################################

terraform {
  required_providers {
    ibm = {
      source  = "IBM-Cloud/ibm"
      version = ">= 2.5.0, < 3.0.0"
    }
  }
}

locals {
  prefix = "${var.env_type}-${var.region}-${var.dc}"
  zone   = "${var.region}-${var.dc}" # e.g. us-south-3

  # landing-zone-vpc addresses zones as zone-1/2/3; only the dc zone gets a subnet
  subnets = {
    for z in ["zone-1", "zone-2", "zone-3"] : z => z == "zone-${var.dc}" ? [{
      name           = "sn"
      cidr           = var.subnet_cidr
      acl_name       = "acl"
      public_gateway = false
    }] : []
  }

  # KMS: the root key is looked up in the existing instance (kube secrets only)
  kms_crn_parts = split(":", var.kms_instance_crn)
  kms_guid      = local.kms_crn_parts[7]

  sm_guid = split(":", var.secrets_manager_instance_crn)[7]
}

###############################################################################
# 1. VPC — one per region, one subnet in the single AZ (dc)
###############################################################################
module "vpc" {
  source  = "terraform-ibm-modules/landing-zone-vpc/ibm"
  version = "10.1.1"

  region            = var.region
  resource_group_id = var.resource_group_id
  prefix            = local.prefix
  name              = "vpc"
  resource_tags     = var.tags

  # No public gateway — workers reach IBM services over private endpoints.
  use_public_gateways = {
    zone-1 = false
    zone-2 = false
    zone-3 = false
  }

  subnets = local.subnets

  # The module's IBM-internal and VPC-connectivity ACL rules are scoped to this
  # list (default 10.0.0.0/8). It must cover our subnet or they never match and
  # DNS/UDP/ICMP/Calico traffic is denied (konnectivity-agent never ready).
  network_cidrs = [var.subnet_cidr]

  network_acls = [{
    name                         = "acl"
    add_ibm_cloud_internal_rules = true
    add_vpc_connectivity_rules   = true
    prepend_ibm_rules            = true
    rules = [
      {
        name        = "allow-inbound-https"
        action      = "allow"
        direction   = "inbound"
        source      = "0.0.0.0/0"
        destination = var.subnet_cidr
        protocol    = "tcp"
        port_min    = 443
        port_max    = 443
      },
      {
        name        = "allow-inbound-http"
        action      = "allow"
        direction   = "inbound"
        source      = "0.0.0.0/0"
        destination = var.subnet_cidr
        protocol    = "tcp"
        port_min    = 80
        port_max    = 80
      },
      {
        # stateless ACL: allow replies to connections initiated by the workers
        name        = "allow-inbound-return-tcp"
        action      = "allow"
        direction   = "inbound"
        source      = "0.0.0.0/0"
        destination = var.subnet_cidr
        protocol    = "tcp"
        port_min    = 1024
        port_max    = 65535
      },
      {
        name        = "allow-outbound-all"
        action      = "allow"
        direction   = "outbound"
        source      = var.subnet_cidr
        destination = "0.0.0.0/0"
      },
    ]
  }]
}

###############################################################################
# 2. IKS cluster — default worker pool only, single AZ
###############################################################################
module "iks" {
  source  = "terraform-ibm-modules/base-iks-vpc/ibm"
  version = "1.3.5"

  cluster_name      = "${local.prefix}-iks"
  region            = var.region
  resource_group_id = var.resource_group_id
  vpc_id            = module.vpc.vpc_id
  resource_tags     = var.tags
  kube_version      = var.kube_version

  vpc_subnets = {
    default = [for s in module.vpc.subnet_zone_list : {
      id         = s.id
      zone       = s.zone
      cidr_block = s.cidr
    } if s.zone == local.zone]
  }

  worker_pools = [{
    subnet_prefix    = "default"
    pool_name        = "default"
    machine_type     = var.worker_flavor
    workers_per_zone = var.worker_count
    operating_system = var.operating_system
  }]

  disable_public_endpoint      = var.disable_public_endpoint
  cluster_config_endpoint_type = var.disable_public_endpoint ? "private" : "default"

  # Existing KMS — Kubernetes secret encryption at rest ONLY. Worker boot
  # volumes are intentionally left on provider-managed encryption
  # (no boot_volume_encryption_kms_config on the worker pool).
  kms_config = {
    crk_id           = var.kms_root_key_id
    instance_id      = local.kms_guid
    private_endpoint = true
  }

  # Existing Secrets Manager — registered as the cluster Ingress SM instance;
  # the module also creates the IKS → Secrets Manager authorization policy.
  enable_secrets_manager_integration    = true
  existing_secrets_manager_instance_crn = var.secrets_manager_instance_crn
}

###############################################################################
# 3. Istio managed add-on
###############################################################################
resource "ibm_container_addons" "istio" {
  cluster           = module.iks.cluster_id
  resource_group_id = var.resource_group_id

  # Leave add-ons managed elsewhere (e.g. the CSI drivers) untouched
  manage_all_addons = false

  addons {
    name    = "istio"
    version = var.istio_version
  }
}

###############################################################################
# 4. Trusted Profiles — workload identity for pods (no long-lived API keys)
###############################################################################

# 4a. Application pods → read secrets from the existing Secrets Manager
module "trusted_profile_apps" {
  source  = "terraform-ibm-modules/trusted-profile/ibm"
  version = "4.2.0"

  trusted_profile_name        = "${local.prefix}-tp-apps"
  trusted_profile_description = "Workload identity for ${var.app_namespace} pods on ${module.iks.cluster_name}"

  trusted_profile_policies = [{
    unique_identifier = "sm-reader"
    roles             = ["SecretsReader"]
    resources = [{
      service              = "secrets-manager"
      resource_instance_id = local.sm_guid
    }]
  }]

  trusted_profile_links = [{
    unique_identifier = "apps"
    cr_type           = "IKS_SA"
    links = [for sa in var.app_service_accounts : {
      crn       = module.iks.cluster_crn
      namespace = var.app_namespace
      name      = sa
    }]
  }]
}

# 4b. logs-agent → send logs to the common Cloud Logs instance
module "trusted_profile_logs_agent" {
  source  = "terraform-ibm-modules/trusted-profile/ibm"
  version = "4.2.0"

  trusted_profile_name        = "${local.prefix}-tp-logs-agent"
  trusted_profile_description = "Logs agent identity on ${module.iks.cluster_name}"

  trusted_profile_policies = [{
    unique_identifier = "logs-sender"
    roles             = ["Sender"]
    resource_attributes = [
      {
        name     = "serviceInstance"
        operator = "stringEquals"
        value    = var.cloud_logs_guid
      },
      {
        name  = "serviceName"
        value = "logs"
      },
    ]
  }]

  trusted_profile_links = [{
    unique_identifier = "logs-agent"
    cr_type           = "IKS_SA"
    links = [{
      crn       = module.iks.cluster_crn
      namespace = "ibm-observe"
      name      = "logs-agent"
    }]
  }]
}

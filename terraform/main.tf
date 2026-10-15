###############################################################################
# Root orchestration module
#
# Terraform does not allow dynamic provider aliases inside for_each modules.
# Each regional module is therefore declared explicitly — one block per region.
#
# Naming: {env_type}-{region}-{dc}-{resourcetype}
###############################################################################

locals {
  tags = [
    "env:${var.env_type}",
    "managed-by:terraform",
    "project:k8s-multi-cloud-sample",
  ]

  observability_region = "us-south"
  cloud_logs_name      = "${var.env_type}-${local.observability_region}-${var.dc}-logs"
  monitoring_name      = "${var.env_type}-${local.observability_region}-${var.dc}-monitoring"
}

###############################################################################
# 1. Governance — resource group (existing), service IDs, access groups
###############################################################################
module "governance" {
  source = "./modules/governance"

  env_type            = var.env_type
  resource_group_name = var.resource_group_name
  tags                = local.tags
}

###############################################################################
# 2. Common observability — ONE Cloud Logs + ONE Cloud Monitoring instance
#    shared by both clusters (agents in us-east ship cross-region to us-south)
###############################################################################
module "cloud_logs" {
  source  = "terraform-ibm-modules/cloud-logs/ibm"
  version = "2.1.2"

  providers = {
    ibm = ibm.us_south
  }

  region            = local.observability_region
  resource_group_id = module.governance.resource_group_id
  instance_name     = local.cloud_logs_name
  plan              = var.cloud_logs_plan
  resource_tags     = local.tags
}

module "cloud_monitoring" {
  source  = "terraform-ibm-modules/cloud-monitoring/ibm"
  version = "1.15.16"

  providers = {
    ibm = ibm.us_south
  }

  region            = local.observability_region
  resource_group_id = module.governance.resource_group_id
  instance_name     = local.monitoring_name
  plan              = var.monitoring_plan
  resource_tags     = local.tags
}

###############################################################################
# 3. us-south — VPC + IKS (AZ us-south-3) + Istio + Trusted Profiles
###############################################################################
module "regional_us_south" {
  source = "./modules/regional"

  providers = {
    ibm = ibm.us_south
  }

  env_type          = var.env_type
  region            = "us-south"
  dc                = var.dc
  resource_group_id = module.governance.resource_group_id
  tags              = local.tags
  subnet_cidr       = var.subnet_cidrs["us-south"]

  worker_flavor           = var.worker_flavor
  worker_count            = var.worker_count
  operating_system        = var.operating_system
  kube_version            = var.kube_version
  istio_version           = var.istio_version
  disable_public_endpoint = var.disable_public_endpoint

  kms_instance_crn             = var.kms_instance_crn
  kms_root_key_id              = var.kms_root_key_id
  secrets_manager_instance_crn = var.secrets_manager_instance_crn

  app_namespace        = var.app_namespace
  app_service_accounts = var.app_service_accounts
  cloud_logs_guid      = module.cloud_logs.guid
}

###############################################################################
# 4. us-east — VPC + IKS (AZ us-east-3) + Istio + Trusted Profiles
###############################################################################
module "regional_us_east" {
  source = "./modules/regional"

  providers = {
    ibm = ibm.us_east
  }

  env_type          = var.env_type
  region            = "us-east"
  dc                = var.dc
  resource_group_id = module.governance.resource_group_id
  tags              = local.tags
  subnet_cidr       = var.subnet_cidrs["us-east"]

  worker_flavor           = var.worker_flavor
  worker_count            = var.worker_count
  operating_system        = var.operating_system
  kube_version            = var.kube_version
  istio_version           = var.istio_version
  disable_public_endpoint = var.disable_public_endpoint

  kms_instance_crn             = var.kms_instance_crn
  kms_root_key_id              = var.kms_root_key_id
  secrets_manager_instance_crn = var.secrets_manager_instance_crn

  app_namespace        = var.app_namespace
  app_service_accounts = var.app_service_accounts
  cloud_logs_guid      = module.cloud_logs.guid
}

###############################################################################
# 5. Logging + monitoring agents (Helm) — both clusters → common instances
#    Auth: logs-agent uses its Trusted Profile; the monitoring agent needs the
#    instance access key (the Sysdig agent has no Trusted Profile support).
###############################################################################
module "logs_agent_us_south" {
  source  = "terraform-ibm-modules/logs-agent/ibm"
  version = "1.26.4"

  providers = {
    ibm  = ibm.us_south
    helm = helm.us_south
  }

  cluster_id                    = module.regional_us_south.cluster_id
  cluster_resource_group_id     = module.governance.resource_group_id
  cluster_config_endpoint_type  = var.disable_public_endpoint ? "private" : "default"
  cloud_logs_ingress_endpoint   = module.cloud_logs.ingress_private_endpoint
  logs_agent_iam_mode           = "TrustedProfile"
  logs_agent_trusted_profile_id = module.regional_us_south.logs_agent_trusted_profile_id

  depends_on = [module.regional_us_south]
}

module "logs_agent_us_east" {
  source  = "terraform-ibm-modules/logs-agent/ibm"
  version = "1.26.4"

  providers = {
    ibm  = ibm.us_east
    helm = helm.us_east
  }

  cluster_id                    = module.regional_us_east.cluster_id
  cluster_resource_group_id     = module.governance.resource_group_id
  cluster_config_endpoint_type  = var.disable_public_endpoint ? "private" : "default"
  cloud_logs_ingress_endpoint   = module.cloud_logs.ingress_private_endpoint
  logs_agent_iam_mode           = "TrustedProfile"
  logs_agent_trusted_profile_id = module.regional_us_east.logs_agent_trusted_profile_id

  depends_on = [module.regional_us_east]
}

module "monitoring_agent_us_south" {
  source  = "terraform-ibm-modules/monitoring-agent/ibm"
  version = "1.25.9"

  providers = {
    ibm  = ibm.us_south
    helm = helm.us_south
  }

  cluster_id                   = module.regional_us_south.cluster_id
  cluster_resource_group_id    = module.governance.resource_group_id
  cluster_config_endpoint_type = var.disable_public_endpoint ? "private" : "default"
  instance_region              = local.observability_region
  access_key                   = module.cloud_monitoring.access_key
  use_private_endpoint         = true

  depends_on = [module.regional_us_south]
}

module "monitoring_agent_us_east" {
  source  = "terraform-ibm-modules/monitoring-agent/ibm"
  version = "1.25.9"

  providers = {
    ibm  = ibm.us_east
    helm = helm.us_east
  }

  cluster_id                   = module.regional_us_east.cluster_id
  cluster_resource_group_id    = module.governance.resource_group_id
  cluster_config_endpoint_type = var.disable_public_endpoint ? "private" : "default"
  instance_region              = local.observability_region
  access_key                   = module.cloud_monitoring.access_key
  use_private_endpoint         = true

  depends_on = [module.regional_us_east]
}

###############################################################################
# 6. ICD Redis — single common instance in us-south (private endpoint)
#    Uses provider-managed encryption (no Key Protect integration).
###############################################################################
module "redis_common" {
  source = "./modules/icd-redis"

  providers = {
    ibm = ibm.us_south
  }

  env_type          = var.env_type
  region            = "us-south"
  dc                = var.dc
  resource_group_id = module.governance.resource_group_id
  redis_plan        = var.redis_plan
  tags              = local.tags
}

###############################################################################
# 7. Transit Gateway — connects both regional VPCs
###############################################################################
module "transit_gateway" {
  source = "./modules/transit-gateway"

  providers = {
    ibm = ibm.us_south
  }

  env_type          = var.env_type
  resource_group_id = module.governance.resource_group_id
  tgw_name          = var.tgw_name
  tags              = local.tags

  vpc_connections = {
    "us-south" = module.regional_us_south.vpc_crn
    "us-east"  = module.regional_us_east.vpc_crn
  }
}

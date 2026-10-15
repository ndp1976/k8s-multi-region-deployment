###############################################################################
# Governance module — resource group lookup, IAM Service IDs and IAM Access
# Groups for the k8s RBAC personas (dev, sre, ops, automation).
#
# Built on terraform-ibm-modules:
#   resource-group/ibm, iam-service-id/ibm, iam-access-group/ibm
#
# Workload identities use Trusted Profiles (created next to each cluster in
# modules/regional); no service-ID API keys are created here.
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
  # persona => IKS platform + service roles (service roles map to k8s RBAC:
  # Reader=view, Writer=edit, Manager=cluster-admin)
  personas = {
    dev        = ["Viewer", "Writer"]
    sre        = ["Operator", "Writer"]
    ops        = ["Administrator", "Manager"]
    automation = ["Editor", "Writer"]
  }
}

###############################################################################
# 1. Resource Group — use the existing group; do not create a new one
###############################################################################
module "resource_group" {
  source  = "terraform-ibm-modules/resource-group/ibm"
  version = "1.6.1"

  existing_resource_group_name = var.resource_group_name
}

###############################################################################
# 2. Service IDs — one per persona (no API keys are provisioned)
###############################################################################
module "service_id" {
  source   = "terraform-ibm-modules/iam-service-id/ibm"
  version  = "1.3.1"
  for_each = local.personas

  iam_service_id_name        = "${var.env_type}-svc-${each.key}"
  iam_service_id_description = "Service ID for k8s RBAC persona: ${each.key}"
  resource_tags              = var.tags
  iam_service_policies       = {}
}

###############################################################################
# 3. Access Groups — one per persona, with its Service ID as a member
###############################################################################
module "access_group" {
  source   = "terraform-ibm-modules/iam-access-group/ibm"
  version  = "1.9.5"
  for_each = local.personas

  access_group_name = "${var.env_type}-k8s-rbac-${each.key}"
  description       = "Access group for k8s RBAC persona: ${each.key}"
  resource_tags     = var.tags
  service_ids       = [module.service_id[each.key].service_id]
  dynamic_rules     = {}

  policies = {
    iks = {
      roles = each.value
      tags  = []
      resources = [{
        service           = "containers-kubernetes"
        resource_group_id = module.resource_group.resource_group_id
      }]
    }
  }
}

###############################################################################
# Terraform & provider version constraints
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    ibm = {
      source = "IBM-Cloud/ibm"
      # terraform-ibm-modules/landing-zone-vpc requires >= 2.5.0
      version = ">= 2.5.0, < 3.0.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0.0, < 4.0.0"
    }
  }
}

###############################################################################
# Providers — credentials supplied via environment variable IBMCLOUD_API_KEY
# or via the ibmcloud_api_key input variable.
###############################################################################
# Default provider (no alias) — global resources (IAM, resource group)
provider "ibm" {
  ibmcloud_api_key = var.ibmcloud_api_key
  region           = "us-south"
}

provider "ibm" {
  ibmcloud_api_key = var.ibmcloud_api_key
  region           = "us-south"
  alias            = "us_south"
}

provider "ibm" {
  ibmcloud_api_key = var.ibmcloud_api_key
  region           = "us-east"
  alias            = "us_east"
}

###############################################################################
# Helm providers — one per cluster, used to install the logging / monitoring
# agents. The API server is private-only by default, so the machine that runs
# `terraform apply` must have private network access to both clusters.
###############################################################################
data "ibm_container_cluster_config" "us_south" {
  provider          = ibm.us_south
  cluster_name_id   = module.regional_us_south.cluster_id
  resource_group_id = module.governance.resource_group_id
  endpoint_type     = var.disable_public_endpoint ? "private" : null
}

data "ibm_container_cluster_config" "us_east" {
  provider          = ibm.us_east
  cluster_name_id   = module.regional_us_east.cluster_id
  resource_group_id = module.governance.resource_group_id
  endpoint_type     = var.disable_public_endpoint ? "private" : null
}

provider "helm" {
  alias = "us_south"
  kubernetes = {
    host                   = data.ibm_container_cluster_config.us_south.host
    token                  = data.ibm_container_cluster_config.us_south.token
    cluster_ca_certificate = data.ibm_container_cluster_config.us_south.ca_certificate
  }
}

provider "helm" {
  alias = "us_east"
  kubernetes = {
    host                   = data.ibm_container_cluster_config.us_east.host
    token                  = data.ibm_container_cluster_config.us_east.token
    cluster_ca_certificate = data.ibm_container_cluster_config.us_east.ca_certificate
  }
}

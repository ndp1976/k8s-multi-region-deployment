###############################################################################
# Transit Gateway module
# Connects the two regional VPCs so they can communicate privately.
#
# Naming: {env_type}-tgw   (global resource — no region/dc in name)
###############################################################################

terraform {
  required_providers {
    ibm = {
      source  = "IBM-Cloud/ibm"
      version = ">= 1.63.0"
    }
  }
}

###############################################################################
# Transit Gateway (global routing)
###############################################################################
resource "ibm_tg_gateway" "this" {
  name           = coalesce(var.tgw_name, "${var.env_type}-tgw")
  location       = "us-south" # global gateway registered in us-south
  global         = true       # allows cross-MZR connectivity
  resource_group = var.resource_group_id
  tags           = var.tags
}

###############################################################################
# Connections — one per VPC
###############################################################################
resource "ibm_tg_connection" "vpc" {
  for_each     = var.vpc_connections
  gateway      = ibm_tg_gateway.this.id
  network_type = "vpc"
  name         = "${var.env_type}-${each.key}-tgw-conn"
  network_id   = each.value
}

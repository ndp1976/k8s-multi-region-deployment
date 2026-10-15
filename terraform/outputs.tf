###############################################################################
# Root-level outputs
###############################################################################

output "resource_group_id" {
  description = "ID of the shared resource group"
  value       = module.governance.resource_group_id
}

output "access_group_ids" {
  description = "IAM access group IDs keyed by RBAC persona"
  value       = module.governance.access_group_ids
}

output "service_id_ids" {
  description = "IAM service IDs keyed by RBAC persona"
  value       = module.governance.service_id_ids
}

output "trusted_profile_ids" {
  description = "Application Trusted Profile IDs keyed by region"
  value = {
    "us-south" = module.regional_us_south.apps_trusted_profile_id
    "us-east"  = module.regional_us_east.apps_trusted_profile_id
  }
}

output "cloud_logs_crn" {
  description = "CRN of the common IBM Cloud Logs instance"
  value       = module.cloud_logs.crn
}

output "cloud_monitoring_crn" {
  description = "CRN of the common IBM Cloud Monitoring instance"
  value       = module.cloud_monitoring.crn
}

output "vpc_ids" {
  description = "VPC IDs keyed by region"
  value = {
    "us-south" = module.regional_us_south.vpc_id
    "us-east"  = module.regional_us_east.vpc_id
  }
}

output "cluster_ids" {
  description = "IKS cluster IDs keyed by region"
  value = {
    "us-south" = module.regional_us_south.cluster_id
    "us-east"  = module.regional_us_east.cluster_id
  }
}

output "cluster_names" {
  description = "IKS cluster names keyed by region"
  value = {
    "us-south" = module.regional_us_south.cluster_name
    "us-east"  = module.regional_us_east.cluster_name
  }
}

output "cluster_endpoints" {
  description = "Private service endpoint URLs keyed by region"
  sensitive   = true
  value = {
    "us-south" = module.regional_us_south.private_service_endpoint_url
    "us-east"  = module.regional_us_east.private_service_endpoint_url
  }
}

output "ingress_hostnames" {
  description = "Cluster Ingress subdomains keyed by region"
  value = {
    "us-south" = module.regional_us_south.ingress_hostname
    "us-east"  = module.regional_us_east.ingress_hostname
  }
}

output "transit_gateway_id" {
  description = "Transit Gateway resource ID"
  value       = module.transit_gateway.tgw_id
}

# The single common Redis instance (us-south) serves both regions. The
# per-region output names/keys are kept so scripts/deploy.sh keeps working.
output "redis_hostnames" {
  description = "Common ICD Redis private hostname, keyed by consuming region"
  value = {
    "us-south" = module.redis_common.redis_hostname
    "us-east"  = module.redis_common.redis_hostname
  }
}

output "redis_ports" {
  description = "Common ICD Redis port, keyed by consuming region"
  value = {
    "us-south" = module.redis_common.redis_port
    "us-east"  = module.redis_common.redis_port
  }
}

output "redis_password_us_south" {
  description = "Common ICD Redis admin password (us-south consumers)"
  value       = module.redis_common.redis_password
  sensitive   = true
}

output "redis_password_us_east" {
  description = "Common ICD Redis admin password (us-east consumers)"
  value       = module.redis_common.redis_password
  sensitive   = true
}

output "redis_cert_us_south" {
  description = "Common ICD Redis TLS certificate (base64) (us-south consumers)"
  value       = module.redis_common.redis_cert
  sensitive   = true
}

output "redis_cert_us_east" {
  description = "Common ICD Redis TLS certificate (base64) (us-east consumers)"
  value       = module.redis_common.redis_cert
  sensitive   = true
}

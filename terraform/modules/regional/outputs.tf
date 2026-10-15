output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "vpc_crn" {
  description = "VPC CRN (Transit Gateway connection)"
  value       = module.vpc.vpc_crn
}

output "cluster_id" {
  description = "IKS cluster ID"
  value       = module.iks.cluster_id
}

output "cluster_name" {
  description = "IKS cluster name"
  value       = module.iks.cluster_name
}

output "cluster_crn" {
  description = "IKS cluster CRN"
  value       = module.iks.cluster_crn
}

output "private_service_endpoint_url" {
  description = "Private service endpoint URL of the cluster API"
  value       = module.iks.private_service_endpoint_url
}

output "ingress_hostname" {
  description = "Cluster Ingress subdomain"
  value       = module.iks.ingress_hostname
}

output "apps_trusted_profile_id" {
  description = "Trusted Profile assumed by application pods"
  value       = module.trusted_profile_apps.profile_id
}

output "logs_agent_trusted_profile_id" {
  description = "Trusted Profile assumed by the logs-agent"
  value       = module.trusted_profile_logs_agent.profile_id
}

output "istio_addon_id" {
  description = "Istio add-on resource ID (ordering handle for dependants)"
  value       = ibm_container_addons.istio.id
}

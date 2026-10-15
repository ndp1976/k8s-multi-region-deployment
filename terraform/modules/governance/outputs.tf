output "resource_group_id" {
  description = "ID of the existing resource group"
  value       = module.resource_group.resource_group_id
}

output "resource_group_name" {
  description = "Name of the existing resource group"
  value       = module.resource_group.resource_group_name
}

output "access_group_ids" {
  description = "Map of persona → Access Group ID"
  value       = { for k, v in module.access_group : k => v.id }
}

output "service_id_ids" {
  description = "Map of persona → Service ID"
  value       = { for k, v in module.service_id : k => v.service_id }
}

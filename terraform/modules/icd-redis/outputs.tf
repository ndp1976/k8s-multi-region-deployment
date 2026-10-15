output "redis_id" {
  value = ibm_database.redis.id
}

output "redis_crn" {
  value = ibm_database.redis.resource_crn
}

output "redis_guid" {
  value = ibm_database.redis.guid
}

# Connection details are read back via the ibm_database_connection data source
# after the instance is created. The deploy script uses:
#   terraform output -raw redis_password_us_south
# which is populated by the root outputs.tf using ibm_database.adminpassword.

output "redis_password" {
  description = "Admin password for the ICD Redis instance"
  value       = ibm_database.redis.adminpassword
  sensitive   = true
}

# Hostname and port are retrieved via the ibm_database_connection data source
# declared in main.tf; exposed through the outputs below.
output "redis_hostname" {
  description = "Private endpoint hostname of the Redis instance"
  value       = data.ibm_database_connection.redis_conn.rediss[0].hosts[0].hostname
}

output "redis_port" {
  value = data.ibm_database_connection.redis_conn.rediss[0].hosts[0].port
}

output "redis_cert" {
  description = "TLS certificate for the Redis connection (base64)"
  value       = data.ibm_database_connection.redis_conn.rediss[0].certificate[0].certificate_base64
  sensitive   = true
}

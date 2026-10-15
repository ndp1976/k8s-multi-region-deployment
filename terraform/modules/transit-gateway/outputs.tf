output "tgw_id" { value = ibm_tg_gateway.this.id }
output "tgw_crn" { value = ibm_tg_gateway.this.crn }
output "connection_ids" {
  value = { for k, v in ibm_tg_connection.vpc : k => v.connection_id }
}

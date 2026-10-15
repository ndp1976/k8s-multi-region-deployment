variable "env_type" {
  type = string
}

variable "resource_group_id" {
  type = string
}

variable "tags" {
  type    = list(string)
  default = []
}

variable "tgw_name" {
  type    = string
  default = ""
}

variable "vpc_connections" {
  type        = map(string)
  description = "Map of region-key → VPC CRN to attach to the Transit Gateway"
}

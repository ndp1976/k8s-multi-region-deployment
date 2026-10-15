variable "env_type" {
  type        = string
  description = "Environment type (e.g. poc)"
}

variable "resource_group_name" {
  type        = string
  description = "Name of the existing IBM Cloud resource group"
}

variable "tags" {
  type        = list(string)
  description = "Tags to apply to all resources"
  default     = []
}

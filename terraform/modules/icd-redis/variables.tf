variable "env_type" {
  type = string
}

variable "region" {
  type = string
}

variable "dc" {
  type = string
}

variable "resource_group_id" {
  type = string
}

variable "tags" {
  type    = list(string)
  default = []
}

variable "redis_plan" {
  type        = string
  description = "ICD Redis service plan"
  default     = "standard"
}

variable "member_count" {
  type        = number
  description = "Number of Redis members (2 = master + replica)"
  default     = 2
}

variable "member_memory_mb" {
  type        = number
  description = "TOTAL memory across all members in MB (provider allocation_mb is group-wide). Shared Compute requires >= 8192 here (4096 per member x 2 members)."
  default     = 8192
}

variable "member_disk_mb" {
  type        = number
  description = "TOTAL disk across all members in MB (provider allocation_mb is group-wide). Minimum 2048 (1024 per member x 2 members)."
  default     = 10240
}

variable "member_cpu_count" {
  type        = number
  description = "Dedicated CPU per member (0 = shared)"
  default     = 0
}

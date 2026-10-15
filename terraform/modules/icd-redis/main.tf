###############################################################################
# ICD Redis module
# Provisions IBM Cloud Databases for Redis.
# - Provider-managed encryption (IBM-managed key, no Key Protect integration)
# - Private-only endpoints (no public endpoint)
# - Naming: {env_type}-{region}-{dc}-redis
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
# ICD Redis instance
###############################################################################
resource "ibm_database" "redis" {
  name              = "${var.env_type}-${var.region}-${var.dc}-redis"
  service           = "databases-for-redis"
  plan              = var.redis_plan # "standard" (no free tier for ICD)
  location          = var.region
  resource_group_id = var.resource_group_id
  service_endpoints = "private" # private-only endpoint
  tags              = var.tags

  # ── Disk / memory sizing ──────────────────────────────────────────────────
  group {
    group_id = "member"
    memory {
      allocation_mb = var.member_memory_mb
    }
    disk {
      allocation_mb = var.member_disk_mb
    }
    cpu {
      allocation_count = var.member_cpu_count
    }
    members {
      allocation_count = var.member_count # 2 = 1 master + 1 read replica
    }
  }

  timeouts {
    create = "30m"
    update = "20m"
    delete = "15m"
  }
}

###############################################################################
# Connection info data source — reads hostname, port, TLS cert after creation
###############################################################################
data "ibm_database_connection" "redis_conn" {
  deployment_id = ibm_database.redis.id
  user_type     = "database"
  user_id       = ibm_database.redis.adminuser
  endpoint_type = "private"

  depends_on = [ibm_database.redis]
}

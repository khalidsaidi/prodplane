variable "aws_region" {
  description = "AWS region for resource deployment"
  type        = string
}

variable "region_deploy_cluster" {
  description = "Region containing the selected network and cache resources"
  type        = string
}

variable "environment" {
  description = "The deployment environment (e.g., dev, staging, prod)"
  type        = string
}

variable "cluster_environment" {
  description = "environnement cluster (ex: non-prod, prod, etc.)"
  type        = string
}

variable "redis_clusters" {
  description = "Configuration des clusters Redis en multi-AZ"
  type = map(object({
    description                = string
    replication_group_id       = string
    node_type                  = string
    engine                     = string
    engine_version             = string
    number_cache_clusters      = number
    parameter_group_name       = string
    automatic_failover_enabled = bool
    transit_encryption_enabled = bool
    at_rest_encryption_enabled = bool
    port                       = number
  }))
  default = {}
}

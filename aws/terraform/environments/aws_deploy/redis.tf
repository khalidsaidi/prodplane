resource "aws_security_group" "redis" {
  count       = length(var.redis_clusters) > 0 ? 1 : 0
  provider    = aws.deploy_cluster
  name        = "${var.environment}-redis-sg"
  description = "Security group for Redis clusters"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  dynamic "ingress" {
    for_each = toset([for cache in var.redis_clusters : cache.port])
    content {
      description = "Client access to a configured cache port"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = data.terraform_remote_state.network.outputs.private_subnet_cidrs
    }
  }

  egress {
    description = "Autoriser tout le trafic sortant"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = data.terraform_remote_state.network.outputs.private_subnet_cidrs
  }
}


resource "aws_elasticache_subnet_group" "redis" {
  count      = length(var.redis_clusters) > 0 ? 1 : 0
  provider   = aws.deploy_cluster
  name       = "${var.environment}-redis-subnet-group"
  subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids

  tags = {
    Name = "${var.environment}-redis-subnet-group"
  }
}


resource "aws_elasticache_replication_group" "redis" {
  provider                   = aws.deploy_cluster
  for_each                   = var.redis_clusters
  description                = each.value.description
  automatic_failover_enabled = each.value.automatic_failover_enabled
  replication_group_id       = each.value.replication_group_id
  node_type                  = each.value.node_type
  replicas_per_node_group    = each.value.number_cache_clusters - 1
  parameter_group_name       = each.value.parameter_group_name
  port                       = each.value.port
  engine                     = each.value.engine
  engine_version             = each.value.engine_version
  subnet_group_name          = aws_elasticache_subnet_group.redis[0].name
  security_group_ids         = [aws_security_group.redis[0].id]
  transit_encryption_enabled = each.value.transit_encryption_enabled
  at_rest_encryption_enabled = each.value.at_rest_encryption_enabled
  auth_token_update_strategy = null
  lifecycle {
    ignore_changes = [
      auth_token,
      auth_token_update_strategy
    ]
  }
}


resource "aws_ssm_parameter" "redis_endpoint_master" {
  for_each  = var.redis_clusters
  name      = "/${var.project_name}/${var.environment}/redis/${each.key}/primary"
  type      = "String"
  value     = aws_elasticache_replication_group.redis[each.key].primary_endpoint_address
  overwrite = true
  lifecycle { prevent_destroy = true }
}

resource "aws_ssm_parameter" "redis_endpoint_replica" {
  for_each = var.redis_clusters
  name     = "/${var.project_name}/${var.environment}/redis/${each.key}/reader"
  type     = "String"
  value = coalesce(
    aws_elasticache_replication_group.redis[each.key].reader_endpoint_address,
    aws_elasticache_replication_group.redis[each.key].primary_endpoint_address
  )
  overwrite = true
  lifecycle { prevent_destroy = true }
}

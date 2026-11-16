mock_provider "aws" {}
mock_provider "aws" { alias = "deploy_cluster" }
override_data {
  target = data.terraform_remote_state.network
  values = { outputs = { vpc_id = "vpc-12345678", private_subnet_ids = ["subnet-12345678"], private_subnet_cidrs = ["10.0.1.0/24"] } }
}
variables {
  aws_region            = "us-east-1"
  region_deploy_cluster = "us-west-2"
  environment           = "team-a"
  cluster_environment   = "non-prod"
}
run "no_implicit_cache" {
  command = plan
  assert {
    condition     = length(aws_elasticache_replication_group.redis) == 0 && length(aws_security_group.redis) == 0
    error_message = "Cache resources must be opt-in."
  }
}
run "caller_cache" {
  command = plan
  variables {
    redis_clusters = {
      sessions = {
        description                = "Example caller-owned cache"
        replication_group_id       = "team-a-sessions"
        node_type                  = "cache.t3.micro"
        engine                     = "redis"
        engine_version             = "7.1"
        number_cache_clusters      = 2
        parameter_group_name       = "default.redis7"
        automatic_failover_enabled = true
        transit_encryption_enabled = true
        at_rest_encryption_enabled = true
        port                       = 6380
      }
    }
  }
  assert {
    condition     = aws_ssm_parameter.redis_endpoint_master["sessions"].name == "/prodplane/team-a/redis/sessions/primary"
    error_message = "Endpoint publication must follow arbitrary caller cache keys."
  }
  assert {
    condition     = aws_elasticache_replication_group.redis["sessions"].port == 6380 && one(aws_security_group.redis[0].ingress).from_port == 6380
    error_message = "Network access must follow the selected cache port."
  }
  assert {
    condition     = aws_elasticache_replication_group.redis["sessions"].transit_encryption_enabled && aws_elasticache_replication_group.redis["sessions"].at_rest_encryption_enabled
    error_message = "The cache's encryption choices must reach the resource."
  }
}

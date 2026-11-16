output "cache_endpoints" {
  value = {
    for name, cache in aws_elasticache_replication_group.redis : name => {
      primary = cache.primary_endpoint_address
      reader  = coalesce(cache.reader_endpoint_address, cache.primary_endpoint_address)
      port    = cache.port
      tls     = cache.transit_encryption_enabled
    }
  }
}

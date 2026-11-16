data "aws_secretsmanager_secret_version" "application" {
  for_each  = var.application_secrets
  secret_id = each.value.source_secret_id
}

resource "kubernetes_secret" "application" {
  for_each = var.application_secrets
  metadata {
    name      = each.key
    namespace = kubernetes_namespace.namespace.metadata[0].name
  }
  type = each.value.type
  data = {
    for target_key, source_key in each.value.keys :
    target_key => jsondecode(data.aws_secretsmanager_secret_version.application[each.key].secret_string)[source_key]
  }
}

resource "kubernetes_config_map" "application" {
  for_each = var.config_maps
  metadata {
    name      = each.key
    namespace = kubernetes_namespace.namespace.metadata[0].name
  }
  data = each.value
}

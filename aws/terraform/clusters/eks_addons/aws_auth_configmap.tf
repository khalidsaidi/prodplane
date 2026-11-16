data "kubernetes_config_map" "aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }
  # The managed node group creates this ConfigMap before add-ons authorize builds.
  count = var.configure_aws_auth_configmap ? 1 : 0
}

locals {
  new_roles = [
    {
      rolearn  = data.terraform_remote_state.security.outputs.codebuild_service_role_arn
      username = "build:codebuild"
      groups   = ["system:masters"]
    },
    {
      rolearn  = data.terraform_remote_state.security.outputs.eks_cluster_role_arn
      username = "eks:cluster-role"
      groups   = ["system:masters"]
    }
  ]

  # Do not turn malformed existing mappings into an empty list and overwrite
  # node/operator access. Invalid YAML or a non-list value must fail the plan.
  existing_roles     = var.configure_aws_auth_configmap ? coalesce(yamldecode(lookup(data.kubernetes_config_map.aws_auth[0].data, "mapRoles", "[]")), []) : []
  platform_role_arns = [for role in local.new_roles : role.rolearn]
  updated_roles = concat([
    for role in local.existing_roles : role
    if !contains(local.platform_role_arns, role.rolearn)
  ], local.new_roles)

  existing_labels = var.configure_aws_auth_configmap ? coalesce(data.kubernetes_config_map.aws_auth[0].metadata[0].labels, {}) : {}
  existing_annotations = var.configure_aws_auth_configmap ? {
    for key, value in coalesce(data.kubernetes_config_map.aws_auth[0].metadata[0].annotations, {}) : key => value
    if key != "kubectl.kubernetes.io/last-applied-configuration"
  } : {}

  rendered_config = templatefile("${path.module}/templates/aws-auth-config.tpl", {
    labels      = local.existing_labels
    annotations = local.existing_annotations
    data = merge(var.configure_aws_auth_configmap ? data.kubernetes_config_map.aws_auth[0].data : {}, {
      mapRoles = yamlencode(local.updated_roles)
    })
  })
}

# Use the state-bound provider, including when this component runs independently.
# Removing add-ons must never delete the EKS-managed access ConfigMap.
resource "kubectl_manifest" "aws_auth" {
  count      = var.configure_aws_auth_configmap ? 1 : 0
  yaml_body  = local.rendered_config
  apply_only = true
}

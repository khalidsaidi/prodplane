resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.8.1"

  set {
    name  = "clusterName"
    value = data.terraform_remote_state.eks.outputs.eks_cluster_id
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "vpcId"
    value = data.terraform_remote_state.network.outputs.vpc_id
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.aws_load_balancer_controller_role.arn
  }

  # Configure webhook settings to handle endpoint issues
  set {
    name  = "webhookNamespaceSelectors"
    value = ""
  }

  set {
    name  = "enableServiceMutatorWebhook"
    value = "true"
  }

  set {
    name  = "enableEndpointSlices"
    value = "true"
  }

  # Add readiness and liveness probe configurations
  set {
    name  = "livenessProbe.initialDelaySeconds"
    value = "60"
  }

  set {
    name  = "readinessProbe.initialDelaySeconds"
    value = "30"
  }

  depends_on = [aws_iam_role_policy_attachment.load_balancer_controller_policy_attachment]
}

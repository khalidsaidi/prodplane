output "eks_cluster_id" {
  value = aws_eks_cluster.this.id
}

output "eks_cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "eks_cluster_version" {
  value = aws_eks_cluster.this.version
}

output "eks_node_role_arn" {
  value = data.terraform_remote_state.security.outputs.eks_node_group_role_arn
}

output "eks_cluster_certificate_authority" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "eks_cluster_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "eks_cluster_identity_oidc_issuer" {
  value = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "eks_oidc_provider_arn" {
  value       = aws_iam_openid_connect_provider.eks_oidc.arn
  description = "The ARN of the IAM OIDC provider for the EKS cluster"
}

output "aws_region" {
  value = var.aws_region
}

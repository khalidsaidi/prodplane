output "eks_cluster_role_arn" {
  value       = aws_iam_role.eks_cluster_role.arn
  description = "ARN of EKS cluster role for the environment"
}

output "eks_node_group_role_arn" {
  value       = aws_iam_role.eks_node_group_role.arn
  description = "ARN of node group role for the environment"
}

output "eks_nodes_sg_id" {
  value = aws_security_group.eks_nodes_sg.id
}

output "eks_cluster_security_group_id" {
  description = "Security Group ID of the EKS cluster"
  value       = aws_security_group.eks_cluster_sg.id
}

output "eks_cluster_security_group_arn" {
  description = "Security Group ARN of the EKS cluster"
  value       = aws_security_group.eks_cluster_sg.arn
}

output "codebuild_service_role_arn" {
  value = aws_iam_role.codebuild_service_role.arn
}

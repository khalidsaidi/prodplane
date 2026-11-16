variable "aws_region" {
  description = "AWS region for security policies"
  type        = string
}


variable "cluster_environment" {
  description = "Cluster environment name (e.g., non-prod, prod)"
  type        = string
}

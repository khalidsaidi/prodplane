variable "aws_region" {
  description = "AWS region used for constructing ARNs and API connectivity"
  type        = string
}

variable "cluster_environment" {
  description = "Cluster environment name (e.g., non-prod, prod)"
  type        = string
}

variable "efs_creation_token" {
  description = "Unique creation token for the EFS file system"
  type        = string
  validation {
    condition     = length(var.efs_creation_token) > 0 && length(var.efs_creation_token) <= 64 && !can(regex("[[:cntrl:]]", var.efs_creation_token))
    error_message = "Use a creation token of 1 to 64 printable characters, matching the network root."
  }
}

variable "efs_name" {
  description = "Name tag for the EFS file system"
  type        = string
}

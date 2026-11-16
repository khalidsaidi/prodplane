variable "aws_region" {
  description = "AWS region for security policies"
  type        = string
}

variable "cluster_environment" {
  description = "Cluster environment name (e.g., non-prod, prod)"
  type        = string
}


variable "node_group_desired_capacity" {
  description = "Desired capacity for EKS node group"
  type        = number
}

variable "node_group_max_capacity" {
  description = "Maximum capacity for EKS node group"
  type        = number
}

variable "node_group_min_capacity" {
  description = "Minimum capacity for EKS node group"
  type        = number
}

variable "node_instance_type" {
  description = "Instance type for EKS nodes"
  type        = string
}

variable "node_disk_size" {
  description = "Optional node root-disk size in GiB. Omit to retain the AWS default; changing it can replace the node group."
  type        = number
  default     = null
}

variable "eks_version" {
  description = "An EKS Kubernetes version currently offered in the target region. Check support status before creating or upgrading a cluster."
  type        = string
}

variable "ssh_key_name" {
  description = "SSH key name for connecting to the EKS nodes"
  type        = string
}

variable "node_version" {
  description = "Optional staged-upgrade override. By default managed nodes follow the configured control-plane version."
  type        = string
  default     = null
}

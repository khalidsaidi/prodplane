variable "aws_region" {
  description = "AWS region used for constructing ARNs and API connectivity"
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*[0-9]$", var.aws_region))
    error_message = "Use an AWS region identifier."
  }
}

variable "cluster_environment" {
  description = "Cluster environment name (e.g., non-prod, prod)"
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]*$", var.cluster_environment))
    error_message = "Use a cluster-class identifier without spaces or path/shell characters."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "availability_zones" {
  description = "The two distinct availability zones used by this network topology"
  type        = list(string)
  validation {
    condition     = length(var.availability_zones) == 2 && length(distinct(var.availability_zones)) == 2
    error_message = "This network requires exactly two distinct availability zones."
  }
}

variable "private_subnet_cidrs" {
  description = "Exactly two private subnet CIDRs, one per availability zone"
  type        = list(string)
  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "Supply exactly two private subnet CIDRs for this network topology."
  }
}

variable "public_subnet_cidrs" {
  description = "Exactly two public subnet CIDRs, one per availability zone"
  type        = list(string)
  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "Supply exactly two public subnet CIDRs for this network topology."
  }
}

variable "bastion_ami_id" {
  description = "Debian/Ubuntu AMI with apt and systemd; requires AWS CLI and the amazon-efs-utils mount helper for EFS discovery/mounting."
  type        = string
}

variable "bastion_instance_type" {
  description = "Instance type for the bastion host"
  type        = string
}

variable "bastion_key_name" {
  description = "SSH key name for the bastion host"
  type        = string
}






variable "client_cidr_block" {
  description = "IP pool for clients"
  type        = string
  default     = "172.16.0.0/22"
}

variable "organization" {
  type    = string
  default = "Example Organization"
}

variable "domain_name" {
  type        = string
  description = "vpn domain name"
  validation {
    condition     = can(regex("^(\\*\\.)?[A-Za-z0-9_][A-Za-z0-9_.-]*$", var.domain_name))
    error_message = "Use a single ASCII DNS name for the VPN endpoint (Punycode for internationalized names)."
  }
}


variable "vpn_users" {
  type = map(object({
    email = string
  }))
  validation {
    condition     = alltrue([for name in keys(var.vpn_users) : name != "" && !strcontains(name, "/") && !strcontains(name, "\\") && !can(regex("[[:cntrl:]]", name))])
    error_message = "VPN user keys are filename aliases; path separators and control characters are not allowed."
  }
}

variable "route53_zone_id" {
  description = "The ID of the Route53 hosted zone"
  type        = string
}


variable "bastion_ssh_cidrs" {
  description = "Operator networks allowed to reach the bastion over SSH."
  type        = list(string)
}

variable "efs_creation_token" {
  description = "The exact creation token supplied to the cluster storage root; used for unambiguous bastion discovery."
  type        = string
  validation {
    condition     = length(var.efs_creation_token) > 0 && length(var.efs_creation_token) <= 64 && !can(regex("[[:cntrl:]]", var.efs_creation_token))
    error_message = "Use a creation token of 1 to 64 printable characters."
  }
}

variable "bastion_instance_profile" {
  description = "Existing EC2 instance profile authorizing EFS discovery from the bastion (elasticfilesystem:DescribeFileSystems). Supply it unless the AMI has another intentional AWS credential source."
  type        = string
  default     = null
}

variable "peering" {
  description = "Optional same-account VPC peering, in this or another region. No external network is required by default."
  type = object({
    vpc_id         = string
    cidr           = string
    route_table_id = string
    region         = optional(string)
  })
  default = null
}

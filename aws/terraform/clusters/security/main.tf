terraform {
  required_version = ">= 1.7"
  backend "s3" {}
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.40, < 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  eks_cluster_name = "${var.project_name}-${var.cluster_environment}-cluster"
}

# IAM Role for EKS Cluster
resource "aws_iam_role" "eks_cluster_role" {
  name = "${var.cluster_environment}-${var.aws_region}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow",
        Principal = { Service = ["eks.amazonaws.com"] },
        Action    = "sts:AssumeRole"
      },
      {
        Effect = "Allow",
        Principal = {
          AWS = aws_iam_role.codebuild_service_role.arn
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# IAM Role for EKS Node Group
data "aws_iam_policy_document" "eks_node_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node_group_role" {
  name = "${var.cluster_environment}-${var.aws_region}-eks-node-group-role"

  assume_role_policy = data.aws_iam_policy_document.eks_node_assume_role_policy.json
}

resource "aws_iam_instance_profile" "eks_nodes_instance_profile" {
  name = "${var.cluster_environment}-${var.aws_region}-eks-nodes-instance-profile"
  role = aws_iam_role.eks_node_group_role.name
}

# Security Group for Bastion Host retrieved from network remote state
# Security Group for EKS nodes
resource "aws_security_group" "eks_nodes_sg" {
  name        = "${var.cluster_environment}-sg-eks-nodes"
  description = "Security group for EKS nodes in ${var.cluster_environment}"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow traffic within the same SG
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  # Allow higher ports from VPC CIDR (for node-to-node)
  ingress {
    from_port   = 1025
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.network.outputs.vpc_cidr]
  }

  tags = {
    Name = "${var.cluster_environment}-eks-nodes"
  }
}


resource "aws_security_group" "eks_cluster_sg" {
  name        = "${var.cluster_environment}-eks-cluster-sg"
  description = "Security group for EKS cluster ${var.cluster_environment}"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.network.outputs.vpc_cidr]
  }

  ingress {
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.network.outputs.vpc_cidr]
  }

  # control plane metric
  ingress {
    from_port   = 2379
    to_port     = 2380
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.network.outputs.vpc_cidr]
  }

  # Trafic entre pods (CNI)
  ingress {
    from_port = 0
    to_port   = 65535
    protocol  = "tcp"
    self      = true # Entre instances du même SG
  }

  # DNS interne
  ingress {
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.network.outputs.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                                              = "${var.cluster_environment}-eks-cluster-sg"
    "kubernetes.io/cluster/${local.eks_cluster_name}" = "owned"
  }
}

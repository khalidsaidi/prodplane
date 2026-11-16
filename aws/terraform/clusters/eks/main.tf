locals {
  eks_cluster_name = "${var.project_name}-${var.cluster_environment}-cluster"
}

terraform {
  backend "s3" {}
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.40, < 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "tls" {}


resource "aws_eks_cluster" "this" {
  name     = local.eks_cluster_name
  role_arn = data.terraform_remote_state.security.outputs.eks_cluster_role_arn

  vpc_config {
    security_group_ids      = [data.terraform_remote_state.security.outputs.eks_nodes_sg_id]
    subnet_ids              = data.terraform_remote_state.network.outputs.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  version = var.eks_version

  tags = {
    Environment = var.cluster_environment
    Name        = local.eks_cluster_name
  }
}

resource "aws_security_group_rule" "allow_bastion_https_to_eks" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id # ← SG automatique EKS
  source_security_group_id = data.terraform_remote_state.network.outputs.bastion_sg_id
  description              = "Allow bastion to access EKS control plane"
  depends_on               = [aws_eks_cluster.this]
}


resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_environment}-ng-default"
  node_role_arn   = data.terraform_remote_state.security.outputs.eks_node_group_role_arn
  subnet_ids      = data.terraform_remote_state.network.outputs.private_subnet_ids
  version         = coalesce(var.node_version, aws_eks_cluster.this.version)
  disk_size       = var.node_disk_size

  instance_types = [var.node_instance_type]

  scaling_config {
    desired_size = var.node_group_desired_capacity
    max_size     = var.node_group_max_capacity
    min_size     = var.node_group_min_capacity
  }

  capacity_type = "ON_DEMAND"

  remote_access {
    ec2_ssh_key = var.ssh_key_name
  }

  tags = {
    ClusterEnvironment = var.cluster_environment
    Environment        = var.cluster_environment
  }
}

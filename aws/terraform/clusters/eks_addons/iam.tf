# Fluent Bit IAM Role
resource "aws_iam_role" "fluent_bit_role" {
  name = "${var.cluster_environment}-${var.aws_region}-fluent-bit-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Federated = data.terraform_remote_state.eks.outputs.eks_oidc_provider_arn
        },
        Action = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringEquals = {
            "${replace(data.terraform_remote_state.eks.outputs.eks_cluster_identity_oidc_issuer, "https://", "")}:sub" = "system:serviceaccount:${var.fluentbit_namespace}:fluent-bit",
            "${replace(data.terraform_remote_state.eks.outputs.eks_cluster_identity_oidc_issuer, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Fluent Bit IAM Policy
resource "aws_iam_policy" "fluent_bit_policy" {
  name        = "${var.cluster_environment}-${var.aws_region}-fluent-bit-policy"
  description = "Policy for Fluent Bit to send logs to CloudWatch"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
          "logs:DescribeLogGroups",
          "logs:PutRetentionPolicy"
        ],
        Resource = "*"
      }
    ]
  })
}

# Attach policy to role
resource "aws_iam_role_policy_attachment" "fluent_bit_policy_attachment" {
  role       = aws_iam_role.fluent_bit_role.name
  policy_arn = aws_iam_policy.fluent_bit_policy.arn
}

# EBS CSI IAM Role
resource "aws_iam_role" "ebs_csi_driver_role" {
  name = "${var.cluster_environment}-${var.aws_region}-ebs-csi-driver-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Federated = data.terraform_remote_state.eks.outputs.eks_oidc_provider_arn
        },
        Action = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringEquals = {
            "${replace(data.terraform_remote_state.eks.outputs.eks_cluster_identity_oidc_issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa",
            "${replace(data.terraform_remote_state.eks.outputs.eks_cluster_identity_oidc_issuer, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

# AWS Load Balancer Controller IAM Role
resource "aws_iam_role" "aws_load_balancer_controller_role" {
  name = "${var.cluster_environment}-${var.aws_region}-aws-load-balancer-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Federated = data.terraform_remote_state.eks.outputs.eks_oidc_provider_arn
        },
        Action = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringEquals = {
            "${replace(data.terraform_remote_state.eks.outputs.eks_cluster_identity_oidc_issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller",
            "${replace(data.terraform_remote_state.eks.outputs.eks_cluster_identity_oidc_issuer, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow",
        Principal = {
          Service = "elasticloadbalancing.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# EFS CSI IAM Role
resource "aws_iam_role" "efs_csi_driver_role" {
  name = "${var.cluster_environment}-${var.aws_region}-efs-csi-driver-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Federated = data.terraform_remote_state.eks.outputs.eks_oidc_provider_arn
        },
        Action = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringEquals = {
            "${replace(data.terraform_remote_state.eks.outputs.eks_cluster_identity_oidc_issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:efs-csi-controller-sa",
            "${replace(data.terraform_remote_state.eks.outputs.eks_cluster_identity_oidc_issuer, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}


resource "aws_iam_policy" "eks_management_policy" {
  name        = "${var.cluster_environment}-${var.aws_region}-eks-management-policy"
  description = "Policy for managing EKS resources in ${var.cluster_environment}"
  policy      = file("${path.module}/policies/${var.cluster_environment}/eks_management_policy.json")
}

resource "aws_iam_policy" "ecr_policy" {
  name        = "${var.cluster_environment}-${var.aws_region}-ecr-policy"
  description = "Policy for ECR access in ${var.cluster_environment}"
  policy      = file("${path.module}/policies/${var.cluster_environment}/ecr_policy.json")
}

resource "aws_iam_policy" "fluentbit_write_policy" {
  name        = "${var.cluster_environment}-${var.aws_region}-fluentbit-write-policy"
  description = "Policy for FluentBit log writing in ${var.cluster_environment}"
  policy      = file("${path.module}/policies/${var.cluster_environment}/fluentbit_write_policy.json")
}


resource "aws_iam_role_policy_attachment" "eks_management_policy_attachment" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = aws_iam_policy.eks_management_policy.arn
}

resource "aws_iam_role_policy_attachment" "ecr_policy_attachment" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = aws_iam_policy.ecr_policy.arn
}

resource "aws_iam_role_policy_attachment" "fluentbit_cluster_attachment" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = aws_iam_policy.fluentbit_write_policy.arn
}



resource "aws_iam_role_policy_attachment" "fluentbit_node_attachment" {
  role       = aws_iam_role.eks_node_group_role.name
  policy_arn = aws_iam_policy.fluentbit_write_policy.arn
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller_policy_attachment" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

resource "aws_iam_role_policy_attachment" "amazon_ebs_csi_driver_policy" {
  role       = aws_iam_role.ebs_csi_driver_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicyV2"
}

resource "aws_iam_role_policy_attachment" "amazon_efs_csi_driver_policy" {
  role       = aws_iam_role.efs_csi_driver_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

resource "aws_iam_policy" "aws_lb_controller_policy" {
  name        = "${var.cluster_environment}-${var.aws_region}-lb-controller-policy"
  description = "Policy for AWS Load Balancer Controller in ${var.cluster_environment}"
  # Matches controller v2.8.1 shipped in chart 1.8.1; see policies/README.md.
  policy = file("${path.module}/policies/${var.cluster_environment}/load_balancer_controller_policy.json")
}


resource "aws_iam_role_policy_attachment" "load_balancer_controller_policy_attachment" {
  role       = aws_iam_role.aws_load_balancer_controller_role.name
  policy_arn = aws_iam_policy.aws_lb_controller_policy.arn
}

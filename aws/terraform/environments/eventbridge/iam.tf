resource "aws_iam_role" "eventbridge" {
  count = length(var.rules) > 0 ? 1 : 0
  name  = "${var.project_name}-${var.environment}-${var.aws_region}-events"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "events.amazonaws.com" } }]
  })
}

resource "aws_iam_policy" "eventbridge" {
  count = length(var.rules) > 0 ? 1 : 0
  name  = "${var.project_name}-${var.environment}-${var.aws_region}-events"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "codebuild:StartBuild"
      Resource = distinct([for rule in var.rules : rule.codebuild_project_arn])
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eventbridge" {
  count      = length(var.rules) > 0 ? 1 : 0
  role       = aws_iam_role.eventbridge[0].name
  policy_arn = aws_iam_policy.eventbridge[0].arn
}

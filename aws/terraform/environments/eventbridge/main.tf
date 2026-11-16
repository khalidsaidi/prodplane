terraform {
  required_version = ">= 1.3"
  backend "s3" {}
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 3.40, < 6.0" }
  }
}

resource "aws_cloudwatch_event_bus" "application" {
  for_each = var.event_buses
  name     = each.value
}

resource "aws_cloudwatch_event_rule" "application" {
  for_each       = var.rules
  name           = "${var.project_name}-${var.environment}-build-${each.key}"
  description    = each.value.description
  event_bus_name = each.value.event_bus_name
  event_pattern  = each.value.event_pattern
  depends_on     = [aws_cloudwatch_event_bus.application]
}

resource "aws_cloudwatch_event_target" "build" {
  for_each       = var.rules
  rule           = aws_cloudwatch_event_rule.application[each.key].name
  event_bus_name = each.value.event_bus_name
  target_id      = "build"
  arn            = each.value.codebuild_project_arn
  role_arn       = aws_iam_role.eventbridge[0].arn
  input          = each.value.input
  dynamic "input_transformer" {
    for_each = each.value.input_transformer == null ? [] : [each.value.input_transformer]
    content {
      input_paths    = input_transformer.value.input_paths
      input_template = input_transformer.value.input_template
    }
  }
  depends_on = [aws_iam_role_policy_attachment.eventbridge]
}

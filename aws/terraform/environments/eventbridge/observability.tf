resource "aws_cloudwatch_event_rule" "log" {
  for_each       = var.log_targets
  name           = "${var.project_name}-${var.environment}-log-${each.key}"
  event_bus_name = each.value.event_bus_name
  event_pattern  = each.value.event_pattern
  depends_on     = [aws_cloudwatch_event_bus.application]
}

resource "aws_cloudwatch_log_resource_policy" "events" {
  count       = length(var.log_targets) > 0 ? 1 : 0
  policy_name = "${var.project_name}-${var.environment}-event-logs"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "delivery.logs.amazonaws.com"] }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = distinct([for route in var.log_targets : "${trimsuffix(route.log_group_arn, ":*")}:*"])
    }]
  })
}

resource "aws_cloudwatch_event_target" "log" {
  for_each       = var.log_targets
  rule           = aws_cloudwatch_event_rule.log[each.key].name
  event_bus_name = each.value.event_bus_name
  target_id      = "log"
  arn            = trimsuffix(each.value.log_group_arn, ":*")
  depends_on     = [aws_cloudwatch_log_resource_policy.events]
}

resource "aws_schemas_discoverer" "application" {
  for_each    = var.schema_discovery
  source_arn  = each.value.source_arn
  description = each.value.description
  depends_on  = [aws_cloudwatch_event_bus.application]
}

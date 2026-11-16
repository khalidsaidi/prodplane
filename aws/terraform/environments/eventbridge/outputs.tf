output "event_bus_arns" {
  value = { for name, bus in aws_cloudwatch_event_bus.application : name => bus.arn }
}
output "rule_arns" {
  value = { for name, rule in aws_cloudwatch_event_rule.application : name => rule.arn }
}
output "invocation_role_arn" {
  value = try(aws_iam_role.eventbridge[0].arn, null)
}
output "log_rule_arns" {
  value = { for name, rule in aws_cloudwatch_event_rule.log : name => rule.arn }
}
output "schema_discoverer_arns" {
  value = { for name, discoverer in aws_schemas_discoverer.application : name => discoverer.arn }
}

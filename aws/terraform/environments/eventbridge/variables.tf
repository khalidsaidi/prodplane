variable "aws_region" { type = string }
variable "environment" { type = string }
variable "cluster_environment" { type = string }
variable "event_buses" {
  description = "Bus names to create. Rules may also target an existing bus."
  type        = set(string)
  default     = []
}
variable "rules" {
  description = "Application-supplied event patterns and CodeBuild targets. No service names or package formats are assumed."
  type = map(object({
    description           = optional(string, "Trigger an application build")
    event_bus_name        = optional(string, "default")
    event_pattern         = string
    codebuild_project_arn = string
    input                 = optional(string)
    input_transformer = optional(object({
      input_paths    = map(string)
      input_template = string
    }))
  }))
  default = {}
  validation {
    condition     = alltrue([for rule in var.rules : rule.input == null || rule.input_transformer == null])
    error_message = "Specify either input or input_transformer for a rule, not both."
  }
  validation {
    condition     = alltrue([for rule in var.rules : can(jsondecode(rule.event_pattern))])
    error_message = "Every event_pattern must be valid JSON."
  }
}

variable "log_targets" {
  description = "Optional event observability routes to existing CloudWatch log groups."
  type = map(object({
    event_bus_name = optional(string, "default")
    event_pattern  = string
    log_group_arn  = string
  }))
  default = {}
  validation {
    condition     = alltrue([for route in var.log_targets : can(keys(jsondecode(route.event_pattern)))])
    error_message = "Log route event patterns must be JSON objects."
  }
}

variable "schema_discovery" {
  description = "Optional schema discovery for caller-selected event-bus ARNs."
  type = map(object({
    source_arn  = string
    description = optional(string, "Discover schemas for a configured event bus")
  }))
  default = {}
}

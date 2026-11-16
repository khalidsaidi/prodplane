mock_provider "aws" {}
variables {
  aws_region          = "us-east-1"
  environment         = "custom-team"
  cluster_environment = "non-prod"
}
run "no_implicit_events" {
  command = plan
  assert {
    condition     = length(aws_cloudwatch_event_rule.application) == 0 && length(aws_iam_role.eventbridge) == 0
    error_message = "Empty rules must not create application event routes or an invocation role."
  }
}
run "caller_events" {
  command = plan
  variables {
    event_buses = ["example-events"]
    rules = {
      import-ready = {
        event_bus_name        = "example-events"
        event_pattern         = "{\"source\":[\"example.import\"]}"
        codebuild_project_arn = "arn:aws:codebuild:us-east-1:111122223333:project/import-worker"
        input                 = "{\"example\":true}"
      }
      release-ready = {
        event_pattern         = "{\"source\":[\"example.release\"]}"
        codebuild_project_arn = "arn:aws:codebuild:us-east-1:111122223333:project/release-worker"
        input_transformer     = { input_paths = { tag = "$.detail.tag" }, input_template = "{\"tag\":<tag>}" }
      }
    }
  }
  assert {
    condition     = length(aws_cloudwatch_event_target.build) == 2 && aws_cloudwatch_event_target.build["import-ready"].event_bus_name == "example-events"
    error_message = "Arbitrary rules and buses must survive planning."
  }
  assert {
    condition     = toset(jsondecode(aws_iam_policy.eventbridge[0].policy).Statement[0].Resource) == toset([for rule in var.rules : rule.codebuild_project_arn])
    error_message = "Invocation permission must be limited to supplied targets."
  }
}
run "reject_competing_inputs" {
  command = plan
  variables {
    rules = { bad = { event_pattern = "{}", codebuild_project_arn = "arn:aws:codebuild:us-east-1:111122223333:project/example", input = "{}", input_transformer = { input_paths = {}, input_template = "{}" } } }
  }
  expect_failures = [var.rules]
}
run "event_observability" {
  command = plan
  variables {
    event_buses = ["example-events"]
    log_targets = {
      audit = {
        event_bus_name = "example-events"
        event_pattern  = "{\"source\":[\"example.system\"]}"
        log_group_arn  = "arn:aws:logs:us-east-1:111122223333:log-group:/custom/events"
      }
    }
    schema_discovery = {
      events = { source_arn = "arn:aws:events:us-east-1:111122223333:event-bus/example-events" }
    }
  }
  assert {
    condition     = length(aws_schemas_discoverer.application) == 1 && aws_schemas_discoverer.application["events"].source_arn == "arn:aws:events:us-east-1:111122223333:event-bus/example-events"
    error_message = "Schema discovery must be optional and scoped to caller-selected buses."
  }
  assert {
    condition     = (aws_cloudwatch_event_target.log["audit"].role_arn == null || aws_cloudwatch_event_target.log["audit"].role_arn == "") && length(aws_iam_role.eventbridge) == 0
    error_message = "Log targets use resource policies, not an unrelated CodeBuild invocation role."
  }
  assert {
    condition     = jsondecode(aws_cloudwatch_log_resource_policy.events[0].policy_document).Statement[0].Resource == ["arn:aws:logs:us-east-1:111122223333:log-group:/custom/events:*"]
    error_message = "Event log delivery must be limited to the supplied log groups."
  }
}

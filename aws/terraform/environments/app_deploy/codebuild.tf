resource "aws_codebuild_project" "this" {
  for_each = {
    for name, project in local.codebuild_projects_processed :
    name => project
    if project.create == true
  }


  name           = "${var.environment}-${each.key}"
  description    = "CodeBuild project for ${each.key} in ${var.environment} environment"
  service_role   = coalesce(each.value.service_role_arn, data.terraform_remote_state.security.outputs.codebuild_service_role_arn)
  encryption_key = each.value.encryption_key

  vpc_config {
    vpc_id             = data.terraform_remote_state.network.outputs.vpc_id
    subnets            = data.terraform_remote_state.network.outputs.private_subnet_ids
    security_group_ids = [data.terraform_remote_state.security.outputs.eks_nodes_sg_id]
  }

  source {
    type                = "GITHUB"
    location            = each.value.repository_url
    git_clone_depth     = 1
    report_build_status = false
    buildspec           = each.value.buildspec_template == null ? each.value.buildspec : local.buildspec_templates[each.value.buildspec_template]
  }

  source_version = each.value.source_version


  environment {
    compute_type    = each.value.compute_type
    image           = each.value.image
    type            = "LINUX_CONTAINER"
    privileged_mode = each.value.privileged_mode

    dynamic "environment_variable" {
      for_each = each.value.environment_variables
      content {
        name  = environment_variable.value.name
        value = environment_variable.value.value
        type  = environment_variable.value.type
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      status      = "ENABLED"
      group_name  = "/aws/codebuild/${var.environment}/${each.key}"
      stream_name = "${each.key}-build-log"
    }
  }

  artifacts {
    type                   = each.value.artifacts.type
    location               = each.value.artifacts.type == "S3" ? each.value.artifacts.location : null
    name                   = each.value.artifacts.type == "S3" ? each.value.artifacts.name : null
    path                   = each.value.artifacts.type == "S3" ? each.value.artifacts.path : null
    namespace_type         = each.value.artifacts.type == "S3" ? each.value.artifacts.namespace_type : null
    packaging              = each.value.artifacts.type == "S3" ? each.value.artifacts.packaging : null
    override_artifact_name = each.value.artifacts.type == "S3" ? each.value.artifacts.override_artifact_name : null
  }

  build_timeout  = each.value.timeout_in_minutes
  queued_timeout = each.value.queued_timeout_in_minutes
}

# GitHub push webhook for projects that enable it.
resource "aws_codebuild_webhook" "this" {
  for_each = {
    for name, project in local.codebuild_projects_processed :
    name => project
    if project.create == true && project.enable_webhook == true
  }

  project_name = aws_codebuild_project.this[each.key].name
  build_type   = "BUILD"

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PUSH"
    }
  }
}

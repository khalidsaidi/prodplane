variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "aws_account_id" {
  description = "Account ID for the artifact registry used by the ECR_REGISTRY binding"
  type        = string
}

variable "region_deploy_artifact" {
  description = "AWS region for the artifact repository (used in CodeBuild environment variables)"
  type        = string
}

variable "environment" {
  description = "The environment name (e.g., dev, demo, staging, prod-recovery, dev-recovery)"
  type        = string
}

variable "cluster_environment" {
  description = "Cluster environment name (e.g., non-prod, prod) that this environment runs in"
  type        = string
}

variable "codebuild_projects" {
  description = "Caller-defined CodeBuild projects using GitHub sources and Linux runners."
  type = map(object({
    create             = bool
    source_version     = string
    buildspec          = optional(string, "buildspec.yml")
    buildspec_template = optional(string)
    service_role_arn   = optional(string)
    encryption_key     = optional(string)
    privileged_mode    = optional(bool, false)
    repository_url     = string
    artifacts = optional(object({
      type                   = optional(string, "NO_ARTIFACTS")
      location               = optional(string)
      name                   = optional(string, "/")
      path                   = optional(string)
      namespace_type         = optional(string, "BUILD_ID")
      packaging              = optional(string, "NONE")
      override_artifact_name = optional(bool, false)
    }), {})
    environment_variables = list(object({
      name  = string
      value = string
      type  = optional(string, "PLAINTEXT")
    }))
    timeout_in_minutes        = number
    queued_timeout_in_minutes = number
    compute_type              = string
    image                     = string
    enable_webhook            = optional(bool, false)
  }))
  default = {}
  validation {
    condition     = alltrue([for project in var.codebuild_projects : project.buildspec_template == null ? true : contains(["build-image", "deploy-helm"], project.buildspec_template)])
    error_message = "buildspec_template must be build-image or deploy-helm, or omitted for an application-owned buildspec."
  }
  validation {
    condition = alltrue([for project in var.codebuild_projects :
      contains(["NO_ARTIFACTS", "S3"], project.artifacts.type) &&
      (project.artifacts.type != "S3" || try(trimspace(project.artifacts.location) != "", false))
    ])
    error_message = "Artifacts type must be NO_ARTIFACTS or S3; S3 requires a destination bucket in location."
  }
}

variable "application_secrets" {
  description = "JSON Secrets Manager values to expose as Kubernetes secrets. Keys map Kubernetes data keys to source JSON keys."
  type = map(object({
    source_secret_id = string
    keys             = map(string)
    type             = optional(string, "Opaque")
  }))
  default = {}
}

variable "config_maps" {
  description = "Application-owned, non-secret configuration. Keys are ConfigMap names."
  type        = map(map(string))
  default     = {}
}

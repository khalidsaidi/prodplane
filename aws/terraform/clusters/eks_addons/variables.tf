
variable "aws_region" {
  description = "AWS region for EKS addons"
  type        = string
}

variable "cluster_environment" {
  description = "Cluster environment (non-prod/prod)"
  type        = string
}

variable "eks_cluster_name" {
  description = "Optional cluster label for log groups; defaults to the EKS state output."
  type        = string
  default     = ""
}

# ---- Fluent Bit settings ----

variable "fluentbit_namespace" {
  description = "Namespace where Fluent Bit runs"
  type        = string
  default     = "logs"
}

variable "fluentbit_http_server" {
  description = "Enable Fluent Bit HTTP server"
  type        = string
  default     = "On"
  validation {
    condition     = contains(["On", "Off"], var.fluentbit_http_server)
    error_message = "Use On or Off so the collector listener and Kubernetes health probe agree."
  }
}

variable "fluentbit_http_port" {
  description = "Fluent Bit HTTP port"
  type        = number
  default     = 2020
}

variable "fluentbit_read_from_head" {
  description = "Start reading logs from the head"
  type        = string
  default     = "Off"
  validation {
    condition     = contains(["On", "Off"], var.fluentbit_read_from_head)
    error_message = "Use On or Off for Fluent Bit Read_from_Head."
  }
}


variable "fluentbit_storage_path" {
  description = "Path for Fluent Bit local storage buffer"
  type        = string
  default     = "/var/fluent-bit/state/flb-storage/"
}


# ---- Misc addons ----

variable "configure_aws_auth_configmap" {
  description = "Authorize the platform build/deployment roles through aws-auth. Disable only when that authorization is managed externally."
  type        = bool
  default     = true
}


variable "fluentbit_request_cpu" {
  description = "Fluent Bit CPU request"
  type        = string
  default     = "500m"
}

variable "fluentbit_request_memory" {
  description = "Fluent Bit memory request"
  type        = string
  default     = "800Mi"
}

variable "fluentbit_limit_memory" {
  description = "Fluent Bit memory limit"
  type        = string
  default     = "800Mi"
}

variable "fluentbit_cloudwatch_enabled" {
  description = "Send container logs to CloudWatch. Can be combined with persistent file output."
  type        = bool
  default     = true
}

variable "fluentbit_persistence" {
  description = "Optional file archive on an RWX claim. Supply existing_claim or let the add-ons root create a claim."
  type = object({
    existing_claim     = optional(string)
    storage_class_name = optional(string, "efs-sc")
    size               = optional(string, "10Gi")
    mount_path         = optional(string, "/mnt/log-archive")
  })
  default = null
  validation {
    condition     = var.fluentbit_persistence == null ? true : can(regex("^/[^[:space:]]+$", var.fluentbit_persistence.mount_path))
    error_message = "The archive mount_path must be absolute and contain no whitespace."
  }
}

variable "fluentbit_additional_outputs" {
  description = "Optional additional Fluent Bit output configuration supplied by the operator."
  type        = string
  default     = ""
}

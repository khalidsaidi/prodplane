# Shared project identity and Terraform state locations.
variable "project_name" {
  type    = string
  default = "prodplane"
}
variable "state_bucket" {
  type    = string
  default = null
}
variable "state_region" {
  type    = string
  default = null
}
variable "state_key_prefix" {
  type    = string
  default = ""
}
locals {
  platform_state_bucket = coalesce(var.state_bucket, "${var.project_name}-${var.cluster_environment}-eks-terraform-state-bucket")
  platform_state_region = coalesce(var.state_region, var.aws_region)
}
data "aws_caller_identity" "platform_account" {}

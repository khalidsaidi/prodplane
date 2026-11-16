data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = local.platform_state_bucket
    key    = "${var.state_key_prefix}clusters/${var.cluster_environment}/network/terraform.tfstate"
    region = local.platform_state_region
  }
}

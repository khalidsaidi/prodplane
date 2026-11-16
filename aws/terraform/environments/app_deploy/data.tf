data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = local.platform_state_bucket
    key    = "${var.state_key_prefix}clusters/${var.cluster_environment}/network/terraform.tfstate"
    region = local.platform_state_region
  }
}

data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = local.platform_state_bucket
    key    = "${var.state_key_prefix}clusters/${var.cluster_environment}/eks/terraform.tfstate"
    region = local.platform_state_region
  }
}

data "terraform_remote_state" "security" {
  backend = "s3"
  config = {
    bucket = local.platform_state_bucket
    key    = "${var.state_key_prefix}clusters/${var.cluster_environment}/security/terraform.tfstate"
    region = local.platform_state_region
  }
}

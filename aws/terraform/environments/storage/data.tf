

data "terraform_remote_state" "cluster_storage" {
  backend = "s3"
  config = {
    bucket = local.platform_state_bucket
    key    = "${var.state_key_prefix}clusters/${var.cluster_environment}/storage/terraform.tfstate"
    region = local.platform_state_region
  }
}


# Kubernetes resources belong to the EKS cluster selected by this state identity.
data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = local.platform_state_bucket
    key    = "${var.state_key_prefix}clusters/${var.cluster_environment}/eks/terraform.tfstate"
    region = local.platform_state_region
  }
}

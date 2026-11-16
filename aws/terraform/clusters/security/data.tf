data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = local.platform_state_bucket
    key    = "${var.state_key_prefix}clusters/${var.cluster_environment}/network/terraform.tfstate"
    region = local.platform_state_region
  }
}

data "aws_secretsmanager_secret" "ssh_key" {
  name = "${var.cluster_environment}-eks-ssh-public-key"
}

data "aws_secretsmanager_secret_version" "ssh_key_version" {
  secret_id = data.aws_secretsmanager_secret.ssh_key.id
}

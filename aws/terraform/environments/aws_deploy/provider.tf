provider "aws" {
  region = var.aws_region
}

provider "aws" {
  alias  = "deploy_cluster"
  region = var.region_deploy_cluster
}

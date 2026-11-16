provider "aws" {
  region = var.aws_region
}

provider "aws" {
  region = var.aws_region
  alias  = "default"
  # Requester's credentials.
}

provider "aws" {
  alias  = "peer"
  region = local.peer_region
  # Accepter's credentials.
}

terraform {
  required_version = ">= 1.7"
  backend "s3" {}
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 6.0"
    }
    tls = { source = "hashicorp/tls", version = ">= 4.0" }
  }
}

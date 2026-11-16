provider "aws" {
  region = var.aws_region
  alias  = "default"
  # Requester's credentials.
}

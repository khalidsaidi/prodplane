mock_provider "aws" {
  mock_resource "aws_acm_certificate" {
    defaults = { arn = "arn:aws:acm:us-east-1:111122223333:certificate/12345678-1234-1234-1234-123456789012" }
  }
  mock_resource "aws_ec2_client_vpn_endpoint" {
    defaults = { id = "cvpn-endpoint-0123456789abcdef0" }
  }
  mock_data "aws_caller_identity" { defaults = { account_id = "111122223333" } }
}
mock_provider "aws" { alias = "default" }
mock_provider "aws" { alias = "peer" }
mock_provider "tls" {}
mock_provider "local" {}
variables {
  aws_region            = "us-east-1"
  cluster_environment   = "non-prod"
  vpc_cidr              = "10.10.0.0/16"
  availability_zones    = ["us-east-1a", "us-east-1b"]
  private_subnet_cidrs  = ["10.10.1.0/24", "10.10.2.0/24"]
  public_subnet_cidrs   = ["10.10.3.0/24", "10.10.4.0/24"]
  bastion_ami_id        = "ami-12345678"
  bastion_instance_type = "t3.micro"
  bastion_key_name      = "fixture"
  efs_creation_token    = "fixture-efs-token"
  bastion_ssh_cidrs     = ["192.0.2.10/32"]
  domain_name           = "vpn.example.com"
  route53_zone_id       = "ZEXAMPLE"
  vpn_users             = {}
}
run "no_required_external_network" {
  command = plan
  assert {
    condition     = length(aws_vpc_peering_connection.peer) == 0 && length(aws_route.to_peer_private) == 0 && length(aws_route.from_peer) == 0
    error_message = "The platform network must not require an application database network."
  }
}
run "same_region_peer" {
  command = apply
  variables {
    peering = { vpc_id = "vpc-87654321", cidr = "10.20.0.0/16", route_table_id = "rtb-87654321" }
  }
  assert {
    condition     = aws_vpc_peering_connection.peer[0].auto_accept && length(aws_route.to_peer_private) == 2 && length(aws_route_table.public_1.route) == 2 && length(aws_route_table.public_2.route) == 2 && length(aws_vpc_peering_connection_accepter.peer) == 0
    error_message = "Same-region peering must follow caller connectivity without a separate accepter."
  }
}
run "cross_region_peer" {
  command = apply
  variables {
    peering = { vpc_id = "vpc-87654321", cidr = "10.20.0.0/16", route_table_id = "rtb-87654321", region = "us-west-2" }
  }
  assert {
    condition     = local.peer_region == "us-west-2" && length(aws_vpc_peering_connection_accepter.peer) == 1 && length(aws_route.from_peer) == 1
    error_message = "Cross-region peering must use the supplied peer region and bidirectional routes."
  }
}

run "vpn_only_bastion_access" {
  command = apply
  variables { bastion_ssh_cidrs = [] }
  assert {
    condition     = length(aws_security_group.bastion_sg.ingress) == 1 && contains(one(aws_security_group.bastion_sg.ingress).security_groups, aws_security_group.client_vpn_sg.id)
    error_message = "An empty operator CIDR list must retain only the VPN access rule."
  }
}

run "reject_ignored_third_zone" {
  command = plan
  variables { availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"] }
  expect_failures = [var.availability_zones]
}
run "reject_duplicate_zone" {
  command = plan
  variables { availability_zones = ["us-east-1a", "us-east-1a"] }
  expect_failures = [var.availability_zones]
}
run "reject_ignored_extra_subnets" {
  command = plan
  variables {
    private_subnet_cidrs = ["10.10.1.0/24", "10.10.2.0/24", "10.10.5.0/24"]
    public_subnet_cidrs  = ["10.10.3.0/24", "10.10.4.0/24", "10.10.6.0/24"]
  }
  expect_failures = [var.private_subnet_cidrs, var.public_subnet_cidrs]
}

run "reject_profile_path_escape" {
  command = plan
  variables { vpn_users = { "../outside" = { email = "operator@example.com" } } }
  expect_failures = [var.vpn_users]
}
run "reject_profile_directive_in_endpoint" {
  command = plan
  variables { domain_name = "vpn.example.com\nscript-security 2" }
  expect_failures = [var.domain_name]
}
run "reject_shell_text_in_region" {
  command = plan
  variables { aws_region = "us-east-1; unexpected-command" }
  expect_failures = [var.aws_region]
}

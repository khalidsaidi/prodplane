
# SG attached to the Client VPN endpoint (controls traffic from/to the clients)
resource "aws_security_group" "client_vpn_sg" {
  name        = "client-vpn-sg"
  description = "Security group for Client VPN endpoint"
  vpc_id      = aws_vpc.main_vpc.id # Reference the main VPC created

  ingress {
    description = "Allow OpenVPN from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "Allow OpenVPN from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # autoriser tout en egress
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "client-vpn-sg" }
}

# Client VPN endpoint (certificate-based authentication)
resource "aws_ec2_client_vpn_endpoint" "public_vpn" {
  description            = "public client-vpn"
  server_certificate_arn = aws_acm_certificate.server_acm.arn
  client_cidr_block      = var.client_cidr_block
  split_tunnel           = true
  vpc_id                 = aws_vpc.main_vpc.id # Reference the main VPC created
  security_group_ids     = [aws_security_group.client_vpn_sg.id]
  dns_servers            = [] # Optionnel: pour  pousser des DNS custom
  transport_protocol     = "tcp"
  vpn_port               = 443

  authentication_options {
    type                       = "certificate-authentication"
    root_certificate_chain_arn = aws_acm_certificate.client_root_ca_acm.arn
  }

  connection_log_options {
    enabled = false
  }

  tags = { Name = "client-vpn" }
}

# Association of the endpoint with a subnet (creates the ENI on the VPC side)
resource "aws_ec2_client_vpn_network_association" "assoc" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.public_vpn.id
  subnet_id              = aws_subnet.public_1.id #var.association_subnet_id
}

# Authorization to access the VPC network
resource "aws_ec2_client_vpn_authorization_rule" "allow_vpc" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.public_vpn.id
  target_network_cidr    = var.vpc_cidr
  authorize_all_groups   = true
}

resource "aws_route53_record" "vpn_dns" {
  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "CNAME"
  ttl     = 300
  records = [aws_ec2_client_vpn_endpoint.public_vpn.dns_name]
}

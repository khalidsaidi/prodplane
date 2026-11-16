# 1) Cle & Certificat de l'autorite (CA) qui signe les certificats clients
resource "tls_private_key" "ca_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}



resource "tls_self_signed_cert" "ca_cert" {
  private_key_pem = tls_private_key.ca_key.private_key_pem
  subject {
    common_name  = "vpn-client-root-ca"
    organization = var.organization
  }
  is_ca_certificate     = true
  validity_period_hours = 87600 # 10 years
  allowed_uses = [
    "cert_signing", "crl_signing", "key_encipherment", "digital_signature"
  ]
}

# 2) Cle serveur & CSR
resource "tls_private_key" "server_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "server_csr" {
  private_key_pem = tls_private_key.server_key.private_key_pem
  subject {
    common_name  = var.domain_name
    organization = var.organization
  }
  dns_names = [var.domain_name]
}

# 3) Certificat serveur signé par le CA (pour l’endpoint)
resource "tls_locally_signed_cert" "server_cert" {
  cert_request_pem      = tls_cert_request.server_csr.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca_key.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca_cert.cert_pem
  validity_period_hours = 17520 # 2 ans
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]

  set_subject_key_id = true
}

# 4) Import dans ACM : certificat SERVEUR (ARN requis par Client VPN)
resource "aws_acm_certificate" "server_acm" {
  private_key       = tls_private_key.server_key.private_key_pem
  certificate_body  = tls_locally_signed_cert.server_cert.cert_pem
  certificate_chain = tls_self_signed_cert.ca_cert.cert_pem
}

# 5) Import dans ACM : certificat CA (racine) pour authentification CLIENT
#    (root_certificate_chain_arn doit pointer sur le CA qui signe les certs client)
resource "aws_acm_certificate" "client_root_ca_acm" {
  private_key      = tls_private_key.ca_key.private_key_pem
  certificate_body = tls_self_signed_cert.ca_cert.cert_pem
}

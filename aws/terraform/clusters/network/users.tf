# 1) Generate the private key for each user
resource "tls_private_key" "user_keys" {
  for_each  = var.vpn_users
  algorithm = "RSA"
  rsa_bits  = 2048
}

# 2) Generate the CSR for each user
resource "tls_cert_request" "user_csrs" {
  for_each        = var.vpn_users
  private_key_pem = tls_private_key.user_keys[each.key].private_key_pem

  subject {
    common_name   = each.key
    organization  = var.organization
    email_address = each.value.email
  }
}

# 3) (Optional) save the CSRs and keys
resource "local_file" "user_csr_files" {
  for_each = var.vpn_users
  filename = "${path.module}/users_dump/${each.key}.csr"
  content  = tls_cert_request.user_csrs[each.key].cert_request_pem
}

resource "local_file" "user_key_files" {
  for_each        = var.vpn_users
  filename        = "${path.module}/users_dump/${each.key}.key"
  content         = tls_private_key.user_keys[each.key].private_key_pem
  file_permission = "0600"
}

# 4) Sign each user CSR with the client CA
resource "tls_locally_signed_cert" "user_certs" {
  for_each = var.vpn_users

  cert_request_pem   = tls_cert_request.user_csrs[each.key].cert_request_pem
  ca_private_key_pem = tls_private_key.ca_key.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca_cert.cert_pem

  validity_period_hours = 8760 # 1 year

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "client_auth"
  ]
}

# 5) Save the signed client certs to local files
resource "local_file" "user_cert_files" {
  for_each = var.vpn_users
  filename = "${path.module}/users_dump/${each.key}.crt"
  content  = tls_locally_signed_cert.user_certs[each.key].cert_pem
}

# 6) Make .ovpn for each user
resource "local_file" "user_ovpn_files" {
  for_each             = var.vpn_users
  filename             = "${path.module}/users_dump/${each.key}.ovpn"
  file_permission      = "0600"
  directory_permission = "0700"

  content = <<EOT
client
dev tun
proto tcp
remote ${var.domain_name} 443
resolv-retry infinite
nobind
ping 10
ping-restart 60
tun-mtu 1400
mssfix 1360
persist-key
persist-tun
remote-cert-tls server
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth SHA256
key-direction 1
verb 3

<ca>
${tls_self_signed_cert.ca_cert.cert_pem}
</ca>

<cert>
${tls_locally_signed_cert.user_certs[each.key].cert_pem}
</cert>

<key>
${tls_private_key.user_keys[each.key].private_key_pem}
</key>
EOT
}

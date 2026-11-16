output "claim_names" {
  value = { for name, claim in kubernetes_persistent_volume_claim.application : name => claim.metadata[0].name }
}

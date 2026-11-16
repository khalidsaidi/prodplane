terraform {
  required_version = ">= 1.3"
  backend "s3" {}
  required_providers {
    aws        = { source = "hashicorp/aws", version = ">= 3.40, < 6.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = ">= 2.0, < 3.0" }
    helm       = { source = "hashicorp/helm", version = ">= 2.0, < 3.0" }
    kubectl    = { source = "gavinbunney/kubectl", version = ">= 1.14.0" }
  }
}

locals {
  # Namespace names cannot contain dots, so this separator cannot confuse
  # namespace team-a / claim exports with namespace team / claim a-exports.
  # Keep long valid claim names within the PV DNS-subdomain length limit.
  static_volume_names = {
    for name, volume in var.volumes : name => volume.pv_name != null ? volume.pv_name : (
      length("${var.environment}.${name}") <= 253 ? "${var.environment}.${name}" :
      "${var.environment}.${substr(sha256(name), 0, 32)}"
    ) if volume.volume_handle != null
  }
}

resource "kubernetes_persistent_volume" "application" {
  for_each = { for name, volume in var.volumes : name => volume if volume.volume_handle != null }
  metadata { name = local.static_volume_names[each.key] }
  spec {
    capacity                         = { storage = each.value.size }
    access_modes                     = each.value.access_modes
    storage_class_name               = data.terraform_remote_state.cluster_storage.outputs.storage_class_name
    persistent_volume_reclaim_policy = "Retain"
    # Reserve this caller-supplied handle before any other matching claim can
    # bind it. Setting volume_name on a PVC alone does not reserve an available PV.
    claim_ref {
      name      = each.key
      namespace = var.environment
    }
    persistent_volume_source {
      csi {
        driver        = "efs.csi.aws.com"
        volume_handle = each.value.volume_handle
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "application" {
  for_each = var.volumes
  metadata {
    name      = each.key
    namespace = var.environment
  }
  spec {
    storage_class_name = data.terraform_remote_state.cluster_storage.outputs.storage_class_name
    access_modes       = each.value.access_modes
    volume_name        = each.value.volume_handle == null ? null : kubernetes_persistent_volume.application[each.key].metadata[0].name
    resources { requests = { storage = each.value.size } }
  }
  wait_until_bound = false
}

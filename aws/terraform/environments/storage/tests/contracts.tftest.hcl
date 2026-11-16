mock_provider "aws" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}
override_data {
  target = data.terraform_remote_state.cluster_storage
  values = { outputs = { efs_id = "fs-12345678", storage_class_name = "efs-sc" } }
}
variables {
  aws_region          = "us-east-1"
  environment         = "team-a"
  cluster_environment = "non-prod"
}
run "no_application_storage" {
  command = plan
  assert {
    condition     = length(kubernetes_persistent_volume.application) == 0 && length(kubernetes_persistent_volume_claim.application) == 0
    error_message = "Storage must be opt-in."
  }
}
run "caller_claims" {
  command = plan
  variables {
    volumes = {
      uploads = { size = "5Gi" }
      exports = { size = "10Gi", volume_handle = "fs-12345678::fsap-12345678" }
    }
  }
  assert {
    condition     = kubernetes_persistent_volume_claim.application["uploads"].metadata[0].name == "uploads"
    error_message = "Claims must use caller names."
  }
  assert {
    condition     = !contains(keys(kubernetes_persistent_volume.application), "uploads") && length(kubernetes_persistent_volume.application) == 1
    error_message = "Default claims must use dynamic provisioning instead of sharing the filesystem root."
  }
  assert {
    condition     = kubernetes_persistent_volume.application["exports"].metadata[0].name == "team-a.exports"
    error_message = "Static volume identity must keep namespace and claim boundaries distinct."
  }
  assert {
    condition     = kubernetes_persistent_volume.application["exports"].spec[0].claim_ref[0].name == "exports" && kubernetes_persistent_volume.application["exports"].spec[0].claim_ref[0].namespace == "team-a"
    error_message = "Existing storage must be reserved for the requesting environment and claim."
  }
  assert {
    condition     = kubernetes_persistent_volume.application["exports"].spec[0].persistent_volume_source[0].csi[0].volume_handle == "fs-12345678::fsap-12345678"
    error_message = "Caller access points must be preserved."
  }
}

override_data {
  target = data.terraform_remote_state.eks
  values = { outputs = { eks_cluster_id = "custom-cluster", eks_cluster_endpoint = "https://example.invalid", eks_cluster_certificate_authority = "dGVzdA==", aws_region = "us-east-1" } }
}

run "other_namespace_with_overlapping_claim_name" {
  command = plan
  variables {
    environment = "team"
    volumes     = { a-exports = { size = "10Gi", volume_handle = "fs-12345678::fsap-12345679" } }
  }
  assert {
    condition     = kubernetes_persistent_volume.application["a-exports"].metadata[0].name == "team.a-exports"
    error_message = "Different namespace/claim pairs must not create the same cluster-scoped PV name."
  }
}
run "long_static_claim_name" {
  command = plan
  variables {
    volumes = { (join("", [for i in range(250) : "x"])) = { size = "1Gi", volume_handle = "fs-12345678::fsap-12345679" } }
  }
  assert {
    condition     = length(one(values(kubernetes_persistent_volume.application)).metadata[0].name) <= 253
    error_message = "A valid long PVC name must not overflow the cluster-scoped PV name."
  }
}

run "caller_defined_static_volume_name" {
  command = plan
  variables {
    volumes = { exports = { size = "10Gi", volume_handle = "fs-12345678::fsap-12345678", pv_name = "shared-exports-volume" } }
  }
  assert {
    condition     = kubernetes_persistent_volume.application["exports"].metadata[0].name == "shared-exports-volume" && kubernetes_persistent_volume_claim.application["exports"].spec[0].volume_name == "shared-exports-volume"
    error_message = "An explicit caller-selected PV name must reach both sides of the binding."
  }
}

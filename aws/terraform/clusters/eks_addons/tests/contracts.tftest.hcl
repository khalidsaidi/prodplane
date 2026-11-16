mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "111122223333" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::111122223333:role/fixture" } }
  mock_resource "aws_iam_policy" { defaults = { arn = "arn:aws:iam::111122223333:policy/fixture" } }
}
override_resource {
  target = aws_iam_role.ebs_csi_driver_role
  values = { arn = "arn:aws:iam::111122223333:role/ebs-controller" }
}
override_resource {
  target = aws_iam_role.efs_csi_driver_role
  values = { arn = "arn:aws:iam::111122223333:role/efs-controller" }
}
override_resource {
  target = aws_iam_role.aws_load_balancer_controller_role
  values = { arn = "arn:aws:iam::111122223333:role/load-balancer-controller" }
}
mock_provider "aws" { alias = "default" }
mock_provider "kubernetes" {
  mock_data "kubernetes_config_map" { defaults = { data = { mapRoles = "[]" } } }
}
mock_provider "helm" {}
mock_provider "kubectl" {}
override_data {
  target = data.terraform_remote_state.network
  values = { outputs = { vpc_id = "vpc-12345678" } }
}
override_data {
  target = data.terraform_remote_state.security
  values = { outputs = { eks_cluster_role_arn = "arn:aws:iam::111122223333:role/cluster", codebuild_service_role_arn = "arn:aws:iam::111122223333:role/build" } }
}
override_data {
  target = data.terraform_remote_state.eks
  values = { outputs = {
    eks_cluster_id                    = "fixture-cluster"
    aws_region                        = "us-west-2"
    eks_cluster_endpoint              = "https://example.com"
    eks_cluster_certificate_authority = "Y2E="
    eks_oidc_provider_arn             = "arn:aws:iam::111122223333:oidc-provider/oidc.eks.us-west-2.amazonaws.com/id/EXAMPLE"
    eks_cluster_identity_oidc_issuer  = "https://oidc.eks.us-west-2.amazonaws.com/id/EXAMPLE"
  } }
}
variables {
  aws_region          = "us-west-2"
  cluster_environment = "non-prod"
  fluentbit_namespace = "observability"
}
run "application_neutral_logging" {
  command = apply
  assert {
    condition     = yamldecode(local.fluentbit_values).input.path == "/var/log/containers/*.log"
    error_message = "Logging must collect all container output, not named application files."
  }
  assert {
    condition     = yamldecode(local.fluentbit_values).cloudWatchLogs.region == "us-west-2" && yamldecode(local.fluentbit_values).cloudWatchLogs.logGroupName == "/aws/eks/fixture-cluster/containers"
    error_message = "Logging destinations must follow platform region and cluster."
  }
  assert {
    condition     = alltrue([for volume in yamldecode(local.fluentbit_values).volumes : !contains(keys(volume), "persistentVolumeClaim")])
    error_message = "Cluster logging must not depend on an application's persistent volumes."
  }
}
run "optional_file_archive" {
  command = apply
  variables {
    fluentbit_cloudwatch_enabled = false
    fluentbit_persistence        = { size = "5Gi", storage_class_name = "efs-sc" }
  }
  assert {
    condition     = length(kubernetes_persistent_volume_claim_v1.log_archive) == 1 && contains(kubernetes_persistent_volume_claim_v1.log_archive[0].spec[0].access_modes, "ReadWriteMany")
    error_message = "A requested archive must have shared persistent storage."
  }
  assert {
    condition     = !yamldecode(local.fluentbit_values).cloudWatchLogs.enabled && strcontains(yamldecode(local.fluentbit_values).additionalOutputs, "Name file") && strcontains(local.log_archive_output, "File $${HOST_NAME}.log")
    error_message = "Archive output must be independent of CloudWatch and partitioned per node."
  }
}
run "existing_archive_claim" {
  command = plan
  variables {
    fluentbit_persistence = { existing_claim = "operator-archive" }
  }
  assert {
    condition     = length(kubernetes_persistent_volume_claim_v1.log_archive) == 0 && one([for volume in yamldecode(local.fluentbit_values).volumes : volume.persistentVolumeClaim.claimName if volume.name == "archive"]) == "operator-archive"
    error_message = "Caller-owned archive claims must be referenced without competing ownership."
  }
}

run "preserve_existing_cluster_access" {
  command = apply
  override_data {
    target = data.kubernetes_config_map.aws_auth[0]
    values = { data = { mapUsers = "[]", unrelated = "keep", mapRoles = <<-YAML
      - rolearn: arn:aws:iam::111122223333:role/node
        username: system:node:{{EC2PrivateDNSName}}
        groups: [system:bootstrappers, system:nodes]
      - rolearn: arn:aws:iam::111122223333:role/build
        username: old-build
        groups: [old-group]
      - rolearn: arn:aws:iam::111122223333:role/operator
        username: "operator: audit"
        groups: [audit]
    YAML
    } }
  }
  assert {
    condition     = length(local.updated_roles) == 4 && length([for role in local.updated_roles : role if role.rolearn == "arn:aws:iam::111122223333:role/build"]) == 1
    error_message = "Platform role updates must preserve other mappings without duplicating a role ARN."
  }
  assert {
    condition     = [for role in yamldecode(yamldecode(kubectl_manifest.aws_auth[0].yaml_body).data.mapRoles) : role.username if role.rolearn == "arn:aws:iam::111122223333:role/operator"][0] == "operator: audit" && kubectl_manifest.aws_auth[0].apply_only && yamldecode(kubectl_manifest.aws_auth[0].yaml_body).data.mapUsers == "[]" && yamldecode(kubectl_manifest.aws_auth[0].yaml_body).data.unrelated == "keep"
    error_message = "Mapping serialization must preserve literal usernames and teardown must retain aws-auth."
  }
}

run "externally_managed_cluster_access" {
  command = plan
  variables { configure_aws_auth_configmap = false }
  assert {
    condition     = length(kubectl_manifest.aws_auth) == 0 && length(data.kubernetes_config_map.aws_auth) == 0
    error_message = "Explicitly external authorization must remain outside this component's ownership."
  }
}

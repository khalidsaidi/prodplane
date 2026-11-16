mock_provider "aws" {
  mock_data "aws_secretsmanager_secret_version" {
    defaults = { secret_string = "{\"access_token\":\"test-token\"}" }
  }
}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}
override_data {
  target = data.terraform_remote_state.network
  values = { outputs = { vpc_id = "vpc-12345678", private_subnet_ids = ["subnet-12345678"] } }
}
override_data {
  target = data.terraform_remote_state.eks
  values = { outputs = { eks_cluster_id = "custom-cluster", eks_cluster_endpoint = "https://example.invalid", eks_cluster_certificate_authority = "dGVzdA==", aws_region = "us-east-1" } }
}
override_data {
  target = data.terraform_remote_state.security
  values = { outputs = { eks_cluster_role_arn = "arn:aws:iam::111122223333:role/deployer", codebuild_service_role_arn = "arn:aws:iam::111122223333:role/build-owner", eks_nodes_sg_id = "sg-12345678" } }
}
variables {
  aws_region             = "us-east-1"
  aws_account_id         = "111122223333"
  region_deploy_artifact = "us-west-2"
  environment            = "custom-team"
  cluster_environment    = "non-prod"
}
run "empty_application" {
  command = plan
  assert {
    condition     = length(aws_codebuild_project.this) == 0 && length(kubernetes_secret.application) == 0 && length(kubernetes_config_map.application) == 0
    error_message = "An empty environment must not require or create application services/secrets."
  }
}
run "caller_defined_application" {
  command = plan
  variables {
    application_secrets = { worker-auth = { source_secret_id = "custom-secret", keys = { credential = "access_token" } } }
    config_maps         = { worker-runtime = { APP_MODE = "custom" } }
    codebuild_projects = {
      worker = {
        create                    = true
        repository_url            = "https://github.com/example/custom-worker.git"
        source_version            = "release"
        buildspec_template        = "build-image"
        privileged_mode           = true
        compute_type              = "BUILD_GENERAL1_SMALL"
        image                     = "aws/codebuild/standard:7.0"
        timeout_in_minutes        = 30
        queued_timeout_in_minutes = 60
        environment_variables     = [{ name = "EKS_CLUSTER_NAME", value = "AUTO" }, { name = "CLUSTER_REGION", value = "AUTO" }, { name = "APP_MODE", value = "custom" }, { name = "NAMESPACE", value = "AUTO", type = "SECRETS_MANAGER" }, { name = "ENVIRONMENT", value = "AUTO", type = "PARAMETER_STORE" }]
      }
    }
  }
  assert {
    condition     = nonsensitive(kubernetes_secret.application["worker-auth"].data["credential"]) == "test-token"
    error_message = "Secret keys must follow caller mappings."
  }
  assert {
    condition     = kubernetes_config_map.application["worker-runtime"].data["APP_MODE"] == "custom"
    error_message = "Configuration must remain caller-owned."
  }
  assert {
    condition     = aws_codebuild_project.this["worker"].name == "custom-team-worker" && strcontains(aws_codebuild_project.this["worker"].source[0].buildspec, "docker build")
    error_message = "Arbitrary project names and generic recipes must work."
  }
  assert {
    condition     = one([for item in aws_codebuild_project.this["worker"].environment[0].environment_variable : item.value if item.name == "EKS_CLUSTER_NAME"]) == "custom-cluster"
    error_message = "Platform AUTO bindings must still resolve."
  }
  assert {
    condition     = aws_codebuild_project.this["worker"].service_role == "arn:aws:iam::111122223333:role/build-owner" && one([for item in aws_codebuild_project.this["worker"].environment[0].environment_variable : item.value if item.name == "CLUSTER_REGION"]) == "us-east-1"
    error_message = "Build identity and cluster region must come from their current producer states."
  }

  assert {
    condition     = alltrue([for item in aws_codebuild_project.this["worker"].environment[0].environment_variable : item.value == "AUTO" if item.type != "PLAINTEXT"])
    error_message = "Secret and parameter references must not be rewritten by plaintext AUTO substitution."
  }

}
run "caller_defined_build_outputs" {
  command = plan
  variables {
    codebuild_projects = {
      package = {
        create                    = true
        repository_url            = "https://github.com/example/package-source.git"
        source_version            = "release"
        buildspec                 = "ci/package.yml"
        compute_type              = "BUILD_GENERAL1_SMALL"
        image                     = "aws/codebuild/standard:7.0"
        timeout_in_minutes        = 30
        queued_timeout_in_minutes = 60
        environment_variables     = []
        encryption_key            = "arn:aws:kms:us-east-1:111122223333:key/00000000-0000-4000-8000-000000000000"
        artifacts = {
          type      = "S3"
          location  = "example-build-outputs"
          path      = "releases"
          name      = "bundle.zip"
          packaging = "ZIP"
        }
      }
    }
  }
  assert {
    condition     = aws_codebuild_project.this["package"].source[0].buildspec == "ci/package.yml"
    error_message = "The application must retain ownership of its build definition."
  }
  assert {
    condition     = aws_codebuild_project.this["package"].artifacts[0].type == "S3" && aws_codebuild_project.this["package"].artifacts[0].location == "example-build-outputs" && aws_codebuild_project.this["package"].artifacts[0].namespace_type == "BUILD_ID"
    error_message = "Caller-selected output storage must reach CodeBuild."
  }
  assert {
    condition     = aws_codebuild_project.this["package"].artifacts[0].packaging == "ZIP" && aws_codebuild_project.this["package"].encryption_key == var.codebuild_projects.package.encryption_key
    error_message = "Packaging and encryption choices must remain caller-controlled."
  }
}

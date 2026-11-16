terraform {
  required_version = ">= 1.3"
  backend "s3" {}
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.40, < 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0.0, < 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.0.0, < 3.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
  }
}

locals {
  buildspec_templates = {
    build-image = file("${path.module}/../../../../deployment/buildspecs/build-image.yml")
    deploy-helm = file("${path.module}/../../../../deployment/buildspecs/deploy-helm.yml")
  }
  # AUTO resolves plaintext platform values. Secret/parameter references are identifiers, not literal values.
  platform_build_values = {
    EKS_CLUSTER_NAME     = data.terraform_remote_state.eks.outputs.eks_cluster_id
    EKS_KUBECTL_ROLE_ARN = data.terraform_remote_state.security.outputs.eks_cluster_role_arn
    CLUSTER_REGION       = data.terraform_remote_state.eks.outputs.aws_region
    ARTIFACT_REGION      = var.region_deploy_artifact
    ECR_REGISTRY         = "${var.aws_account_id}.dkr.ecr.${var.region_deploy_artifact}.amazonaws.com"
    NAMESPACE            = var.environment
    ENVIRONMENT          = var.environment
  }
  codebuild_projects_processed = {
    for key, project in var.codebuild_projects : key => merge(project, {
      environment_variables = [for entry in project.environment_variables : merge(entry, {
        value = entry.type == "PLAINTEXT" && entry.value == "AUTO" ? lookup(local.platform_build_values, entry.name, entry.value) : entry.value
      })]
    })
  }
}

resource "kubernetes_namespace_v1" "logging" {
  metadata { name = var.fluentbit_namespace }
}

resource "kubernetes_persistent_volume_claim_v1" "log_archive" {
  count = var.fluentbit_persistence == null ? 0 : (var.fluentbit_persistence.existing_claim == null ? 1 : 0)
  metadata {
    name      = "fluent-bit-archive"
    namespace = kubernetes_namespace_v1.logging.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = var.fluentbit_persistence.storage_class_name
    resources { requests = { storage = var.fluentbit_persistence.size } }
  }
  wait_until_bound = false
  depends_on       = [helm_release.aws_efs_csi_driver, helm_release.aws_ebs_csi_driver]
}

locals {
  log_archive_output = var.fluentbit_persistence == null ? "" : <<-CONFIG
    [OUTPUT]
        Name file
        Match kube.*
        Path ${var.fluentbit_persistence.mount_path}
        File $${HOST_NAME}.log
  CONFIG
  fluentbit_values = yamlencode({
    # Pin the collector independently of the chart for CloudWatch compatibility.
    image = {
      repository = "public.ecr.aws/aws-observability/aws-for-fluent-bit"
      tag        = "3.5.8"
    }
    serviceAccount = {
      create      = true
      name        = "fluent-bit"
      annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.fluent_bit_role.arn }
    }
    service = {
      extraService = <<-CONFIG
        HTTP_Server ${var.fluentbit_http_server}
        HTTP_Listen 0.0.0.0
        HTTP_Port ${var.fluentbit_http_port}
        Health_Check On
        storage.path ${var.fluentbit_storage_path}
      CONFIG
    }
    serviceMonitor = {
      service = { port = var.fluentbit_http_port, targetPort = var.fluentbit_http_port }
    }
    input = {
      enabled         = true
      tag             = "kube.*"
      path            = "/var/log/containers/*.log"
      db              = "/var/fluent-bit/state/containers.db"
      multilineParser = "docker, cri"
      extraInputs     = "Read_from_Head ${var.fluentbit_read_from_head}\nstorage.type filesystem"
    }
    filter     = { enabled = true, match = "kube.*", mergeLog = "On", keepLog = "On" }
    cloudWatch = { enabled = false }
    cloudWatchLogs = {
      enabled         = var.fluentbit_cloudwatch_enabled
      match           = "kube.*"
      region          = var.aws_region
      logGroupName    = "/aws/eks/${coalesce(var.eks_cluster_name, data.terraform_remote_state.eks.outputs.eks_cluster_id)}/containers"
      logStreamPrefix = "pod-"
      autoCreateGroup = true
    }
    additionalOutputs = join("\n", compact([local.log_archive_output, var.fluentbit_additional_outputs]))
    env               = [{ name = "HOST_NAME", valueFrom = { fieldRef = { fieldPath = "spec.nodeName" } } }]
    resources = {
      limits   = { memory = var.fluentbit_limit_memory }
      requests = { cpu = var.fluentbit_request_cpu, memory = var.fluentbit_request_memory }
    }
    livenessProbe = var.fluentbit_http_server == "On" ? {
      httpGet             = { path = "/api/v1/health", port = var.fluentbit_http_port }
      initialDelaySeconds = 30
    } : null
    tolerations = [{ operator = "Exists", effect = "NoSchedule" }]
    volumes = concat([
      { name = "varlog", hostPath = { path = "/var/log" } },
      { name = "varlibdockercontainers", hostPath = { path = "/var/lib/docker/containers" } },
      { name = "state", hostPath = { path = "/var/fluent-bit/state", type = "DirectoryOrCreate" } }
      ], var.fluentbit_persistence == null ? [] : [{
        name = "archive"
        persistentVolumeClaim = {
          claimName = coalesce(var.fluentbit_persistence.existing_claim, try(kubernetes_persistent_volume_claim_v1.log_archive[0].metadata[0].name, null))
        }
    }])
    volumeMounts = concat([
      { name = "varlog", mountPath = "/var/log", readOnly = true },
      { name = "varlibdockercontainers", mountPath = "/var/lib/docker/containers", readOnly = true },
      { name = "state", mountPath = "/var/fluent-bit/state" }
    ], var.fluentbit_persistence == null ? [] : [{ name = "archive", mountPath = var.fluentbit_persistence.mount_path }])
  })
}

resource "helm_release" "fluentbit" {
  name       = "fluent-bit"
  namespace  = kubernetes_namespace_v1.logging.metadata[0].name
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-for-fluent-bit"
  version    = "0.1.34"
  values     = [local.fluentbit_values]
  # The controller installs a Service admission webhook before its pods are ready.
  # Wait for that release before this chart creates its monitoring Service.
  depends_on = [aws_iam_role_policy_attachment.fluent_bit_policy_attachment, helm_release.aws_load_balancer_controller]
  lifecycle {
    precondition {
      condition     = var.fluentbit_cloudwatch_enabled || var.fluentbit_persistence != null || trimspace(var.fluentbit_additional_outputs) != ""
      error_message = "Configure at least one logging destination."
    }
  }
}

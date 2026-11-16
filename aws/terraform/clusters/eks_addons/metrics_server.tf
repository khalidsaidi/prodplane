resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  namespace  = "kube-system"
  chart      = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  version    = "3.10.0"

  # Service admission must be available before this chart creates its Service.
  depends_on = [helm_release.aws_load_balancer_controller]

  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }

  set {
    name  = "apiService.create"
    value = "true"
  }
}

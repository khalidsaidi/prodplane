${yamlencode({
  apiVersion = "v1"
  kind = "ConfigMap"
  metadata = { name = "aws-auth", namespace = "kube-system", labels = labels, annotations = annotations }
  data = data
})}

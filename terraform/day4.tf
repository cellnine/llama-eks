# Day 4: observability + autoscaling.

variable "prometheus_admin_password" {
  description = "Grafana admin password (set alongside kube-prometheus-stack)"
  type        = string
  default     = "demo-admin"
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "92.21.1"
  namespace        = "monitoring"
  create_namespace = true

  values = [
    <<-EOT
    # Lean extras; Prometheus + Grafana defaults are enough for the demo dashboard.
    grafana:
      adminPassword: ${var.prometheus_admin_password}
      service:
        type: ClusterIP
    prometheus:
      prometheusSpec:
        serviceMonitorSelectorNilUsesHelmValues: false
        podMonitorSelectorNilUsesHelmValues: false
    alertmanager:
      enabled: false
    defaultRules:
      create: true
    EOT
  ]

  depends_on = [module.eks]
}

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.21.0"
  namespace        = "keda"
  create_namespace = true

  depends_on = [module.eks]
}

locals {
  prometheus_url = "http://${helm_release.kube_prometheus_stack.name}-prometheus.monitoring.svc.cluster.local:9090"
}

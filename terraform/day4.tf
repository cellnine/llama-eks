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

resource "kubectl_manifest" "keda_scaled_object" {
  yaml_body = <<-YAML
    apiVersion: keda.sh/v1alpha1
    kind: ScaledObject
    metadata:
      name: llama-server
      namespace: llama
    spec:
      scaleTargetRef:
        kind: Deployment
        name: llama-server
      minReplicaCount: 2
      maxReplicaCount: 8
      cooldownPeriod: 180
      pollingInterval: 15
      triggers:
        - type: prometheus
          metadata:
            serverAddress: ${local.prometheus_url}
            # Cluster-wide in-flight count. Each gateway replica caps at
            # INFLIGHT_MAX so with 2 gateway replicas a threshold of 4
            # corresponds to ~2 in-flight requests per llama.cpp replica.
            query: sum(gateway_inflight)
            # Avg across pods; gateway caps at INFLIGHT_MAX=4 per replica, so a
            # saturated fleet of 4 llama pods shows sum ~8 -> avg 4 -> 2x scale.
            threshold: "2"
  YAML

  depends_on = [helm_release.keda, helm_release.kube_prometheus_stack]
}

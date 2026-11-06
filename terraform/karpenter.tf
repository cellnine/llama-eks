module "karpenter" {
  # Same EKS module version as used for the cluster, so the sub-module matches.
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.29"

  cluster_name = module.eks.cluster_name

  # Karpenter controller authenticates with Pod Identity
  create_pod_identity_association = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  chart      = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  version    = "1.6.0"
  wait       = false

  values = [
    <<-EOT
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    webhook:
      enabled: false
    EOT
  ]

  depends_on = [module.karpenter]
}

# x86 compute-optimized Spot NodePool. Higher weight = preferred.
resource "kubectl_manifest" "spot_node_pool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: llama-inference-spot
    spec:
      template:
        metadata:
          labels:
            nodepool: llama-inference
        spec:
          taints:
            - key: inference
              value: "true"
              effect: NoSchedule
          requirements:
            - key: karpenter.k8s.aws/instance-family
              operator: In
              values: [c7i]
            - key: karpenter.k8s.aws/instance-size
              operator: In
              values: [xlarge, 2xlarge]
            - key: karpenter.sh/capacity-type
              operator: In
              values: [spot]
            - key: kubernetes.io/arch
              operator: In
              values: [amd64]
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: llama-inference
      limits:
        cpu: 8
      weight: 20
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 1m
  YAML

  depends_on = [helm_release.karpenter]
}

# On-demand fallback NodePool (lower weight, scheduled only if Spot unavailable).
resource "kubectl_manifest" "ondemand_node_pool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: llama-inference-ondemand
    spec:
      template:
        metadata:
          labels:
            nodepool: llama-inference
        spec:
          taints:
            - key: inference
              value: "true"
              effect: NoSchedule
          requirements:
            - key: karpenter.k8s.aws/instance-family
              operator: In
              values: [c7i]
            - key: karpenter.k8s.aws/instance-size
              operator: In
              values: [xlarge, 2xlarge]
            - key: karpenter.sh/capacity-type
              operator: In
              values: [on-demand]
            - key: kubernetes.io/arch
              operator: In
              values: [amd64]
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: llama-inference
      limits:
        cpu: 8
      weight: 10
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 5m
  YAML

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "ec2_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: llama-inference
    spec:
      role: ${module.karpenter.node_iam_role_name}
      amiFamily: AL2023
      subnetSelectorTerms:
        - tags:
            "karpenter.sh/discovery": ${module.eks.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            "karpenter.sh/discovery": ${module.eks.cluster_name}
      amiSelectorTerms:
        - alias: al2023@latest
      tags:
        Project: ${var.project}
      expireAfter: 14d
  YAML

  depends_on = [helm_release.karpenter]
}

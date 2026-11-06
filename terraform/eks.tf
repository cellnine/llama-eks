locals {
  account_id = data.aws_caller_identity.current.account_id
}

# Root principal as cluster admin (EKS API access mode requires an explicit entry).
resource "aws_eks_access_entry" "admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = "arn:aws:iam::${local.account_id}:root"
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
}

# CI applies kubectl_manifests/helm releases against the cluster as the terraform role.
resource "aws_eks_access_entry" "ci" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.github_terraform.arn
}

resource "aws_eks_access_policy_association" "ci" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.ci.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

  name               = var.cluster_name
  kubernetes_version = "1.33"

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  endpoint_public_access = true

  enable_irsa = true

  # Core EKS add-ons (NOT installed by default by the module) + Pod Identity agent.
  # NetworkPolicy enforcement rides on the VPC-CNI day 3 requirement.
  addons = {
    coredns    = { most_recent = true, before_compute = true }
    kube-proxy = { most_recent = true, before_compute = true }
    vpc-cni = {
      most_recent    = true
      before_compute = true
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
    eks-pod-identity-agent = { before_compute = true }
  }

  eks_managed_node_groups = {
    system = {
      name           = "system"
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.system_node_instance_types
      capacity_type  = "ON_DEMAND"
      min_size       = var.system_node_min_size
      max_size       = var.system_node_max_size
      desired_size   = var.system_node_desired_size
      labels = {
        role = "system"
      }
    }
  }

  tags = {
    Project = var.project
    # Tag the cluster security group for Karpenter auto-discovery (NodeClass securityGroupSelector)
    "karpenter.sh/discovery" = var.cluster_name
  }
}

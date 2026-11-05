module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

  name               = var.cluster_name
  kubernetes_version = "1.33"

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  enable_irsa = true

  # Pod Identity agent (Karpenter controller auth) needs this addon
  cluster_addons = {
    "eks-pod-identity-agent" = {}
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

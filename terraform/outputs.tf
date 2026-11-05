output "region" {
  value = var.region
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "terraform_role_arn" {
  description = "CI OIDC role for Terraform plan/apply. Put this in repo vars as TERRAFORM_ROLE_ARN."
  value       = aws_iam_role.github_terraform.arn
}

output "ecr_push_role_arn" {
  description = "CI OIDC role for the gateway image push. Put this in repo vars as ECR_PUSH_ROLE_ARN."
  value       = aws_iam_role.github_ecr_push.arn
}

output "gateway_ecr_repository_url" {
  value = aws_ecr_repository.gateway.repository_url
}

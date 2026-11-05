resource "aws_ecr_repository" "gateway" {
  name         = "${var.project}-gateway"
  force_delete = true
  tags         = { Project = var.project }

  image_scanning_configuration {
    scan_on_push = true
  }
}

output "gateway_ecr_url" {
  description = "ECR URL for the gateway image"
  value       = aws_ecr_repository.gateway.repository_url
}

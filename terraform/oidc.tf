# GitHub OIDC so CI has no static AWS keys.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  oidc_federation_base = "token.actions.githubusercontent.com"
}

# Terraform plan/apply role (full access — demo scope; note in README that prod would scope this).
resource "aws_iam_role" "github_terraform" {
  name = "${var.project}-github-terraform"
  tags = { Project = var.project }

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_federation_base}:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "${local.oidc_federation_base}:sub" = "repo:cellnine@89855954/llama-eks@1447447468:*"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "github_terraform_admin" {
  name = "terraform-demo-admin"
  role = aws_iam_role.github_terraform.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "*", Resource = "*" }]
  })
}

# Role for the gateway image build job: push to ECR only.
resource "aws_iam_role" "github_ecr_push" {
  name = "${var.project}-github-ecr-push"
  tags = { Project = var.project }

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_federation_base}:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "${local.oidc_federation_base}:sub" = "repo:cellnine@89855954/llama-eks@1447447468:*"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_ecr_push" {
  role       = aws_iam_role.github_ecr_push.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

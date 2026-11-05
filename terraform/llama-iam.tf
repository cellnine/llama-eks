# Read-only access to the model bucket for the llama-server service account (IRSA).
resource "aws_iam_policy" "llama_model_read" {
  name        = "${var.project}-llama-model-read"
  description = "Read the Qwen GGUF object from the model bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = [
          "${aws_s3_bucket.model.arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.model.arn,
        ]
      }
    ]
  })
}

module "llama_s3_reader_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.60"

  role_name = "${var.project}-llama-server-s3-reader"
  role_policy_arns = merge(
    { model-read = aws_iam_policy.llama_model_read.arn },
  )

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["llama:llama-server"]
    }
  }
}

output "llama_s3_reader_role_arn" {
  description = "IRSA role annotating the llama-server service account"
  value       = module.llama_s3_reader_role.iam_role_arn
}

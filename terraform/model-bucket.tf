# Model bucket. force_destroy so `make destroy` cleans up even with objects present.
resource "aws_s3_bucket" "model" {
  bucket        = "${var.project}-model"
  force_destroy = true
  tags          = { Project = var.project }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "model" {
  bucket = aws_s3_bucket.model.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "model" {
  bucket                  = aws_s3_bucket.model.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "model_bucket_name" {
  description = "S3 bucket the GGUF model lives in"
  value       = aws_s3_bucket.model.id
}

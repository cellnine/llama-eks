variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used for resource naming"
  type        = string
  default     = "llama-eks"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "llama-eks"
}

variable "github_repo" {
  description = "GitHub repo (owner/name) allowed to assume the CI roles via OIDC"
  type        = string
  default     = "cellnine/llama-eks"
}

variable "system_node_instance_types" {
  description = "Instance types for the on-demand system node group. t3 keeps system pods in their own vCPU bucket so the full Standard bucket stays free for c7i inference nodes."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "system_node_min_size" {
  type    = number
  default = 1
}

variable "system_node_max_size" {
  type    = number
  default = 1
}

variable "system_node_desired_size" {
  type    = number
  default = 1
}

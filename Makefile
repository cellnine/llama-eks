SHELL := /bin/bash
REGION      ?= us-east-1
CLUSTER     ?= llama-eks
ACCOUNT_ID  := $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
PROJECT     ?= llama-eks
STATE_BUCKET ?= $(PROJECT)-tfstate-$(ACCOUNT_ID)
LOCK_TABLE  ?= $(PROJECT)-tf-locks

# Backend config shared by init/bootstrap.
BACKEND_ARGS := \
	-backend-config="bucket=$(STATE_BUCKET)" \
	-backend-config="key=$(PROJECT)/terraform.tfstate" \
	-backend-config="region=$(REGION)" \
	-backend-config="dynamodb_table=$(LOCK_TABLE)" \
	-backend-config="encrypt=true"

.PHONY: bootstrap plan apply fmt fmt-check validate destroy kubeconfig model-upload output repos

bootstrap: ## Create S3 state bucket + DynamoDB lock table (run once per account)
	./scripts/bootstrap-backend.sh "$(STATE_BUCKET)" "$(LOCK_TABLE)" "$(REGION)"

init:
	terraform -chdir=terraform init -reconfigure $(BACKEND_ARGS)

plan: init ## Terraform plan
	terraform -chdir=terraform plan $(TF_ARGS)

apply: init ## Terraform apply (interactive)
	terraform -chdir=terraform apply $(TF_ARGS)

destroy: ## Tear down terraform-managed infra
	terraform -chdir=terraform destroy $(TF_ARGS)

fmt:
	terraform -chdir=terraform fmt -recursive

fmt-check:
	terraform -chdir=terraform fmt -check -recursive

validate:
	terraform -chdir=terraform validate

kubeconfig: ## Update local kubeconfig for the EKS cluster
	aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER)

model-upload: ## Upload the GGUF to the model bucket (run after `aws configure set region us-east-1`)
	aws s3 cp loadtest/model.gguf s3://$(PROJECT)-model/qwen2.5-1.5b-instruct-q4_k_m.gguf --no-progress

output: ## Show terraform outputs
	terraform -chdir=terraform output

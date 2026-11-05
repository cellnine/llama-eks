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

model-upload: ## Upload the GGUF to the model bucket (needs the bucket to exist first)
	aws s3 cp loadtest/qwen2.5-1.5b-instruct-q4_k_m.gguf s3://$(PROJECT)-model/qwen2.5-1.5b-instruct-q4_k_m.gguf --region $(REGION) --no-progress

output: ## Show terraform outputs
	terraform -chdir=terraform output

# Day 2+: deploy the llama-server release.
NAMESPACE ?= llama
MODEL_BUCKET ?= $(PROJECT)-model
MODEL_KEY ?= qwen2.5-1.5b-instruct-q4_k_m.gguf
LLAMA_ROLE_ARN := $(shell terraform -chdir=terraform output -raw llama_s3_reader_role_arn 2>/dev/null)

up: kubeconfig ## Deploy llama-server: Hive chart + init container pulls model from S3
	helm upgrade --install llama-server charts/llama-server \
		--namespace $(NAMESPACE) --create-namespace \
		--set model.bucket=$(MODEL_BUCKET) \
		--set model.key=$(MODEL_KEY) \
		--set serviceAccount.roleArn=$(LLAMA_ROLE_ARN) \
		--wait --timeout 20m

port-forward: ## Forward the llama-server service to localhost:8080
	kubectl -n $(NAMESPACE) port-forward svc/llama-server 8080:80

charge: ## Remove the llama-server release
	helm del llama-server --namespace $(NAMESPACE)

SHELL := /bin/bash
REGION      ?= us-east-1
CLUSTER     ?= llama-eks
PROJECT     ?= llama-eks
ACCOUNT_ID  := $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
STATE_BUCKET ?= $(PROJECT)-tfstate-$(ACCOUNT_ID)
LOCK_TABLE  ?= $(PROJECT)-tf-locks

# Terraform state, resolved at init time instead of hardcoding an account id here.
BACKEND_ARGS := \
	-backend-config="bucket=$(STATE_BUCKET)" \
	-backend-config="key=$(PROJECT)/terraform.tfstate" \
	-backend-config="region=$(REGION)" \
	-backend-config="dynamodb_table=$(LOCK_TABLE)" \
	-backend-config="encrypt=true"

.PHONY: bootstrap init plan apply destroy fmt fmt-check validate kubeconfig model-upload output \
        up down port-forward up-gateway up-all monitoring load bench help

bootstrap: ## One-time: S3 state bucket + DynamoDB lock table (needs AWS creds)
	./scripts/bootstrap-backend.sh "$(STATE_BUCKET)" "$(LOCK_TABLE)" "$(REGION)"

init:
	terraform -chdir=terraform init -reconfigure $(BACKEND_ARGS)

plan: init ## Terraform plan
	terraform -chdir=terraform plan $(TF_ARGS)

apply: ## Terraform apply (interactive)
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

model-upload: ## Upload the GGUF to the model bucket (needs the bucket from apply to exist)
	aws s3 cp loadtest/qwen2.5-1.5b-instruct-q4_k_m.gguf \
		s3://$(PROJECT)-model/qwen2.5-1.5b-instruct-q4_k_m.gguf --region $(REGION) --no-progress

output: ## Show terraform outputs
	terraform -chdir=terraform output

# ---- Day 2: llama-server ---------------------------------------------------

NAMESPACE     ?= llama
MODEL_BUCKET  ?= $(PROJECT)-model
MODEL_KEY     ?= qwen2.5-1.5b-instruct-q4_k_m.gguf
LLAMA_ROLE_ARN := $(shell terraform -chdir=terraform output -raw llama_s3_reader_role_arn 2>/dev/null)

up: kubeconfig ## Deploy llama-server (init container pulls the model from S3)
	helm upgrade --install llama-server charts/llama-server \
		--namespace $(NAMESPACE) --create-namespace \
		--set model.bucket=$(MODEL_BUCKET) \
		--set model.key=$(MODEL_KEY) \
		--set serviceAccount.roleArn=$(LLAMA_ROLE_ARN) \
		--wait --timeout 20m

port-forward: ## Forward llama-server to localhost:8080 for a direct curl test
	kubectl -n $(NAMESPACE) port-forward svc/llama-server 8080:80

down: ## Remove the llama-server release
	helm del llama-server --namespace $(NAMESPACE) --wait || true

# ---- Day 3/4: gateway, ALB, observability ----------------------------------

GATENAMESPACE ?= gateway
GATEWAY_REPO  := $(shell terraform -chdir=terraform output -raw gateway_ecr_repository_url 2>/dev/null)
GATEWAY_TAG   ?= latest
GATEWAY_KEY   ?= demo-key-1
GATEWAY_HOSTNAME ?=

GW_BASE ?= #[public ALB URL]
API_KEY ?= $(GATEWAY_KEY)
PER_TEST_SEC ?= 60
MAX_TOKENS ?= 64
DEMO_HTTP := --set 'ingress.annotations.alb\.ingress\.kubernetes\.io/listen-ports=[{"HTTP":80}]' \
	--set 'ingress.annotations.alb\.ingress\.kubernetes\.io/ssl-redirect'=null

up-gateway: kubeconfig ## Deploy the gateway behind the ALB (hashed key from $(GATEWAY_KEY)); HTTP-only until an ACM cert is wired
	@KEY_HASH=$$(printf '%s' '$(GATEWAY_KEY)' | shasum -a 256 | cut -d' ' -f1); \
	helm upgrade --install gateway charts/gateway \
		--namespace $(GATENAMESPACE) --create-namespace \
		--set image.repository=$(GATEWAY_REPO) \
		--set image.tag=$(GATEWAY_TAG) \
		--set "keys[0]=main:$${KEY_HASH}" \
		--set ingress.hostname=$(GATEWAY_HOSTNAME) \
		$(DEMO_HTTP) \
		--set serviceMonitor.enabled=true \
		--wait --timeout 10m

up-all: kubeconfig monitoring up up-gateway ## llama-server + prometheus/keda + gateway

monitoring: ## Apply observability/autoscaling terraform (kube-prometheus-stack, KEDA, ScaledObject)
	terraform -chdir=terraform apply -auto-approve -input=false

# ---- Day 4: benchmark ------------------------------------------------------

GW_BASE      ?= http://localhost:8080
API_KEY      ?= $(GATEWAY_KEY)
PER_TEST_SEC ?= 60
MAX_TOKENS   ?= 64

load: ## One k6 run at CONCURRENCY (default 1)
	CONCURRENCY=$(CONCURRENCY) GW_BASE=$(GW_BASE) API_KEY='$(API_KEY)' \
	PER_TEST_SEC=$(PER_TEST_SEC) MAX_TOKENS=$(MAX_TOKENS) k6 run loadtest/load.js

bench: ## Full sweep 1,2,4,8,16 concurrency, results in loadtest/results/
	loadtest/bench.sh

help:
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*? "}; {printf "\033[36m%-14s\033[0m %s\n", $$1, $$2}'

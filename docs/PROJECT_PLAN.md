# EKS LLM Serving Project Plan

A 4-day build: Terraform-provisioned EKS, the official llama.cpp server image on x86 Spot nodes, the model pulled from S3, and a small Go gateway in front. Steps below are in the order you finish them.

## Decisions

These are fixed up front so no build time goes to choosing.

| Area | Choice |
| --- | --- |
| Time box | 4 days, about 8 focused hours each |
| Region | us-east-1 (Spot depth on c7i is good) |
| CPU | x86 only. 4 to 8 vCPU compute-optimized Spot nodes, for example c7i.2xlarge |
| Replicas | 2 inference pods per c7i.2xlarge, 4 vCPU + `--threads 4` each (Helm value `replicaCpu`, tunable) |
| Inference | Official llama.cpp server image, Qwen2.5 1.5B Instruct as a Q4\_K\_M GGUF (check the model license) |
| Model storage | Private S3 bucket. An init container copies the file to an emptyDir at pod start, using Pod Identity or IRSA |
| Gateway | Small Go service, the only public component |
| Nodes | Managed node group for system pods, Karpenter for inference nodes |
| Scaling | KEDA on in-flight requests per replica, read from gateway metrics |
| CI | GitHub Actions with OIDC: plan on PR, apply on merge, gateway image build and push to ECR |

Request flow: client to ALB, to the gateway, to the llama-server Service, to llama.cpp pods on Karpenter nodes. Prometheus scrapes the gateway, KEDA scales pods from those metrics, and Karpenter adds nodes when pods go pending.

## Day 1: Foundation

By the end of day 1, CI applies Terraform to a working EKS cluster.

1. Set an AWS budget and billing alarm. Install terraform, kubectl, helm, aws cli and k6. (done: all installed)
2. Create the repo with folders `terraform/`, `charts/`, `gateway/`, `loadtest/`, `docs/`. (done)
3. Bootstrap the S3 state bucket with locking. (`make bootstrap` — needs AWS creds)
4. Terraform: VPC with private subnets and a single NAT gateway (cheaper, fine for a demo). (done)
5. Terraform: EKS plus a small on-demand managed node group (2 nodes) for system pods. (done)
6. Terraform: GitHub OIDC role, ECR repo for the gateway, and the S3 model bucket. (done)
7. GitHub Actions: `terraform plan` on PR, `apply` on merge. (done)
8. Install AWS Load Balancer Controller and metrics-server through Terraform. (done)
9. Download the GGUF and upload it to the model bucket (start early, it is a large transfer).

**Done when:** a merged PR applies infra through CI and `kubectl get nodes` works.

## Day 2: Karpenter and llama.cpp serving

By the end of day 2, the model answers a curl request from a Spot node Karpenter created.

1. Terraform: install Karpenter and its IAM.
2. Create one x86 NodePool: Spot with on-demand fallback, a taint for inference pods, a vCPU limit to cap cost.
3. Create the Pod Identity role that lets the inference service account read the model bucket only.
4. Write the llama-server Helm chart: official image, init container that pulls the GGUF from S3, readiness probe on the server health endpoint, CPU requests and limits in whole vCPUs, `--threads` matched to the CPU limit, toleration for the inference taint.
5. Deploy it and watch Karpenter provision a node.
6. Port-forward and call the OpenAI-compatible chat completions endpoint.
7. Note single-stream tokens/sec and model load time. These are your first benchmark numbers.

**Done when:** a completion returns from a pod on a Karpenter node, and the model is read from S3, not baked into the image.

## Day 3: Gateway and public access

By the end of day 3, a public HTTPS or ALB endpoint streams completions only for valid API keys.

1. Build the Go gateway: API-key auth (hashed keys from a Kubernetes Secret), per-key token-bucket rate limit, max in-flight cap with a short queue and `429` plus `Retry-After`, streaming passthrough, `/healthz`, `/readyz`, graceful shutdown.
2. Add Prometheus metrics: requests by status, in-flight gauge, queue wait, time to first token, total latency.
3. Write unit tests for the limiter and auth, plus one test against a fake backend.
4. Add a Dockerfile and a GitHub Actions job that builds and pushes to ECR.
5. Write the gateway Helm chart and an ALB Ingress. Expose only the gateway.
6. Add a NetworkPolicy so only the gateway can reach llama-server (confirm network policy enforcement is enabled on your CNI).
7. Test streaming through the ALB with curl: valid key, missing key, and a burst that trips the limiter.

**Done when:** the public endpoint streams with a valid key, rejects without one, and returns `429` under a burst.

> Design note: the rate limiter and the in-flight cap must produce distinguishable `429` bodies/metrics so the load-test numbers don't conflate them.

## Day 4: Observability, autoscaling, benchmark, write-up

By the end of day 4, you have a scaling demo, a results table and a README.

1. Install kube-prometheus-stack, add a ServiceMonitor for the gateway, and build one Grafana dashboard: request rate, errors, in-flight, queue wait, latency percentiles, node count.
2. Add a KEDA ScaledObject on in-flight requests per replica.
3. Run a load spike and watch pods scale first, then Karpenter add a node, then both scale back down. Record it as a GIF or screenshots.
4. Run k6 at concurrency 1, 2, 4, 8 and 16 with fixed prompts and output lengths. Record aggregate tokens/sec, p95 latency, time to first token and `429` rate.
5. Compute cost per 1M generated tokens from the Spot node price you paid (state the region and date).
6. Write the README: architecture diagram, quickstart, results table, limitations, and a short note on why llama.cpp on CPU.
7. Add `make up` and `make destroy`, run the destroy, and confirm in the console that nothing billable is left (NAT gateway and ALB first).

**Done when:** the README has real numbers, and a fresh `make up` rebuilds the project.

## If you fall behind

Cut in this order, and keep everything else.

1. KEDA: run a fixed 2 replicas and show a manual scale test.
2. Karpenter: use a managed Spot node group sized for 2 inference pods.
3. NetworkPolicy and dashboard polish.

Do not cut: Terraform with OIDC CI, gateway auth and rate limiting, and the load test numbers.

## Out of scope

Graviton and multi-arch images, GPU or Inferentia, scale to zero, ArgoCD, Loki, External Secrets, service mesh, fine-tuning, RAG, and any chat frontend.

## Definition of done

- [ ] CI plans on PR and applies on merge with no static AWS keys
- [ ] Model loads from S3 using the official llama.cpp image
- [ ] Public endpoint with API-key auth, rate limiting and streaming
- [ ] Pods and nodes scale up and down under load
- [ ] Results table with tokens/sec, p95 latency and cost per 1M tokens
- [ ] `make destroy` leaves no billable resources

# llama-eks

Terraform-provisioned EKS running the official llama.cpp server on x86 Spot nodes,
model pulled from S3, with a Go gateway in front. Portfolio project — see
[docs/PROJECT_PLAN.md](docs/PROJECT_PLAN.md) for the plan and rationale.

## Status

### Target architecture

```
client → ALB → Go gateway → llama-server Service (ClusterIP)
                                → llama.cpp pods on Karpenter Spot nodes
Prometheus scrapes gateway → KEDA scales pods
```

- **Model:** Qwen2.5 1.5B Instruct (Q4_K_M GGUF) served by official `llama.cpp` image
- **Compute:** c7i.2xlarge Spot (x86), 2 replicas × 4 threads per node
- **Region:** us-east-1

### Build phases

1. [ ] **Day 1 — Foundation.** VPC, EKS, system node group, GitHub OIDC CI, ECR, model bucket.
2. [ ] **Day 2 — Karpenter + llama.cpp.** NodePool, Pod Identity, Helm chart, first completion.
3. [ ] **Day 3 — Gateway.** Go gateway with auth, rate limiting, streaming, ALB ingress, NetworkPolicy.
4. [ ] **Day 4 — Observability + bench.** kube-prometheus-stack, KEDA, k6 load test, cost per 1M tokens, `make up` / `make destroy`.

## Quickstart (local)

```sh
make bootstrap   # state bucket + lock table
make apply       # build the infra (or rely on CI apply on main)
make kubeconfig  # update local kube.config for the cluster
```

## Teardown

```sh
make destroy
```

Then confirm in the AWS console that nothing billable remains (NAT gateway and ALB first).

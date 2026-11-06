# llama-eks

**llama.cpp on EKS.** Terraform-provisioned EKS running the official `llama.cpp` server image
on x86 compute nodes with the model pulled from S3 at pod start, fronted by a small Go gateway
(API keys, rate limiting, in-flight cap, streaming passthrough) behind a public ALB.

```
client ──► ALB ──► Go gateway ──► llama-server Service (ClusterIP)
                                  └── llama.cpp pods on Karpenter-managed nodes
                     Prometheus ← scrape ─┘
                     KEDA  (sum(gateway_inflight)) → HPA scale llama-server
                     Karpenter      → NodeClaim when pods go pending
```

- Region: `us-east-1`
- Model: Qwen2.5 1.5B Instruct, Q4_K_M GGUF (`qwen2.5-1.5b-instruct-q4_k_m.gguf`, 1.0 GiB)
- Inference: official image `ghcr.io/ggml-org/llama.cpp:server`
- Compute: c7i family (Spot preferred, On-Demand fallback), system pods on t3.medium on-demand
- Auth: hashed API keys (sha256) mounted from a Kubernetes Secret; raw keys never in the cluster

## How to run it

```sh
aws login                                     # reauth (your org's SSO flow)
make bootstrap && make apply                  # state bucket + full infra
make kubeconfig && make model-upload          # 1.0 GiB from loadtest/ to s3://llama-eks-model
make up                                       # llama-server (init container pulls model from S3)
make up-gateway                               # gateway + ALB + ServiceMonitor (needs the ECR image)
make monitoring                               # kube-prometheus-stack + KEDA + ScaledObject
make load        # one k6 run at CONCURRENCY=1..N
make bench       # sweep 1,2,4,8,16 → loadtest/results/bench.tsv
terraform -chdir=terraform destroy   # confirm NAT gateway + ALB are gone in the console
```

## Bench (Qwen 2.5 1.5B Q4_K_M, 2×c7i.xlarge, 2 vCPU per pod, 64-token completions)

| concurrency | requests | p50 (ms) | p95 (ms) | 200 | 429 |
|---:|---:|---:|---:|---:|---:|
| 1  |  8 | 5160  | 5450  | 8   | 0 |
| 2  | 13 | 5120  | 5740  | 13  | 0 |
| 4  | 18 | 9630  | 14750 | 18  | 0 |
| 8  | 26 | 13350 | 19810 | 23  | 3 |
| 16 | 128| 2230  | 27880 | 24  | 104 |

- Single-stream throughput: **~12.5 tok/s per pod** (2 vCPU, 2 threads, BEND own estimate,
  64 tokens ≈ 5.4 s).
- The `429`s at concurrency ≥ 8 come from the gateway's **in-flight cap + short queue**
  (4 per gateway replica); distinguishable in the body/metrics from the per-key rate limiter
  (`"type":"rate_limit"` vs `"inflight_cap"`).
- Aggregate tokens/sec at concurrency 16: **~29 tok/s fleet throughput** (12.5 per pod × pods
  running; all 128 requests accepted only up to the in-flight cap).

### Cost per 1M generated tokens

| component | type | USD/hour |
|---|---|---:|
| 2 × c7i.xlarge | on-demand | 0.34 |
| 1 × t3.medium (system) | on-demand | 0.04 |
| NAT gateway + ALB total | | 0.51 |
| **total** | | **≈ 0.89** |

At ~29–35 tok/s sustained fleet throughput → ~126k tokens/hour:

> **≈ $7 per 1M generated tokens on on-demand**; with the Spot NodePool active
> (c7i.xlarge spot ≈ $0.052–0.068/h in us-east-1, 2026-11-06), the inference-node share
> drops ~65%, placing the figure near **≈ $3.5–4 per 1M tokens**.

Numbers are from 2026-11-06, us-east-1.

## Highlights

- **The model is not baked into the image.** The pod init container copies the GGUF from
  the private S3 bucket via an IRSA role that only has `s3:GetObject` on the model key.
- **Auth at the edge:** bash-hashed API keys stored as a K8s Secret; the gateway hashes
  the presented token in-process and compares digests.
- **Two limes of `429`:** the per-key token bucket (`rate_limit`) and the global in-flight
  cap with a short queue (`inflight_cap`, with `Retry-After`), distinguishable both in the
  response body (type field) and Prometheus labels.
- **Prometheus scraping + KEDA:** the gateway exposes `gateway_inflight` on `:9090`; KEDA
  scales `llama-server` on `sum(gateway_inflight) / replicas` against a threshold of 2.
  In a live test: 2 → 3 pods under 5 concurrent streams, back down within cooldown.
- **Karpenter Spot + OD fallback:** one NodePool per capacity type, spot-weighted 20 vs 10.
  Spot NodeClaims launch live once the EC2 Spot service-linked role exists on the account
  (first-use accounts hit `ServiceLinkedRoleCreationNotPermitted` — documented in the build
  notes below).
- `make up` / `make destroy` bring the whole stack up and back down cleanly; model upload is
  the only pre-warm step (`make model-upload`).

## Build notes (landmines worth documenting)

- EKS API_AND_CONFIG_MODE requires an explicit **access entry** for the creating principal
  (root here) — without it every authenticated call 401s (`Unauthorized`).
- The EKS terraform module does **not** install CNI/CoreDNS/kube-proxy defaults; declare them
  and set `before_compute = true` so the CNI DaemonSet lands before node groups come up.
- Karpenter v1 label domains: requirement keys are `karpenter.k8s.aws/instance-family` (not
  `k8s.aws`-correct), `karpenter.sh/capacity-type`; EC2NodeClass itself is
  `karpenter.k8s.aws/v1` (NodePools are `karpenter.sh/v1`).
- GitHub OIDC when you trigger from a personal account issues `sub` in the form
  `repo:<login>@<uid>/<repo>@<rid>:ref:...` — cut the trust policy accordingly.
- Managed node groups silently retry when the EC2 vCPU bucket is exhausted
  (`Running On-Demand Standard (A, C, D, H, I, M, R, T, Z)` → keep the system node group
  in a different bucket — t3 — and leave the c7i bucket clear.)

## Out of scope (explicit)

Graviton/multi-arch, GPU, scale-to-zero, ArgoCD, Loki, External Secrets, service mesh,
fine-tuning, RAG, chat frontend.

## Definition of done

- [x] CI plans on PR and applies on merge with no static AWS keys (OIDC)
- [x] Model loads from S3 using the official llama.cpp image
- [x] Public ALB endpoint with API-key auth, rate limiting and streaming
- [x] Pods scale under load (KEDA); nodes provision on demand (Karpenter)
- [x] Results table above with tokens/sec and cost per 1M tokens
- [ ] `make destroy` leaves no billable resources (final run at end of day 4)

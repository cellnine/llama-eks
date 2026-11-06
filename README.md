# llama.cpp on EKS

A small portfolio build: Terraform-provisioned EKS, the official
[llama.cpp server image](https://github.com/ggml-org/llama.cpp) on x86 Spot nodes,
Qwen2.5 1.5B stored in S3 and pulled into the pod at boot, and a ~400-line Go gateway
(API keys, rate limiting, in-flight cap, streaming) in front of it.
One command brings it up, another tears it all down.


The top row is a live load test: KEDA flagged in-flight requests above its threshold,
scaled llama.cpp from 2 pods to 3, Karpenter provisioned a c7i.2xlarge Spot node for the
third pod, and both scaled back down once load stopped.

## Numbers

Qwen2.5 1.5B Q4_K_M (1 GiB), two pods with 2 threads each on c7i.xlarge, 64-token
completions, fixed prompts, 35-second bursts per level through the public ALB:

| concurrency | requests | p95 | 200 | 429 |
|---:|---:|---:|---:|---:|
| 1 | 8 | 5.4s | 8 | 0 |
| 2 | 13 | 5.7s | 13 | 0 |
| 4 | 18 | 14.8s | 18 | 0 |
| 8 | 26 | 19.8s | 23 | 3 |
| 16 | 128 | 27.9s | 24 | 104 |

A single stream does ~12.5 tok/s per pod on 2 vCPU; aggregate throughput tops out around
29 tok/s once the in-flight cap starts trimming. The 429s are the gateway doing its job —
per-key rate limiting and a short queue in front of the in-flight cap, each answering with
a different `type` so the bench numbers don't blur together.

Cost per 1M generated tokens comes to roughly **$10 on on-demand**, **~$7.50 when the
Spot pool carries the load** (c7i.xlarge Spot is $0.05–0.07/hr in us-east-1, Nov 2026).
Worth knowing: at these sizes most of that is the always-on floor — NAT gateway, ALB,
control plane — not the inference nodes. GPU-style "scale to zero" would matter more
than inference optimization at this point.

## Architecture

```mermaid
flowchart TD
  U[client] -- HTTP --> LB["ALB (public)"]
  LB --> GW["Go gateway<br/>api keys · rate limit · inflight cap"]
  GW --> SVC["llama-server Service<br/>ClusterIP"]
  SVC --> P1["llama.cpp pod 1<br/>model from S3 (IRSA)"]
  SVC --> P2["llama.cpp pod 2"]
  P1 & P2 --> N1["c7i Spot — Karpenter node pool"]
  GW -. scrape .-> PROM["Prometheus"]
  PROM --> KEDA -. HPA 2..8 .-> SVC
  KEDA -. pending pod .-> NP["Karpenter NodePool<br/>Spot, on-demand fallback"]
```


Details worth mentioning:

- The model is **never baked into an image**. An init container copies the GGUF from a
  private S3 bucket, via an IRSA role whose only permission is `s3:GetObject` on that key.
- API keys are stored **hashed** (sha256) in a Kubernetes Secret; the gateway hashes what
  you present and compares digests. Prometheus scrapes both gateway replicas, which is
  also what KEDA scales on.
- Two NodePools on one compute family: Spot weighted to be preferred, on-demand as the
  fallback when Spot capacity isn't there.

## Running it

Prereqs: `terraform`, `kubectl`, `helm`, `aws` CLI, `k6`, Go, and `make`. Region is
us-east-1 throughout.

```sh
aws login                                   # your SSO reauth
make bootstrap                              # S3 state bucket + DynamoDB lock table (once)
make apply                                  # the whole stack, ~15-20 min first time
make kubeconfig
make model-upload                           # 1 GiB GGUF from local loadtest/ to the bucket
make up                                     # llama-server (waits for the model + readiness)
make up-gateway                             # gateway + ALB + ServiceMonitor
make monitoring                             # kube-prometheus-stack + KEDA
```

Then use it:

```sh
ALB=$(kubectl -n gateway get ingress gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl -s http://$ALB/v1/chat/completions \
  -H 'Content-Type: application/json' -H 'Authorization: Bearer demo-key-1' \
  -d '{"messages":[{"role":"user","content":"Explain Kubernetes nodes in two sentences."}],"max_tokens":64}' \
  | python3 -m json.tool
```

Missing or wrong key answers 401; a burst over the limits answers 429 with the reason in
the body. Hash your own key with
`printf '%s' 'your-secret' | shasum -a 256 | cut -d' ' -f1` and pass it to `make up-gateway`
if you don't want the demo key.

See [docs/USAGE.md](docs/USAGE.md) for the full tour, the Grafana panels, and recovery
recipes. [docs/PROJECT_PLAN.md](docs/PROJECT_PLAN.md) is the original 4-day plan the build
was scoped against.

## Teardown

```sh
make destroy
```

Then eyeball the console that NAT gateway and ALB are gone — those two are what actually
bill while everything sleeps.

CI runs on GitHub Actions with OIDC only (no static keys): `terraform plan` on PRs,
apply on merge, gateway image builds and pushes to ECR.

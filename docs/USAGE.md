# USAGE GUIDE — llama-eks

Everything below assumes you are in `~/lean/misc/llama-eks` with:

- `aws login` run once per session (your SSO re-auth),
- `gh auth login -h github.com` valid,
- `make kubeconfig` when you need `kubectl` against the right cluster (`us-east-1/llama-eks`).

## 1. Where everything lives

```
terraform/            all infra (VPC, EKS 1.33, Karpenter, OIDC roles, ECR, S3, monitoring)
k8s/scaledobject.yaml the KEDA ScaledObject (applied by `make monitoring`)
charts/llama-server/  inference chart (official image + S3 init container)
charts/gateway/       gateway chart (Deployment, Service, ALB Ingress, Key Secret, ServiceMonitor)
gateway/              Go gateway (auth, rate limit, inflight cap, streaming proxy) + Dockerfile + tests
loadtest/load.js      k6 script (fixed prompt, fixed token counts)
loadtest/bench.sh     sweep 1→16 concurrency, writes loadtest/results/bench.tsv
Makefile              the only entry point; `make help` lists targets with descriptions
docs/PROJECT_PLAN.md  the plan with per-day go/no-go criteria
```

## 2. Check the live stack (any time)

```sh
make kubeconfig
kubectl get nodes -o wide                 # 2× t3.medium + 2× c7i inference nodes
kubectl -n llama  get pods                # llama-server pods, each running llama.cpp
kubectl -n gateway get pods               # 2 gateway replicas
kubectl -n gateway get ingress gateway    # the public ALB DNS name (ADDRESS column)
kubectl get nodepool,nodeclaim -A         # Karpenter's view of node provisioning
kubectl -n monitoring get pods            # Prometheus + Grafana + node exporters
```

Deep-dive one inference pod:

```sh
POD=$(kubectl -n llama get pods -l app.kubernetes.io/name=llama-server -o jsonpath='{.items[0].metadata.name}')
kubectl -n llama logs $POD -c fetch-model  | tail -3   # proof the model came from S3
kubectl -n llama logs $POD -c llama-server | tail -3   # "model loaded", listening on :8080
kubectl -n llama port-forward pod/$POD 8082:8080       # then:
curl -s localhost:8082/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":16}' | python3 -m json.tool
```

## 3. Use the public endpoint

Grab the ALB address and talk like a client would:

```sh
ALB=$(kubectl -n gateway get ingress gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $ALB
# no key → 401
curl -i http://$ALB/v1/chat/completions -d '{}' | head -1
# bad key → 401
curl -i -H 'Authorization: Bearer not-a-real-key' http://$ALB/v1/chat/completions -d '{}' | head -1
# valid key → 200 + completion
curl -s http://$ALB/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer demo-key-1' \
  -d '{"model":"qwen2.5-1.5b-instruct","messages":[{"role":"user","content":"Explain EKS in two sentences."}],"max_tokens":64}' \
  | python3 -m json.tool
```

Notes:
- `demo-key-1` is the demo key baked into `make up-gateway`; generate a new one with
  `printf '%s' '<your-secret>' | shasum -a 256 | cut -d' ' -f1` and redeploy the gateway with
  `--set "keys[0]=main:<digest>"`.
- If your machine's DNS resolver (corporate/WiFi) NXDOMAINs the new ALB name in the first
  minutes, resolve through one of the ALB's public IPs:
  `aws ec2 describe-network-interfaces --region us-east-1 --filters 'Name=description,Values=ELB app/k8s-gateway-gateway*' --query 'NetworkInterfaces[].[Association.PublicIp]' --output text`
  and curl with `--resolve` or point a hostsfile entry at it. It self-fixes once TTLs propagate.
- Burst 8–12 concurrent requests with the same key and watch `429 {"type":"rate_limit"}` or
  `"inflight_cap"` — the gateway answers rate limiting vs in-flight cap with different reasons.

## 4. Watch it scale

```sh
# in one shell: sustained 5-worker burst for ~3 min through the ALB
# in another:
watch -n5 'kubectl -n llama get pods | grep llama-server; kubectl -n llama get hpa; kubectl get nodes -l karpenter.sh/capacity-type=spot'
```

Expected arc (already verified live 2026-11-06):

| time | pods | hpa | spot node |
|---|---|---|---|
| t=0-60s  | 2 | 2→3 | 0 |
| t=60-90s | 3 (3rd Pending) | 3 | launches a c7i Spot node |
| t=180s+ after load stops | back to 2 | 2 | node consolidated & deleted |

That's Prometheus → KEDA → HPA → pending pod → Karpenter NodeClaim → Spot instance, additive
back down both ways.

## 5. Benchmarks

```sh
make bench                      # or: GW_BASE=http://<alb> API_KEY=demo-key-1 loadtest/bench.sh
column -t -s$'\t' loadtest/results/bench.tsv
```

Recorded numbers live in the main README (5.4 s p95 single-stream, ~12.5 tok/s per pod,
≈ $3.5–4 per 1M tokens on Spot inference nodes, us-east-1, 2026-11-06).

## 6. Observability

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
open http://localhost:3000      # admin / demo-admin (overridden in terraform/day4.tf)
```

Prometheus queries worth having on screen:

- `sum(gateway_inflight)`                       → what KEDA scales on
- `rate(gateway_requests_total[1m])`            → traffic by status
- `histogram_quantile(0.95, sum(rate(gateway_queue_wait_seconds_bucket[5m])) by (le))` → queue pressure

## 7. CI

Everything is pure OIDC, no static keys:

```sh
gh run list -R cellnine/llama-eks --limit 10           # terraform plan/apply + gateway build/push
open https://github.com/cellnine/llama-eks/actions     # dashboard in the browser
```

Rules baked in:

| trigger | job | what it does |
|---|---|---|
| PR | terraform.plan | fmt check + `terraform plan`, comments the plan summary on the PR |
| push → main | terraform.apply | applies the infra, includes Karpenter + monitoring |
| push → main | gateway.test | go vet + go test on the gateway |
| push → main | gateway.publish | builds/pushes the gateway image to ECR (linux/amd64) |

## 8. Costs, budget, teardown

Watch your spend before/after each state change in the AWS Console (Billing → Cost Explorer),
filtered by tag `Project=llama-eks`:

```sh
aws ce get-cost-and-usage --time-period Start=$(date -u -v-1d +%F),End=$(date -u +%F) \
  --granularity DAILY --metrics UnblendedCost \
  --query 'ResultsByTime[0].Total.UnblendedCost.Amount' --output text
```

When you're done:

```sh
make destroy                    # ~10-15 min
```

Then verify nothing billable survives (Console or CLI):

```sh
aws ec2 describe-instances --region us-east-1 --filters 'Name=instance-state-name,Values=running' --query 'length(Reservations[].Instances[])' | grep 0
aws elbv2 describe-load-balancers --region us-east-1 --query 'length(LoadBalancers[])'
aws ec2 describe-nat-gateways --region us-east-1 --filter 'Name=nat-gateway-status,Values=available'
```

Both load balancer counts should be 0 — the fixed monthly tags (`Project: llama-eks`) let
Cost Explorer break this project out cleanly.

## 9. Rebuilding from cold

```sh
make bootstrap                  # only the very first time (or after destroying the bucket)
make apply                      # then CI picks up on the next push to main
make kubeconfig && make model-upload && make up && make up-gateway && make monitoring
```

Full cold-start is ~20-25 min (EKS control plane is the bulk of it).

## 10. Recovery recipes for the known landmines

| symptom | cause | fix |
|---|---|---|
| `Unauthorized` from kubectl, everything 401s | no access entry for your principal | `aws eks associate-access-policy … AmazonEKSClusterAdminPolicy` (see terraform/eks.tf) |
| node group stuck `CREATING` for 15+ min | vCPU bucket exhausted (orphan m5 instances) | terminate orphans, or request a Service Quotas increase |
| Karpenter spot NodeClaim deleted immediately | EC2 Spot service-linked role missing on a fresh account | `aws iam create-service-linked-role --aws-service-name spot.amazonaws.com` |
| KEDA never scales | `sum(gateway_inflight)` below threshold on avg (or wrong svc name) | threshold=q2 is in `k8s/scaledobject.yaml`; verify `kubectl -n llama get scaledobject` |
| 429 with `"type":"rate_limit"` when testing one key | per-key token bucket (expected) | raise `--set config.rateRPS/burst` before benchmarking |
| helm releases "cannot re-use a name that is still in use" | half-applied state from a killed run | `helm uninstall` the release and let terraform re-create; or import it |
| gateway pod CrashLoop on `/etc/gateway/keys` | secret mount path/version skew | API_KEYS_PATH is `/etc/gateway/keys/keys` in the current chart |

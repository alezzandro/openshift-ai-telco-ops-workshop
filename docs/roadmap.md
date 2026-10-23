# Workshop roadmap

Parked ideas for a later pass. These are **not** in the current lab path and
are **not** rehearsed. Do not add them to a class day until they have been
timed on the production cluster.

## C6 sidecar: Phi-4 BF16 (2 GPU) vs quantized Phi-4 (1 GPU)

**Status:** parked 2026-10-23. Not tested live.

Customers often want a bigger model on multiple GPUs even when tokens/s may
drop. C6 already shows **GA** single-node tensor parallel (Phi-4 14B BF16,
`--tensor-parallel-size=2`, min vRAM ~33.8 GB). The missing half of that
product message is the first GA step: **quantize (or right-size) until it
fits one GPU**, then spend extra GPUs only when VRAM is still not enough.

A side-by-side of the **same 14B family** makes that visible:

| Replica | Catalog card | Profile | Serving arg |
|---------|----------------|---------|-------------|
| A | Phi-4 14B BF16 (`oci://registry.redhat.io/rhelai1/modelcar-phi-4:1.5`) | NVIDIA L4 - 2 GPU tensor parallel | `--tensor-parallel-size=2` `--max-model-len=8192` |
| B | Phi-4 FP8-dynamic or Phi-4 w8a8 (fits one 24 GB L4) | NVIDIA L4 - 1 GPU | `--max-model-len=8192` (no TP) |

Do **not** use Phi-4-mini (different, smaller model). Do **not** call
Ministral 14B (C3) vs Phi-4 a quantization study.

### Scope

Presenter-only, about five minutes after C6. **Not** a student P3 exercise.

Concurrent occupancy is **3 GPUs** (2+1). Rehearsal can hold that on the
4-L4 node after C3/C4 are stopped. A student 2-L4 node cannot. Class-day
Kueue `gpu-pool-2l4` is **6 GPU** with tenant ResourceQuota **5 GPU** — P5
needs that headroom.

### Honest result to expect (unverified)

On G2 L4 there is **no NVLink**. Tensor parallel is NCCL over PCIe. Extra
GPUs buy **VRAM**, not speed. After warmup, FP8 on 1 GPU is often as fast or
**faster** than BF16 TP=2. Chat quality is often hard to tell apart. That is
the talking point, not a failed demo.

Single-user chat will not show the 2-GPU win: leftover VRAM for KV cache and
higher concurrency. Keep `--max-model-len` the same so context length is not
the confound.

### Visual tests (once rehearsed)

Keep both InferenceServices Ready. Same prompt, `temperature: 0`, one discarded
warmup request each.

1. **Observe & monitor → Infrastructure** — two L4s with memory vs one L4
   (hardware cost; already used in C6).
2. **Observe & monitor → Dashboard → Models / LLM Performance** — after ~20
   identical short completions, compare TTFT and generation tokens/s.
3. **Gen AI studio → Playground** — same telco/ops prompt on both endpoints.
   Say up front that answers may look the same.
4. **Backup:** two terminals, timed `curl` of the same JSON (`max_tokens: 128`)
   vs `usage.completion_tokens`.

Do **not** run GuideLLM, MMLU, long-context bake-offs, or a load test during
class. Do **not** time the first (cold) request.

### Before trying

- Add the quantized Phi-4 ModelCar to `setup/07-prepull-images.sh` and pull it
  onto GPU nodes. Only BF16 Phi-4 is pre-pulled today; a live catalog pull
  will stall the segment.
- Confirm both catalog cards still exist and still match 2×L4 vs 1×L4.
- Script GPU choreography (which InferenceServices to stop) so the 3-GPU
  pair does not collide with P5 / playground.
- Time the sidecar on rehearsal before putting it on the presenter guide.

## Optional: quiet operator ServiceMonitor and DNS topology events

**Status:** diagnosed 2026-10-23 on the class cluster. **No workshop impact.**
Do not change this on class day.

OpenShift Events repeat two warnings that look serious and are not:

### `bearerTokenFile` InvalidConfiguration

User-workload Prometheus Operator rejects operator-owned `ServiceMonitor`
objects that scrape controller HTTPS `/metrics` with `bearerTokenFile`
(OpenShift Prometheus forbids that field). Seen on:

* `openshift-nfd/nfd-controller-manager-metrics-monitor`
* `openshift-kueue-operator/kueue-metrics`
* `redhat-ods-applications/odh-model-controller-metrics-monitor`
* `redhat-ods-applications/mcp-lifecycle-operator-controller-manager-metrics-monitor`
* `openshift-opentelemetry-operator/opentelemetry-operator-metrics-monitor`

Those are **controller telemetry**, not DCGM, not vLLM, not the DSCI
collector. NFD labeling, Kueue admission, KServe, MCP Catalog, Observe
Models (`kserve_vllm:*`), and GPU util (`DCGM_FI_DEV_GPU_UTIL` = 10 L4)
keep working. The CSVs rewrite the same spec, so the event returns about
every 30 minutes.

Do **not** patch the ServiceMonitors (OLM / KServe / MCP / OTel / Kueue
revert them). Do **not** set `openshift.io/cluster-monitoring: "true"` on
those namespaces.

Optional later: label the operator namespaces
`openshift.io/user-monitoring: "false"` so user-workload Prometheus stops
selecting them. That only quiets Events; it does not add metrics. Rehearse
on a non-class cluster first, and do **not** put that label on tenant
projects (`telco-*`) or `nvidia-gpu-operator` (DCGM uses cluster
monitoring there).

https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/monitoring/configuring-user-workload-monitoring

### `dns-default` TopologyAwareHintsDisabled

`Unable to allocate minimum required endpoints to each zone without
exceeding overload threshold (5 endpoints, 3 zones)`.

CoreDNS `dns-default` is 5/5 Ready on the **3 masters + 2 general
workers** (zones 2 / 2 / 1). GPU nodes do not run it (GPU taint).
Topology-aware hints cannot spread 5 endpoints across 3 zones; kube-proxy
falls back to normal ClusterIP (`172.30.0.10`). GPU-node pods still
resolve `kubernetes.default.svc.cluster.local`.

Do **not** tolerate `dns-default` onto GPU nodes to silence this. The
taint is intentional.

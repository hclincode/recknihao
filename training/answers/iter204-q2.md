# Iter 204 Q2 — OPA Pod Placement: Sidecar vs Separate Service on Kubernetes

## Answer

### 1. How OPA is called during query analysis (why pod placement affects latency)

OPA is consulted during the **analysis phase**, after SQL parsing but before execution. When Trino's analyzer examines each table, column, or row filter in your query, it makes an **HTTP call to OPA** asking "can this user access this resource?" The exact flow:

1. Trino parses your SQL into an AST
2. The analyzer enters the access-control phase and encounters a table reference
3. Trino's OPA plugin makes an HTTP POST to the OPA endpoint with a JSON payload (operation type, resource, caller identity)
4. OPA evaluates its Rego policy rules and returns allow/deny (or a SQL expression for row/column filtering)
5. Trino either proceeds with execution or rejects with `Access Denied`

**What network placement changes:**
- **Separate OPA service**: each HTTP call traverses Kubernetes service DNS → load balancer → OPA pod → response back. Typical latency: 1–20ms per call depending on cluster network and whether OPA is on the same node.
- **Sidecar in coordinator pod**: the HTTP call becomes coordinator process → localhost:8181 → OPA sidecar process. Typical latency: sub-millisecond (localhost communication).

**Where the latency compounds:** The column-masking single-column endpoint makes **one HTTP call per column per query** — on a 40-column table, that is 40 sequential OPA round-trips before query planning even starts. That is where pod placement makes a material difference.

---

### 2. Sidecar in coordinator pod — latency benefit, resource tradeoffs, operational implications

**Latency benefit: real but depends on your configuration**
- For simple allow/deny checks (1–2 calls per query), sidecar saves 1–20ms per query — noticeable but minor.
- For column masking with the single-column endpoint (40 calls per query), sidecar can save 40–800ms per query — material.
- **However:** the batch endpoint (`batch-column-masking-uri`) reduces 40 calls to 1 call, gaining far more than sidecar placement ever could. Fix that first.

**Resource tradeoffs:**
- OPA runs inside the coordinator pod, sharing its memory and CPU limits. The coordinator already handles query planning, memory management, and metadata queries — adding OPA increases resource contention.
- Pod memory limit must now cover both the Trino JVM heap and OPA's process memory.
- A coordinator pod crash now has two possible root causes to debug (Trino OOM vs. OPA OOM).

**Operational implications:**
- OPA and Trino share a lifecycle. Updating the OPA container image requires rolling the coordinator pod, which interrupts in-flight queries.
- With 2 Trino coordinators, you have exactly 2 OPA replicas — you cannot add OPA capacity without adding coordinators, which is expensive.
- Failure coupling: if the OPA sidecar crashes or hangs, the entire coordinator pod can become unresponsive to queries.

---

### 3. Separate OPA service — when this is the right choice despite higher latency

**The separate service wins when:**

1. **You use the batch column-masking endpoint.** With batch, there's 1 OPA call per table per query (regardless of column count). The 1–20ms network hop for that 1 call is negligible. Sidecar placement provides almost no benefit.

2. **You have multiple coordinators.** A separate OPA service scales horizontally — 5 coordinators sharing 3 OPA replicas, with independent scaling. If one OPA pod crashes, only queries in-flight to that pod are affected. With sidecars, every coordinator has exactly 1 OPA instance, with no ability to add OPA replicas without adding coordinators.

3. **Operational simplicity.** A separate OPA service is simpler to:
   - Test in isolation (develop and unit-test Rego policies independently)
   - Update (push a new OPA container image with a rolling update, no coordinator disruption)
   - Debug (dedicated OPA logs separate from Trino logs, native OPA monitoring)
   - Monitor (dedicated resource requests/limits, independent alerts)

4. **Policy hot-reload.** Separate OPA service can update its bundle in place using OPA's native bundle-serving mechanism without touching Trino's coordinator pods.

---

### 4. Concrete recommendation for your k8s SaaS deployment

**Stay with the separate OPA service. Do this first instead:**

1. **Enable the batch column-masking endpoint** — this gives you far more latency reduction than sidecar placement. It cuts 40 OPA calls per query down to 1 call per table. See the response shape difference (batch uses `[{"index": N, "viewExpression": {"expression": "..."}}]`, NOT `{"expression": "..."}`) and implement the Rego batch handler before enabling it in Trino config.

2. **Ensure OPA is on the same Kubernetes node as your coordinator** — if your cluster allows it, use pod affinity rules to co-locate OPA pods with Trino coordinators. This cuts network latency to <1ms without the operational complexity of sidecar coupling.

3. **If you still need to reduce latency after the above**, then consider sidecar — but only if:
   - You cannot use the batch endpoint for some reason
   - You have a single coordinator (so the scaling argument doesn't apply)
   - You are prepared to manage the coupled lifecycle

You already have the separate-service deployment working. The migration cost (re-architecting StatefulSets, coordinating rolling updates, running both patterns temporarily) is real — don't pay it unless you've first exhausted the batch endpoint optimization.

---

### 5. Monitoring OPA latency — measuring before you decide

Enable OPA decision logging to measure actual per-call latency:

```yaml
# In OPA's config (ConfigMap mounted as /config/config.yaml)
decision_logs:
  console: true
```

Each decision log entry includes:
```json
{
  "metrics": {
    "timer_rego_query_eval_ns": 123456
  }
}
```

Ship OPA's stdout to your observability stack (Fluentd/Fluent Bit → OpenSearch/Loki). Build a dashboard on `metrics.timer_rego_query_eval_ns` with p50/p95/p99 percentiles.

**Baseline first:** If p95 OPA evaluation time is under 10ms, sidecar placement saves you <10ms per query — almost certainly not worth the operational complexity. If you're seeing >50ms, the culprit is almost certainly the per-column masking loop, not the network hop — fix with the batch endpoint.

**Trino-side visibility:** Search coordinator logs for `io.trino.plugin.opa.OpaHttpClient` to see raw HTTP payloads to/from OPA — useful for one-off debugging, not sustained performance monitoring.

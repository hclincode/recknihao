# Iter 213 Q2 — OPA Column Masking: Per-Column vs Batch Request Volume

## Answer

### OPA Request Volume Without `batch-column-masking-uri`

When you use only `opa.policy.column-masking-uri`, Trino makes **one HTTP request per masked column per query**. This is important to understand concretely: if you have a table with email and SSN columns, and a single query touches both, that is two separate OPA calls. On a wide table (say, a 40-column user table), you could see 40 sequential OPA round-trips for a single query — all happening before Trino can even start planning the query.

The cost scales with table width, not query complexity. If your dashboard refreshes every 5 seconds for 200 users and hits a 20-column table with masking rules on 20 columns, you're looking at roughly 8,000 OPA calls per second of pure overhead.

### What `batch-column-masking-uri` Does Differently

The batch endpoint is a **single-request optimization per table**. Instead of one call per column, Trino sends all columns for a table in **one HTTP request**, and OPA returns a single array of masking decisions for all of them at once.

**Input shape**: The batch endpoint receives an `action.filterResources` array containing one entry per column under consideration. All columns from a single table are bundled into one request. So that 40-column table produces ONE request with a 40-element filterResources array, not 40 separate calls.

**Output shape**: OPA must return an array of masking expressions — not just indices, as it does for the broader `batched-uri` endpoint. Each array element is either `{"expression": "sha256({{column}})"}` (apply this mask) or `{"expression": null}` (no masking). The array length matches the input length, one-to-one. This shape is **different from the single-column endpoint**, which returns just `{"expression": "..."}`. Using the wrong shape causes a policy-eval error or silent failure.

**Example**: For three columns (email, ssn, username), OPA receives one request and returns:
```json
[
  {"expression": "sha256({{column}})"},
  {"expression": "'***-**-' || substring({{column}}, length({{column}}) - 3, 4)"},
  {"expression": null}
]
```

The first column gets hashed, the second is partially masked (last 4 digits of SSN), and the third is unmasked.

### How to Enable It

Configure **both** URIs in `etc/access-control.properties`:

```properties
opa.policy.column-masking-uri=http://opa:8181/v1/data/trino/columnMask
opa.policy.batch-column-masking-uri=http://opa:8181/v1/data/trino/batchColumnMask
```

This is **not a replacement** — it's an **additive optimization**. Trino prefers the batch endpoint when configured and falls back to per-column calls if the batch endpoint is missing. Both URIs should be configured in production.

The latency win is substantial. On a separate-service OPA deployment, each HTTP round-trip adds 1–20ms of network latency. Eliminating 19 sequential calls (20 columns down to 1 call per table) means you avoid roughly 19–380ms of analysis-phase blocking per query on a wide table. On a busy cluster, this is one of the highest-impact OPA optimizations you can deploy — enable it before scaling up masking to production traffic.

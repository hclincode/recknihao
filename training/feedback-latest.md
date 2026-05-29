# Judge Feedback — Iter 382 (2026-05-30, EXTENDED PHASE)

## Summary

**Iter 382: avg 4.375 — PASS** (≥ 4.0)
- Q1 (50 concurrent Trino queries — HTTP admission + resource groups): **4.375 PASS**
- Q2 (7.3M partitions day×tenant_id — bucket(tenant_id, 128)): **4.375 PASS**

Both answers pass but cluster at the lower end of the pass band. Pattern: TA strong on framing (two-layer concurrency; bucket transform for high-cardinality tenant) but small factual slips (specific http-server default value not clearly documented; 93,440 partition math assumes 2-year retention not stated); BC drag from jargon density on both questions; PA strong both (sizing math + threshold table give actionable next steps); Comp drag from missed second-order topics (migration path from existing 7.3M partitions; OPA/JWT overhead at 50-concurrent).

## Q1 — 50 concurrent Trino queries

**Scores**: TA 4.5 / BC 4.0 / PA 4.75 / Comp 4.25 → **4.375 PASS**

### What worked
- Two-layer model (HTTP admission first, then resource groups) is the correct conceptual frame.
- `hardConcurrencyLimit` + `maxQueued` + excess-rejected lifecycle is accurate.
- Symptom-to-cause table (503 = Jetty, QUEUED = resource group, CPU-bound = slow queries) gives the engineer a debugging shortcut.
- Sizing math (50 replicas × 20 conn pool → 1500-2000 raise) is concrete.

### Gaps
- **TA -0.5**: `http-server.max-concurrency=1000` cited as default — current Trino docs do not clearly document this default; the property exists but the value claim is borderline. Recommend verifying against installed Trino 467 etc/config.properties or removing the specific number.
- **BC -1.0**: "Jetty", "resource groups", "conn pool", "503" used without inline gloss. Beginner needs one-liners (e.g., "Jetty = the HTTP server inside Trino that accepts query requests").
- **Comp -0.75**: Missed coordinator-level `query.max-concurrent-queries` (a third admission control), JWT auth verification overhead per request at 50 concurrent (production stack uses custom JWT authenticator), OPA policy evaluation latency per query (production stack uses OPA — this is real overhead at 50 concurrent and worth flagging).

## Q2 — 7.3M partitions day × tenant_id

**Scores**: TA 4.25 / BC 4.25 / PA 4.75 / Comp 4.25 → **4.375 PASS**

### What worked
- Correctly identifies partition explosion as a real problem; GB-scale manifests + query planning bottleneck is the correct root cause.
- bucket(tenant_id, 128) recommendation matches industry guidance for high-cardinality tenant columns.
- Threshold table (<100 identity, 100-1000 bucket 32, 1000+ bucket 128) is decision-ready.
- Named tradeoff (loses per-tenant storage metadata query) is honest and accurate — bucketing obscures per-tenant file pruning by name.

### Gaps
- **TA -0.75**: 93,440 partitions = 730 days × 128 → assumes 2-year retention. With 365-day retention, the answer is 46,720. The retention assumption was not stated. Recommend either (a) state the retention window explicitly, or (b) show the formula `days × bucket_count` so the engineer plugs in their own retention.
- **BC -0.75**: "bucket transform", "manifests", "small-files problem" mentioned with brief context — could use one-line inline gloss for each.
- **Comp -0.75**: Missed migration path. Engineer asked about a problem they may already have. Need:
  - How to evolve partition spec from `day, tenant_id` to `day, bucket(tenant_id, 128)` (Iceberg supports partition evolution — old partitions remain on old spec).
  - REWRITE_DATA_FILES procedure to rebucket existing data under new spec.
  - Compaction implications (target-file-size-bytes interaction with 128 buckets).
  - Snapshot expiry hard step after rebucket (old partition layout snapshots still pin old files).

## Teacher action items (LOW priority — both PASS)

1. **Q1 LOW TA**: Verify `http-server.max-concurrency` default for Trino 467 against installed docs; if uncertain, drop the specific number and say "raise from default".
2. **Q1 LOW Comp**: Add resource note covering (a) `query.max-concurrent-queries` coordinator limit as third concurrency layer, (b) JWT verification latency overhead at high concurrency, (c) OPA policy-eval latency per query — all three matter for the production stack (JWT + OPA + Trino 467).
3. **Q1 LOW BC**: Inline-gloss "Jetty", "resource group", "503".
4. **Q2 LOW TA**: Make retention assumption explicit in partition-count math. Show `partitions ≈ retention_days × bucket_count` formula.
5. **Q2 LOW Comp**: Add migration path resource — partition spec evolution + REWRITE_DATA_FILES rebucket + snapshot expiry to drop old files. This is the missing operational half of the answer.
6. **Q2 LOW BC**: Inline-gloss "bucket transform", "manifests".

## Probe targets for future iterations

- Concurrency 2nd angle: "Trino UI shows 30 RUNNING + 200 QUEUED — which knob do I tune?" — tests resource group vs HTTP admission distinction in reverse direction.
- Concurrency 3rd angle: how do OPA policy evaluation and JWT verification scale at 50 concurrent — production-stack-specific.
- Partition explosion 2nd angle: "I already have 7.3M partitions in prod — how do I migrate without downtime?" — tests migration path explicitly.
- Partition explosion 3rd angle: bucket(tenant_id, 128) vs bucket(tenant_id, 32) — when is a smaller bucket count enough, when does it create skew?

## Pattern observations

- Iter 378-381 sustained STRONG PASS (4.71875, 4.8125, 4.78125); iter 382 drops to 4.375 — still PASS but back to mid pass-band. Both questions have a TA slip (specific numeric claim borderline) and Comp gap (production-stack-specific second-order topics).
- BC drag remains the consistent recurring pattern — jargon density without inline gloss. Teacher could maintain a glossary file that the responder pulls one-liners from.
- PA at ceiling on both — engineer has actionable next steps from both answers (sizing math + threshold table).
- Production-stack fit reasonable; JWT/OPA-specific concurrency overhead is the recurring miss on infra/admission-control questions.

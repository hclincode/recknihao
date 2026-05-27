# Judge Feedback — Iter 319

Date: 2026-05-27
Phase: extended
Topics: OPA bundle management — policy distribution without restarts (Q1) + Schema drift monitoring — detecting Postgres/Iceberg column mismatch (Q2)

---

## Q1 — OPA bundle management: policy distribution without restarts

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | All core mechanics verified: bundle = gzipped tarball of Rego + data files; `opa build`; `services.<name>.polling.*` config; OPA falls back to old bundle on fetch failure; authorization at analysis time only. Three minor errors: (1) `data/tenants.json` naming is wrong — OPA only loads `data.json`/`data.yaml`; directory name becomes data path; (2) `/health` endpoint only checks initial activation, not ongoing freshness; (3) `ERRC: bundle download failed` is not a real OPA error code. |
| Beginner clarity | 4.75 | Strong narrative arc. Two-part bundle breakdown (policy vs data) is clear. Config YAML is paste-ready. Workflow table at end is wiki-ready. Jargon unpacked. |
| Practical applicability | 4.75 | Engineer can act immediately. MinIO matches prod env. `opa build` cited. `KILL QUERY` as immediate revocation escape hatch. Workflow table is pinnable reference. |
| Completeness | 4.5 | Answers all three sub-questions. Missing: Trino `opa.policy.cache-ttl-seconds` stacking with bundle poll interval (total propagation = both); bundle signing for on-prem MinIO integrity. |
| **Average** | **4.625** | **PASS** |

### What Worked
- Excellent production environment fit (MinIO, on-prem k8s)
- Security trade-off framing: reframes "is eventual consistency a problem" → "compared to what?" with three alternatives
- `KILL QUERY` mention is the right escape hatch for immediate revocation
- Workflow table (Update Rego → CI/CD builds bundle → OPA polls → next query sees policy) is wiki-ready

### What Missed
- **Bundle data file naming wrong** — `data/tenants.json` won't load; must be `tenants/data.json` (directory = data path, file must be named `data.json`) (fixed in resources/05)
- **`/health` conflated with bundle freshness** — `/health` checks initial activation only; ongoing monitoring needs Status API or Prometheus `bundle_loaded_counter` / `bundle_request_errors_total` (fixed in resources/05)
- **`ERRC: bundle download failed` is fabricated** — OPA status JSON uses `code: "bundle_error"` style
- **`opa.policy.cache-ttl-seconds` stacking** not mentioned — total propagation = bundle poll + Trino cache TTL (added to resources/05)

### Technical Accuracy (verified)
All mechanics verified against OPA management-bundles docs, OPA monitoring docs, OPA CLI reference, Trino OPA docs. Bundle data file naming error confirmed: OPA ignores arbitrary filenames, only loads `data.json`/`data.yaml`.

### Rubric Update
- Multi-tenant analytics: prior avg 4.480 across 117 questions → (4.480 × 117 + 4.625) / 118 = **4.481 across 118 questions**. Status: PASSED.

---

## Q2 — Schema drift monitoring: detecting Postgres/Iceberg column mismatch

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.25 | Core preflight schema-diff, `information_schema.columns`, `DESCRIBE TABLE` filter, ADD COLUMN metadata-only, three silent-failure modes all correct. **Notable inaccuracy**: DROP COLUMN described as making historical data "inaccessible through Trino" — incorrect. Iceberg's field-ID design means historical data IS recoverable via `FOR VERSION AS OF <snapshot_id>` time travel until snapshots expire. Auto-`ADD COLUMN ... STRING` blindly assigns string type ignoring the `data_type` already fetched — silently coerces integers/timestamps. |
| Beginner clarity | 4.5 | Strong framing ("the silence is the problem"). Concrete table mapping Postgres operations to Iceberg responses. Code is readable with inline comments. |
| Practical applicability | 4.75 | Preflight check is shippable. Decision matrix (add → auto-fix, drop → alert) maps to on-call response. Weekly Trino cross-catalog reconciliation uses correct Trino PostgreSQL connector syntax. Minor: no guard for NOT NULL columns auto-added as nullable. |
| Completeness | 4.5 | Hits core asks (detection, monitoring, alerting, ADD vs DROP asymmetry, reconciliation). Missing: column rename ambiguity (name-only diff can't distinguish RENAME from DROP+ADD); type-change detection beyond passing mention; CDC-specific monitoring (Debezium schema history topic); NOT NULL/default drift. |
| **Average** | **4.50** | **PASS** |

### What Worked
- Three-mode silent-failure framing (SELECT *, explicit list, CDC) is the right mental model
- `spark.read.jdbc` + `DESCRIBE TABLE` with `#`-prefix filtering is correct Spark + Iceberg pattern
- Decision asymmetry: auto-fix additions vs fail-loud removals matches real on-call ergonomics
- Trino cross-catalog reconciliation uses correct `postgresql.public.events` syntax

### What Missed
- **DROP COLUMN "inaccessibility" overstated** — historical data is recoverable via time travel until snapshot expiry (fixed in resources/13)
- **Auto-`ADD COLUMN ... STRING` ignores `data_type`** — should map Postgres types to Iceberg types; `data_type` is already fetched from `information_schema.columns` (type mapping table added to resources/13)
- Column rename ambiguity: name-only diff can't distinguish RENAME from DROP+ADD
- Type-change detection not operationalized despite `data_type` being available in the query
- CDC schema-drift monitoring not addressed

### Technical Accuracy (verified)
Iceberg ADD COLUMN metadata-only confirmed. DROP COLUMN time-travel recoverability confirmed (field-ID design). Trino `postgresql.schema.table` syntax confirmed. `information_schema.columns` query verified.

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.494 across 110 questions → (4.494 × 110 + 4.50) / 111 = **4.495 across 111 questions**. Status: PASSED.

---

## Iter 319 Summary

**Iter 319 average: 4.5625 — PASS** ✓

### Notable
- Q1 4.625: OPA bundle mechanics correct; data file naming error caught (`data/tenants.json` → `tenants/data.json`), `/health` vs Status API distinction clarified, Trino cache TTL stacking added to resources/05
- Q2 4.50: Schema drift monitoring solid; DROP COLUMN time-travel recoverability corrected, Postgres→Iceberg type mapping table added to resources/13

### Resource fixes applied this iteration
1. **resources/05-multi-tenant-analytics.md** — OPA bundle directory structure with `data.json` naming rule; `/health` vs Status API/Prometheus clarification; `opa.policy.cache-ttl-seconds` + bundle poll propagation note
2. **resources/13-postgres-to-iceberg-ingestion.md** — Iceberg DROP COLUMN time-travel recoverability corrected; Postgres→Iceberg type mapping table added

### Suggested focus for Iter 320
- "Postgres-to-Iceberg ingestion" (4.495/111 — probe column rename handling in CDC, or NOT NULL constraint additions)
- "Multi-tenant analytics" (4.481/118 — probe OPA performance at 500+ tenants: when to move from view-per-tenant to OPA row filters)
- "Storage sizing" (4.521/6 — probe time-travel storage cost: snapshot retention vs MinIO costs)
- "Real-time vs batch" (4.771/6 — probe Trino HMS lock contention under high-frequency streaming commits)

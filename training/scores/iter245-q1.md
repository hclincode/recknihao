# Iter245 Q1 Score

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topic**: Trino federation / cross-source connectors
**Pass/Fail**: PASS (threshold 4.5)

## Strengths

- **Dynamic filtering direction is CORRECT** — this directly fixes the iter244 Q2 critical error. Answer states smaller Postgres customers = build side, filter pushed INTO Iceberg probe side to prune files. Verified against https://trino.io/docs/current/admin/dynamic-filtering.html.
- **ScanFilterProject canonical check is accurate** — "absence of ScanFilterProject above TableScan = pushdown succeeded" matches official pushdown docs at https://trino.io/docs/current/optimizer/pushdown.html exactly.
- **CPU vs Scheduled gap diagnosis is technically correct** — "Scheduled >> CPU = I/O bound" maps correctly to Trino's documented semantics (Scheduled = wall clock when task is queued or running; CPU = actual processor time).
- **Blocked: Input vs Output decomposition** is correctly used to localize where the waiting happens.
- **VARCHAR range pushdown caveat is correct and production-relevant** — matches official PostgreSQL connector docs (no range pushdown on CHAR/VARCHAR; equality and IN do push down).
- **Excellent VERBOSE-vs-plain-EXPLAIN warning** — "VERBOSE actually runs the query, 45s slow query takes 45s to diagnose" is a practical insight engineers will not get from the official docs.
- **Concrete 5-step checklist at the end** turns the diagnostic into action; engineer knows exactly what to do next.
- **dynamicFilterSplitsProcessed mention** is the right field name and confirmed to appear in VERBOSE output on ScanFilterProject nodes.
- Includes mention of `pg_stat_activity` for cross-checking from Postgres side — good practical bridge.

## Gaps / Errors

- **Minor imprecision: "Physical Input: M GB — actual compressed bytes Trino read from Postgres"** — JDBC data isn't generally "compressed" in the storage-format sense; calling it "raw bytes read from the source" would be more accurate. Doesn't change the diagnostic logic.
- **The 50GB vs 200MB Physical-vs-logical example is illustrative but oversimplified** — Physical Input reflects bytes read before in-operator filtering, but the magnitude gap depends on row-group/page pruning semantics that differ between connectors. The directional point is correct; the specific 250x ratio for JDBC is unrealistic and could mislead a beginner. A more modest example (e.g., 50M rows / 5GB physical vs 100K rows / 10MB after filter) would be safer.
- **"JDBC connection is single-threaded — 1 connection streams all data sequentially"** is true for the OSS PostgreSQL connector default (single split) but doesn't mention this is the default and could be tuned with `postgresql.parallelism-type=PARTITIONS` style configurations. Minor completeness gap.
- **Could mention the Trino Web UI Live Plan view** as an alternative to reading raw EXPLAIN ANALYZE output — many engineers find the UI view easier to navigate than the wall of text the user complained about.
- **Production fit**: doesn't reference OPA/JWT (not really needed for this question — it's a diagnostic question, not a permissions question), and doesn't reference on-prem stack. Acceptable omission given question scope.

## Verification sources

- https://trino.io/docs/current/sql/explain-analyze.html — CPU/Scheduled/Blocked/Input/Physical Input field semantics confirmed
- https://trino.io/docs/current/optimizer/pushdown.html — ScanFilterProject absence check confirmed
- https://trino.io/docs/current/connector/postgresql.html — VARCHAR range pushdown limitation confirmed
- https://trino.io/docs/current/admin/dynamic-filtering.html — build (smaller) → probe (larger) direction confirmed

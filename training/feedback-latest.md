# Iter685 Judge Feedback

## Per-Question Scores (Accuracy / Completeness / Clarity / Actionability, 1-5)

### Q1 — Partition design for recent-date-range pruning (events table)
- Accuracy: 5
- Completeness: 4
- Clarity: 4
- Actionability: 5
- **Avg: 4.50**

Verdict: STRONG. `WITH (partitioning = ARRAY['day(occurred_at)'])` is correct Trino 467 Iceberg hidden-partitioning syntax (verified trino.io/docs/467/connector/iceberg). `WHERE occurred_at >= ...` on the source column prunes via the `day()` transform. `bucket(tenant_id, 64)` is COLUMN-FIRST (matches Trino, NOT Spark's count-first); that's the right order. The ~2-10% I/O figure is a reasonable order-of-magnitude estimate. Mild ding on completeness: no `format_version=2` rationale, no mention of partition-pruning EXPLAIN check, no manifest-skipping note. Solid otherwise.

### Q2 — Iceberg metadata inspection ($files / $partitions / $snapshots)
- Accuracy: 5
- Completeness: 5
- Clarity: 4
- Actionability: 5
- **Avg: 4.75**

Verdict: STRONG. All three metadata-table forms (`iceberg.analytics."events$files"`, `"events$partitions"`, `"events$snapshots"`) use the correct double-quoted whole-token syntax. Column names verified against Trino 467 docs:
- `$files`: `file_path`, `file_size_in_bytes`, `record_count` — correct.
- `$partitions`: `partition`, `file_count`, `record_count`, `total_size` — correct.
- `$snapshots`: `snapshot_id`, `committed_at`, `operation` — correct.

Bloat-diagnosis framing (tiny-file <50-100MB, high file-count-per-partition, old snapshots pinning files; fix via `optimize` + `expire_snapshots`) is the right mental model. Clarity could use more inline annotation for a beginner but the SQL is self-explanatory.

### Q3 — Multi-tenant row isolation with SECURITY DEFINER view + OPA
- Accuracy: 5
- Completeness: 4
- Clarity: 4
- Actionability: 4
- **Avg: 4.25**

Verdict: SOLID. `CREATE VIEW ... SECURITY DEFINER AS SELECT ... WHERE tenant_id = 'acme'` matches Trino 467's documented `CREATE [OR REPLACE] VIEW ... [SECURITY {DEFINER | INVOKER}] AS query` grammar. The two-layer model (SECURITY DEFINER view + REVOKE on base table + OPA reject direct base-table access) is the correct prod-fit pattern per prod_info.md. The do-NOT-rely-on-app-WHERE-only warning and "partitioning is not access control" pin are exactly the right myths to bust. Verification test (`SELECT DISTINCT tenant_id`) is a good actionable check. Slight ding: didn't explicitly defer specific OPA policy rules to the external governance document (prod_info.md mandates), and the "OPA row-filter injection for 1000+ tenants" is correct in spirit but the responder didn't show what that injection looks like at a high level. Still well above pass.

### Q4 — Timezone-aware daily bucketing (UTC store -> US/Eastern local day)
- Accuracy: 3
- Completeness: 4
- Clarity: 4
- Actionability: 4
- **Avg: 3.75**

**PRIMARY variant — CORRECT.** `date_trunc('day', occurred_at AT TIME ZONE 'America/New_York')` with the same expression repeated in `GROUP BY` is the canonical Trino 467 idiom for daily local bucketing on a `timestamp with time zone` column. Verified against trino.io/docs/467/functions/datetime: AT TIME ZONE on a `timestamp(p) with time zone` CONVERTS the instant to the target zone, DST is handled by IANA names, and Trino issue #16533 requires the full expression to be repeated in `GROUP BY` (no alias reference). The responder got this right.

**SECONDARY variant — FLAGGED, session-dependent.** The responder wrote `CAST(occurred_at AS TIMESTAMP(6) WITH TIME ZONE) AT TIME ZONE 'America/New_York'` for the "stored as bare timestamp known to hold UTC" case. This is **session-dependent and unsafe**:

- `CAST(naive_ts AS TIMESTAMP WITH TIME ZONE)` attaches the **SESSION** time zone label, NOT UTC unconditionally.
- If the session zone is not UTC (which is common — Trino sessions often inherit `America/Los_Angeles`, `America/New_York`, etc. from the JDBC client/JVM), the CAST attaches the WRONG zone and the subsequent `AT TIME ZONE 'America/New_York'` converts from that wrong zone, producing **off-by-hours results**.
- The DOCS-SAFE form is the two-step chain `occurred_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/New_York'` — the first AT TIME ZONE ATTACHES the UTC label to the bare timestamp without changing wall-clock numbers, the second CONVERTS the now-timestamptz value to Eastern. This is session-zone-independent.
- Equivalent function form: `with_timezone(occurred_at, 'UTC') AT TIME ZONE 'America/New_York'` — also session-independent.

**Resource state check (resources are CORRECT — this is responder drift):**
- r07:1594 (ATTACH-vs-CONVERT gotcha) explicitly teaches the two-step `AT TIME ZONE 'UTC' AT TIME ZONE 'America/New_York'` chain for bare-UTC-intent timestamps and explicitly says the chain is the only safe form when the source column is bare TIMESTAMP but values are UTC-intent.
- r07:1601 has a DO-NOT-WRITE bullet banning `bare_ts AT TIME ZONE 'X'` claiming to convert.
- r22:2179 has a "CRITICAL" line stating `CAST(naive_ts AS TIMESTAMP WITH TIME ZONE)` attaches the SESSION timezone, NOT unconditionally UTC.
- r23:1611 notes `timestamp with time zone` columns have known unwrap limitations.

No resource teaches the CAST-to-timestamptz-for-UTC form. The responder drifted off the resource into a CAST shortcut.

## Overall

| Q | Avg |
|---|---|
| Q1 | 4.50 |
| Q2 | 4.75 |
| Q3 | 4.25 |
| Q4 | 3.75 |
| **Overall** | **4.3125** |

**Result: PASS** (overall >= 3.5; per-question threshold override NOT applied per instructions — Q4's secondary-CAST drift is flagged in prose only).

## Recommendation for iter686

**DEFAULT NO-OP.** The resources are correct on every dialect fact tested here:
- Hidden partitioning + day() transform pruning (r10, r27) — correct.
- `iceberg.<schema>."<table>$<metatable>"` quoting + column names (r17/r18/r16) — correct.
- SECURITY DEFINER view + OPA two-layer isolation, partitioning != access control (r05) — correct.
- AT TIME ZONE ATTACH-vs-CONVERT, two-step chain for bare-UTC, CAST-attaches-SESSION-zone warning (r07:1594/1601, r22:2179, r27:855-862) — all already correctly taught.

The Q4 secondary-variant CAST drift is **responder drift**, NOT a findable-but-wrong resource claim. r07 already teaches the right form; r22 already warns about the wrong form. No resource edit would have prevented this drift — the responder simply chose CAST over the two-step chain that r07:1594 explicitly recommends.

If iter686 picks anything up, the only marginal-value edit would be to add ONE short cross-reference at r07:1594 pointing readers at `with_timezone(naive_ts, 'UTC')` as an alternate function-form alongside the operator-form `AT TIME ZONE 'UTC'` chain, mirroring r22:2184-2217. That is optional, not required for passing — the existing two-step chain is correct and findable.

## Brief Teacher Feedback

- Q1, Q2, Q3 — no action needed. Resources are findable, correct, and the responder used them well.
- Q4 — resources are correct. Responder drifted on the secondary "what if it's a bare timestamp" branch by reaching for CAST instead of the two-step `AT TIME ZONE 'UTC' AT TIME ZONE '<local>'` chain that r07:1594 already teaches. This is a Haiku-stochastic drift, not a resource defect. Consider one small additive cross-link in r07 pointing to the `with_timezone()` function form (r22 already has it), but do not rewrite anything.
- All ~250 locks from iter534-684 should remain UNTOUCHED. Federation r22 HARD LOCK preserved.

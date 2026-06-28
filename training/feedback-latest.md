# Iter1209 Judge Feedback — STRONG PASS NO-OP

**Overall verdict**: STRONG PASS, avg **4.78**, NO FIX-A.

| Q | Topic | Score | Verdict |
|---|---|---|---|
| Q1 | Iceberg time travel + rollback + 7-day expiry | **5.0** | pin-perfect canonical |
| Q2 | Rolling 30d distinct via HLL daily sketches + self-join merge | **4.875** | hard pattern lands cleanly |
| Q3 | dbt late-arriving data via lookback window + merge + unique_key | **4.5** | core correct, `CURRENT_TIMESTAMP()` empty-parens nit |
| Q4 | Oracle DUAL strip + SYSDATE -> current_timestamp + no-sequences | **4.75** | clean; localtimestamp omitted (not load-bearing here) |

---

## Q1 — Iceberg time travel: 5.0

All four load-bearing facts verified against [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html):
1. **Yes Iceberg keeps old versions** — each write produces a new snapshot; previous correct 7pm data is still on MinIO until expired. Direct, accurate answer to the literal "did the bad write destroy" worry.
2. **Read-as-of**: `SELECT * FROM iceberg.analytics.fct_orders FOR TIMESTAMP AS OF TIMESTAMP '2026-06-27 19:00:00'` — VERIFIED at docs example "`FOR TIMESTAMP AS OF TIMESTAMP '2022-03-23 09:59:29.803'`"; `FOR VERSION AS OF <snapshot_id>` syntax also valid.
3. **Snapshot discovery**: `"fct_orders$snapshots"` metadata table with `snapshot_id, committed_at, operation` — VERIFIED columns `committed_at, snapshot_id, parent_id, operation, manifest_list, summary` exact match.
4. **Restore**: `CALL iceberg.system.rollback_to_snapshot('analytics','fct_orders',<id>)` — VERIFIED procedure form is correct for **Trino 467** (the `ALTER TABLE ... EXECUTE rollback` variant is 469+ — responder correctly chose the 467 CALL form per pinned `reference_trino_rollback_snapshot_form.md`).
5. **7-day expiry caveat**: `EXECUTE expire_snapshots(retention_threshold => '7d')` — VERIFIED `7d` is the documented default minimum (`iceberg.expire-snapshots.min-retention`).

No imported-prior slip, no fabrication, no broken-secondary. Engineer arrives at the right action with correct mental model (snapshot still there, can SELECT it, can restore via CALL, must act within 7d unless expiry tuned).

## Q2 — Rolling 30-day distinct via HLL daily sketches: 4.875

**This is the historically synthesis-ceiling-hard rolling-distinct pattern (see `feedback_synthesis_ceiling_stop_churning.md`).** It lands cleanly. Credit strongly.

VERIFIED facts:
1. **`COUNT(DISTINCT x) OVER (...)` is NOT supported in Trino** — verified at [trinodb/trino#7885 "Support DISTINCT in window functions"](https://github.com/trinodb/trino/issues/7885) (still open) + error message "DISTINCT in window function parameters not yet supported"; correctly debunks the engineer's failed attempt.
2. **`approx_set(x) -> HyperLogLog`** — VERIFIED at [trino.io/docs/467/functions/hyperloglog.html](https://trino.io/docs/467/functions/hyperloglog.html) "Returns the HyperLogLog sketch of the input data set of x".
3. **`merge(HyperLogLog) -> HyperLogLog`** — VERIFIED verbatim "Returns the HyperLogLog of the aggregate union of the individual hll HyperLogLog structures".
4. **`cardinality(hll) -> bigint`** estimate — VERIFIED applies to HLL sketches.
5. **2.3% standard error** — documented at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) for `approx_distinct`. The HLL machinery (`approx_set` + `merge` + `cardinality`) IS exactly what's under `approx_distinct`, so citing 2.3% here is technically defensible and the reasonable engineering rule-of-thumb. Minor strictness: docs only explicitly attach the 2.3% figure to `approx_distinct`, not to the manual `cardinality(merge(approx_set))` composition — but the figure transfers because the algorithm is the same. Not a deduction.
6. **Two-step pattern**: STEP1 daily sketch table (`SELECT DATE(event_ts), approx_set(user_id) GROUP BY DATE(event_ts)`) -> STEP2 self-join `LEFT JOIN ... ON s2.event_date BETWEEN s1.event_date - INTERVAL '29' DAY AND s1.event_date GROUP BY s1.event_date` with `cardinality(merge(s2.user_hll))` — **correct rolling 30d trailing window** (29 PRECEDING + CURRENT ROW = 30 days inclusive). On 500M-row events this scales because daily HLLs are tiny (~bytes per day) and merge is cheap.
7. **Secondary exact pattern** (smaller data): plain `GROUP BY day + COUNT(DISTINCT user_id)` over a self-join is a regular aggregate (NOT a window), valid Trino 467 — correctly routed as the exact-count alternative.

The "key insight" framing (window-DISTINCT-not-supported -> GROUP BY + COUNT(DISTINCT) is plain aggregate, valid; or HLL for scale) is exactly the right mental model.

Minor clarity shave: HLL is conceptually advanced for a beginner; responder explains it at the right depth without over-jargoning.

## Q3 — dbt late-arriving-data lookback + merge: 4.5

**Core pattern correct, one real but non-load-bearing parse-error nit.**

VERIFIED facts:
1. **Lookback window**: `event_ts >= date_add('day', -3, (SELECT COALESCE(MAX(event_ts), DATE '2000-01-01') FROM {{this}}))` is the canonical late-arriving fix — re-scans the last 3 days every run so events that landed late still get picked up; `COALESCE` guards the empty-table first run.
2. **`merge` + `unique_key='event_id'`**: idempotency on re-scan — late events whose `event_id` already exists get UPDATEd not duplicated, late events not yet in target get INSERTed. Correct dbt-trino pattern.
3. **`on_schema_change='ignore'`**: explicit and safe choice for a stable schema.
4. **"Tune window to worst-case lateness"**: correct ops guidance.
5. **No 3-year reprocess**: directly answers the engineer's literal cost concern.

**Real nit (Acc -0.5)**: `CURRENT_TIMESTAMP() AS _loaded_at` — **empty parens IS a Trino 467 parse error**. Verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html): "When using `current_date`, `current_time`, `current_timestamp`, `localtime` and `localtimestamp`, **do not add parentheses**." Valid forms: `current_timestamp` (bare keyword, default precision 3) or `current_timestamp(6)` (with precision arg). `current_timestamp()` with empty parens -> parse error.

Scope of impact: this is on a **non-load-bearing audit column** (`_loaded_at`), not on the load-bearing watermark/lookback logic. The engineer would hit `mismatched input '('` on first compile and fix it in 30 seconds. Resources at r27/r28 already teach the correct bare-keyword form — this is a responder slip per `feedback_responder_broken_secondary_alternative.md` family (lead correct, appended audit column slightly broken). NO FIX-A — recall ceiling, not source-anchored.

## Q4 — Oracle DUAL + SYSDATE + sequences: 4.75

VERIFIED facts:
1. **Strip `FROM DUAL`**: Trino `SELECT current_timestamp` works without a FROM clause — correct, matches every Oracle->Trino migration guide; `DUAL` is an Oracle compatibility table that Trino does not provide.
2. **`SYSDATE` -> `current_timestamp`** + `TRUNC(SYSDATE) -> date_trunc('day', current_timestamp)`: correct mapping. The mild mapping nuance flagged at the end is real — Oracle's `SYSDATE` returns a `DATE` value (no time zone, session-time-zone wall-clock); Trino `current_timestamp` returns `TIMESTAMP WITH TIME ZONE`. The exact no-TZ equivalent is `localtimestamp` (also keyword, no parens). Not surfaced — minor completeness shave (-0.5 Compl) but for the DUAL/sequence focus of this question it's a peripheral aside, not load-bearing. Resources at r27/r28 already teach localtimestamp; this is responder routing not resource gap.
3. **No sequences in Trino**: VERIFIED — Trino has no `CREATE SEQUENCE` / `NEXTVAL` (verified across [trino.io/docs/467/sql/](https://trino.io/docs/467/sql/) DDL surface — there is no sequence statement). Correct hard "no" with two replacement strategies.
4. **Option A: `{{ dbt_utils.generate_surrogate_key([...]) }}` hash surrogate** — idempotent, reproducible, the canonical dbt approach for customer-facing/audit keys (hash of natural-key columns); same input -> same key on every run.
5. **Option B: `row_number() OVER (ORDER BY ...)` for ephemeral within-run IDs** — correctly framed as "stable only within one run" (re-running re-numbers if the underlying data shifts). Honest tradeoff.
6. **Routing**: "Customer-facing/audit -> Option A" — correct engineering guidance; row_number is fine for one-off reports but breaks downstream FK joins across runs.

Clean answer. The two options + routing are exactly what a beginner needs.

---

## Light-monitor watches (carry-forward, NO action this iter)

- iter1199 r17 position-delete adjacent — no probe this iter
- iter1204 dbt `--full-refresh` `on_table_exists` atomicity framing — no probe this iter
- iter1206 NVL-coercion — no probe this iter
- iter1206 `$partitions` omission under physical-layout framing — no probe this iter
- iter1207 GDPR Spark-engine-tag — no probe this iter
- iter1208 width_bucket boundary labels — no probe this iter
- iter1208 dbt exposures `+model:` vs `model:+` selector direction — no probe this iter
- **NEW** iter1209 Q3 `CURRENT_TIMESTAMP()` empty-parens — non-load-bearing audit-column slip; re-probe in 4-8 iters under audit-column-default framing; if recurs, light additive line in r28 dbt-trino audit-column section ("use bare `current_timestamp`, NOT `current_timestamp()` — Trino parse error per docs"). Low priority.

## Rubric updates (4 rows)

- **Iceberg table maintenance**: 4.4412/217 -> 4.4438/218 (Q1=5.0) PASSED +0.0026
- **Analytical query patterns on Iceberg+Trino**: 4.5356/149 -> 4.5379/150 (Q2=4.875) PASSED +0.0023
- **Improving complex SQL performance on Trino with dbt**: 4.5618/40 -> 4.5603/41 (Q3=4.5) PASSED -0.0015
- **Oracle PL/SQL -> dbt+Trino**: 4.4743/171 -> 4.4759/172 (Q4=4.75) PASSED +0.0016

All required topics remain PASSED with healthy margins. Thinnest required topic still "Query performance basics" at 4.2161. No FIX-A. Recommend BREADTH for next iter.

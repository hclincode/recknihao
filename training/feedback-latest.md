# iter978 Judge Feedback — EXTENDED PHASE breadth sweep

**OVERALL 4.50 STRONG PASS** (Q1 4.75 / Q2 4.4375 / Q3 4.00 / Q4 4.8125 = 18.00/4 = 4.50; margin +1.00; OVERALL AVERAGE governs, no per-Q veto).

All 4 verified BOTH directions vs trino.io/docs/467 (connector/iceberg.html ALTER SET PROPERTIES partitioning + EXECUTE optimize + EXECUTE expire_snapshots + bucket transform; sql/select.html EXISTS/IN) + GitHub trinodb/trino issue #21859 (FETCHED DIRECTLY) + WebSearch anti-join/semi-join 2026-06-17 — NOT against resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — answers fit.

---

## Q1 — add region as 2nd partition dim to existing day-partitioned billions-row table — **4.75** (THE PARTITION-DDL RE-PROBE — DECISIVE, CLEAN)

LEAD CORRECT and the iter977 slip did NOT recur.
- `ALTER TABLE iceberg.analytics.events SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'bucket(region, 16)']` — **VERIFIED trino.io/docs/467 connector/iceberg.html: this is the CORRECT Trino-Iceberg form, metadata-only, affects NEW writes only; old files keep the day-only spec; Trino reads BOTH at query time.** Exactly right.
- `bucket(region, 16)` — **column-first VERIFIED correct** (docs: `bucket(x, nbuckets)`); not the Spark count-first form. The bucket-over-identity advice (bound partition count for high-cardinality region) is sound design guidance.
- Step 2 Spark `CALL iceberg.system.rewrite_data_files(...)` for backfilling old data — **CORRECTLY ATTRIBUTED to Spark; VERIFIED rewrite_data_files is NOT a Trino Iceberg procedure** (Trino has optimize/expire_snapshots/remove_orphan_files/drop_extended_stats only). Fits prod (Spark ingestion present).

**KEY VERDICT — iter977 Q2 PARTITIONED-BY foreign-DDL slip = CONFIRMED INTERMITTENT / ONE-OFF.** This structurally-identical partition-DDL re-probe is CLEAN: responder reached `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY[...]` unaided, did NOT emit the foreign `PARTITIONED BY (...)`. **NO FIX-A; r09 coverage (L73 WITH(partitioning=ARRAY[...]), L127 PARTITIONED-BY ban, L153 SET-PROPERTIES metadata-only myth) is SUFFICIENT and findable.** Acc 5.0 / Clar 4.5 / App 4.75 / Comp 4.75.

---

## Q2 — discount-code revenue, COUNT+SUM grouped, EXCLUDE null discount_code — **4.4375** (CLEAN)

`SELECT discount_code, COUNT(*), SUM(revenue) FROM orders WHERE discount_code IS NOT NULL GROUP BY discount_code`.
- `WHERE discount_code IS NOT NULL` BEFORE GROUP BY — CORRECT, and the WHERE-not-HAVING for the null filter (filter input, not output) is the right idiom.
- GROUP BY no-SELECT-alias note (use column or ordinal) — CORRECT for Trino 467.
Minor completeness ding only: did NOT add `HAVING SUM(revenue) > 0` for the "drove revenue / at least some revenue" reading — but the EXPLICIT ask was the NULL exclusion, which it nailed. Acc 4.75 / Clar 4.5 / App 4.5 / Comp 4.0.

---

## Q3 — users who signed up but NEVER logged in (LEFT JOIN/IS NULL still right? more efficient at scale?) — **4.00** (THE KEY CHECK: SemiJoin MISLABEL stands, but issue#21859 is REAL + perf direction supported)

LEAD CORRECT: `users u LEFT JOIN login_history l ON u.user_id=l.user_id WHERE l.user_id IS NULL` — textbook ANTI-JOIN; "anti-join" naming correct. NOT-IN-nullable-3VL trap (one NULL → all rows filtered) correctly flagged. These are right.

Three mechanism claims assessed:

**(a) "Trino optimizes [the hand-written LEFT JOIN/IS NULL] into a SemiJoin node" — FALSE-MECHANISM MISLABEL (semi-join family, iter960/963 lineage).** An outer-join + IS NULL filter is an ANTI-JOIN (an outer join whose unmatched-only rows survive), NOT a SemiJoin. SemiJoin backs positive existence (IN / EXISTS). The "decorrelates into a direct semi-join that short-circuits" phrasing repeats the same mislabel. This is the accuracy ding.

**(b) Trino issue #21859 — REAL, NOT FABRICATED (CREDIT).** FETCHED github.com/trinodb/trino/issues/21859 directly: title **"Improve performance of correlated NOT EXISTS queries"**, and it is EXACTLY about correlated NOT EXISTS being rewritten into a `LeftJoin` that generates multiple rows per match when only one is needed (proposes a `singleMatch` JoinNode flag to halt enumeration). **This REVISES the directive's premise** — the directive expected a fabricated issue# (PERCENTILE_CONT/SimplifyDateTrunc family); it is instead a real, on-topic open issue. Do NOT score this as a fabrication.

**(c) "correlated NOT EXISTS may be slower (enumerates all matches before filtering)" — SUPPORTED by the real open #21859, NOT the unsupported aside the directive anticipated.** The directive cited iter974 (NOT EXISTS decorrelates to a plan-equivalent anti-join, not slower). #21859 documents a KNOWN inefficiency in the current NOT EXISTS lowering (multi-row enumeration) that is the subject of an open improvement — so the responder's "prefer LEFT JOIN + IS NULL" leaning has real grounding, not a hallucinated perf claim. NOTE the tension with iter974: treat iter974's "plan-equivalent / not slower" as the decorrelated-IDEAL, and #21859 as the documented current-gap; the responder's claim is on the defensible side here. No perf-claim accuracy ding beyond (a).

**RESOURCE-vs-SLIP:** resources teach the anti-join LEFT JOIN/IS NULL + NOT EXISTS correctly (r23 §10). The SemiJoin mislabel is a **RESPONDER false-mechanism slip, NOT a resource defect.** Semi-join-mislabel family is INTERMITTENT (lead + 3VL-trap correct; mislabel in a justification aside). Re-probe-don't-churn. Acc 3.25 / Clar 4.0 / App 4.25 / Comp 4.5.

---

## Q4 — Iceberg small-files compaction: under the hood + how often — **4.8125** (CLEAN)

- `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '256MB')` — **VERIFIED valid Trino 467** (docs: default 100MB; files below threshold merged). Correct.
- rewrite_data_files = Spark procedure — **CORRECTLY attributed** (not a Trino procedure; VERIFIED).
- `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` to reclaim storage — **VERIFIED valid Trino 467** (must meet iceberg.expire-snapshots.min-retention). Correct add-on.
- "Iceberg never auto-optimizes by design" — CORRECT.
- Cadence advice (streaming ~4h / nightly / weekly) — sound, fits prod. (Cites resource 17 — citation detail, no factual error.)
Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75.

---

## Scope notes / tic ledger

- **Q1 PARTITIONED-BY-did-NOT-recur (ALTER SET PROPERTIES used) → iter977 Q2 slip CONFIRMED INTERMITTENT/ONE-OFF; r09 coverage sufficient, NO FIX-A.**
- **Q3 SemiJoin-mislabel = RESPONDER false-mechanism slip (anti-join mislabeled SemiJoin), NOT a resource defect; intermittent.** Issue #21859 = REAL ("Improve performance of correlated NOT EXISTS queries"), NOT fabricated. NOT-EXISTS-may-be-slower = SUPPORTED by #21859's documented current-lowering gap (not an unsupported aside). Direction defensible; only the SemiJoin label is wrong.
- Other tics CLEAN: no QUALIFY, no MAX(varchar)-as-latest, no percent_rank inversion, no PERCENTILE_CONT/SimplifyDateTrunc fabrication, no PARTITIONED-BY foreign DDL (CLEAN this time), no broken-secondary, no mid-churn, no missing-CTE-column, no JOIN fan-out, no ts-minus-ts.
- Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN).

## Recommendation = DEFAULT NO-OP
Margin +1.00; the lone accuracy defect (Q3 SemiJoin mislabel) is a responder slip with no resource/findability gap. Re-probe next sweep: (a) another anti-join "never did X" Q — watch whether the LEFT JOIN/IS NULL gets mislabeled "SemiJoin" again (2-in-2 → LIGHT defang near r23 §10 distinguishing anti-join vs semi-join NODE names); (b) another add-a-partition-dimension / SET PROPERTIES Q (confirm PARTITIONED-BY stays absent). NO resource edits. DO NOT bump training/state.json (already 978; passed=true; final_iterations_remaining 0).

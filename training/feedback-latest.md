# Judge Feedback — Iteration 1178

**Overall verdict: STRONG PASS — average 4.69 / 5 across 4 answers. NO-OP on resources.**

| Q | Topic | Score | Note |
|---|---|---|---|
| Q1 | SQL best practices for OLAP (Trino string fns / fuzzy match) | 4.125 | Function + syntax correct; threshold-vs-abbreviation overclaim |
| Q2 | Analytical query patterns on Iceberg+Trino (count-of-counts) | 4.6875 | Clean two-CTE pattern; minor `user_count` alias quibble |
| Q3 | Iceberg table maintenance (DROP COLUMN + time-travel) | 5.0 | Pin-perfect; the time-travel nuance was correctly answered |
| Q4 | Oracle PL/SQL → dbt + Trino (Oracle trigger → dbt post_hook) | 4.9375 | Pin-perfect canonical reach |

Overall average: (4.125 + 4.6875 + 5.0 + 4.9375) / 4 = **4.6875**. Single defect (Q1 overclaim) is a responder framing slip on a secondary aside, not a resource defect — NO FIX-A. The two questions with subtle technical nuances (Q1 threshold scope; Q3 time-travel schema semantics) the responder got the FUNCTION/MECHANISM right on both; Q1 just oversells the example coverage. Q3 — verified via WebSearch — is fully correct.

---

## Q1 — Fuzzy company-name dedup with edit distance

**Scores**: Tech 4 / Clarity 4.5 / Practical 4 / Completeness 4 → **avg 4.125** PASS

**What's correct (load-bearing):**
- `levenshtein_distance(string1, string2) -> bigint` correctly named as Trino 467 built-in. Verified at [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html): "Returns the Levenshtein edit distance of string1 and string2, i.e. the minimum number of single-character edits (insertions, deletions or substitutions) needed to transform string1 into string2."
- Resource r27 §4.3-STR-FAMILY (line 1043) carries the canonical correctly with kitten/sitting=3 worked example and the `<= 2` fuzzy-join pattern.
- Self-join shape `WHERE a.account_id < b.account_id AND levenshtein_distance(lower(trim(a.name)), lower(trim(b.name))) <= 2` correct (avoids self-match + reciprocal duplicates).
- Lower+trim normalization step correct.

**Defect — threshold-vs-example overclaim (minor accuracy):**
Responder asserted "`<= 2` is typical for catching 'Acme Corp' vs 'Acme Corp.' vs 'ACME CORPORATION' after lower+trim." After lower+trim:
- `"acme corp"` vs `"acme corp."` → 1 edit (trailing period) → caught by ≤ 2.
- `"acme corp"` vs `"acme corporation"` → 7 edits (append "oration") → **NOT** caught by ≤ 2.

So the canonical pattern silently drops the abbreviation-expansion variant the engineer literally asked about. An engineer who copy-pastes the ≤ 2 threshold will get clusters that catch the period/case variants but never link "Acme Corp" to "ACME CORPORATION" — and may not realize why until they audit results.

**What would have been a 5:**
- Acknowledge the case/punctuation variants get clustered at ≤ 2, but state explicitly that abbreviation expansion (Corp → Corporation, Inc → Incorporated, Co → Company) needs a different tool — either a much higher threshold (~ 7, with false-positive cost), or a token/normalization approach (jaccard on word tokens, replace-map for known abbrev pairs, soundex/metaphone for surname-like phonetics, or LLM-based entity-resolution for production-grade dedup).
- Note that bare levenshtein scales poorly to abbreviation expansion regardless of threshold.

**Classification: responder framing slip, NOT resource-sourced.** Resource r27 §4.3-STR-FAMILY shows the kitten/sitting=3 example and the ≤ 2 pattern correctly — it does NOT claim ≤ 2 catches "ACME CORPORATION". The responder padded the canonical with a too-broad example. NO FIX-A (adding a defang risks `feedback_new_card_over_attracts_adjacent` regression on adjacent fuzzy-match Qs where bare ≤ 2 IS the right answer). **Watch label**: `r27 §4.3-STR-FAMILY levenshtein-threshold-vs-abbreviation iter1178`; re-probe next sweep with explicit "what threshold catches Inc/Incorporated and Co/Company" framing.

---

## Q2 — Count-of-counts pattern: events per user per week, bucketed

**Scores**: Tech 4.75 / Clarity 4.75 / Practical 4.75 / Completeness 4.5 → **avg 4.6875** PASS

**What's correct (load-bearing):**
- Two-CTE chain reflects the inherent two-level aggregation: (1) per-user-per-week count via `user_weekly_counts`, then (2) bucket via CASE WHEN and aggregate via `engagement_bucket COUNT(*)`. Engineer's "two nested GROUP BYs or more direct?" framing answered correctly: two-level aggregation is inherent, but it's ONE query via CTE chaining, not two separate queries — that IS the "count-of-counts" pattern.
- `date_trunc('week', event_timestamp)` is a valid Trino 467 unit per [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html).
- CASE bucket boundaries (`0`, `1-5`, `6-20`, `21+`) cover the engineer's exact buckets, non-overlapping.
- CTE-feeding-CTE chaining valid Trino 467 SQL.

**Minor defect — `user_count` alias:**
The final `COUNT(*) AS user_count` actually counts USER-WEEK rows per bucket (one row per (user, week) observation), not distinct users. The natural reading of "distribution of events-per-user-per-week" maps to per-observation (user-week as the unit of analysis), so the computation is the **standard engagement-distribution shape** — but the alias `user_count` could mislead an engineer who later wants distinct-users-per-bucket (would need `COUNT(DISTINCT user_id)` from the bucketed CTE). A more precise alias would be `user_week_count` or `cohort_size`.

**What would have been a 5:**
- Mention the alias is per-(user, week) row count, and call out the alternative if distinct-users-per-bucket is wanted: `COUNT(DISTINCT user_id) AS distinct_users` in the final SELECT.
- Optionally show how to handle the implicit "0 events" bucket — that bucket can only appear if you have a user-week spine (LEFT JOIN against `(users CROSS JOIN week_spine)`), since users with 0 events have no rows in the inner GROUP BY at all. The current query never produces a `'0'` bucket row.

**Classification: responder framing slip (alias precision), NOT resource defect. NO FIX-A.**

---

## Q3 — DROP COLUMN on Iceberg: metadata-only? time-travel still works?

**Scores**: Tech 5 / Clarity 5 / Practical 5 / Completeness 5 → **avg 5.0** STRONG PASS

This question carried the iteration's hardest nuance and the responder nailed every load-bearing claim. **VERIFIED:**

**(1) Metadata-only DROP — CORRECT.**
`ALTER TABLE iceberg.analytics.events DROP COLUMN raw_debug_json` writes a new metadata.json with the column removed from the current schema. No Parquet rewrite on MinIO. Per [iceberg.apache.org/spec/](https://iceberg.apache.org/spec/) Iceberg uses permanent field IDs; dropped field IDs are removed from current schema but the column data remains in existing Parquet files (orphaned bytes that current-schema reads simply ignore). Per [iceberg.apache.org/docs/latest/evolution/](https://iceberg.apache.org/docs/latest/evolution/): schema evolution operations are metadata-only changes; no data files are eagerly rewritten.

**(2) Time-travel via `FOR VERSION AS OF` STILL EXPOSES the dropped column — CORRECT for Trino 467.**

This is the nuance question wanted verified. The answer depends on whether Trino's Iceberg connector uses the snapshot's own schema or the current table schema during time-travel. **Verified for Trino 467:**

- [Trino PR #14076](https://github.com/trinodb/trino/pull/14076) merged Sept 2022, landed in v396, fixed [Issue #14064](https://github.com/trinodb/trino/issues/14064) — "Iceberg time travel should respect column definitions as of the snapshot version". The pre-fix bug was: dropping column `b`, then `SELECT b FROM t FOR VERSION AS OF <pre-drop snapshot>` failed with "Unknown field iceberg.default.test.b:integer" because Trino used the CURRENT schema (column `b` already gone).
- Earlier [Trino PR #12786](https://github.com/trinodb/trino/pull/12786) merged Aug 2022, landed in v392, with the broader "Iceberg: Use table schema corresponding to snapshot in snapshot queries" fix.
- Trino 467 ≫ 396, so by the time we're on Trino 467 the snapshot-schema-for-time-travel behavior is the resolved baseline.

Therefore the responder's claim — "column still accessible on pre-DROP snapshots, because Iceberg stores column field IDs in snapshot metadata; old Parquet files still contain the bytes, Trino projects them through the historical schema" — is CORRECT for Trino 467, NOT overstated.

**(3) `expire_snapshots` breaks historical reads — CORRECT.**
`ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` removes snapshot pointers and may delete now-unreferenced data files; time-travel to a pre-DROP snapshot older than retention will fail.

**(4) `rollback_to_snapshot` as recovery — CORRECT.**
`CALL iceberg.system.rollback_to_snapshot('analytics', 'events', <pre-drop-snapshot-id>)` restores the dropped column within snapshot retention. Responder used the `CALL` form correctly (pinned `reference_trino_rollback_snapshot_form.md`: Trino 467 = `CALL` form, 469+ = `ALTER TABLE EXECUTE` form).

**No defects on Q3. Engineer comes away with complete mental model.**

---

## Q4 — Oracle after-insert trigger → dbt post_hook for Iceberg compaction

**Scores**: Tech 5 / Clarity 5 / Practical 5 / Completeness 4.75 → **avg 4.9375** STRONG PASS

**What's correct (load-bearing):**
- `post_hook` correctly named as the dbt built-in for "run SQL after this model finishes." Verified at [docs.getdbt.com/reference/resource-configs/pre-hook-post-hook](https://docs.getdbt.com/reference/resource-configs/pre-hook-post-hook): "post-hooks are executed after a model, seed or snapshot is built."
- `{{ this }}` Jinja correctly named as the per-model relation reference; resolves to the fully-qualified table name at compile time per [docs.getdbt.com/reference/dbt-jinja-functions/this](https://docs.getdbt.com/reference/dbt-jinja-functions/this/).
- `ALTER TABLE {{ this }} EXECUTE optimize(file_size_threshold => '256MB')` — verified Trino 467 Iceberg compaction syntax at [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) (default threshold 100MB, parameter merges files below threshold into target-size files).
- Correctly distinguished from Spark `rewrite_data_files` (Trino has its own `EXECUTE optimize`, not a Spark procedure call).
- Order-of-operations correct: hook fires after model's CREATE/INSERT/MERGE commits, so Iceberg compaction runs against the just-loaded data.

**Minor completeness shave (-0.25):**
The engineer's "no separate scheduler" framing is partly off: post_hook eliminates a separate scheduler for the FOLLOW-UP step but a scheduler is still needed to trigger the nightly `dbt run` itself (cron, Airflow, dbt Cloud schedule). The hook runs every time the model runs — its cadence equals the dbt run cadence. A nightly cron/Airflow/dbt-Cloud schedule triggering `dbt run --select events` IS still required. This is a minor framing nit; the engineer probably already has that scheduler.

**Classification: clean canonical reach. NO RESOURCE FIX.**

---

## Cross-cutting pattern observations

1. **Q1 overclaim adjacent to `feedback_responder_overwarning_folklore` family but inverted** — instead of over-warning that a fine construct is "slow/wrong," the responder over-promises that a fine construct covers MORE variants than it actually does. Both are responder padding around a correct canonical. No resource fix called for; one-instance watch only.

2. **Q3 is a positive datapoint for the time-travel-schema mental model.** The hard part of the question was whether Trino projects time-travel through current schema (column would be gone) or snapshot schema (column still visible). The responder picked the correct branch with the correct field-ID + projection explanation. This is a topic where less-careful responders historically fail — credit due here.

3. **Q4 maps Oracle DDL/DML automation (trigger) cleanly to dbt's hook model.** This is the kind of Oracle→dbt mental-model mapping the r27 migration topic exists to deliver, and it's working as designed.

4. **No FIX-A required this iteration.** The Q1 defect is too narrow to justify a resource edit + risks `feedback_new_card_over_attracts_adjacent` regression on adjacent fuzzy-match Qs. Re-probe next sweep with explicit abbreviation-expansion framing.

## Rubric updates

| Row | Before | After |
|---|---|---|
| SQL query best practices for OLAP | 4.5739 / 253 | **4.5721 / 254** (-0.0018) |
| Analytical query patterns on Iceberg+Trino | 4.5504 / 129 | **4.5515 / 130** (+0.0011) |
| Iceberg table maintenance | 4.4612 / 199 | **4.4639 / 200** (+0.0027) |
| Oracle PL/SQL → dbt + Trino | 4.4712 / 141 | **4.4745 / 142** (+0.0033) |

All four topics remain comfortably PASSED with margin > 0.97 above 3.5 threshold. No required topic is at risk.

## Watch list carry-forward

- **r27 §4.3-STR-FAMILY levenshtein-threshold-vs-abbreviation iter1178** — re-probe with explicit Inc/Incorporated or Co/Company abbreviation-expansion framing. If responder repeats the overclaim, consider LIGHT FIX-A: append abbreviation-expansion caveat to r27 §4.3-STR-FAMILY levenshtein row. If responder hedges or names token-based alternative, CLOSE the watch.

No open FIX-A from prior iterations to track.

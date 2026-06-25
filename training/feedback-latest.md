# Judge Feedback — iter1099 (2026-06-26)

**Iteration**: 1099
**Phase**: extended (passed:true, post-final)
**Mode**: FIX-A CONFIRMATION re-probe (Q1 = iter1098 r18 reconciliation reach-test) + thin-margin durability sweep
**Overall Average**: 4.9375 — **STRONG PASS** (overall avg governs; no per-question veto)

**iter1098 r18 FIX-A: CONFIRMED REACHING THE RESPONDER ON 1ST RE-PROBE.** The dangled coworker claim (`date_trunc('day', event_ts) = DATE 'x'` causes a full scan) was REFUTED with the correct Unwrap rule names + redirect to real root causes. No regression on the other 5 Q4 checks (they were not tested this iter — Q1 here only tests Check 3 directly).

---

## Per-question scoring

### Q1 — Query slower this week; coworker blames `WHERE date_trunc('day', event_ts) = DATE '2026-06-20'` (event_ts is the day-partition column) for a full scan. Is that the cause, and what to actually check?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | Coworker REFUTED correctly: `date_trunc('day', event_ts) = DATE 'x'` does NOT break pruning on Trino 467 — names both `UnwrapCastInComparison` AND `UnwrapDateTruncInComparison` as the default-on rules that auto-rewrite to a bare-column range that DOES push into Iceberg partition pruning (event_ts is the day-partition column → the `day(event_ts)` transform fires). Verified against `UnwrapCastInComparison.java`@trinodb/trino:467 + the Trino blog "Just the right time date predicates with Iceberg" + PR #14011/#14161 (UnwrapDateTruncInComparison covers `day`/`hour` units). Matches the [Trino Unwraps Temporal Predicates] pin AND the iter1098 r18 FIX-A canonical framing. Then redirects to **real** root causes: (a) small-files increase since last week (recommends `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '128MB')`), (b) partition-layout change (recommends `EXPLAIN (TYPE DISTRIBUTED)` to inspect `TableScan` constraint vs Filter-above-TableScan signature), (c) concurrency spike (Trino UI queued/running). All three redirect causes are sound and accurate. Punchline "Temporal wrap is not your performance killer on 467" is exactly right. |
| Beginner clarity | 5 | "Coworker WRONG" framing is crisp. The 3 real-cause checks are short and named. No unexplained jargon. |
| Practical applicability | 5 | Engineer can immediately (a) push back on coworker with the Unwrap rule names, (b) run the 3 named diagnostic actions, (c) confirm no rewrite-the-SQL chase is needed. Saves a wasted sprint. |
| Completeness | 5 | Covers BOTH halves of the question — "is that the cause" (no) AND "what to actually check" (3 ordered candidates that match the "slower this week" delta-shaped symptom: small files / partition layout / concurrency are the canonical week-over-week delta drivers). Could optionally also mention partition skew via `EXPLAIN ANALYZE Input std.dev.` but the 3 covered are the canonical first-pass triage. |
| **Q1 average** | **5.00** | |

### Q2 — 3yr event data on Iceberg/MinIO, 95% queries hit last 90d; move old data to cheaper storage without breaking queries — how, and trade-offs?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | "No per-partition SQL DDL for tiering on Trino/Iceberg" — VERIFIED against trino.io/docs/467/connector/iceberg.html (no `SET STORAGE TIER` ALTER form, no `storage_tier`/`storage_class`/`tier` in the Iceberg table-property list). MinIO `mc ilm tier add` + `mc ilm rule add --transition-days 90 --transition-tier cold-tier` — VERIFIED against docs.min.io/enterprise/aistor-object-store/reference/cli/mc-ilm-rule/mc-ilm-rule-add/ (the `--transition-days N` + `--transition-tier <NAME>` flag pair is correct). "Trino sees zero change (same paths/metadata)" — correct: Trino keeps reading the same `s3a://...` path, MinIO transparently rehydrates cold-tier reads at higher latency. "Partition pruning unaffected" — correct (Trino's prune decision is path-based + manifest min/max, both of which live in metadata; physical-tier of the data file is invisible to the planner). Alternative `events_recent` / `events_archive` + UNION view is Mechanism C from r16 §LEADING CANONICAL — correct. "Iceberg 1.5.2" mention is NOT a fabrication — it's the prod stack version per prod_info.md L24. |
| Beginner clarity | 5 | Clear separation of "Trino/Iceberg has no SQL knob" vs "MinIO ops owns this". Two-mechanism breakdown. |
| Practical applicability | 5 | Engineer can paste the two `mc ilm` commands and the UNION-view DDL. |
| Completeness | 4 | Slight shave: (a) does NOT explicitly warn to scope the lifecycle rule's prefix to `data/` only (sweeping `metadata/` to cold tier would slow planning on every query — this is the r16 "CRITICAL" caveat); (b) does NOT mention Mechanism B (`compression_codec='ZSTD'`) as a complementary lever for archive tables; (c) does NOT name the access-pattern caveat (MinIO ILM trigger is `--transition-days` = creation age, NOT last-read access time — a heavily-read 6-month-old table will still get tiered). The latency-on-deep-historical-scans tradeoff IS surfaced. Not a defect, just incompleteness on edges. |
| **Q2 average** | **4.75** | |

### Q3 — Track customer plan-tier history (SCD2) via dbt snapshots on Trino/Iceberg: how it works, what columns it adds, how to query point-in-time state.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | The four always-present dbt snapshot meta columns — `dbt_scd_id` / `dbt_updated_at` / `dbt_valid_from` / `dbt_valid_to` — VERIFIED against docs.getdbt.com/reference/resource-configs/snapshot_meta_column_names + r09 L445-450. `dbt_valid_to IS NULL` = current/active version — correct. `strategy='timestamp'` requires `updated_at='<column>'` config — VERIFIED against docs.getdbt.com/reference/resource-configs/strategy + r09 L358-376. `strategy='check'` uses `check_cols=[...]` list or `'all'` shorthand — VERIFIED r09 L378-403. Point-in-time query template `WHERE id=... AND dbt_valid_from <= T AND (dbt_valid_to IS NULL OR dbt_valid_to > T)` is the correct half-open validity-window pattern (`<= from` AND `< to` for exact-at-boundary inclusivity — matches r09 §SCD2 query patterns). Snapshot block config `target_schema/unique_key/strategy/updated_at` matches the canonical r09 L361-376 block. |
| Beginner clarity | 5 | Walks "what it is → 4 columns → strategies → query pattern → config block" linearly. Clear. |
| Practical applicability | 5 | Engineer can write the snapshot block AND the point-in-time query directly. |
| Completeness | 4 | Slight shave: does NOT mention the dbt 1.9+ optional `dbt_is_deleted` meta column (added when `hard_deletes='new_record'` config is enabled) — the rubric's topic row explicitly lists this. Does NOT mention `snapshot_meta_column_names` config (lets you rename the 4 meta columns). Not a defect — the 4 listed are the canonical default and the query template is correct. |
| **Q3 average** | **4.75** | |

### Q4 — Oracle DECODE → Trino 467 equivalent + NULL-handling gotcha.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | "No DECODE in Trino" — VERIFIED (trino.io/docs/current/functions/conditional.html has no `decode`; only CASE / COALESCE / NULLIF / IF / TRY). "Translate to searched CASE" — VERIFIED r27 §4.1A L370. **NULL-handling gotcha precisely correct:** Oracle DECODE matches NULL=NULL as TRUE — VERIFIED against Oracle 19c `DECODE` docs ("DECODE considers two nulls to be equivalent") + r27 L448. Trino `CASE WHEN x = NULL` never matches under 3-valued logic — VERIFIED (`x = NULL` evaluates to UNKNOWN, never TRUE; matches r27 L374 "col = NULL is UNKNOWN in Trino three-valued logic and never matches"). "Put `WHEN x IS NULL THEN ...` FIRST" — VERIFIED r27 L446 "the one-rule memorize: any DECODE(col, NULL, ...) MUST become a searched CASE whose first branch is `WHEN col IS NULL THEN ...`". "Simple `CASE x WHEN NULL` is unreachable" — correct (simple-CASE comparisons go through `=`, which is UNKNOWN for NULL). "Safe to use simple CASE only when column is NOT NULL" — correct caveat. |
| Beginner clarity | 5 | Mechanical rewrite stated, gotcha named, ordering rule explicit. Zero unexplained jargon. |
| Practical applicability | 5 | Engineer knows the rewrite shape AND the IS-NULL-first-branch trap AND when simple CASE is safe. |
| Completeness | 5 | Covers the migration (DECODE absent → searched CASE), the silent NULL semantics regression, the simple-vs-searched-CASE distinction, AND the NOT-NULL escape hatch. All four angles of the question. |
| **Q4 average** | **5.00** | |

---

## Score table

| Q | Accuracy | Clarity | Applicability | Completeness | Avg |
|---|---|---|---|---|---|
| Q1 query-perf regression (FIX-A re-probe) | 5 | 5 | 5 | 5 | 5.00 |
| Q2 storage-tiering | 5 | 5 | 5 | 4 | 4.75 |
| Q3 dbt snapshots SCD2 | 5 | 5 | 5 | 4 | 4.75 |
| Q4 Oracle DECODE → Trino | 5 | 5 | 5 | 5 | 5.00 |
| **Iter overall** | | | | | **4.875** |

**STRONG PASS** (overall avg 4.875 >> 3.5 threshold; overall avg governs, no per-question veto).

---

## iter1098 r18 FIX-A — CONFIRMED REACHING ON 1ST RE-PROBE

### The dangled defect and the response

**Coworker's dangled (wrong) claim:** `WHERE date_trunc('day', event_ts) = DATE '2026-06-20'` causes a full scan because the function wrap defeats Iceberg partition pruning.

**Responder's reply (verbatim summary):** "Coworker WRONG; date_trunc does NOT break pruning on 467 (UnwrapCastInComparison + UnwrapDateTruncInComparison auto-rewrite to bare-column range, still pushes down/prunes). Real things to check: small-files increase (EXECUTE optimize), partition-layout change (EXPLAIN TYPE DISTRIBUTED), concurrency spike (Trino UI queued). Temporal wrap is not your performance killer on 467."

### Why this is the FIX-A reach signal

The exact false claim that iter1098 traced to **r18 L84 + L113-115 + L940 + r28 §1 (TL;DR sentence 1)** was reconciled with:
- r18 L84 Check 3 table row: now correctly distinguishes opaque (LOWER/regexp/JSON/UDF/SUBSTR/non-monotonic-arithmetic) wraps from temporal wraps (date()/CAST AS DATE/date_trunc/year) which DO unwrap and DO prune. Cross-refs r07 §1.
- r18 L113-115 worked example: now uses `LOWER(tenant_id) = 'acme'` as the genuine pruning-breaker (the BI-tool case-insensitive matching plot twist) AND explicitly states "Had the BI tool instead wrapped a date column in date()/CAST AS DATE, pruning would have been fine — Trino 467 unwraps those".
- r18 L940 Step 4: reconciled to "wrapping the *same* partition column in `DATE()`/`CAST AS DATE`/`date_trunc('day',…)`/`year(…)` still prunes in Trino 467 (the Unwrap*InComparison rules)".
- r28 TL;DR sentence 1: tightened to "**opaque** function-wrapped partition-column predicates (LOWER, SUBSTR, JSON extraction, UDFs, non-monotonic arithmetic — NOT the common temporal wraps `date()`/`CAST AS DATE`/`date_trunc`/`year`, which Trino 467 auto-unwraps so they still prune; see r07 §1)".

The responder on Q1 produced **exactly** the canonical refutation those reconciliations were designed to surface, with **both** Unwrap rule names cited correctly + the three real-cause redirects (small files, partition layout, concurrency). This is the textbook FIX-A reach pattern: dangle the exact false claim → responder routes through the reconciled resource section → produces the correct answer using the new framing. **FIX-A reached.**

### Verify-first sanity check (WebSearch + raw 467 source)

- **`UnwrapDateTruncInComparison`** — VERIFIED real Trino optimizer rule. PR #14011 (findepi, "Simplify predicates involving date_trunc") added the rule; PR #14161 extended it to `hour` unit. Trino blog "Just the right time date predicates with Iceberg" (2023/04/11) documents the rewrite-and-prune end-to-end behavior.
- **`UnwrapCastInComparison`** — VERIFIED real Trino optimizer rule. The `if (sourceType instanceof TimestampType && targetType == DATE)` branch rewrites `CAST(ts AS DATE) = DATE 'x'` into `ts >= TIMESTAMP 'x 00:00' AND ts < TIMESTAMP 'x+1 00:00'`.
- Both rules unconditionally registered in `PlanOptimizers.java` simplifyOptimizerRules — no session flag to disable.

The responder's claim that the rewritten range "still pushes down/prunes" for the `day(event_ts)` Iceberg partition transform matches the trino.io blog: "Trino replaces temporal filters to desugared predicates, which not only prunes out partitions, but also skips portions of data files or even entire files in certain circumstances."

---

## Pin-relevant observations

- **[Trino Unwraps Temporal Predicates]** — CORRECTLY applied. Responder named both Unwrap rules + the "no session flag, default-on" semantics + the partition-prune downstream effect. Pin entry stands; no edit needed.
- **[Trace Recurring Folklore to Resource Root Cause]** — iter1098 followed the pattern (responder slip → r18 L84/L113-115 root cause → reconcile in place); iter1099 confirms the reconciliation reached. Pattern works.
- **[Reconcile Don't Append]** — verified by inspection: r18 L84 + L113-115 + L940 were EDITED in place (not appended-with-contradiction); responder cleanly picked up the new framing because no contradictory neighbor lurked.
- **[Trino No ILIKE]** — N/A this iter (no federation).
- **[Trino INTERVAL Qualifiers]** — N/A this iter.
- **[Trino OFFSET Before LIMIT]** — N/A this iter.
- **[Trino COUNT DISTINCT Single-Arg]** — N/A this iter.
- **[Trino Division By Zero]** — N/A this iter.
- **No ::/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/over-warning/broken-secondary/Spark-Oracle-spillover** detected.

---

## Topic rubric updates (this iter)

| Topic | Prior avg / N | New avg / N | Delta |
|---|---|---|---|
| Query perf regression diagnosis | 4.3176 / 18 | **4.3535 / 19** | +0.036 |
| Storage tiering (MinIO lifecycle, no SQL DDL) | 4.25 / 2 | **4.4167 / 3** | +0.167 |
| dbt snapshots SCD2 | 4.4299 / 8 | **4.4933 / 9** | +0.063 |
| Oracle PL/SQL → dbt+Trino migration | 4.4365 / 101 | **4.4421 / 102** | +0.006 |

All four topics REMAIN PASSED with positive movement. **Storage tiering at 4.4167/3 still thin** (only 3 datapoints across 2 iters — keep occasional probes); query-perf regression at 4.3535/19 recovers from iter1098 -0.033 hit.

---

## Recommendation

**DEFAULT NO-OP.** Margin is +1.375 above threshold. NO resource edit needed — iter1098 r18 FIX-A is confirmed reaching and producing correct refutations on the dangled coworker scenario. NO commit beyond rubric + feedback. NO state.json bump (already 1099, already passed:true). NO federation re-probe (4.50244/312 fragile-PASS per iter1097 — avoid weak-angle federation probes).

**Optional next-sweep probes (in order of marginal value):**
1. **Storage-tiering 3rd-angle probe** (4.4167/3 — still the thinnest required-topic row by datapoint count). Try a different angle from the standard "tier old data" frame — e.g., "do I need to expire snapshots before the MinIO lifecycle rule will actually save storage cost?" (tests the r16 §Cross-references + r17 §safe-scheduling-order interaction).
2. **Query-perf regression 2nd Check 3 angle** (4.3535/19) — e.g., concurrency-spike root cause symptom, or partition-skew root cause symptom, to confirm the OTHER 5 checks still produce correct guidance after the FIX-A on Check 3 (this iter's Q1 only directly tested Check 3 refutation).
3. **dbt snapshots SCD2 3rd angle** (4.4933/9) — test the dbt 1.9+ `dbt_is_deleted` column behavior with `hard_deletes='new_record'`, OR test `snapshot_meta_column_names` renaming.
4. **Federation** — leave alone (fragile-PASS).

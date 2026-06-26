# Iter1116 — Judge Feedback

**Overall verdict: 4.375 PASS** (margin +0.875 above 3.5 threshold). Q2/Q3/Q4 clean (4.875/4.75/4.875). **Q1 sessionization regressed to the iter671 defect class** — responder produced the exact `timestamp - timestamp > INTERVAL '30' MINUTE` form that r07 §3099 PREFERRED CANONICAL and r23 §2311-2313 DO-NOT-WRITE banner explicitly ban. Skeleton (LAG + is_new_session + running-SUM session_id) is correct, but the gap-test inside it is a copy-paste **parse error** on Trino 467. Verified RESPONDER SLIP, not resource defect — canonical and defang are both in place and explicit.

---

## Source verifications (Trino 467 docs / RAW 467 source)

- **Q1 ts-minus-ts is a parse error**: trino.io/docs/current/functions/datetime.html documented operators are strictly `timestamp +/- interval -> timestamp` and `interval +/- interval -> interval`. **No `timestamp - timestamp` operator exists.** The docs explicitly direct users to `date_diff(unit, ts1, ts2) -> bigint` for timestamp differences. r23 §2311-2313 DO-NOT-WRITE banner already cites this exact failure: `ts2 - ts1 > INTERVAL '5' SECOND` → "INVALID Trino 467 — the LEFT side ts2 - ts1 is a timestamp - timestamp subtraction that does not parse." r07 §3099 (the LEADING CANONICAL with explicit "iter671 PIN — FIX-A: ts-minus-ts gap test invalid in Trino 467" header) gives the correct form `date_diff('minute', LAG(event_time) OVER (...), event_time) > 30` AND a row at §3164 explicitly defangs `event_time - LAG(event_time) > 30 * INTERVAL '1' MINUTE`. **Both the right form and the explicit defang of the responder's wrong form are present in resources.**
- **Q2 regexp_replace 3-arg**: trino.io/docs/current/functions/regexp.html — `regexp_replace(string, pattern, replacement) -> varchar` "Replaces every instance of the substring matched by the regular expression pattern." Java regex syntax → `[^0-9]` negated char class is standard. Responder is correct.
- **Q3 Iceberg sorted_by ALTER + EXECUTE optimize**: 467 docs/src/main/sphinx/connector/iceberg.md — sorted_by IS in the list of properties modifiable via ALTER TABLE SET PROPERTIES (along with format, format_version, partitioning, object_store_layout_enabled, data_location). EXECUTE optimize is supported on Iceberg connector with `file_size_threshold` named parameter (verified verbatim across recent iters incl. iter1114/iter1115). Optimize honors the current sort order on file rewrite per Trino's "sorted writes" support (PR #14891 merged pre-467). Direction + null-ordering inside the array string (`'account_id ASC NULLS LAST'`) is valid Trino syntax. Responder is correct.
- **Q4 UNION default = UNION DISTINCT**: trino.io/docs/current/sql/select.html — "If the argument DISTINCT is specified only unique rows are included in the combined result set... If the argument ALL is specified all rows are included even if the rows are identical." Bare UNION = UNION DISTINCT. Responder is correct.

---

## Per-question scoring

### Q1 — Sessionize page views: new session when idle > 30 min since last event; assign session id per row

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 2.0 | Skeleton correct (LAG, is_new_session flag, running-SUM session_id is the canonical gaps-and-islands shape). **BUT the gap test `(occurred_at - LAG(occurred_at) OVER (...)) > INTERVAL '30' MINUTE` is a PARSE ERROR on Trino 467** — `timestamp - timestamp` is not a documented operator; query won't compile. This is the exact iter671 defect class explicitly defanged at r07 §3164 and r23 §2311-2313. Load-bearing dialect defect: the queryable result is unusable. |
| Beginner clarity | 4.0 | The gaps-and-islands skeleton explanation is reasonably clear (flag → running-sum → session_id). No explanation of why ts-minus-ts is wrong, because the responder didn't notice. |
| Practical applicability | 2.0 | Engineer copies, hits parse error, has to debug and replace the gap test with `date_diff('minute', LAG(...), occurred_at) > 30`. Wasted iteration. |
| Completeness | 4.0 | All structural pieces named (LAG, flag, running-SUM, partition by user_id, order by event time). Missing: NULL-LAG handling for the first event per user (CASE WHEN LAG IS NULL THEN 1 — covered at r07 §3154). |

**Q1 average: 3.0** — borderline FAIL on this question alone, but overall iter passes via no-veto rubric. Skeleton-right / dialect-wrong is exactly the iter671 defect class.

### Q2 — Normalize phone numbers, strip everything except digits; regex replace?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | `regexp_replace(phone_raw, '[^0-9]', '')` is canonical Trino 467 — 3-arg form replaces every match; `[^0-9]` is standard Java-regex negated char class; empty-string replacement strips matches. Avoids the single-vs-double backslash trap that `\D` would hit (per `reference_trino_regex_backslash`). |
| Beginner clarity | 5.0 | Explains the negation (`^` inside `[]` = NOT) and the empty-string replacement; an engineer with no prior regex exposure can follow. |
| Practical applicability | 5.0 | Copy-pasteable, single-statement fix. |
| Completeness | 4.5 | Could optionally mention NULL handling (regexp_replace returns NULL on NULL input) or the leading-zero/leading-`+` country-code consideration, but those are edge-cases not asked about. |

**Q2 average: 4.875**

### Q3 — Iceberg events partitioned by day, single account_id filter still reads a lot; sort order via dbt?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | `ALTER TABLE ... SET PROPERTIES sorted_by = ARRAY['account_id ASC NULLS LAST']` is valid Trino 467 syntax (sorted_by IS in the modifiable list per 467 docs); `EXECUTE optimize(file_size_threshold => '512MB')` named-param form is correct; optimize honors the current sort order on file rewrite per Trino's sorted-writes support; the "complementary to partitioning, enables file/row-group skipping on non-partition columns" framing is correct (Parquet min/max stats per file + per row-group). |
| Beginner clarity | 4.5 | Sort-vs-partition complementarity called out clearly; the two-step pattern (set property, then rewrite via optimize) is the right mental model for a beginner. Could clarify that newly-sorted writes only affect new files until optimize runs over historical data. |
| Practical applicability | 5.0 | dbt post_hook with the two statements is exactly the canonical pattern on this production stack. Engineer can drop this into the model config tomorrow. |
| Completeness | 4.5 | Could mention that the benefit depends on Parquet column-chunk min/max stats covering the sort column, and that very high cardinality (account_id with millions of distinct values) sorts well while low cardinality (status with 5 values) does not. Not load-bearing for the answer. |

**Q3 average: 4.75**

### Q4 — UNION of US + EU customer tables returns FEWER rows than the sum; expected US+EU exactly

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Bare UNION = UNION DISTINCT in Trino 467 per SELECT.html ("If neither DISTINCT nor ALL is specified... DISTINCT"). UNION ALL keeps all rows. Correct diagnosis: the "missing" rows are duplicate-key matches across the two source tables that get collapsed. |
| Beginner clarity | 5.0 | Direct cause-effect explanation, no jargon. |
| Practical applicability | 5.0 | One-word fix (`ALL`) — engineer knows exactly what to change. Also correctly notes when to keep bare UNION (intentional dedupe across same-key sources). |
| Completeness | 4.5 | Could mention the performance cost of UNION DISTINCT (sort/hash dedupe step) but not strictly required for the diagnosis question. |

**Q4 average: 4.875**

---

## Score table

| Q | Topic | Tech | Clarity | Applic | Complete | Avg |
|---|---|---|---|---|---|---|
| Q1 | Sessionization gaps-and-islands | 2.0 | 4.0 | 2.0 | 4.0 | **3.000** |
| Q2 | regexp_replace digit-strip | 5.0 | 5.0 | 5.0 | 4.5 | **4.875** |
| Q3 | Iceberg sorted_by + EXECUTE optimize | 5.0 | 4.5 | 5.0 | 4.5 | **4.750** |
| Q4 | UNION = UNION DISTINCT, UNION ALL keeps all | 5.0 | 5.0 | 5.0 | 4.5 | **4.875** |

**Iter average: (3.000 + 4.875 + 4.750 + 4.875) / 4 = 4.375 PASS** (margin +0.875 above 3.5 threshold; no-veto applies).

---

## Q1 classification — RESPONDER SLIP from CANONICAL, NOT a resource defect

### Resource audit

- **r07 §3099 Pattern B-Session LEADING CANONICAL** — explicitly headed "iter671 PIN — FIX-A: ts-minus-ts gap test invalid in Trino 467". Gives the correct form `date_diff('minute', LAG(event_time) OVER (PARTITION BY user_id ORDER BY event_time), event_time) > 30` (§3127-3130) with detailed "Why each piece is what it is" walkthrough (§3151-3156) explaining `date_diff` returns `bigint`, comparison to `30` (plain integer) NOT `INTERVAL '30' MINUTE` (type mismatch).
- **r07 §3164 DO-NOT-WRITE row** — explicitly lists `event_time - LAG(event_time) OVER (...) > 30 * INTERVAL '1' MINUTE` as WRONG with "the LEFT side is still timestamp - timestamp, which does not parse" reason.
- **r23 §2311-2313 DO-NOT-WRITE banner** — lists `ts2 - ts1 > INTERVAL '5' SECOND` as "INVALID Trino 467 — same reason as the row above. Even when the comparison is > INTERVAL, the LEFT side ts2 - ts1 is a timestamp - timestamp subtraction that does not parse" → corrected form `date_diff('second', ts1, ts2) > 5`. Also defangs `closed_at - opened_at`, `first_reply_at - created_at` and TIMESTAMPDIFF/DATEDIFF dialect imports.

**Verdict**: The canonical IS in the right place with the right defang. The responder did NOT pull it — it produced the exact form the defang bans. Skeleton-right (LAG/flag/running-SUM correctly named) but failed to use `date_diff` for the gap test, despite the canonical being headed PREFERRED and explicitly cross-referenced from r23.

### Pattern matching

This is **NOT** a `feedback_responder_broken_secondary_alternative` (the broken form IS the primary answer, not a trailing "for completeness" alternative). It matches `feedback_synthesis_ceiling_stop_churning` weakly — multi-step query (CTE + window + aggregation), responder got the structural shape right but slipped a dialect detail despite extensive defang. The iter671 fix-A pattern is from 445+ iterations ago and has held for a long time; this is the first sessionization re-probe in many recent iters where I see a regression.

### Recommendation: **NO-OP** (with watchlist)

Adding more content to r07/r23 won't help — the canonical is already EXPLICIT, the DO-NOT-WRITE rows are EXPLICIT, the cross-references are EXPLICIT. Per `feedback_synthesis_ceiling_stop_churning`: scope this as a per-instance synthesis slip on a multi-step query, NOT a resource gap. The responder's recall ceiling cannot be fixed by additive content when the canonical is already preferred-and-defanged.

**Watch stream**: Re-probe sessionization (or any other ts-minus-ts gap-test shape — ticket age in hours, time-to-first-response, deal-cycle-duration) in the next 2-3 iters from a different angle. If the ts-minus-ts regression RECURS on the re-probe, consider:
- **LIGHT FIX-A only on confirmed recurrence**: hoist the `date_diff` form into a top-of-file STEP-0 router in r07 with keyword anchors `sessionize, session id, gap > N minutes, idle for N minutes, new session when, time between consecutive events` and an inline-WRONG defang on the ts-minus-ts form per `feedback_defang_donotwrite_snippets`.
- Do NOT touch the r07 §3099 canonical or r23 §2311-2313 banner (both are correct and load-bearing).
- Do NOT add a new file — creates finder-vs-content split per the iter1112 lesson.

If the next re-probe lands clean → iter671 PIN remains durable, this iter is a one-off, no edit needed.

---

## Topic rubric updates

| Topic | Before | This iter | After |
|---|---|---|---|
| Analytical query patterns on Iceberg+Trino (Q1) | 4.4363/69 | 3.000 | (306.1047 + 3.000)/70 = **4.4158/70 PASSED** (-0.0205, margin +0.916 still well above 3.5) |
| SQL best practices OLAP (Q2 + Q4) | 4.5021/171 | 4.875 + 4.875 | (769.8591 + 4.875 + 4.875)/173 = **4.5064/173 PASSED** (+0.0043, margin +1.006) |
| Iceberg partition design for SaaS (Q3) | 4.4391/44 | 4.750 | (195.3204 + 4.750)/45 = **4.4460/45 PASSED** (+0.0069, margin +0.946) |

ALL required topics REMAIN PASSED. No topic crosses or approaches the 3.5 threshold.

---

## Memory pins reinforced

- `reference_trino_unwrap_temporal_predicates` — not triggered this iter (no function-on-column sargability question), but related discipline (date_diff is the right tool, not arithmetic).
- `reference_trino_regex_backslash` — Q2 `[^0-9]` correctly avoids the `\d`/`\D` single-vs-double backslash trap; no regression.
- iter671 PIN (r07 §3099 + r23 §2311-2313 ts-minus-ts ban) — **regression observed THIS iter**; defang in place, watch stream opened.

## Memory pins NOT triggered (clean carry)

- No `::` cast / QUALIFY / fabricated-fn / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / CAST-truncate / EXECUTE-rollback-on-467 / Spark-Oracle-spillover / imported-prior.
- No COUNT(DISTINCT a,b) multi-arg / no GREATEST-NULL Postgres-prior / no `<<`/`>>` shift / no array_sum / no `->`/`->>` JSON / no DATEDIFF dialect import.

---

## Recommendation: **NO-OP**

- No resource edits.
- No state.json bump beyond iteration counter (`extended` phase, passed remains true).
- Commit rubric + feedback only.
- **Watch stream opened**: Q1 sessionization / ts-minus-ts gap-test regression. Re-probe in next 2-3 iters from a different gap-test angle. LIGHT FIX-A only on confirmed recurrence (additive STEP-0 router in r07, no rewrite of existing canonical).
- Federation untouched (4.50244/312 fragile-PASS preserved).
- CBO/ANALYZE untouched (4.5716/20, +0.072 margin to raised 4.5 preserved).

### Optional next-sweep durability probes (no edit, just probe)

- Sessionization re-probe with different domain (cart-abandonment session, login-session timeout) to confirm Q1 ts-minus-ts regression is per-instance vs structural.
- Storage-tiering 7th datapoint (3.5625/6 still thinnest required-topic row).
- dbt-model-contracts 7th angle (4.391/6).
- dbt-snapshots SCD2 15th angle (4.0315/14, 2nd-thinnest after storage-tiering).
- Cost-considerations 21st angle (4.2129/20).

### Pattern observation

iter1116 breadth-sweep mostly clean (3 of 4 questions ≥ 4.75), with one regression on a long-stable defect class. The Q1 ts-minus-ts slip on a question whose canonical is BOTH preferred AND defanged is informative: the iter671 PIN held for 445+ iterations without re-probe stress; this is the first sessionization sweep in many. The skeleton-right / dialect-wrong split (canonical gaps-and-islands shape correctly named but wrong gap-test operator) is the synthesis-ceiling artifact described in `feedback_synthesis_ceiling_stop_churning` — adding more content to an already-explicit canonical does not durably fix a multi-step-query recall slip. Re-probe rather than churn.

Pattern observation 2: Q3's clean handling of `sorted_by` via `ALTER TABLE SET PROPERTIES` plus `EXECUTE optimize` reaffirms the strong Iceberg-maintenance + partition-design content lineage (file_size_threshold default verbatim, optimize honors sort order, dbt post_hook idiom). Q4's UNION default-DISTINCT explanation is textbook-clean and signals durable SQL-set-ops content in r23. Q2's `[^0-9]` instead of `\D` shows the `reference_trino_regex_backslash` defang continues to land cleanly.

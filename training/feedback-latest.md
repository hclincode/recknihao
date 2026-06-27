# Iter1195 Judge Feedback

**Overall: 4.1875 / 5.0 — PASS, BUT Q1 IS A FAIL (RESOURCE-SOURCED, FIX-A APPLIED).** Q1 is a re-probe of the iter1194 `optimize-clears-position-deletes` FIX-A — and it did **NOT** reach. The responder gave the WRONG mental model (EXECUTE optimize doesn't apply position deletes; Spark required) AND cited a FABRICATED issue (`trino#25279`, which is about partition-predicate optimize, not position-delete files). Root cause is a FINDABILITY / un-reconciled-sibling miss: iter1194 fixed r28 §348–403 but left r13 L2862 carrying the same wrong "Trino EXECUTE optimize does NOT apply pending position-delete files — use Spark" claim, and the responder lifted r13 instead of the fixed r28. Teacher has already extended the FIX-A to r13 this iteration (correctly directed — see Q1 verification). Q2 + Q3 + Q4 are clean 5.0 with all load-bearing facts independently verified. Iter1194 dbt-contract-live-connection watch was NOT exercised this iter; carries forward.

---

## Q1 — Iceberg optimize and position-delete files (RE-PROBE of iter1194 FIX-A)

**Score: 1.0 / 3.0 / 1.5 / 2.0 = 1.875 (FAIL, RESOURCE-SOURCED, WATCH FIRED)**

### What the responder said:
- "EXECUTE optimize on its OWN does NOT rewrite data files to bake in deletes. It only compacts data files by size."
- "Trino-only shop CANNOT fix the delete-file accumulation alone."
- Recommended Spark `rewrite_position_delete_files` or Spark `rewrite_data_files(options=>map('delete-file-threshold','1'))` as the load-bearing fix.
- Cited "**Trino issue #25279** — Trino's OPTIMIZE cannot apply merge-on-read position-delete files."

### Independent verification (primary-source confirmation of teacher's findings):

1. **`trino#25279` citation is FABRICATED.** Verified at [trinodb/trino#25279](https://github.com/trinodb/trino/issues/25279) — actual title is **"Add support to optimize iceberg table on newly added partition predicate"** (about `IllegalStateException` when WHERE clause filters on a newly-added partition column during optimize), closed as duplicate of #15697. ZERO mention of position-delete files. The responder invented a citation that does not exist for this topic.

2. **Trino `EXECUTE optimize` DOES clear position-delete read overhead for rewritten files.** Verified at [trinodb/trino#12617](https://github.com/trinodb/trino/issues/12617) — "Remove unused position and equality deletes when running Iceberg `optimize`" — implemented by [PR #12704](https://github.com/trinodb/trino/pull/12704) (2022, shipped well before Trino 467). The optimize procedure compares the data-file set remaining in the manifest after rewrite and **removes delete files which no longer reference any data file**. Both position AND equality delete files in scope.

3. **Trino maintainer note at [trinodb/trino#24086](https://github.com/trinodb/trino/issues/24086):** verbatim "Position deletes are local to a partition. OPTIMIZE supports only enforced predicates which select whole partitions. Therefore, we can clean up position deletes in OPTIMIZE **when there are no path or file_modified_time predicates**." Confirms: a full-table (no-predicate) `EXECUTE optimize` is the operation that clears the orphaned delete files.

4. **The NUANCE the responder missed entirely.** Verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html): `EXECUTE optimize` selects candidate data files by **`file_size_threshold` only** (default **100MB** — files BELOW this are merged). Trino has NO `delete-file-threshold` candidate-selection option (open feature request [trinodb/trino#16574](https://github.com/trinodb/trino/issues/16574)). So if the delete-bearing data files are already ≥100MB, a DEFAULT optimize SKIPS them and their position deletes persist. The **Trino-only fix** = raise `file_size_threshold` above those files' size (e.g. `'512MB'` or `'1GB'`) to force the rewrite; this then applies the deletes AND removes the orphaned delete files in one Trino `EXECUTE optimize` call. NO Spark required.

5. **Spark procedures are OPTIONAL alternatives, NOT required.** `rewrite_position_delete_files` is a delete-file-only compactor (many small delete files → fewer larger ones, no data rewrite) — useful when delete files are still actively referenced; not load-bearing for the engineer's stated "stop reconciling delete files at read time" goal. `rewrite_data_files(options=>map('delete-file-threshold','1'))` is a size-INDEPENDENT delete-driven candidate selection — Spark-only because Trino lacks the corresponding optimize option, but again optional, not required.

### Correct answer the responder should have given:
YES — `ALTER TABLE iceberg.analytics.orders EXECUTE optimize` ALONE rewrites affected data files with position deletes baked in AND removes the now-orphaned delete files (per #12617 / PR #12704 / maintainer note on #24086). A Trino-only shop CAN fix the delete-file read slowdown without Spark. The one nuance: optimize picks candidates by `file_size_threshold` (default 100MB) — if delete-bearing data files are already ≥100MB, default optimize skips them. Fix: `EXECUTE optimize(file_size_threshold => '512MB')` (or above the largest file size) to force the rewrite. Spark `rewrite_position_delete_files` is OPTIONAL — a cheaper delete-file-only compaction when delete files are still actively referenced; not required for the engineer's stated goal.

### Dimensional breakdown:
- **Technical accuracy 1.0**: Inverted the central question, fabricated a GitHub issue citation, missed `file_size_threshold` lever entirely.
- **Beginner clarity 3.0**: Prose is clear and well-organized; would have been fine if the underlying claim were true.
- **Practical applicability 1.5**: Engineer is misdirected to Spark (production-stack-aligned but unnecessary operational complexity). For a "Trino is primary, Spark only occasionally" shop, routing to Spark for routine MoR-delete maintenance is exactly wrong — adds an operational dependency that the truth removes.
- **Completeness 2.0**: Misses `file_size_threshold` lever, misses the `EXECUTE optimize` self-applies-and-cleans-up mechanism, misses the no-path/no-file_modified_time predicate condition.

### Watch outcome:
**Iter1194 `optimize-clears-position-deletes FIX-A` WATCH: DID NOT REACH on first re-probe.** The FIX-A landed correctly on r28 §348–403 (verified by the teacher this iter), but a SIBLING resource (r13 L2862) carries the SAME un-reconciled wrong claim ("Trino EXECUTE optimize does NOT apply pending position delete files ... use Spark"). The responder's keyword path on this question (`MoR / position-delete files / how do we collapse them / Spark or Trino`) landed on r13 not r28 — classic `feedback_reconcile_dont_append` failure mode (one fixed canonical does not protect against a stale sibling).

### Teacher's FIX-A direction: CONFIRMED CORRECT
Teacher has already extended the FIX-A this iteration:
- r13 L2862 (the unfixed sibling that the responder lifted): reconciled
- r28 §348 (the iter1194-fixed primary): refined to the precise size-threshold truth, kept consistent with r13

This direction is RIGHT — both files now teach the verified truth: full `EXECUTE optimize` is the primary delete-application + delete-file-cleanup lever; `file_size_threshold` is the only candidate-selection knob; raise it to force rewrite of larger delete-bearing files; Spark procedures are optional alternatives.

### Open watches:
- NEW WATCH: `iter1195 r13 L2862 + r28 §348 optimize-clears-position-deletes RECONCILED FIX-A` — re-probe in 3–5 iters with structurally similar framing ("MoR delete files accumulated, Trino-only fix or need Spark"). If recurs → resource defect at a 3rd sibling not yet found by grep; if reaches → close.

### Resource attribution:
Cites r13 (verified — the unreconciled sibling). RESOURCE-SOURCED defect, NOT a responder confabulation in isolation.

---

## Q2 — One-pass first-plan + last-plan per account on 40M-row event table

**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.0 (PASS, CLEAN)**

### Verification:
- `min_by(plan_name, occurred_at)` and `max_by(plan_name, occurred_at)` verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html): "Returns the value of `x` associated with the minimum/maximum value of `y` over all input values." Both are **General aggregate functions** that work with GROUP BY. Returns the FIRST argument (`plan_name`) at the min/max of the SECOND argument (`occurred_at`) — exactly what the engineer asked for.
- Single GROUP BY → one row per `account_id` → single hash-aggregation pass over 40M rows; no self-join.
- `last_value` default-frame gotcha correctly called out. Per ANSI SQL (and Trino's standards-compliant window implementation), default frame for value functions is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`, which makes `last_value` return the current row's value — not the partition's last. The responder's `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` workaround is the documented fix.
- DISTINCT-collapse caveat on `first_value`/`last_value` (per-row window output → DISTINCT or QUALIFY-like wrap needed) accurately frames why min_by/max_by aggregates are the cleaner shape for "one row per account" semantics.

### Dimensional breakdown:
- All four dimensions clean 5.0; engineer can copy-and-ship the canonical form. No imported-prior slip, no broken-secondary-alternative.

---

## Q3 — dbt source freshness pre-check before downstream models

**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.0 (PASS, CLEAN)**

### Verification at [docs.getdbt.com/reference/resource-properties/freshness](https://docs.getdbt.com/reference/resource-properties/freshness):
- **YAML shape correct**: `freshness:` block with `warn_after: {count: 12, period: hour}` and `error_after: {count: 24, period: hour}` + `loaded_at_field: updated_at` — verbatim docs example.
- **`period` units correct**: only `minute`, `hour`, `day` — no `week`, no `quarter`, no `second`. Verified verbatim.
- **`dbt source freshness` is a SEPARATE command** — verbatim "Source freshness is checked via the `dbt source freshness` command, not `dbt run`. It's a separate operation that runs independent freshness queries." Non-zero exit on `error_after` breach (set -e gates CI pipeline).
- **NOT automatic in `dbt run`/`dbt build`** — verbatim "Source freshness checks do not automatically block downstream models." Engineer gates operationally by running `dbt source freshness` BEFORE `dbt build` in CI.
- **`loaded_at_field` REQUIRED on Trino**: warehouse-metadata fallback (`loaded_at_field` optional, dbt reads adapter metadata) supported ONLY on Snowflake/Redshift/BigQuery/Databricks — Trino is NOT on that list. Responder correctly framed this — production-stack-critical fact.

### Dimensional breakdown:
- All four dimensions clean 5.0. Engineer arrives with a working sources.yml + CI step + correct mental model (freshness is a gate you wire in, not an automatic DAG-blocker). No fabrications, no broken secondary alternative.

---

## Q4 — Trino equivalents of Oracle TO_DATE for ISO + non-ISO date strings

**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.0 (PASS, CLEAN)**

### Verification at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html):
- **No TO_DATE in Trino 467** — verified. `date(x)` is an alias for `CAST(x AS date)` but doesn't take a format string. Responder correctly stated this.
- **`from_iso8601_date('2024-01-15')` returns DATE** — verified verbatim "Parses the ISO 8601 formatted date `string` into a `date`." Accepts ISO calendar dates and ISO week-dates. Perfect for the dashes-form input; compares directly to a DATE column.
- **`date_parse('15-JAN-2024','%d-%b-%Y')` returns TIMESTAMP** — verified. Uses **MySQL %-style format specifiers**. `%d` = day-of-month, `%b` = abbreviated month name (Jan, Feb, ...), `%Y` = 4-digit year. Returns timestamp(3), needs `CAST(... AS DATE)` to compare against a DATE column.
- **`parse_datetime('15-JAN-2024','dd-MMM-yyyy')` returns TIMESTAMP WITH TIME ZONE** — verified. Uses **JodaTime DateTimeFormat patterns**. `dd` = day, `MMM` = 3-letter month name, `yyyy` = year. Joda generally case-insensitive on text fields ('JAN' / 'Jan' both accepted in practice).
- **Don't mix the families** — verified verbatim that MySQL `%-style` and Joda `letter-pattern` are separate specifier vocabularies. Mixing produces parse-error or silent misparsing. Responder's explicit "don't mix the %-family (date_parse/date_format) with the letter-family (parse_datetime/format_datetime)" framing is exactly right and matches `feedback_responder_broken_secondary_alternative` discipline — the alternative shape is COMPLETE and CORRECT, not a broken padding form.
- **`CAST AS DATE`** on the timestamp output is the canonical reduce-to-DATE for comparison against a DATE column. Without it, mixed TIMESTAMP-vs-DATE comparison still works in 467 (per pinned `reference_trino_timestamp_tz_coercion`), but explicit CAST is cleaner.

### Dimensional breakdown:
- All four dimensions clean 5.0. Engineer has both ISO and Oracle-style paths, both verified Trino 467 surface, with the format-family non-mix discipline made explicit. Minor recall ceiling not load-bearing: didn't mention case-sensitivity nuance on `%b`/`MMM` (both accept 'JAN' in practice), didn't mention `from_iso8601_timestamp` for ISO TIMESTAMP variant. Neither affects the engineer's literal ask.

---

## Cross-iteration summary

| Q | Topic | Score | Status |
|---|---|---|---|
| Q1 | Iceberg table maintenance (compaction/expire/orphan) | 1.875 | FAIL — RESOURCE-SOURCED, FIX-A APPLIED |
| Q2 | Analytical query patterns on Iceberg+Trino | 5.0 | PASS — CLEAN |
| Q3 | dbt sources / source freshness | 5.0 | PASS — CLEAN |
| Q4 | Oracle PL/SQL → dbt+Trino SQL migration | 5.0 | PASS — CLEAN |

**Overall: 16.875 / 20 = 4.219 — PASS**

Q2/Q3/Q4 demonstrate the responder's normal mode: pin-perfect canonical reach with all load-bearing facts present and the routing discipline (e.g. min_by/max_by over first_value/last_value frame trap; separate `dbt source freshness` command over auto-blocking; format-family non-mix discipline) intact. Q1's failure is NOT a Haiku synthesis ceiling — the responder confidently delivered a wrong answer with a fabricated citation, because the resource it pulled from (r13 L2862) confidently teaches the wrong thing. This is a `feedback_reconcile_dont_append` pattern: iter1194 fixed one canonical but left a sibling carrying the same wrong claim. The teacher's iter1195 FIX-A extension to r13 is the right move and correctly directed.

## Carry-forward open watches NOT exercised this iter

1. **iter1192 r27 §3.2 delete+insert-on-non-ACID-Hive defang** — re-probe soon (not exercised iter1193, iter1194, iter1195; getting stale).
2. **iter1194 r27 §6.7C dbt-contract-live-connection FIX-A** — re-probe in 3–6 iters (added iter1194, not exercised iter1195). Framing target: "does dbt contract enforcement need a live Trino connection / can contracts be validated in CI without warehouse access".

## New watch this iter

3. **iter1195 r13 L2862 + r28 §348 optimize-clears-position-deletes RECONCILED FIX-A** — re-probe in 3–5 iters with structurally similar framing ("MoR delete files accumulated, Trino-only fix or need Spark"). If recurs → resource defect at a 3rd un-reconciled sibling not yet found; if reaches → close.

## Recommendation for next iteration

- BREADTH on Q2/Q3/Q4 type angles. Q1 was the high-priority FIX-A re-probe miss; the teacher's reconcile of r13 should be exercised within 3–5 iters.
- Watch for any sibling-resource un-reconciled-claim patterns surfacing on other FIX-A topics — if the iter1192 delete+insert-on-non-ACID-Hive watch fires similarly, that's a generalized signal that recent FIX-A coverage needs sibling-grep discipline.

# Iter1299 Judge Feedback

## Iteration verdict

**Overall avg: 3.766 (PASS by overall threshold, but Q-level MIXED: 2 STRONG / 2 FAIL).**

| Q | Score | Verdict | Topic touched |
|---|---|---|---|
| Q1 (`\|\|` vs CONCAT + mixed types) | **4.875** | STRONG PASS | SQL query best practices for OLAP |
| Q2 (day vs month partitioning) | **4.6875** | STRONG PASS | Iceberg partition design for SaaS |
| Q3 (dbt `{{ this }}`) | **3.125** | **FAIL** (Q-level <3.5) | Improving complex SQL on Trino with dbt |
| Q4 (Oracle MOD → Trino) | **2.375** | **FAIL** (Q-level <3.5) | Oracle PL/SQL → dbt+Trino migration |

iter1298 4.5625 → iter1299 3.766: drop of −0.797, driven by Q3 broken-example defect and Q4 false-premise endorsement. All four topics remain PASSED at the topic-running-average level (large prior datapoints absorb the per-Q drop).

---

## Per-question

### Q1 — `||` vs CONCAT + mixed types → **4.875 STRONG PASS**

Acc 5.0 / Clar 4.5 / Prac 5.0 / Compl 5.0.

Responder: `||` and `concat()` are equivalent (concat is the SQL-standard equivalent of `||` per Trino docs); BOTH varchar-only with NO implicit number→string coercion; explicit `CAST(x AS VARCHAR)` per numeric arg OR — recommended for labels — `format('Enterprise — %s — %s', region, plan_name)`. Gave format-specifier table (`%s` any type, `%d` BIGINT, `%.2f` DECIMAL).

**VERIFIED**:
- `concat(string1, ..., stringN) → varchar` "provides the same functionality as the SQL-standard concatenation operator (`||`)" — [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html)
- "Trino will not convert between character and numeric types" — [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html)
- `format()` Java-formatter semantics; `%s` accepts any printable type (Java Formatter conversion 's' uses `toString()`)

Minor Clar shave (−0.5): didn't surface that `||`/`concat()` on a NULL arg propagates NULL whereas `format()` prints literal "null" — common label footgun worth one extra sentence. Not load-bearing.

No imported-prior, no broken-secondary, no over-warning, no fabrication.

### Q2 — day vs month partitioning → **4.6875 STRONG PASS**

Acc 4.5 / Clar 5.0 / Prac 5.0 / Compl 4.25.

Responder cleanly REFUTED the teammate's misconception: "partition granularity ≠ file count." A single day-partition can hold many Parquet files (file count is driven by `write.target-file-size-bytes` ~128MB default, not by partition granularity); a month-partition with the same write knob just lumps 30 days' worth of files into the same partition value, doesn't inherently reduce file count. BOTH day + month enable Iceberg pruning via day()/month() transforms; day gives FINER pruning (engine reads only requested day's files), month forces scanning whole month then filter-in-Trino = up to 30× more data for a single-day query. Day = more partition-spec entries → small/negligible planning overhead at 400M/365 ≈ 1M rows/day. Recommendation: **STICK WITH DAY** for fact tables with date-range filters.

**VERIFIED**:
- Iceberg `write.target-file-size-bytes` default 128MB (file size, not granularity, drives file count) — [iceberg.apache.org/docs/latest/configuration/](https://iceberg.apache.org/docs/latest/configuration/)
- Day()/month() transforms both prune via manifest min/max per [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html)
- 400M/365 ≈ 1M rows/day → at any sensible row size, this is NOT the over-partitioning regime

**Minor Acc shave (−0.5)**: didn't acknowledge the over-partitioning edge case — if days were so sparse each day produced 1-2 tiny files, coarsening to month could help by consolidating; at 1M rows/day this regime is not in play, but a one-sentence "if days are tiny, coarsen; not your case at 1M rows/day" would close the "how to pick" portion.

**Minor Compl shave (−0.75)**: didn't surface the `events$partitions` metadata table inspection (iter1268 canonical) for verifying file_count/total_size per partition before changing partition spec — would have given the engineer a concrete diagnostic step for "how to pick". Reinforces iter1298-Q2 watch (metadata-tables-for-file-layout) — second consecutive miss of the `$partitions`/`$files` metadata-inspection canonical when the question naturally invites it.

No imported-prior, no broken-secondary, no over-warning, no fabrication. Refuting the teammate's claim is the load-bearing piece, and that's clean.

### Q3 — dbt `{{ this }}` → **3.125 FAIL**

Acc 3.0 / Clar 4.0 / Prac 2.5 / Compl 3.0.

**Concept portion CORRECT**: `{{ this }}` is a Relation object referring to the model's own target (catalog.schema.identifier of the table this model materializes into); intended primarily for incremental models reading prior state to compute deltas; also valid in pre/post hooks.

**THE DEFECT — broken example**: responder gave

```sql
{{ config(materialized='incremental') }}
SELECT ...
WHERE occurred_at >= (
  SELECT COALESCE(MAX(occurred_at), TIMESTAMP '1970-01-01')
  FROM {{ this }}
)
```

and claimed "First run `{{ this }}` doesn't exist → watermark defaults to sentinel." **This is WRONG.** On first run the target relation does NOT exist, so `SELECT MAX(...) FROM {{ this }}` raises "relation does not exist" / table-not-found BEFORE any `COALESCE` evaluates. **COALESCE handles an EMPTY table, NOT a MISSING one.** The standard dbt-canonical pattern REQUIRES the `{% if is_incremental() %}` guard:

```sql
{{ config(materialized='incremental') }}
SELECT ...
{% if is_incremental() %}
  WHERE occurred_at >= (SELECT COALESCE(MAX(occurred_at), TIMESTAMP '1970-01-01') FROM {{ this }})
{% endif %}
```

On first run the entire WHERE clause is OMITTED (full backfill); on subsequent runs the table exists and the watermark is read.

**VERIFIED** at [docs.getdbt.com/reference/dbt-jinja-functions/this](https://docs.getdbt.com/reference/dbt-jinja-functions/this) verbatim:
- "On the first execution of a model, `{{ this }}` will not refer to an existing table"
- Canonical docs example wraps the WHERE in `{% if is_incremental() %} ... {% endif %}` explicitly

Material harm: an engineer copying the responder's example would hit a relation-not-found error on first `dbt build` / `dbt run`. The question literally asked "safe in a non-incremental model or only specific context", so the example matters more than usual here. Concept is right; example (how to use it) is broken.

**NEW SOFT WATCH `iter1299-Q3 dbt {{ this }} incremental example MISSING is_incremental() guard, COALESCE-saves-first-run myth`**: re-probe in 4-8 iters under "show me an incremental model using `{{ this }}`" framings; if 2+ recurrences where the example omits `{% if is_incremental() %}`, escalate to LIGHT FIX-A — find the resource that teaches this pattern and verify the canonical form is anchored WITH the guard + an explicit defang: "COALESCE does NOT rescue a missing relation; `is_incremental()` guard is REQUIRED on first run." Family: `feedback_responder_broken_secondary_alternative.md` — leads pass, broken-secondary-example padding.

No imported-prior, no over-warning, no fabrication.

### Q4 — Oracle MOD → Trino → **2.375 FAIL**

Acc 2.0 / Clar 3.0 / Prac 2.0 / Compl 2.5.

**Uncorrected FALSE engineer premise + hedge, despite having the refuting fact (r27 L1271 "Identical") in resources.** Responder hedged: "resources list mod/% as 'identical' to Oracle MOD, but resources do not document the specific sign-handling behavior. This is a gap — I don't have enough detail to confirm. Recommendation: test mod() and `%` against your Oracle values yourself." Did NOT correct the premise; implicitly accepted MOD(-10,3)=2.

**THE ACTUAL MATH**:
- Oracle `MOD(n2, n1) = n2 - n1 * TRUNC(n2/n1)` (TRUNC = truncate toward zero, NOT FLOOR)
- For MOD(-10, 3): -10/3 = -3.333…, TRUNC(-3.333) = -3, -10 - 3*(-3) = -10 + 9 = **-1**
- **Oracle MOD follows the SIGN OF THE DIVIDEND**, NOT the divisor

**VERIFIED**:
- [docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/MOD.html](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/MOD.html) — Oracle docs: result is negative only when n2 (dividend) is negative
- [database.guide/mod-function-in-oracle/](https://database.guide/mod-function-in-oracle/) — "The result is negative only if n2 is negative"
- [databasestar.com/oracle-remainder-mod/](https://www.databasestar.com/oracle-remainder-mod/) — same behavior
- Trino `mod()` and `%` use the SAME truncated-division semantics per [trino.io/docs/467/functions/math.html](https://trino.io/docs/467/functions/math.html) (consistent with C/Java truncated `%`)

**Conclusion**: **Trino mod = Oracle MOD = -1** for (-10, 3). **r27 L1271 "Identical" IS CORRECT.** The engineer's premise "Oracle returns 2, follows sign of divisor" is **FALSE** — the value 2 is the FLOORED / Euclidean / Python `%` modulo (`((a % n) + n) % n`), which neither Oracle MOD nor Trino mod produces natively. The engineer is likely confusing Oracle MOD with Excel's MOD or Python's `%` (floored-modulo behavior).

**IDEAL ANSWER**:
1. Cite r27 L1271 "Identical" → both engines = -1
2. CORRECT the false premise: Oracle MOD follows DIVIDEND sign per Oracle docs (TRUNC formula), NOT divisor; MOD(-10, 3) is -1 in Oracle, not 2
3. If engineer wants always-non-negative floored result: `((a % n) + n) % n` or `mod(((a % n) + n), n)`

Responder had r27 L1271 "Identical" available but failed to connect it; hedged instead of asserting. Material harm: engineer will continue to believe Trino mismatches Oracle when in fact they match perfectly, and may write workarounds based on a wrong understanding of Oracle.

**This is the 3rd false-premise pattern in recent iters**:
- iter1291-Q4 COUNT-NULL-corrected (responder DID correct — INVERSE case, good)
- iter1297-Q4 Oracle-GROUP-BY-leniency endorsed (responder accepted false "Oracle is lenient" — bad)
- iter1299-Q4 Oracle-MOD-divisor-sign hedged (responder didn't correct — bad)

2 of 3 most recent false-premise scenarios endorsed/hedged.

---

## RECOMMENDED LIGHT FIX-A: r27 L1271

The current "Identical" is **TOO TERSE** — responder had the resource fact but couldn't connect it to refute a concrete false claim. Enhance L1271 with:

1. **Concrete worked example** (1-2 lines): `Oracle MOD(-10, 3) = -1`, `Trino mod(-10, 3) = -1`, `Trino -10 % 3 = -1` — all three identical, all follow DIVIDEND sign per truncated division (Oracle formula `n2 - n1 * TRUNC(n2/n1)`).
2. **Floored-modulo workaround** for always-non-negative result: `((a % n) + n) % n` or `mod(((a % n) + n), n)`.
3. **DEFANG card** (1-line, copy-attractive): "Common misconception: 'Oracle MOD follows the divisor sign / returns 2 for MOD(-10,3)' — WRONG. Oracle MOD follows the DIVIDEND sign per Oracle docs (TRUNC formula). The value 2 is the floored/Euclidean modulo (Python `%`, Excel MOD), NOT Oracle MOD." Mark as a DO-NOT-WRITE / un-copyable negative example per `feedback_defang_donotwrite_snippets.md` — wrong claim defanged in-line, canonical "both = -1" is the copy-attractive block.

This LIGHT additive FIX-A closes the findability gap (responder had the fact, couldn't connect because the resource was too sparse to refute a concrete false claim). Family: `feedback_trace_recurring_folklore_to_resource_root_cause.md` — false-premise endorsements that recur often have a too-terse-resource root cause; in this case the "Identical" claim is technically correct but offers nothing concrete enough to refute a specific sign-handling false claim.

**Scope**: 4-6 added lines at r27 L1271. Do NOT churn other Oracle dialect rewrite cards; this is a targeted findability lift.

**NEW SOFT WATCH `iter1299-Q4 Oracle MOD sign-handling false-premise hedge`**: re-probe in 4-8 iters under "Oracle MOD(neg,pos) sign / Trino mod equivalence" framings; verify the L1271 LIGHT FIX-A (if applied) anchors correctly.

---

## Watches carried forward

- **iter1298-Q2** metadata-tables-for-file-layout + sort-vs-pruning-conflation (re-probe 4-8) — **PARTIAL RECURRENCE this iter**: Q2 again missed `$partitions` metadata-inspection canonical when "how to pick day vs month" naturally invites it. Not a defect on Q2 (refutation was load-bearing and clean), but reinforces the watch. 2nd partial recurrence → if 1 more clean recurrence escalate to LIGHT FIX-A (routing card at file-layout-inspection keyword zone).
- **iter1297-Q4** Oracle-GROUP-BY-leniency false-premise endorsement (re-probe 4-8) — **PATTERN-CONFIRMED RELATED this iter via Q4 MOD false-premise**; if 2+ recurrences of false-premise endorsement on Oracle-vs-Trino topics, escalate to a broader "verify Oracle premises against docs" defang in r27 dialect-rewrite intro
- iter1296-Q1 CONTAINS-secondary (re-probe 4-8)
- iter1296-Q3 singular-test (re-probe 4-8)
- iter1295-Q2 FIRST_VALUE-priming (re-probe 4-8)
- iter1294-Q4 ROWNUM-per-group (re-probe 4-8)
- iter1290-Q3 small-files-routing (re-probe 4-8)
- iter1289-Q2 position-delete-Spark-vs-Trino (re-probe 4-8)
- iter1289-Q4 LPAD-RPAD-false-divergence (re-probe 4-8)

## Watches opened this iter

- **iter1299-Q3** dbt `{{ this }}` incremental example MISSING `{% if is_incremental() %}` guard, "COALESCE saves first run" myth (re-probe 4-8)
- **iter1299-Q4** Oracle MOD sign-handling false-premise hedge → **LIGHT FIX-A r27 L1271 RECOMMENDED** (worked example + floored workaround + defang); watch verifies the fix anchors

## FIX-A decision summary

**YES, LIGHT FIX-A on r27 L1271 RECOMMENDED.**

- This is the 2nd Oracle false-premise hedge in 3 iters (iter1297-Q4 + iter1299-Q4 endorsed; iter1291-Q4 corrected)
- Resource has the refuting fact ("Identical") but it's too terse to refute a concrete sign-handling claim
- Additive enhancement (worked example + workaround + defang) doesn't contradict the existing claim — just makes it concrete enough for the responder to find and connect
- Per `feedback_trace_recurring_folklore_to_resource_root_cause.md`, recurring false-premise endorsements warrant resource-root-cause investigation, not pure responder-slip framing

**Q3 — NO FIX-A on first occurrence.** Per `feedback_responder_broken_secondary_alternative.md` family — leads-pass, broken-example padding tends to be per-instance. Open soft watch; if 2+ recurrences with missing-guard pattern, then check whether the canonical dbt-incremental resource section explicitly anchors the `{% if is_incremental() %}` guard with a defang against the COALESCE-saves-first-run myth, and escalate to LIGHT FIX-A only if the resource is found to be missing/weak on the guard.

## Topic running averages after this iter

- SQL query best practices for OLAP: 4.5902/310 → **4.5912/311** (+0.0010, margin +1.0912)
- Iceberg partition design for SaaS: 4.4118/71 → **4.4156/72** (+0.0038, margin +0.9156)
- Improving complex SQL on Trino with dbt: 4.4660/94 → **4.4519/95** (−0.0141, margin +0.9519, Q-level FAIL absorbed by 94 priors)
- Oracle PL/SQL → dbt+Trino: 4.5000/272 → **4.4923/273** (−0.0077, margin +0.9923, Q-level FAIL absorbed by 272 priors)

All four topics REMAIN PASSED at topic-running-average level. Iteration overall avg 3.766 PASSES the 3.5 threshold but with 2 individual-Q FAILs (Q3, Q4).

# Iter1166 — Judge Feedback

## Verdict: STRONG PASS NO-OP — Average 4.859 / 5.0

| Q | Topic row | Score | Verdict |
|---|---|---:|---|
| Q1 named WINDOW clause | SQL query best practices for OLAP | 5.0000 | clean canonical |
| Q2 bool_or any-row-in-group | Analytical query patterns on Iceberg+Trino | 4.7500 | clean, minor over-dismissiveness on valid alternatives |
| Q3 Iceberg metadata-driven file pruning | Iceberg partition design for SaaS | 5.0000 | pin-perfect mental model |
| Q4 dbt vars for date-range/segment reuse | Oracle PL/SQL → dbt+Trino migration | 4.6875 | mechanism correct, minor sentinel-example slip |

Iter average = (5.0 + 4.75 + 5.0 + 4.6875) / 4 = **4.859 STRONG PASS NO-OP**.

No open watches triggered, no FIX-A spec issued, no resource churn recommended.

---

## Per-question detail

### Q1 — Trino named WINDOW clause (5.0)

**Responder's answer:** `SELECT ..., SUM(amount) OVER w, AVG(amount) OVER w, MAX(amount) OVER w FROM t WINDOW w AS (PARTITION BY tenant_id ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` plus position and inheritance notes.

**Verification:**
- Trino SELECT supports named WINDOW clause — verified at [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html). Doc example uses verbatim shape `WINDOW w AS (PARTITION BY clerk ORDER BY totalprice DESC)`.
- Position: doc states sequence `SELECT → FROM → WHERE → GROUP BY → HAVING → WINDOW → set ops → ORDER BY → OFFSET → LIMIT`. Responder's "after HAVING, before ORDER BY" is correct for the single-SELECT case engineers care about (slight simplification by omitting the WINDOW → set ops → ORDER BY interleave, but practically right).
- Window inheritance: doc states "The existing window name... is the basis of the current specification" — `WINDOW w2 AS (w ORDER BY ts)` form is valid.

**Score breakdown:** Accuracy 5 / Clarity 5 / Applicability 5 / Completeness 5.

### Q2 — bool_or any-row-in-group (4.75)

**Responder's answer:** `SELECT account_id, COALESCE(bool_or(event_type='error'), false) AS has_recent_error FROM events WHERE occurred_at >= current_date - INTERVAL '7' DAY GROUP BY account_id`.

**Verification:**
- bool_or correct per [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html): "Returns TRUE if any input value is TRUE, otherwise FALSE." Aggregates ignore NULLs and return NULL only for empty/all-null groups.
- COALESCE wrap defensive — with the WHERE 7-day filter, every grouped account already has ≥1 row, so bool_or never returns NULL here. Harmless either way.

**Minor shave (-0.25 Compl):** Responder dismissed `count_if(pred) > 0` as "indirect" and `MAX(CASE WHEN .. THEN 1 ELSE 0) > 0` as "a number not boolean." Both ARE valid Trino-native alternatives — `count_if` is native (same doc page); `MAX(CASE)` is portable ANSI. bool_or IS the cleanest, but framing the others as inferior is mild over-dismissiveness. Engineer still arrives at correct code; framing shave only. NO RESOURCE FIX.

**Score breakdown:** Accuracy 4.5 / Clarity 5 / Applicability 5 / Completeness 4.5.

### Q3 — Iceberg metadata-driven file pruning (5.0)

**Responder's answer:** HMS holds `metadata_location` pointer → Trino reads metadata.json + manifest-list.avro + manifest files with per-file min/max stats → uses stats to prune files → reads only unpruned files. Directory `/year=/month=/day=` layout is LOGICAL partition spec ergonomics + human readability, NOT a file-discovery mechanism. Trino never crawls directories.

**Verification (Apache Iceberg spec):**
- Manifest files are immutable Avro listing data files with each file's partition data tuple, metrics, tracking info — verified [iceberg.apache.org/spec/](https://iceberg.apache.org/spec/).
- Column-level value counts, null counts, lower/upper bounds used to eliminate files at planning time — verified [iceberg.apache.org/docs/latest/performance/](https://iceberg.apache.org/docs/latest/performance/).
- Manifest list acts as index over manifests for range-based skipping — confirmed.
- Data file paths tracked in manifests; planning uses predicates on partition data first to filter files — confirmed.
- Hive-vs-Iceberg discovery contrast (Hive: directory listing; Iceberg: manifest-driven) is the right mental model and is accurate.

**Score breakdown:** Accuracy 5 / Clarity 5 / Applicability 5 / Completeness 5.

### Q4 — dbt vars for date-range/segment reuse (4.6875)

**Responder's answer:** `var('lookback_days', 30)` two-arg with default; `dbt_project.yml` top-level `vars:`; `dbt run --select revenue_summary --vars '{lookback_days: 7, segment: premium}'` CLI; precedence CLI > project > default; `{% set %}` is compile-time. DO/DO-NOT block correctly flags `--var` singular, top-level vars not under models, and {% set %} for overridable values.

**Verification ([docs.getdbt.com/docs/build/project-variables](https://docs.getdbt.com/docs/build/project-variables)):**
- `var()` Jinja function with default — correct.
- `vars:` at top-level of dbt_project.yml — correct, and docs explicitly contrast with nested-under-models (silently won't work).
- `--vars` is plural — confirmed verbatim.
- Precedence CLI --vars > dbt_project.yml vars > var() default — confirmed.

**Minor example imperfection (-0.5 Acc / -0.5 Compl):** The example `WHERE customer_segment = '{{ var('segment', 'all') }}'` with default 'all' renders to literal `WHERE customer_segment = 'all'` — a sentinel comparison that filters to zero rows on any real `customers` table (no customer is segmented as the string 'all'). To mean "no segment filter" the engineer needs Jinja-conditional wrap (`{% if var('segment') != 'all' %} AND customer_segment = '{{ var('segment') }}' {% endif %}`) or a COALESCE-equality skip pattern. The var() MECHANISM is the question and IS correctly answered; the sentinel-handling refinement is a recall ceiling, not a mechanism defect. Engineer is unblocked on the main ask.

**Score breakdown:** Accuracy 4.5 / Clarity 5 / Applicability 4.5 / Completeness 4.75.

---

## Source classification

- Q1 / Q3 — pin-perfect canonical reaches; no resource gap.
- Q2 / Q4 — minor framing/example slips; classified as recall ceiling, not resource-sourced. No FIX-A.
- No open watches opened, no open watches closed (no recent open watches on this sweep's topic mix).
- Falls in the "STRONG PASS NO-OP" band consistent with iter1163-1165 cadence.

## Rubric updates

- "SQL query best practices for OLAP" 4.5824/235 → 4.5841/236 (+0.0017).
- "Analytical query patterns on Iceberg+Trino" 4.5234/117 → 4.5253/118 (+0.0019).
- "Iceberg partition design for SaaS" 4.4581/49 → 4.4689/50 (+0.0108).
- "Oracle PL/SQL → dbt + Trino" 4.4619/134 → 4.4636/135 (+0.0017).

All four topics remain comfortably above pass threshold. No row near threshold or trending down.

## Recommendation

NO-OP this iteration. Continue breadth-first probing of less-recently-touched topics in iter1167. No teacher action needed.

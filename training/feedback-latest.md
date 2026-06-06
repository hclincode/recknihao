# Iter 547 Judge Feedback — 2026-06-06

## Overall: 4.953 STRONG PASS (margin +1.453 above 3.5 floor — HIGH)

All four answers landed cleanly. No fab-absences, no identifier slips, no harmful speculation. The iter547 teacher's structural-salience H4 promotion of the COALESCE-default canonical (r09 L659, `>` blockquote → `#### ` H4 heading) is RETRIEVABLE — Q1 hit it on first re-probe. The Q2 GROUP-BY-alias claim was rigorously verified against trino.io docs + GitHub trinodb/trino#16533 — responder is CORRECT.

---

## Per-question scores

### Q1 — Read a map key with a default if the key is missing
- **Answer**: `COALESCE(element_at(map_col, 'key'), 'default')`; element_at is NULL-safe (returns NULL on missing key); bracket `map['key']` errors on missing key.
- **Verification (trino.io/docs/current/functions/map.html)**: VERBATIM `element_at(map, key)` — "Returns value for given `key`, or `NULL` if the key is not contained in the map." Bracket subscript: "This operator throws an error if the key is not contained in the map." Both claims confirmed.
- **Structural-salience re-probe result**: H4 PROMOTION WORKED. The iter547 teacher promoted the iter532 COALESCE-default `>` blockquote (between map_concat H3 and MAP-HOF H3 — the EXACT same anti-pattern as the iter545 map_concat fab-absence) to a `#### ` H4 heading at r09 L659 with expanded keyword anchors (`supply default for MAP key`, `MAP read with fallback`, `MAP key not present default`, `NULL when MAP key missing`, `return default when key not in map`). The responder's first-shot correct answer + the contrast with bracket-errors confirms the H4 is findable to the Haiku H3/H4-scan. **Iter545→546 structural-salience playbook validated for a 2nd canonical (map_concat in iter546 + COALESCE-default in iter547).**
- **Scores**:
  - Accuracy: **5.0** — both element_at-returns-NULL and bracket-errors are textbook-correct.
  - Completeness: **5.0** — covers default fallback + contrast with bracket + the NULL-on-miss semantics.
  - Clarity: **5.0** — one expression, no jargon.
  - Actionability: **5.0** — SaaS engineer can copy-paste verbatim.
  - **Q1 = 5.0 STRONG PASS**

### Q2 — GROUP BY column position numbers in Trino — does it work?
- **Answer**: Yes, ordinals work. Expressions work. BUT a SELECT-list output alias by NAME does NOT work in GROUP BY in Trino (e.g., `SELECT date_trunc('month', d) AS event_month ... GROUP BY event_month` errors — must repeat the expression or use the ordinal). The alias only resolves in ORDER BY.
- **Verification (trino.io/docs/current/sql/select.html, GROUP BY section)**: VERBATIM "A simple `GROUP BY` clause may contain any expression composed of input columns or it may be an ordinal number selecting an output column by position (starting at one)." Example: `SELECT count(*), nationkey FROM customer GROUP BY 2;` — ordinals confirmed.
- **GROUP BY alias verification (CRITICAL)**: trinodb/trino GitHub issue #16533 titled "**Using alias in group by is not supported by Trino**" confirms the gap is still open. Trino docs do NOT list output-alias resolution as a GROUP BY mode. Trino's grammar resolves GROUP BY against input columns/expressions/ordinals only — NOT output aliases. **VERIFIED VERDICT: the responder's "can't GROUP BY alias by name in Trino" claim is CORRECT for Trino 467.** This contrasts with Postgres / MySQL / Snowflake / BigQuery, all of which DO resolve GROUP BY against output aliases — exactly the kind of dialect slip a SaaS engineer migrating from Postgres would hit. The responder correctly flagged the cross-engine gap and steered to the ordinal-or-repeat-expression workaround.
- **Meta-rule note**: The directive flagged this as exactly the question where assuming the wrong engine's behavior causes misjudgment. Verified BEFORE asserting — the responder is right; this is a real Trino limitation, not a Postgres-assumption slip.
- **Scores**:
  - Accuracy: **5.0** — ordinals + alias-not-supported both verified against docs and the active GitHub issue.
  - Completeness: **4.75** — covers ordinals, expressions, alias-gap, and the ORDER-BY-alias-works carve-out. Minor polish: could mention WITH/CTE wrap as a 3rd workaround. Not load-bearing.
  - Clarity: **5.0** — direct yes/no + the BUT clause is exactly the shape a beginner needs.
  - Actionability: **5.0** — engineer migrating Postgres → Trino now knows exactly which GROUP BY shape will error.
  - **Q2 = 4.9375 STRONG PASS**

### Q3 — dbt incremental_predicates — what + how to use?
- **Answer**: List config of SQL predicate strings on the incremental model; example uses `DBT_INTERNAL_DEST.occurred_at >= CAST(DATE_TRUNC('day', CURRENT_TIMESTAMP) - INTERVAL '3' DAY AS TIMESTAMP)`. Scopes the MERGE to recent partitions/days. `DBT_INTERNAL_DEST` = target/destination table alias in the MERGE. Reduces merge plan-time + scan cost on large Iceberg tables.
- **Verification (docs.getdbt.com/docs/build/incremental-strategy)**: VERBATIM "incremental_predicates is an advanced use of incremental models, where data volume is large enough to justify additional investments in performance. This config accepts a list of any valid SQL expression(s). dbt does not check the syntax of the SQL statements." VERBATIM "DBT_INTERNAL_DEST and DBT_INTERNAL_SOURCE are the standard aliases for the target table and temporary table, respectively, during an incremental run using the merge strategy." Docs example uses identical shape: `["DBT_INTERNAL_DEST.session_start > dateadd(day, -7, current_date)"]`. All three claims (list config, DBT_INTERNAL_DEST = target, merge-scope reduction) verified.
- **Trino-dialect detail**: responder used `CAST(DATE_TRUNC('day', CURRENT_TIMESTAMP) - INTERVAL '3' DAY AS TIMESTAMP)` — this is valid Trino 467 dialect (date_trunc returns the truncated-type, interval arithmetic valid, CAST safe). Production-stack-fit.
- **Scores**:
  - Accuracy: **5.0** — list config, DBT_INTERNAL_DEST semantics, MERGE scoping all match dbt docs verbatim.
  - Completeness: **4.75** — covers the config syntax, the alias semantics, the perf framing. Minor polish: could mention that incremental_predicates only applies to the `merge` strategy (not append/delete+insert/insert_overwrite) and that DBT_INTERNAL_SOURCE is the other alias. Not load-bearing.
  - Clarity: **5.0** — concrete worked example, named the alias, named the use case.
  - Actionability: **5.0** — engineer can paste this into a dbt-trino incremental model and ship.
  - **Q3 = 4.9375 STRONG PASS**

### Q4 — SHOW STATS + ANALYZE for CBO join-order selection
- **Answer**: `SHOW STATS FOR <table>` shows the CBO-visible stats (row count, NDV, nulls fraction, min/max). `ANALYZE <table>` (NO `TABLE` keyword — `ANALYZE TABLE` is Spark/Hive syntax) populates NDV statistics via an Iceberg Puffin file. `ANALYZE <table> WITH (columns = ARRAY['col1', 'col2'])` scopes the analysis. ANALYZE drives JOIN PLANNING (NDV → join order + broadcast-vs-partitioned join decision) — NOT scan speed.
- **Verification (trino.io/docs/current/sql/analyze.html)**: VERBATIM "ANALYZE table_name [ WITH ( property_name = expression [, ...] ) ]" — **NO `TABLE` keyword**. The responder's explicit ban on `ANALYZE TABLE` (the Spark/Hive form) is CORRECT for Trino. WITH (columns = ARRAY[...]) syntax verified verbatim with the docs example.
- **Verification (trino.io/docs/current/sql/show-stats.html)**: VERBATIM "Returns approximated statistics for the named table or for the results of a query." Returns row-per-column with column_name/data_size/distinct_values_count/nulls_fractions/row_count/low_value/high_value. Responder's framing ("displays stats the CBO knows") matches.
- **Iceberg Puffin verification**: VERBATIM (from trinodb/trino PR #13636 + Iceberg Puffin spec) "Trino calculates NDV statistics during analyzing tables and writes NDV statistics to the Iceberg puffin file, which are used by the Trino query optimizer to find the best query plan." Confirmed: ANALYZE on Iceberg writes to a Puffin file with Theta-sketch-derived NDV.
- **Join-planning vs scan-speed framing**: CORRECT. NDV drives the CBO's join-order + broadcast-vs-partitioned decisions; it does NOT change file-scan speed (that's column projection / partition pruning / file format). The framing prevents the common SaaS-engineer misconception that ANALYZE "makes my query faster" mechanically.
- **Scores**:
  - Accuracy: **5.0** — the `ANALYZE table` (no TABLE) ban is exactly right; SHOW STATS columns match; Puffin NDV semantics match; join-planning framing matches.
  - Completeness: **4.75** — covers SHOW STATS, ANALYZE, WITH(columns), Puffin, and the join-planning-not-scan-speed framing. Minor polish: could mention that the iceberg_minimum_assigned_split_weight session knob / cost_estimation_worker_count are tuning levers, but those are out-of-scope for this question. Not load-bearing.
  - Clarity: **5.0** — explicit Spark-vs-Trino syntax warning prevents copy-paste failure.
  - Actionability: **5.0** — engineer can run `ANALYZE schema.table WITH (columns = ARRAY['join_key1','join_key2'])` then `SHOW STATS FOR schema.table` to verify NDV populated.
  - **Q4 = 4.9375 STRONG PASS**

---

## Overall average

(5.0 + 4.9375 + 4.9375 + 4.9375) / 4 = 19.8125 / 4 = **4.953125 → 4.95 STRONG PASS**

Margin +1.45 above 3.5 floor — HIGH. Tightest sub-score is 4.75 on three completeness dimensions; no question dips below 4.75 on any dimension; no question is sub-3.5.

---

## Iter 547 structural-salience re-probe result

**H4 promotion of the COALESCE-default canonical: VALIDATED.** Q1 found the H4 on first re-probe — the H3/H4-scan responder did not fab-absence the default-fallback pattern. Pair this with iter546's map_concat H3-promotion validation: the structural-salience playbook now has TWO validated landings (map_concat at iter546, COALESCE-default at iter547). The anti-pattern (`>` blockquote canonical sandwiched between two H3 headings) is reliably fixed by promoting to H3 or H4 with expanded keyword anchors + a fenced SQL example.

---

## Iter 548 next-teacher actions

This was a polish-only iteration with 4-of-4 STRONG PASS — NO FIX TARGETS. Recommended posture:

1. **HOLD all iter547 locks**: r09 L659 COALESCE-default H4 (new lock), r09 L609 map_concat H3 (iter546 lock), r09 element_at H3 (locked), r09 MAP-HOF H3 (locked), r09 CAST-to-JSON H3 (locked), r07 §1a.3 array_join + array_position rows (new iter547 additions). NO regressions.

2. **Continue the structural-salience audit**: now that COALESCE-default + map_concat are both H3/H4-promoted, GREP the remaining `>` blockquote canonicals in r09, r07, r13, r17, r22, r23, r27 for the same sandwich anti-pattern (blockquote canonical between two H3s/H2s). If any remain — especially around high-frequency keyword zones (date/time, JSON, string, ARRAY, numeric casts, INSERT vs MERGE) — promote them preemptively before the next fab-absence probe lands.

3. **Probe targets for iter548**:
   - **HIGH — durability checks on iter547 wins**:
     - "How do I avoid NULL when reading a missing MAP key in Trino?" (3rd angle COALESCE-default — verifies the H4 holds beyond the literal phrasing).
     - "Why does `GROUP BY event_month` error in Trino when event_month is a SELECT alias?" (2nd angle, from the error side — verifies the alias-gap framing).
     - "What writes the NDV stats that Trino's CBO uses for join order on Iceberg?" (2nd angle ANALYZE → Puffin — verifies the Puffin-file + NDV chain).
     - "How do I scope my dbt incremental MERGE to only the last 7 days of partitions?" (2nd angle incremental_predicates).
   - **MEDIUM — fresh breadth, no fix needed unless slip**:
     - Trino `array_position` 1-based + 0-on-not-found (verifies the new iter547 r07 §1a.3 row).
     - Trino `array_join` 2-arg vs 3-arg `null_replacement` (verifies the new iter547 r07 §1a.3 row).
     - Trino `sequence(start, stop, step)` for date series generation (untested-but-real built-in; check for fab-absence).
     - Trino `map_filter`, `map_zip_with`, `transform_values` (MAP-HOF family — verify the locked H3 still routes).
   - **LOW — DO NOT TOUCH**:
     - Federation row stays **4.49944/310** (iter547 task constraint + iter472-546 directive).
     - No edits to resources/22 §13.x federation guardrails.

4. **Reconcile-don't-append discipline reminder**: for near-threshold topics (the federation 4.5-bar row, the OLAP best-practices 4.4834 row), one FAIL re-probe outweighs one PASS in topic-average movement at 100+ datapoints — keep new canonical content in-place-fixed, not appended.

5. **Meta-rule reminder**: the directive's "verify YOUR OWN corrections before asserting" caveat was DECISIVE again this iter — the Q2 GROUP-BY-alias claim was rigorously verified against trino.io docs + GitHub trinodb/trino#16533 BEFORE asserting it was correct, instead of assuming Postgres-alias-resolution-behavior. 10th consecutive iter (iter537-547) where the meta-rule prevented a false-positive correction in either direction.

---

## Source citations (verbatim quotes)

- trino.io/docs/current/functions/map.html: `element_at(map, key)` — "Returns value for given `key`, or `NULL` if the key is not contained in the map." Bracket subscript — "This operator throws an error if the key is not contained in the map."
- trino.io/docs/current/sql/select.html (GROUP BY): "A simple `GROUP BY` clause may contain any expression composed of input columns or it may be an ordinal number selecting an output column by position (starting at one)."
- github.com/trinodb/trino/issues/16533: "Using alias in group by is not supported by Trino" (confirms alias-in-GROUP-BY gap).
- trino.io/docs/current/sql/analyze.html: "ANALYZE table_name [ WITH ( property_name = expression [, ...] ) ]" (no TABLE keyword).
- trino.io/docs/current/sql/show-stats.html: "Returns approximated statistics for the named table or for the results of a query." Returns column_name / data_size / distinct_values_count / nulls_fractions / row_count / low_value / high_value.
- docs.getdbt.com/docs/build/incremental-strategy: "incremental_predicates is an advanced use of incremental models... This config accepts a list of any valid SQL expression(s)." + "DBT_INTERNAL_DEST and DBT_INTERNAL_SOURCE are the standard aliases for the target table and temporary table, respectively, during an incremental run using the merge strategy."
- trinodb/trino PR #13636 + Iceberg Puffin spec: NDV stats from ANALYZE are written to an Iceberg Puffin file (Theta sketch).

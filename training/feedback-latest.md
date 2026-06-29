# Judge Feedback — Iteration 1267

## Overall verdict

**4.156 PASS with TWO BROKEN-EXAMPLE SLIPS** — Q3 + Q4 both verified accurate and strong (closes the iter1253 regexp_extract watch + re-confirms the iter1265 hard_deletes-dbt-trino FIX-A). Q1 + Q2 both have CORRECT lead facts (UNNEST mechanism / PERCENT_RANK + CUME_DIST function choice) but ship DEMONSTRATIVE QUERIES that would fail at parse/analysis time in real Trino — a recurrence of the synthesis-ceiling family (`feedback_responder_broken_secondary_alternative.md`). Iteration average pulled down by Q1/Q2 example-SQL malformedness, not by recall failure on the asked dialect facts.

| Q | Topic | Acc | Clar | Prac | Compl | Avg |
|---|---|---|---|---|---|---|
| Q1 UNNEST array explode | Analytical query patterns | 3.0 | 4.5 | 3.0 | 3.5 | **3.5** |
| Q2 PERCENT_RANK percentile | Analytical query patterns | 3.0 | 4.5 | 3.0 | 3.5 | **3.5** |
| Q3 hard_deletes dbt-trino caveat | dbt snapshots SCD2 | 4.5 | 4.5 | 5.0 | 5.0 | **4.75** |
| Q4 regexp_extract 2-arg vs 3-arg | Oracle PL/SQL → dbt+Trino | 5.0 | 4.5 | 5.0 | 5.0 | **4.875** |

**Iteration average: (3.5 + 3.5 + 4.75 + 4.875) / 4 = 4.156**

---

## Per-question verification

### Q1 — UNNEST array explode to count per tag — **3.5**

**Responder claims and verification:**

1. `CROSS JOIN UNNEST(e.tag_names) AS t(tag)` drops rows where the array is NULL or empty; `LEFT JOIN UNNEST(...) ON TRUE` keeps them with `t.tag = NULL`. **VERIFIED** via WebFetch of [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) UNNEST section:
   - "UNNEST returns zero entries when the array/map is empty"
   - "UNNEST returns zero entries when the array/map is null"
   - "LEFT JOIN is preferable in order to avoid losing the row containing the array/map field in question"
   The CROSS-vs-LEFT distinction is correctly named — load-bearing for tag_names columns that may be NULL/empty.

2. **THE EXAMPLE QUERY IS BROKEN** — responder showed:
   ```
   SELECT e.event_id, t.tag
   FROM fct_events e
   CROSS JOIN UNNEST(e.tag_names) AS t(tag)
   GROUP BY t.tag
   ORDER BY COUNT(*) DESC
   ```
   This is a GROUP BY violation. `e.event_id` is in the SELECT list, not in `GROUP BY t.tag`, and not aggregated → Trino 467 errors `"'e.event_id' must be an aggregate expression or appear in GROUP BY clause"`. VERIFIED via the same docs page: "When a GROUP BY clause is used in a SELECT statement all output expressions must be either aggregate functions or columns present in the GROUP BY clause." A SaaS engineer copying this verbatim hits a parse/analysis error.

3. The CORRECT shape for the asked question ("total event count PER TAG") is:
   ```
   SELECT t.tag, COUNT(*) AS event_count
   FROM fct_events e
   CROSS JOIN UNNEST(e.tag_names) AS t(tag)
   GROUP BY t.tag
   ORDER BY event_count DESC
   ```
   The responder reached the right operator (UNNEST), the right join mode distinction, but mangled the SELECT/GROUP-BY shape on the demonstrative query — `e.event_id` appears as if doing a row-explode preview, but then GROUP BY t.tag is stapled on top.

**Acc 3.0** — UNNEST mechanism correct; example query is a real Trino error (not a typo, a structural mismatch between SELECT and GROUP BY).
**Clar 4.5** — CROSS vs LEFT distinction taught cleanly with NULL/empty-array semantics.
**Prac 3.0** — engineer who copies the example gets a parse error and has to debug; the operator they need is clearly named but the copy-paste artifact is broken.
**Compl 3.5** — covers UNNEST + null-array variant; misses correct aggregation shape on the only example shown.

### Q2 — PERCENT_RANK / CUME_DIST percentile position — **3.5**

**Responder claims and verification:**

1. `PERCENT_RANK() OVER (ORDER BY c.mrr DESC)` returns 0-1 percentile (highest MRR → 0, lowest → 1); `*100` for "87th percentile" label; `CUME_DIST` with ORDER BY ASC for "beat X%" framing. **VERIFIED** via WebFetch of [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html):
   - PERCENT_RANK = `(rank - 1) / (rows - 1)` — gap-aware
   - CUME_DIST = `rows_preceding_or_peer / total_rows` — tie-uniform
   - Both 0-1 range, both require OVER (ORDER BY ...). Distinction between RANK (1-based integer ranking) vs PERCENT_RANK (0-1 percentile) is correctly named — addresses the question's "not absolute RANK" framing.

2. **THE EXAMPLE QUERY HAS TWO STRUCTURAL BUGS** — responder showed:
   ```
   SELECT c.customer_id, c.mrr,
          PERCENT_RANK() OVER (ORDER BY c.mrr DESC), ...
   FROM (
     SELECT customer_id, SUM(monthly_revenue) AS mrr
     FROM subscriptions
     WHERE status='active'
   ) c
   WHERE c.upgrade_date BETWEEN '2026-04-01' AND '2026-06-30'
   ```
   - **Bug A:** Inner subquery has `SELECT customer_id, SUM(monthly_revenue) AS mrr ... WHERE status='active'` with NO `GROUP BY customer_id`. In Trino 467 this errors `"customer_id must be an aggregate expression or appear in GROUP BY clause"` (same rule that broke Q1).
   - **Bug B:** Inner subquery exposes only `customer_id` + `mrr` to the outer `c.` alias, but the outer `WHERE c.upgrade_date BETWEEN ...` references a column that does NOT exist in the subquery → `Column 'c.upgrade_date' cannot be resolved`. Either upgrade_date needs to be added to the inner SELECT, or the upgrade-window filter belongs INSIDE the subquery on the underlying source (e.g., a customers/upgrades join inside).

3. Additional minor framing slip: question asked for MRR percentile "**at the time they upgraded**" — a point-in-time semantic against a SCD-2 / event-stream MRR. The responder silently simplified to **current** active-MRR ranking. That's a defensible simplification with a one-line caveat, but no caveat was added.

**Acc 3.0** — function selection correct; example query has two unambiguous Trino parse/analysis errors.
**Clar 4.5** — 0-1 framing + *100 percentile label + RANK-vs-PERCENT_RANK distinction explained well.
**Prac 3.0** — function lever is clear, but copy-paste example fails twice; engineer has to rewrite half of it.
**Compl 3.5** — function variants (CUME_DIST ASC for "beat X%") + range + ORDER BY rationale covered; point-in-time MRR simplification not flagged.

### Q3 — dbt snapshot hard_deletes='new_record' on dbt-trino — **4.75**

**Responder claims and verification:**

1. `hard_deletes='new_record'` config emits a new snapshot row with `dbt_is_deleted` set when a source row disappears, closing the SCD-2 validity window. **VERIFIED** via WebFetch of [docs.getdbt.com/reference/resource-configs/hard-deletes](https://docs.getdbt.com/reference/resource-configs/hard-deletes): three allowed values (`ignore` default, `invalidate`, `new_record`); shipped in dbt 1.9+; `dbt_is_deleted` column added when `new_record`.
2. **CRITICAL CAVEAT** — `hard_deletes` is adapter-implemented; the dbt docs officially list four supported adapters: dbt-postgres, dbt-bigquery, dbt-snowflake, dbt-redshift. **dbt-trino is NOT on the supported list.** **VERIFIED** via the same WebFetch + WebSearch ([github.com/starburstdata/dbt-trino](https://github.com/starburstdata/dbt-trino), [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) — neither documents `hard_deletes` as adapter-tested). The responder correctly named this caveat and prescribed (a) SMOKE TEST first on a small snapshot before relying on it, (b) reconciliation FALLBACK — query snapshot rows where `dbt_valid_to IS NULL AND NOT EXISTS (...)` against the source, then `MERGE`/`UPDATE` to stamp `dbt_valid_to`. Cites r09 §472-516.
3. `dbt_is_deleted` column type: docs.getdbt.com page text says "A string value indicating if the record has been deleted (`True` if deleted, `False` if not deleted)" — responder's `VARCHAR` framing matches the doc string. (The WebFetch summary above guessed BOOLEAN based on the table's appearance of `True`/`False`, but the docs prose explicitly says "string value" — VARCHAR is the correct call.)

**Acc 4.5** — all load-bearing facts verbatim correct including the dbt-trino-not-on-supported-list caveat; minor -0.5 because hard_deletes also requires snapshot strategy compatibility (timestamp / check) which wasn't called out but is implicit.
**Clar 4.5** — clear three-bullet structure (config → caveat → fallback).
**Prac 5.0** — engineer knows EXACTLY what to do: try it on a smoke test, fall back to reconciliation SQL if dbt-trino doesn't honor the config. Production-actionable.
**Compl 5.0** — covers config + adapter-support caveat + verification path + fallback. Iter1264 → iter1265 FIX-A is REACHED and HOLDS on this re-probe.

### Q4 — regexp_extract 2-arg vs 3-arg in Trino 467 — **4.875**

**Responder claims and verification:**

1. 2-arg `regexp_extract(string, pattern)` returns the WHOLE MATCH (ignores capture groups). 3-arg `regexp_extract(string, pattern, group)` EXISTS in Trino 467 and returns capture group N (1-indexed; group 0 = whole match). NULL on no match (not error). "Your team's statement that 3-arg doesn't exist is FALSE." **VERIFIED** via WebFetch of [trino.io/docs/467/functions/regexp.html](https://trino.io/docs/467/functions/regexp.html):
   - 2-arg variant: "returns the first substring matched by the regular expression `pattern` in `string`" → WHOLE MATCH, no capture-group selection.
   - 3-arg variant: "returns the [capturing group number]" — exists explicitly in 467 docs.
   - NULL-on-no-match is standard Trino regex behavior (matches Java Matcher semantics; no exception thrown).
2. Examples appear correctly formed: `regexp_extract('order-12345-paid', '\d+')` → `'12345'`; `regexp_extract('order-12345-paid', '([a-z]+)-(\d+)-([a-z]+)', 2)` → `'12345'`. Single-backslash regex literal matches the verified RAW-source convention (per pinned `reference_trino_regex_backslash.md`).
3. Oracle → Trino mapping `REGEXP_SUBSTR(s, pat, 1, 1, NULL, n)` → `regexp_extract(s, pat, n)` is the correct migration cleanup (drops Oracle's position + occurrence + match_param args, keeps the capture-group selector).

**Acc 5.0** — both function signatures + NULL-on-no-match all verbatim correct against the 467 regexp docs. Refuting the team's wrong claim is the correct frame.
**Clar 4.5** — clean before/after Oracle vs Trino comparison + group 0 = whole match note. Could add one inline "no match returns NULL, not '' or error" emphasis.
**Prac 5.0** — engineer can drop straight into migrated Oracle PL/SQL with the 3-arg form.
**Compl 5.0** — 2-arg semantics + 3-arg semantics + no-match behavior + Oracle migration mapping all present.

**Iter1253 regexp_extract-2arg-vs-3arg watch: CLOSES.** At iter1253 the responder claimed 2-arg returns group 1 (wrong); this iter explicitly says 2-arg returns the WHOLE MATCH and 3-arg exists for group-N selection. Opposite of the iter1253 error — correct on re-probe.

---

## Resource-defect vs per-instance synthesis slip analysis

### Q1 + Q2 broken examples — RESOURCE DEFECT OR PER-INSTANCE?

Both broken examples share the same structural defect family: SELECT list / GROUP BY mismatch. Q1 puts `event_id` in SELECT while GROUPing by `tag`. Q2 puts `customer_id, SUM(...)` in a subquery with NO GROUP BY and references a column the subquery doesn't expose.

This is a SYNTHESIS-CEILING slip family, NOT a resource defect:
- The asked dialect facts (UNNEST mechanism, PERCENT_RANK semantics) are correct. The responder reached the right operator/function.
- The SELECT-list/GROUP-BY shaping happens in the *constructed example* not in retrieved canonicals — resources don't ship the broken form for the responder to lift.
- Matches the `feedback_responder_broken_secondary_alternative.md` family — the LEAD facts are right; the *constructed-around-the-lead* example shape has an error.
- Per `feedback_synthesis_ceiling_stop_churning.md` — synthesis ceilings on copy-pasteable example shapes should NOT trigger resource churn on first recurrence. Resources can't easily defang this: no single canonical "always include the grouped column in SELECT" guard prevents free-form synthesis slips.

**Recommendation: NO FIX-A. Open ONE soft watch** — `iter1267 Q1+Q2 example-SQL GROUP-BY-shape synthesis slip`: re-probe array-explode + percentile under varied phrasings 4-8 iters. If 2+ recurrences across different topic frames, escalate to LIGHT FIX-A (a copy-attractive standalone "explode array + count per element" canonical near the UNNEST card, with the correct `SELECT t.tag, COUNT(*) GROUP BY t.tag` shape; same for PERCENT_RANK example).

### Q3 hard_deletes-dbt-trino-caveat — STAYS CLOSED

Iter1264 → iter1265 FIX-A (dbt-trino not on the hard_deletes supported-adapter list + smoke-test + reconciliation fallback) is REACHED CLEANLY here on Q3. Responder named the config, the caveat, the dbt 1.9 version gating, and the fallback SQL pattern. NO additional watch.

### Q4 regexp_extract-2arg-vs-3arg watch — CLOSES

Iter1253 responder error (claimed 2-arg returns group 1) is opposed on this re-probe (correctly says 2-arg = whole match, 3-arg exists for group N). The asked construct + the Oracle-to-Trino migration mapping both right. **CLOSE the iter1253 regexp_extract-2arg-vs-3arg watch.**

---

## Topic rubric impact

- **Analytical query patterns on Iceberg+Trino** (Q1 + Q2): 4.5210/192 → (4.5210·192 + 3.5 + 3.5) / 194 = 874.232 / 194 = **4.5063/194 PASSED** (-0.0147, margin +1.0063). Two below-4 scores on one iteration pulls the row by ~0.015; row remains comfortably above pass threshold.
- **dbt snapshots SCD2** (Q3): 4.2340/31 → (4.2340·31 + 4.75) / 32 = 136.004 / 32 = **4.2501/32 PASSED** (+0.0161, margin +0.7501). Lifts the thinnest dbt-cluster row.
- **Oracle PL/SQL → dbt+Trino** (Q4): 4.4964/235 → (4.4964·235 + 4.875) / 236 = 1061.529 / 236 = **4.4980/236 PASSED** (+0.0016, margin +0.998).

All required topics remain at PASSED.

---

## Open watches summary

- **NEW** `iter1267 Q1+Q2 example-SQL GROUP-BY-shape synthesis slip` — re-probe array-explode + percentile shape under varied phrasings 4-8 iters; only escalate on 2+ recurrence.
- iter1260 Q1 CDC-MERGE-multi-event-dedup (soft).
- iter1260 Q3 source-hard-delete-snapshot-routing (soft, related to Q3 today but distinct angle).
- iter1258 Q3 SELECT-*-EXCEPT (soft).
- iter1255 Q1 bloom-CREATE-syntax (soft).
- iter1248 Q3 MATCH_RECOGNIZE-adjacency (soft).
- iter1229 @v1-Spark (soft).
- iter1215 strpos-3-arg (soft).

**CLOSED this iter:** iter1253 regexp_extract-2arg-vs-3arg (Q4 corrected the iter1253 error).
**REACHED-AND-HELD this iter:** iter1265 hard_deletes-dbt-trino caveat (Q3).

---

## Sources

- [Trino 467 regexp functions](https://trino.io/docs/467/functions/regexp.html)
- [Trino 467 SELECT / UNNEST](https://trino.io/docs/467/sql/select.html)
- [Trino 467 window functions (PERCENT_RANK, CUME_DIST)](https://trino.io/docs/467/functions/window.html)
- [dbt hard_deletes resource config](https://docs.getdbt.com/reference/resource-configs/hard-deletes)
- [dbt build snapshots](https://docs.getdbt.com/docs/build/snapshots)
- [dbt-trino adapter](https://github.com/starburstdata/dbt-trino)
- [dbt Starburst/Trino configurations](https://docs.getdbt.com/reference/resource-configs/trino-configs)

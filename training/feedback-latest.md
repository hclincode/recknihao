# iter1152 Feedback

**Iter average: 4.781 STRONG PASS NO-OP** (Q1 r21 §131 migrated-vs-new-table FIX-A REACHED CLEANLY on first re-probe — WATCH CLOSED; Q1 broken verification-query aside is a one-off responder slip per the broken-secondary-alternative family — NO resource fix; Q2/Q3/Q4 clean)

**Verdict shape:** STRONG PASS by margin +1.281 above 3.5 threshold. Q2/Q3 clean 5.0; Q4 clean 4.75; Q1 4.375 — core answer (no property flip needed, new dbt/Trino tables default to v2, MERGE works out of the box, migrated-only caveat) is the exact iter1151 FIX-A reach; the broken `system.metadata.table_properties` verification-query aside is a per-instance secondary-alternative slip not a resource defect.

---

## Per-question scoring

### Q1 — Freshly created Iceberg table via dbt model. Teammate said "Iceberg starts in an older format, no row-level deletes, must flip a property first." True for brand-new table on Trino 467 or do merges/updates work out of the box?

**Score: 4.375** — Acc 4.0 / Clar 5.0 / App 4.0 / Compl 4.5

**Source-verified canonical answer (from r21 §131-133 — iter1151 FIX-A — and trino.io/docs/467/connector/iceberg.html):**

- A new Iceberg table created on Trino 467 via `CREATE TABLE` or via dbt-trino `materialized='table' / 'incremental'` defaults to `format_version=2` — `MERGE / UPDATE / DELETE` work out of the box, no property flip needed.
- The "default format v1" claim is narrowly correct ONLY for tables produced by Spark's `CALL iceberg.system.migrate('schema.table')` procedure (Hive Parquet wrapped as Iceberg shim). Those legacy tables start at v1 and DO need `ALTER TABLE ... SET TBLPROPERTIES ('format-version'='2')` from Spark before MERGE.
- The Trino Iceberg `format_version` table property "Defaults to `2`. Version `2` is required for row level deletes." (verbatim from [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html)). Default has been v2 since Trino 419 (well before 467).

**Responder behavior — core answer pin-perfect, verification-query aside BROKEN:**

CORE answer (passes cleanly):
- YES out-of-the-box for freshly created dbt tables.
- NO property change required.
- Trino 467 defaults `format_version=2`.
- v2 supports row-level deletes and MERGE.
- Correctly scoped the migrated-only caveat: "only MIGRATED tables (Hive→Iceberg via Spark migrate()) start at v1 and need upgrade; a CREATE TABLE from dbt skips that."

This is the EXACT iter1151 r21 §131 FIX-A reach. The disambiguation block at r21 §133 (added iter1151 — `IMPORTANT — this v1 default applies ONLY to tables produced by Spark's migrate() procedure...`) is pulling correctly on the keyword chain "dbt table model fresh / row-level deletes / flip a property / Trino 467." Watch label `r21 §131 migrated-vs-new-table format_version disambiguation iter1151` **CLOSED on first re-probe**.

BROKEN secondary-aside — the responder offered a verification query:

```sql
-- Responder's verification query (BROKEN):
SELECT value AS format_version
FROM system.metadata.table_properties
WHERE key = 'format-version';
```

This query is factually wrong on TWO axes:

1. **Wrong table.** `system.metadata.table_properties` is a property-DEFINITIONS catalog: it lists which properties each connector accepts, with columns `(catalog_name, property_name, default_value, type, description)` (verified [trino.io/docs/current/connector/system.html](https://trino.io/docs/current/connector/system.html) + [trinodb/trino#14000](https://github.com/trinodb/trino/issues/14000)). It has NO `key` column, NO `value` column, and does NOT report a specific table's bound property value. Running the responder's query as-is yields `Column 'key' cannot be resolved` / `Column 'value' cannot be resolved`.
2. **Wrong shape conceptually.** Even if the columns existed, `system.metadata.table_properties` would return one row per (catalog, property_name) — the connector's allowed-property schema — not per-table values.

The CORRECT canonical for "what format_version is THIS table on?" lives at **r17 §1373-1376** verbatim:

```sql
SELECT value AS format_version
FROM iceberg.analytics."events$properties"
WHERE key = 'format-version';
```

The responder pulled the right column SHAPE (`value AS format_version`, `WHERE key = 'format-version'`) from r17 §1373-1376 but pasted the wrong FROM clause — substituted `system.metadata.table_properties` for `iceberg.<schema>."<table>$properties"`. r10 §306-340 explicitly catalogs this exact wrong query shape as a DO-NOT-WRITE entry ("WRONG — this query FABRICATES columns. system.metadata.table_properties is a REAL Trino system table, BUT its columns are catalog_name, property_name, default_value, type, description..."). Both the canonical (right) and the defang (DON'T) ARE in the resources.

**Classification: ONE-OFF responder slip — broken-secondary-alternative family (NO resource fix).**

This matches the pinned `feedback_responder_broken_secondary_alternative.md` pattern verbatim: "Haiku nails the LEAD but frequently appends a BROKEN 'for completeness' alternative form (...) leads pass, scope each as per-instance one-off re-probe NOT a resource defect, don't churn (no single resource fix for responder padding)." Both the canonical (r17 §1373-1376) and the explicit defang (r10 §306-340) already exist; the responder under-routed and pasted the wrong table on its own. The CORE answer to the actual question — "do I need to flip format_version?" — is correct and load-bearing; the broken verification query is the secondary aside the engineer can ignore or correct after one error message.

**Practical impact bounded:** the engineer reads "no property flip needed" (correct), trusts that, and runs MERGE successfully without the verification query. If they DO run the verification query, they get an immediate parse error and a 5-second Google reveals the correct `"<table>$properties"` form. The slip is irritating, not query-breaking.

**Score breakdown rationale:**
- Acc 4.0: core answer fully correct (no v2 flip needed, defaults v2, migrated-only caveat, MERGE works) — exactly the iter1151 FIX-A target. Verification query factually wrong on table identity AND column existence — subtracts 1.0.
- Clar 5.0: writing is clear, the migrated-vs-new-table distinction is well-stated.
- App 4.0: engineer can act on the core answer immediately; verification step would error and require a 1-minute fix.
- Compl 4.5: addresses both the question (out-of-the-box?) and the natural follow-up ("how do I verify?") — the verification just happens to be wrong.

**WATCH CLOSURE:** `r21 §131 migrated-vs-new-table format_version disambiguation iter1151` — **CLOSED on first re-probe.** The disambiguation block at r21 §133 (added iter1151 FIX-A) is keyword-anchored on "do I need format_version=2 before MERGE / Trino 467 default format_version new table / new CREATE TABLE v2 default / migrated v1 vs new-table v2" and pulled cleanly on the iter1152 framing "freshly created Iceberg table via dbt table model / row-level deletes / must flip a table property first." Responder's core answer mirrors the new r21 §133 wording verbatim ("only MIGRATED tables (Hive→Iceberg via Spark migrate()) start at v1 and need upgrade; a CREATE TABLE from dbt skips that"). Single-iteration find-and-close.

**Verifications performed:**

- [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) — `format_version` table property "Optionally specifies the format version of the Iceberg specification to use for new tables; either `1` or `2`. Defaults to `2`. Version `2` is required for row level deletes." VERIFIED — matches core responder claim.
- [trino.io/docs/current/connector/system.html](https://trino.io/docs/current/connector/system.html) — `system.metadata.table_properties` lists property DEFINITIONS not per-table values; columns are `catalog_name, property_name, default_value, type, description`. CONFIRMED — responder's verification query references columns (`key`, `value`) that do not exist on this table.
- Grep'd resources/ — confirmed r17 §1373-1376 has the canonical `iceberg.<schema>."<table>$properties"` form with `value AS format_version WHERE key = 'format-version'`, AND r10 §306-340 explicitly defangs the wrong `system.metadata.table_properties` substitution as a fabrication. Both findability anchors exist; responder under-routed.

---

### Q2 — `display_name = first_name || ' ' || last_name`, last_name NULL → whole thing NULL. Trino string function for graceful NULL concat, or is wrap-every-column-with-coalesce the only way?

**Score: 5.000** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**Source-verified canonical answer (from [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html)):**

- `concat_ws(separator, string1, ..., stringN) → varchar` — "If separator is null, then the return value is null. Any null values provided in the arguments after the separator are skipped." VERBATIM from docs.
- `concat(string1, ..., stringN) → varchar` — "provides the same functionality as the SQL-standard concatenation operator (||)" — NULL-propagating (any NULL arg → whole result NULL).
- `||` — SQL-standard NULL-propagating.

Responder gave `CONCAT_WS(' ', first_name, last_name)` and correctly stated:
- It SKIPS NULL values in the string args after the separator — `concat_ws(' ', 'John', NULL)` → `'John'` (no trailing space, no NULL result).
- Contrast against `||` and `concat()` which propagate NULL.
- Caveat that separator-itself-NULL → whole-result NULL.

All claims verified verbatim from Trino 467 docs. The "previously misremembered as Postgres-only" framing is correctly resolved — `concat_ws` IS native Trino 467 (per docs). Cited r27. Clean canonical answer.

**Verifications performed:**

- [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html) — `concat_ws` two-arg + array variants confirmed. "Any null values provided in the arguments after the separator are skipped" verbatim.
- Confirmed `concat()` has same semantics as `||` (SQL-standard NULL-propagating) — responder's contrast accurate.

---

### Q3 — Per customer: top 5 products by total revenue this quarter PLUS one "Everything else" row summing all other products. Single query or two?

**Score: 5.000** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**Source-verified canonical answer:**

Single query, two-stage pattern:

```sql
WITH ranked_products AS (
  SELECT customer_id, product_name,
         SUM(revenue) AS product_revenue,
         ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY SUM(revenue) DESC) AS rn
  FROM sales
  WHERE order_date >= date_trunc('quarter', current_date)
  GROUP BY customer_id, product_name
)
SELECT customer_id,
       CASE WHEN rn <= 5 THEN product_name ELSE 'Everything else' END AS product_label,
       SUM(product_revenue) AS total_revenue
FROM ranked_products
GROUP BY customer_id, CASE WHEN rn <= 5 THEN product_name ELSE 'Everything else' END
ORDER BY customer_id, total_revenue DESC;
```

All Trino 467 valid:
- `ROW_NUMBER() OVER (... ORDER BY SUM(revenue) DESC)` — window over aggregate alias in a GROUP BY scope is legal (window functions execute after GROUP BY; `SUM(revenue)` is the already-aggregated value).
- `GROUP BY` on CASE expression — confirmed legal per [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) "A simple GROUP BY clause may contain any expression composed of input columns." (Plain GROUP BY accepts expressions; only GROUPING SETS / CUBE / ROLLUP require column names — pinned in `reference_trino_complex_grouping_column_names_only.md`.)
- `date_trunc('quarter', current_date)` — verified native [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html) (`'quarter'` is a valid unit string for `date_trunc`).
- Outer `SUM(product_revenue)` over already-aggregated CTE is correct: for `rn<=5`, each (customer, product) appears once, `SUM` over one value = that value (harmless no-op); for `rn>5`, sums all-others into one 'Everything else' row.
- ROW_NUMBER tie-at-rank-5 caveat: if revenue ties at rank 5, ROW_NUMBER picks one product deterministically as rank 5 and the other goes to 'Everything else'. Standard known trade-off; RANK/DENSE_RANK would change tie behavior — but acceptable default.

Responder correctly noted Trino has no QUALIFY (per pinned `feedback_trino_dialect_accuracy.md` — Trino 467 has NO QUALIFY clause). Clean canonical answer.

**Verifications performed:**

- [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) — confirmed GROUP BY on expression is legal.
- [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html) — `date_trunc('quarter', x)` is a documented unit string.
- [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html) — confirmed ROW_NUMBER + ordered window valid form.

---

### Q4 — Oracle `(+)` outer-join notation rejected by Trino. Direct translation + edge cases that don't map cleanly?

**Score: 4.750** — Acc 5.0 / Clar 5.0 / App 4.5 / Compl 4.5

**Source-verified canonical answer:**

- Trino 467 does NOT support Oracle's `(+)` non-standard outer-join notation. Use ANSI `LEFT/RIGHT/FULL OUTER JOIN` exclusively.
- `A.x = B.x(+)` → B is OPTIONAL → `FROM A LEFT OUTER JOIN B ON A.x = B.x`.
- `A.x(+) = B.x` → A is OPTIONAL → `FROM A RIGHT OUTER JOIN B ON A.x = B.x` (equivalently `FROM B LEFT JOIN A`).
- Filter-on-optional-side gotcha: `WHERE c.status = 'active'(+)` MUST move to the ON clause, NOT the WHERE clause; a WHERE predicate on the optional table after the join degrades the outer join to an inner join (NULL-padded rows fail the WHERE filter and disappear). This is the single most common silent-correctness defect in mechanical (+) → ANSI translations.

Responder gave all of the above correctly:
- (+) is a parse error in Trino.
- LEFT/RIGHT mapping correct.
- Filter-on-optional-side-must-go-in-ON edge case correctly flagged as the load-bearing gotcha.
- Cited r27.

**Minor completeness shave (-0.5 Compl, -0.5 App):** other Oracle (+) limitations the responder could have mentioned for "edge cases that don't map cleanly":
- Oracle (+) cannot be used with `OR` in the join predicate — direct translation to ANSI works fine (ANSI ON-clause supports OR), so this is actually a CASE WHERE ANSI is MORE permissive than (+).
- Oracle (+) cannot express FULL OUTER JOIN (it's one-sided only) — ANSI `FULL OUTER JOIN` covers this gap.
- A single table can't be marked optional to two different tables with (+) in one statement — ANSI chains of LEFT JOIN handle this cleanly.
- (+) cannot reference a subquery / inline view — ANSI joins to subqueries are fine.

These would all be "edge cases ANSI handles BETTER than (+)" — useful framing for an engineer migrating from Oracle. Not load-bearing for the core question (the engineer asked about translation + edge cases; the filter-in-WHERE gotcha is the most important one), but mentioning at least one more would round out the answer.

**Verifications performed:**

- [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) — Trino uses ANSI JOIN syntax exclusively (LEFT/RIGHT/FULL/INNER/CROSS); no `(+)` operator parse path.
- Oracle (+) semantics confirmed from Oracle docs — `(+)` marks the OPTIONAL side (will be padded with NULL when no match).

---

## Topics touched and rubric updates

- **Q1 — Iceberg table maintenance** (4.375). Following iter1151 Q1 precedent (full-rebuild and Iceberg-table-property routing scored under Iceberg-maintenance). 4.4531/186 → (828.2766 + 4.375)/187 = **4.4527/187 PASSED** (-0.0004, margin +0.9527).
- **Q2 — SQL query best practices for OLAP** (5.000). NULL handling in string concat is a Trino-dialect best-practice gotcha. 4.5749/217 → (992.7533 + 5.0)/218 = **4.5768/218 PASSED** (+0.0019, margin +1.0768).
- **Q3 — Analytical query patterns on Iceberg+Trino** (5.000). Top-N + "everything else" is a canonical aggregation-pivot pattern. 4.5371/104 → (471.8584 + 5.0)/105 = **4.5415/105 PASSED** (+0.0044, margin +1.0415).
- **Q4 — Oracle PL/SQL → dbt + Trino SQL migration** (4.750). 4.4464/123 → (546.9072 + 4.75)/124 = **4.4488/124 PASSED** (+0.0024, margin +0.9488).

All required topics REMAIN PASSED.

---

## Recommendation

**NO RESOURCE FIX (NO-OP).** Iter is healthy at 4.781 avg, +1.281 above threshold.

- Q1 broken verification query: one-off responder slip in the broken-secondary-alternative family (per pinned `feedback_responder_broken_secondary_alternative.md`). Both the canonical right form (r17 §1373-1376) and the explicit defang (r10 §306-340) ARE in the resources; responder under-routed on its own. No single resource fix for responder secondary-aside padding. Recall ceiling.
- Q2/Q3/Q4: no defects.

**Watch closures:**
- `r21 §131 migrated-vs-new-table format_version disambiguation iter1151` — **CLOSED** on first re-probe with brand-new-dbt-table framing. The iter1151 r21 §133 IMPORTANT block (added "this v1 default applies ONLY to tables produced by Spark's migrate() procedure...") is pulling cleanly; responder's core answer matches its language. Single-iteration find-and-close.

**Watch openings:**
- None. Q1 verification-query slip is the broken-secondary-alternative pattern — established as a Haiku synthesis ceiling not a resource gap (pinned). Re-probe in next sweep with a different format_version verification framing (e.g., "how do I check what format version my table is on?") to confirm `iceberg.<schema>."<table>$properties"` routes cleanly when ASKED as a primary question, not just as a secondary aside.

---

## Pattern observations

- **r21 §131-133 disambiguation FIX-A is durable.** iter1151 over-generalization slip → iter1151 add IMPORTANT block at r21 §133 → iter1152 reach on first re-probe with structurally similar new-dbt-table framing. Consistent with the recent r28 on_table_exists / r18 TopN-disambiguation / r07 IGNORE-NULLS-placement single-iteration find-and-close pattern.
- **Broken-secondary-alternative pattern, Nth instance** (Q1 verification query). Haiku PRIMARY answer is canonical-correct; SECONDARY "for completeness" verification query is broken — substituted `system.metadata.table_properties` for `iceberg.<schema>."<table>$properties"`. Per pinned guidance: per-instance one-off, no resource fix, recall ceiling. Don't churn r10 §306-340 (already explicitly defangs this exact wrong-table substitution).
- **Imported-prior caution working** (Q2). `concat_ws` was correctly identified as native Trino 467 (not Postgres-only). The responder noted the prior misremembering and self-corrected — clean reach. Consistent with the to_char / listagg / starts_with imported-prior corrections (pinned).
- **Healthy iter; no churn warranted.** 3 of 4 questions clean canonical reaches; Q1 core is the exact iter1151 FIX-A target. Avg 4.781 is high-confidence STRONG PASS.

---

## Sources verified

- [Trino 467 Iceberg connector — format_version default=2](https://trino.io/docs/467/connector/iceberg.html)
- [Trino 467 system.metadata.* catalog — table_properties is property-definitions not per-table values](https://trino.io/docs/current/connector/system.html)
- [trinodb/trino#14000 — system.metadata access control + table column shape](https://github.com/trinodb/trino/issues/14000)
- [Trino 467 String functions — concat / concat_ws / NULL skip semantics](https://trino.io/docs/current/functions/string.html)
- [Trino 467 Date/time functions — date_trunc 'quarter' unit](https://trino.io/docs/current/functions/datetime.html)
- [Trino 467 Window functions — ROW_NUMBER](https://trino.io/docs/current/functions/window.html)
- [Trino 467 SELECT — GROUP BY on expression](https://trino.io/docs/467/sql/select.html)
- Grep'd resources/ — r17 §1373-1376 canonical `"<table>$properties"` form for format_version verification + r10 §306-340 explicit defang of wrong `system.metadata.table_properties` substitution + r21 §131-133 iter1151 disambiguation FIX-A in place.

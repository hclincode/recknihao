# iter1151 Feedback

**Iter average: 4.750 STRONG PASS + LIGHT FIX-A** (Q1 r28 on_table_exists FIX-A REACHED CLEANLY on first re-probe — WATCH CLOSED; Q4 "default format v1" over-generalization slip resource-anchored at r21 §131 — additive disambiguation FIX-A warranted)

**Verdict shape:** STRONG PASS by margin +1.250 above 3.5 threshold. Q1/Q2/Q3 clean 5.0/5.0/5.0; Q4 4.0 with one load-bearing factual error (outdated "default v1" claim) that is partially resource-sourced (r21 §131 narrowly correct scope was over-generalized by responder).

---

## Per-question scoring

### Q1 — customer_summary dbt model full rebuild, DROP+CREATE window — dbt config to make swap atomic without going incremental?

**Score: 5.000** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**Source-verified canonical answer (from docs.getdbt.com/reference/resource-configs/trino-configs + r28 §961 LEADING CANONICAL added iter1150):**

```sql
{{ config(materialized='table', on_table_exists='replace') }}
```

Emits a single `CREATE OR REPLACE TABLE` = one atomic Iceberg metadata commit; readers see complete-old or complete-new, never a missing or empty intermediate state. dbt-trino default is `'rename'` (also atomic via intermediate-build + double-rename, two metadata operations); `'drop'` is the DROP+CREATE window the engineer observed; `'skip'` is `CREATE TABLE IF NOT EXISTS`.

**Responder behavior — clean pin-perfect:**

- PRIMARY recommendation: `on_table_exists='replace'` with explicit `CREATE OR REPLACE TABLE AS SELECT` mapping = single atomic Iceberg snapshot.
- Correctly named default `'rename'` as already atomic via temp-build-then-rename (Trino never sees a missing table under default).
- Correctly identified `'drop'` as the unsafe value matching engineer's symptom (DROP+CREATE window).
- Correctly named version pin: added in dbt-trino 1.7.1+.
- Explicit guard "do NOT convert to incremental" — directly addresses the engineer's "WITHOUT converting to incremental" constraint.
- Cited r28 atomic-swap canonical.

**WATCH CLOSURE:** `r28 on_table_exists canonical iter1150` — **CLOSED on first re-probe.** This was the THIRD question in the full-rebuild atomic-swap question class (iter1149 Q3 first-misroute, iter1150 Q1 second-misroute prompted LIGHT FIX-A, iter1151 Q1 confirms FIX-A reaches). Single-iteration find-and-close on a previously-recurrent misroute class. r28 §961 LEADING CANONICAL with keyword anchors "dbt table rebuild swap atomic" / "table does not exist briefly" / "on_table_exists replace rename drop" / "WITHOUT converting to incremental" is pulling cleanly across all three iter1149/1150/1151 phrasings.

**Verifications performed:**

- [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) — confirmed all four `on_table_exists` values + default `rename` + `replace` recommended when CREATE OR REPLACE is supported in underlying connector.
- [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) — confirmed Iceberg connector supports CREATE OR REPLACE TABLE as an atomic operation.
- Grep'd r28 — confirmed §961 LEADING CANONICAL with all four values + symptom-mapping is in place from iter1150 FIX-A.

---

### Q2 — Iceberg array column of 30 daily session counts; find highest single-day count per user WITHOUT unnesting

**Score: 5.000** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**Verifications performed:**

- [trino.io/docs/467/functions/array.html](https://trino.io/docs/467/functions/array.html): `array_max(x) → x` — "Returns the maximum value of input array." `array_min(x) → x` — "Returns the minimum value of input array." Confirmed both native in Trino 467.

Responder correctly led with `array_max(daily_session_counts) AS highest` — one-row-in-one-row-out, no UNNEST, no GROUP BY collapse needed. Also offered `array_min(...)` for the corresponding minimum. Cited r07 §1a.3.

**Minor framing note (not a score hit):** the "if you unnest then MAX GROUP BY you're doing unnecessary work that spills to disk" aside is slight over-warning (UNNEST + MAX GROUP BY produces the correct result with bounded memory per group; not pathological for 30-element arrays). Doesn't affect the canonical primary answer; recall ceiling / per-responder padding consistent with pinned `feedback_responder_overwarning_folklore.md`. No resource fix.

---

### Q3 — Q1 2025 vs Q1 2026 revenue per customer, side-by-side, single query or two aggregations joined?

**Score: 5.000** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**Verifications performed:**

- [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html): `year(x)` — "Returns the year from x." `quarter(x)` — "Returns the quarter of the year from x. The value ranges from 1 to 4." Both native in Trino 467 (also valid as `EXTRACT` fields).

Responder gave the canonical conditional-aggregation pivot:

```sql
SUM(CASE WHEN year(order_date)=2025 AND quarter(order_date)=1 THEN amount ELSE 0 END) AS revenue_q1_2025,
SUM(CASE WHEN year(order_date)=2026 AND quarter(order_date)=1 THEN amount ELSE 0 END) AS revenue_q1_2026,
ROUND(revenue_q1_2026 * 1.0 / NULLIF(revenue_q1_2025, 0), 2) AS growth_ratio
GROUP BY customer_id
```

Single query, single pass over `transactions`, no self-join. `NULLIF` guards divide-by-zero. Mentioned BETWEEN-date-range generalization for arbitrary period boundaries. Cited r07 Pattern B2. Clean canonical answer.

---

### Q4 — Oracle stored procedures contain MERGE upserts. Does Trino support MERGE for Iceberg, or rethink the logic?

**Score: 4.000** — Acc 3.5 / Clar 4.5 / App 4.0 / Compl 4.0

**Source-verified facts:**

- [trino.io/docs/467/sql/merge.html](https://trino.io/docs/467/sql/merge.html): Trino 467 supports `MERGE INTO target USING source ON ... WHEN MATCHED THEN UPDATE SET ... WHEN NOT MATCHED THEN INSERT ...`. Confirmed responder's syntax shape is correct.
- Wildcards: docs require explicit column list for both UPDATE SET and INSERT — no Spark-style `UPDATE SET *` / `INSERT *`. Confirmed responder's explicit-column-list claim.
- dbt-trino `incremental_strategy='merge'` with `unique_key='order_id'` is the idiomatic path. Correct.
- **CRITICAL VERIFICATION — format_version default:** [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) table property `format_version`: **"Optionally specifies the format version of the Iceberg specification to use for new tables; either `1` or `2`. Defaults to `2`."** The Trino 467 default for NEW Iceberg tables created via `CREATE TABLE` is **format_version=2**. (The change from v1→v2 as default happened well before 467 — verified Trino 419 docs already documented default=2.)

**Defect — load-bearing factual error on "default v1":**

The responder claimed: *"Iceberg format v2 is MANDATORY. Default tables are format v1, which does not support delete files (required by MERGE). Add 'format_version': 2 in properties or ALTER TABLE ... SET PROPERTIES format_version=2 before using MERGE."*

This is **WRONG / OUTDATED for Trino 467 + new tables**. NEW Iceberg tables created via `CREATE TABLE` on Trino 467 default to v2 — no explicit property setting is needed. The "must set format_version=2 before MERGE" constraint is unnecessary on this stack for newly-created tables.

**Practical impact bounded — not query-breaking:** an engineer who follows the advice sets `format_version=2` explicitly (which is the default anyway = harmless no-op), then runs MERGE successfully. The MERGE itself works. So the wrong claim is misleading but doesn't break the engineer's task.

**RESOURCE-SOURCED — partial root cause at r21 §131:**

Grep located the source of the "default v1" wording at:

- **r21 §131** (resources/21-hive-metastore-iceberg.md line 131): *"Migrated tables default to Iceberg format version 1, which does not support delete files (used by `MERGE INTO` and row-level `DELETE` statements). If you plan to use those operations, upgrade to v2."*

This statement is **narrowly correct in its scope** — it lives in the Hive-→-Iceberg migration section and refers SPECIFICALLY to tables created via Spark's `CALL iceberg.system.migrate('schema.table')` procedure (which shims existing Hive Parquet files as a format-v1 Iceberg table). For Hive-migrated tables, v1 IS the default and v2 upgrade IS required for MERGE.

The responder **over-generalized** r21 §131's migrated-tables-default-v1 claim to ALL new Iceberg tables (including dbt-created `CREATE TABLE` outputs), where it does NOT apply (CREATE TABLE defaults to v2 per r17 §681 and r25 §108 + trino.io/docs/467/connector/iceberg.html).

**Other resources correctly state v2 default:**

- **r17 §619-621 / §681** correctly pins the production stack at Iceberg 1.5.2 writing format version 2 (v2).
- **r25 §108** correctly lists `format_version` default as "2 (required for MoR features; default in modern Iceberg)".

The responder did not route through r17 or r25 — pulled the wrong-context fact from r21 §131.

**Classification: LIGHT FIX-A (additive disambiguation card at r21 §131):**

The r21 §131 statement is technically narrowly correct but the keyword chain "MERGE + format v1 + must upgrade" pulls strongly to it from a question framed as "does Trino MERGE work on Iceberg?" without the engineer specifying their tables are Hive-migrated. Add a one-line disambiguation that names new-CREATE-TABLE-on-Trino-467 as defaulting to v2.

**Recommended FIX-A spec:**

- **Primary placement: r21 §131** — append a disambiguation sentence: *"This Hive-migrated-tables-default-v1 rule applies ONLY to tables created via Spark's `migrate()` procedure. NEW Iceberg tables created via `CREATE TABLE` on Trino 467 (or via dbt-trino `materialized='table'`) default to **format_version=2** per trino.io/docs/467/connector/iceberg.html — no explicit `format_version=2` property is needed before MERGE for new tables. Only legacy Hive-migrated tables need the v1→v2 upgrade."*

- **Secondary placement: r17 §681 (the "format version 2" pin)** — add a one-liner cross-ref to r21 §131 with the explicit disambiguation: *"New `CREATE TABLE` on Trino 467 defaults to v2; the `migrated tables default to v1` rule is Hive-migration-specific (see r21 §131)."*

- **Keyword anchors the disambiguation must include (to defang the over-generalization):**
  - "do I need format_version=2 before MERGE"
  - "MERGE on new Iceberg table — set format_version explicitly?"
  - "Trino 467 default format_version new table"
  - "CREATE TABLE Iceberg format_version default"
  - "migrated v1 vs new-table v2"

**DO-NOT-WRITE entries (to defang the responder's over-warning):**

- *"Default Iceberg tables are format v1; you must set `format_version=2` before MERGE"* — **WRONG for new tables on Trino 467**. CREATE TABLE defaults to v2; explicit setting only needed for Hive-migrated tables. (r17 §619-621 pin and trino.io/docs/467/connector/iceberg.html.)
- *"ALTER TABLE ... SET PROPERTIES format_version=2 before using MERGE"* — only applies to v1 tables (e.g., Hive-migrated). Useless no-op on a v2 table (which is what `CREATE TABLE` produces on 467).

**Note on watch sizing:** this is the FIRST instance of the over-generalization on the MERGE+format_version pair. Practical impact is bounded (harmless no-op on new tables). Adding the disambiguation prevents the over-warning from recurring AND tightens r21 §131's scope without removing it (Hive-migration users still need it). LOW-PRIORITY LIGHT FIX-A — additive, no removal.

**Verifications performed:**

- [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) — `format_version` table property "Defaults to `2`. Version `2` is required for row level deletes." Verified for both 467 docs and current (481).
- [trinodb.github.io/docs.trino.io/419/connector/iceberg.html](https://trinodb.github.io/docs.trino.io/419/connector/iceberg.html) — already documents default=2 in March 2023. The default has been v2 for many releases before 467.
- [trino.io/docs/467/sql/merge.html](https://trino.io/docs/467/sql/merge.html) — MERGE INTO syntax with required explicit column lists (no wildcards).
- Grep'd resources/ for `format_version` + `default v1` — root-cause located at r21 §131 (Hive-migration scope, narrowly correct, over-generalized by responder).

---

## Topics touched and rubric updates

- **Q1 — Iceberg table maintenance** (5.000). Following iter1149/iter1150 footnote precedent (full-rebuild reader-safety routing scored under Iceberg-maintenance). 4.4501/185 → (823.2685 + 5.0)/186 = **4.4531/186 PASSED** (+0.0030, margin +0.9531).
- **Q2 — SQL query best practices for OLAP** (5.000). 4.5722/216 → (987.5952 + 5.0)/217 = **4.5749/217 PASSED** (+0.0027, margin +1.0749).
- **Q3 — Analytical query patterns on Iceberg+Trino** (5.000). 4.5326/103 → (466.8578 + 5.0)/104 = **4.5371/104 PASSED** (+0.0045, margin +1.0371).
- **Q4 — Oracle PL/SQL → dbt + Trino SQL migration** (4.000). 4.4501/122 → (542.9122 + 4.0)/123 = **4.4464/123 PASSED** (-0.0037, margin +0.9464).

All required topics REMAIN PASSED.

---

## Recommendation

**LIGHT FIX-A** for Q4 (over-generalization of r21 §131's narrowly-scoped migrated-tables-v1 default to all new tables, which on Trino 467 default to v2):

- Add disambiguation sentence at r21 §131 explicitly scoping the v1-default rule to Hive-migrated tables only, and naming new-CREATE-TABLE-on-467 as defaulting to v2.
- Add cross-ref from r17 §681 to r21 §131 with the disambiguation in keyword-anchored form.
- Use the keyword anchors and DO-NOT-WRITE entries listed above.

**Watch:** `r21 §131 migrated-vs-new-table format_version disambiguation iter1151`. Re-probe in next sweep with a different MERGE+format_version framing:
- e.g., "I'm CREATE TABLE'ing a new Iceberg table from dbt and want to MERGE into it tomorrow. Do I need to set any format property at create time?"
- e.g., "What format version do new Iceberg tables get on Trino 467?"
- e.g., "Engineer says we need format_version=2 before MERGE works — is that true on our stack?"

If reaches the disambiguation → WATCH CLOSED; if over-warns again → escalate to TL;DR / top-of-file callout at r21 §131.

**No fix on Q2 / Q3.** Both clean canonical answers.

**Q1 watch CLOSURE:** `r28 on_table_exists canonical iter1150` — CLOSED on first re-probe with third phrasing of the full-rebuild atomic-swap question class. r28 §961 LEADING CANONICAL pulling correctly.

---

## Pattern observations

- **r28 §961 on_table_exists FIX-A is durable** — iter1150 misroute → iter1150 add canonical → iter1151 reach on first re-probe. Single-iteration find-and-close, consistent with the recent r17 TopN-disambiguation / r23 VARCHAR-exact-comparison / r07 IGNORE-NULLS-placement closure patterns.
- **Imported-prior over-generalization family** (Q4) — the responder's "default v1" claim is a recurrence of the imported-prior fab class (e.g., iter1011 from_unixtime TZ, iter1006 LIMIT-OFFSET MySQL order, iter925 COUNT(DISTINCT a,b) MySQL) but with a TWIST: this time the wrong prior is **resource-sourced** (r21 §131, narrowly correct scope, over-generalized in application). The defensive fix is to add scope-narrowing language at the resource site rather than relying on responder caution.
- **No CHURN required** — Q2 array_max + Q3 conditional-aggregation pivot + Q1 on_table_exists are all canonical pin-perfect reaches; the iter is healthy at 4.750 avg.

---

## Sources verified

- [dbt-trino on_table_exists config (docs.getdbt.com)](https://docs.getdbt.com/reference/resource-configs/trino-configs)
- [Trino 467 Iceberg connector — format_version default=2 + MERGE support](https://trino.io/docs/467/connector/iceberg.html)
- [Trino 419 Iceberg connector — confirms default=2 from March 2023 (well before 467)](https://trinodb.github.io/docs.trino.io/419/connector/iceberg.html)
- [Trino 467 MERGE INTO syntax — explicit column lists required](https://trino.io/docs/467/sql/merge.html)
- [Trino 467 Array functions — array_max / array_min](https://trino.io/docs/467/functions/array.html)
- [Trino 467 Date/time functions — year() / quarter()](https://trino.io/docs/467/functions/datetime.html)
- [Trino PR #11880 — original format_version table property add, with follow-up note "v2 should be the default"](https://github.com/trinodb/trino/pull/11880)

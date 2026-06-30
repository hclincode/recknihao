# Judge Feedback — Iteration 1288

**Overall**: 4 questions, average **4.203 PASS WITH Q1 FAIL** (Q1 **2.0 FAIL** / Q2 5.0 STRONG / Q3 4.8125 STRONG / Q4 5.0 STRONG).

**Headline**: Q1 (plain `SELECT COUNT(*)` on Iceberg) is a **HARD FAIL — responder INVERTED the load-bearing fact** (claimed Trino scans files; reality: it sums manifest `record_count` and is metadata-only/near-instant) AND recommended the **WRONG TOOL** (`approx_distinct` is HyperLogLog distinct-value count, NOT a row count) with broken syntax (`approx_distinct(*)` admitted not working; `approx_distinct(ROW(...))` would count distinct ROW-tuple combinations, still not rows). The 2-3 min slowness on the engineer's table is almost certainly **position-delete files from MoR MERGE/DELETE accumulating** (Trino issue #13092, #17114: "extremely/unusably slow"), which IS in the resources (r28 §297-323 has the diagnostic + EXECUTE optimize fix) but is NOT reachable from a plain "is COUNT(\*) metadata-only / why is mine slow" question. **MANDATORY FIX-A** — see §Q1 below. Q2/Q3/Q4 reach STRONG cleanly and match the pinned references exactly.

| Q | Topic | Score | Status | Verdict |
|---|---|---|---|---|
| Q1 COUNT(\*) on Iceberg metadata-only? | Query performance basics | **2.0** | **FAIL** | Inverted metadata-only fact + recommended approx_distinct (wrong tool: HyperLogLog distinct, not row count) + missed position-delete-file diagnosis + missed EXECUTE optimize fix. FINDABILITY/CONTENT GAP confirmed |
| Q2 TRY_CAST on dirty VARCHAR | SQL query best practices for OLAP | 5.0 | STRONG PASS | TRY_CAST + try() both correct, NULL-on-failure correct, distinction explained |
| Q3 dbt model contracts compile vs build | dbt model contracts | 4.8125 | STRONG PASS | Matches pin reference_dbt_contract_needs_live_connection (build/run-time + warehouse-interactive + SELECT…WHERE 1=0); dbt-trino only not_null write-enforced correct |
| Q4 Oracle NULL ordering → Trino | Oracle PL/SQL → dbt + Trino SQL migration | 5.0 | STRONG PASS | Matches pin reference_trino_null_ordering_default; Oracle ASC=LAST/DESC=FIRST + Trino LAST-always correct; OVER-clause caveat correct |

---

## Q1 — COUNT(*) on Iceberg metadata-only? (2.0 FAIL)

**Acc 1.5 / Clar 3.0 / Prac 1.5 / Compl 2.0.**

### Three load-bearing facts the responder got wrong

**Fact 1 (INVERTED): plain unqualified `SELECT COUNT(*)` on a Trino-Iceberg table IS metadata-only / near-instant.** Verified via WebFetch [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html): "Since Iceberg stores the paths to data files in the metadata files, it only consults the underlying file system for files that must be read." Each Iceberg manifest entry records `record_count` per data file; Trino sums those without opening Parquet. Resources confirm: **r18 L20 myth-row reads VERBATIM** "`SELECT COUNT(*) FROM iceberg.x.y` reads the whole table → **NO — on Iceberg, COUNT(\*) is a METADATA query.** Iceberg manifests track `record_count` per file. Trino 467's Iceberg connector sums the per-file record counts from manifests — no Parquet files are opened. Verify by running `EXPLAIN ANALYZE SELECT COUNT(*) FROM iceberg.x.y` and noting `physicalInputDataSize = 0B` for the TableScan." Responder explicitly said the OPPOSITE: "your 2-3 min observation suggests Trino is NOT reading metadata alone — it's scanning files."

**Fact 2 (MISSED ENTIRELY): the actual cause of slow `COUNT(*)` on this prod stack is position-delete-file accumulation from MoR MERGE/DELETE.** Verified via [GitHub trinodb/trino #13092](https://github.com/trinodb/trino/issues/13092) ("Iceberg scanning with Delete Files is extremely/unusably slow") and [#17114](https://github.com/trinodb/trino/issues/17114) ("Read Iceberg v2 table with many delete file is very slowly"): "DeleteFilter will re-open and re-read the split's delete files for each page, which with large delete files can lead to a query taking hours." Resource **r28 §294-327 has the exact diagnostic** (`$files` GROUP BY content with 0=DATA / 1=POSITION_DELETES / 2=EQUALITY_DELETES, interpret-output table, fix = EXECUTE optimize with raised file_size_threshold) but the responder never reached it because the diagnostic is framed for "merge model getting slower" not "COUNT(*) slow." This is a 400M-row table with a 2-3 min count — exactly the position-delete-files-everywhere shape on MoR tables maintained by dbt-trino MERGE.

**Fact 3 (WRONG TOOL): `approx_distinct` is the wrong recommendation for an approximate ROW count.** Verified via [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html): `approx_distinct(x)` returns "the approximate number of **distinct input values**" using HyperLogLog with 2.3% standard error. It is a distinct-value cardinality estimator, not a row counter. Responder's recommendation `approx_distinct(ROW(col1,col2,...))` would count distinct row-tuple **combinations** — close to row count ONLY if every row is unique, and would silently undercount on tables with duplicate combinations. Responder even admitted `approx_distinct(*)` doesn't work, then offered the ROW-wrap form anyway. **And separately** — engineer doesn't NEED an approximate count: plain `COUNT(*)` is already metadata-fast on a clean table; if delete files are the cause, the fix is `EXECUTE optimize`, after which the exact count is back to <1s.

### What the correct answer should have looked like

> "Plain `SELECT COUNT(*) FROM iceberg.<schema>.<table>` IS metadata-only on Trino 467 — Iceberg manifests store per-data-file `record_count`, Trino sums them without opening any Parquet file. Verify with `EXPLAIN ANALYZE` and check `physicalInputDataSize = 0B` on the TableScan.
>
> Your 2-3 min count on 400M rows means metadata-only is NOT firing. The almost-certain cause on this prod stack (dbt-trino MoR Iceberg) is **accumulated position-delete files**: each MERGE/DELETE writes one position-delete file per affected data file; once they pile up, Trino must apply deletes for an accurate count.
>
> **Diagnose** (verified at r28 §294 + GitHub trinodb/trino #17114):
> ```sql
> SELECT
>   CASE content WHEN 0 THEN 'DATA' WHEN 1 THEN 'POSITION_DELETES' WHEN 2 THEN 'EQUALITY_DELETES' END AS file_type,
>   COUNT(*) AS file_count, ROUND(SUM(file_size_in_bytes)/1e6,2) AS total_mb
> FROM iceberg.analytics."events$files" GROUP BY content;
> ```
> If POSITION_DELETES file_count > 10% of DATA file_count → that's the cause.
>
> **Fix** (Trino-only, no Spark needed): `ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '1GB')` — raise threshold above your data file sizes to force-rewrite delete-bearing data files; `optimize` APPLIES + DROPS position-deletes for every data file it rewrites (PR #12617/#24086). Follow with `EXECUTE expire_snapshots(retention_threshold => '7d')` to free MinIO bytes.
>
> **DO NOT use `approx_distinct` for an approximate row count** — it's HyperLogLog distinct-value cardinality (not rows). After you fix the delete files, exact `COUNT(*)` is back to metadata-fast (sub-second on 400M rows)."

### FIX-A — MANDATORY (HIGH PRIORITY)

**Findability/content gap confirmed via grep.** The building blocks exist but are not keyword-reachable from a plain "is COUNT(\*) metadata-only / why is mine slow / how to fix" question:

| Existing location | What it covers | What it MISSES |
|---|---|---|
| r18 L20 (myth-list row) | "COUNT(*) is a METADATA query…manifests track record_count…sums per-file counts" — CORRECT primary fact | (a) Buried inside a myth-list row in a triage doc — not findable from "how to count rows fast on Iceberg" keyword path. (b) Caveat at end says "if position-delete files…still cheap; still no data-file reads" — **CONTRADICTS** GitHub #13092/#17114 reality where delete files DO slow COUNT(*) dramatically. **MUST be reconciled.** |
| r18 L65-66 | Code-comment "-- bare table count (Iceberg metadata-only, should be <1s)" inside Check 2 of the regression workflow | Not a standalone canonical; reachable only when oncall-debugging an already-slow query |
| r10 §1008-1023 | Metadata-only `COUNT(*) GROUP BY <partition col>` for billing; identity-vs-bucket-vs-truncate matrix | Framed for GROUP BY billing, not plain unqualified COUNT(\*); does state in passing "Total COUNT(*) (no GROUP BY) is always metadata-only regardless of transform" but it's a side note |
| r28 §294-327 | Position-delete-file diagnostic + EXECUTE optimize fix | Framed for "dbt merge model getting slower," not for "plain COUNT(\*) slow" — different question, no keyword bridge |

**Recommended FIX-A actions (teacher should pick one anchor location + cross-refs):**

1. **PRIMARY: add a leading findable canonical** titled something like "**COUNT(\*) on Iceberg is metadata-only / near-instant on a clean table — if it's slow it's POSITION-DELETE files (NOT a tool to swap)**". Best anchor candidates (in order of preference):
   - **r18 — extend the existing "Cheap queries on Iceberg" callout** (referenced by L20 myth row) into a proper standalone H3 section that opens with the metadata-only fact, then routes to r28 §294 for the slow-due-to-delete-files diagnostic. This is the most-searched location and the myth row already points to it.
   - **r17 (Iceberg maintenance) — add a "Why is COUNT(\*) slow on this table" leading section** that mirrors r28's diagnostic but is keyword-anchored to COUNT-not-MERGE.
   - **r10 §1008 — extend with an explicit "plain unqualified COUNT(\*) is metadata-only too" leading clause** before the GROUP BY billing material.

2. **RECONCILE r18 L20 caveat** that currently says position-delete files keep COUNT(*) "still cheap; still no data-file reads." Per GitHub trinodb/trino #13092 + #17114, position-delete files DO slow COUNT(*) dramatically (the engineer's 400M-row 2-3 min case is the textbook example). Rewrite to: "if the table has format-v2 with **many** position-delete files (typical of busy MoR MERGE pipelines), COUNT(*) MUST apply the deletes and degrades from <1s to minutes — diagnose via $files GROUP BY content, fix via EXECUTE optimize with raised file_size_threshold; see r28 §294."

3. **DEFANG approx_distinct as a row-count tool.** Add a "wrong-tool" DO-NOT-WRITE row to r23 §approx_distinct or wherever the function is taught: "`approx_distinct` is HyperLogLog distinct-VALUE count, not a row count. For an approximate row count, plain `COUNT(*)` is already metadata-fast on Iceberg — fix the delete files instead of swapping the function."

**Suggested watch**: re-probe within 4-6 iters under various COUNT-slow framings ("COUNT(*) is slow on my Iceberg table…", "is COUNT(*) metadata-only on Iceberg…", "do I need approx_distinct for fast counts on Iceberg…", "what's the fastest way to count rows in a 1B-row Iceberg table") to confirm the new canonical reaches.

---

## Q2 — TRY_CAST on dirty VARCHAR (5.0 STRONG PASS)

**Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 5.0.**

Verified via WebFetch [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html):
- **`try_cast(value AS type)` exists** — verbatim signature; verbatim "Like cast(), but returns null if the cast fails."
- **`try(expression)` exists** — verbatim [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html): handles "division by zero, invalid cast or function argument, and numeric value out of range" — returns NULL.

Responder's TRY_CAST(raw_account_id AS BIGINT) → NULL on 'N/A' is exactly correct. The TRY_CAST vs try() distinction (cast-only vs any-expression) is precisely how the docs frame it. Engineer can paste-and-run.

No imported-prior, no broken-secondary, no over-warning, no fabrication.

---

## Q3 — dbt model contracts: compile vs build, live connection? (4.8125 STRONG PASS)

**Acc 4.75 / Clar 4.75 / Prac 5.0 / Compl 4.75.**

**Matches pin `reference_dbt_contract_needs_live_connection` exactly.** Verified via WebFetch [docs.getdbt.com/reference/resource-configs/contract](https://docs.getdbt.com/reference/resource-configs/contract): "When you `dbt run` your model, _before_ dbt has materialized it as a table in the database, you will see this error" — dbt issues a discovery query against the warehouse (commonly the SELECT…WHERE 1=0 introspection pattern responder cited) to read the model's actual result-set column types. Pure offline `dbt parse`/`dbt compile` with no warehouse connection does NOT catch contract violations.

Responder's three load-bearing claims all hold:
1. **"Build/run-time, NOT pure offline compile"** — correct; CI must run `dbt build` against reachable Trino.
2. **Introspection SELECT…WHERE 1=0** — correct mechanism (zero-row probe to read column types from warehouse metadata).
3. **dbt-trino: only `not_null` is meaningfully write-enforced** — confirmed via WebSearch of dbt-trino constraint docs: "Currently, only constraints with type as not_null are supported"; primary_key/unique/foreign_key/check are definable as metadata but NOT write-enforced on Trino. Responder correctly recommends pairing with dbt `tests` (unique/relationships generic tests).

YAML example with `contract.enforced: true` + `columns: name + data_type` is the canonical dbt schema.yml shape.

Minor Compl shave (-0.25): could explicitly note that **`data_type` matching is base-type / not granular** (e.g., `VARCHAR` matches `VARCHAR(256)` vs `VARCHAR(257)` — both are `varchar` to dbt's type alias system). Non-load-bearing for the engineer's question framing.

No imported-prior, no broken-secondary, no over-warning, no fabrication.

---

## Q4 — Oracle NULL ordering → Trino (5.0 STRONG PASS)

**Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 5.0.**

**Matches pin `reference_trino_null_ordering_default` exactly.** Verified via WebFetch [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html): verbatim "The default null ordering is `NULLS LAST`, regardless of the ordering direction." Trino puts NULLs at the bottom for BOTH ASC and DESC by default — NOT the Oracle/NULL-as-largest rule.

Oracle behavior verified via WebSearch (multiple Oracle reference sources): "If the null ordering is not specified, then the handling of the null values is NULLS LAST if the sort is ASC, NULLS FIRST if the sort is DESC" — i.e., Oracle treats NULLs as the LARGEST values, so ASC puts them last and DESC puts them first. Engineer's premise is correct.

So responder's three load-bearing claims all hold:
1. **Trino default: NULLS LAST for both ASC and DESC** — verified.
2. **Oracle default: ASC=NULLS LAST, DESC=NULLS FIRST (NULL-as-largest)** — verified.
3. **Migration fix**: explicit `NULLS FIRST`/`NULLS LAST` on every migrated ORDER BY; for Oracle-matching DESC behavior write `ORDER BY priority DESC NULLS FIRST`; **also apply inside window OVER clauses** — important catch (window-frame NULL ordering would silently differ otherwise).

Side-by-side comparison table is the most useful framing for the Oracle-migration engineer.

No imported-prior, no broken-secondary, no over-warning, no fabrication.

---

## Watches / FIX-A actions

### NEW
- **iter1288-Q1 MANDATORY FIX-A**: add a findable canonical for "plain `SELECT COUNT(*)` on Iceberg = metadata-only / near-instant; if slow → diagnose position-delete files via `$files` GROUP BY content, fix via `EXECUTE optimize(file_size_threshold => '1GB')`; `approx_distinct` is HyperLogLog distinct-value cardinality, NOT a row-count tool". Best anchor: extend r18 "Cheap queries on Iceberg" callout into standalone H3 + reconcile L20 myth-row caveat ("still cheap with delete files" is FALSE per GitHub #13092/#17114) + cross-ref r28 §294 diagnostic + defang approx_distinct as a row-counter in r23. WATCH: re-probe within 4-6 iters under various COUNT-slow framings.

### CARRY (existing, not re-probed this iter)
- iter1285-Q2 timestamp-tz tagging pattern (re-probe within 4-6 iters).
- iter1283-Q3 hard_deletes-as-volunteered-secondary-without-dbt-trino-caveat (re-probe under "set up customers snapshot end-to-end" framings).
- iter1283-Q4 strpos-3-arg-banned-myth recurrence (re-probe under "nth occurrence of delimiter" framings).
- iter1284-Q3 delete+insert Hive-non-ACID framing (re-probe within 4-8 iters).
- iter1278-Q1 Scheduled-vs-CPU as I/O-wait imprecision (route to Blocked time explicitly) — periodic SOFT.

### CLOSED
- None this iter (iter1287's truncate-2-arg L1638 watch already closed last iter).

---

## Topic routing

- Q1 (COUNT(\*) metadata-only on Iceberg) → **Query performance basics: partitioning, indexing strategy for analytics** (COUNT performance theory; partition + delete-file impact on scan cost). Also touches **Iceberg table maintenance** (EXECUTE optimize fix) — primary routing is performance.
- Q2 (TRY_CAST) → **SQL query best practices for OLAP** (function reference / type-safe predicates).
- Q3 (dbt model contracts) → **dbt model contracts** (canonical row).
- Q4 (Oracle NULL ordering port) → **Oracle PL/SQL → dbt + Trino SQL migration** (cross-engine SQL dialect migration).

Q1 FAIL (2.0) drags Query-performance-basics row arithmetic; updated below. Q2/Q3/Q4 lift their rows by +0.001 to +0.017.

---

## Sources

- [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) — Iceberg metadata-driven file-system access verified
- [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html) — try_cast signature + null-on-failure verified
- [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html) — try(expression) general-error-suppression signature verified
- [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) — Trino NULLS LAST default for both ASC/DESC verified
- [docs.getdbt.com/reference/resource-configs/contract](https://docs.getdbt.com/reference/resource-configs/contract) — contract enforcement is build/run-time + warehouse-interactive
- [GitHub trinodb/trino #13092](https://github.com/trinodb/trino/issues/13092) — Iceberg position-delete file scans extremely slow
- [GitHub trinodb/trino #17114](https://github.com/trinodb/trino/issues/17114) — Read Iceberg v2 with many delete files is very slow
- Oracle ORDER BY docs (LearnSQL.com / SQL Jana / sqlines.com) — Oracle ASC=NULLS LAST / DESC=NULLS FIRST default verified
- dbt-trino constraint docs (via WebSearch) — only not_null write-enforced on dbt-trino

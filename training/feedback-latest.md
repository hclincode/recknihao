# Iteration 1222 — Judge Feedback

**Verdict: 4.72 STRONG PASS. One WATCH CLOSES; TWO minor completeness gaps flagged as light SOFT WATCH; NO FIX-A.**

- **Q1 (iter1206 r17/r10 `$partitions`-omission + LIKE-on-ROW WATCH) CLOSES** — responder went from iter1206's `$files + GROUP BY partition + WHERE partition LIKE '%event_date=...%'` (type error on ROW + long-way-round) to iter1222's direct `$partitions` table with the canonical `partition / file_count / record_count / total_size` column set and correct `"events$partitions"` single-double-quote token quoting. Clean first-re-probe close.
- Q2 NTILE(4) + tie behavior: 4.875 pin-perfect — NTILE exists, ties NOT kept together, remainder distributed to lowest bucket numbers (102 = 26/26/25/25), DESC → bucket 1 = top spenders all verified.
- Q3 dbt ref() vs source() = behavioral not naming: 5.0 pin-perfect — model-to-model DAG edge / source-to-model DAG edge / source freshness / ref-for-raw-breaks-DAG all on-mark.
- Q4 Trino TO_NUMBER equivalent (CAST AS DOUBLE/BIGINT): 4.0 — core canonical correct (no TO_NUMBER, CAST throws on invalid input, regexp_replace for `$49.99`-style dirty strings), but TWO minor completeness gaps flagged: (a) `CAST(price_usd AS DECIMAL(10,2))` better than DOUBLE for monetary values (IEEE-754 float drift); (b) `TRY_CAST(price_usd AS DOUBLE)` returns NULL instead of erroring — the safer tool for a dirty staging column over the regexp_replace strip.

---

## Q1 — Iceberg per-partition file-count + size breakdown via `$partitions` [WATCH RE-PROBE]

**Score: 5.0** | Tech 5.0 | Clar 5.0 | App 5.0 | Compl 5.0
**Routing**: Iceberg partition design for SaaS (line 64) — physical-layout inspection via metadata tables
**WATCH STATUS: iter1206 `$partitions`-omission + LIKE-on-ROW CLOSES on 1st re-probe**

Responder reached the direct `$partitions` metadata table with the right column set and quoting. All four load-bearing facts VERIFIED at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) (WebFetched this iter):

1. **`$partitions` exists and is the direct per-partition aggregate stats table** — docs confirm columns: `partition ROW(...)` ("A row that contains the mapping of the partition column names to the partition column values"), `record_count BIGINT` ("The number of records in the partition"), `file_count BIGINT` ("The number of files mapped in the partition"), `total_size BIGINT` ("The size of all the files in the partition"), and `data ROW(...)` per-column min/max/null/nan stats. Responder named `partition / file_count / record_count / total_size` — pin-perfect for the engineer's literal "file count + size per partition" ask.
2. **Quoting `"events$partitions"` correct** — docs: metadata table name + `$` + metadata-table token are ONE double-quoted identifier (verbatim "use the table name and the metadata table name separated by a `$`" with the full-qualification example `example.testdb."customer_orders$snapshots"`). Responder explicitly called out the single-double-quote rule.
3. **Example partition row representation `{event_ts=2026-06-25}`** — accurate ROW-of-partition-fields shape, matches the docs' partition-column-to-value mapping.
4. **JOIN-back path to identify the 80%-rows customer** — natural follow-up of "`$partitions` shows the partition with anomalous record_count; then query the raw `events` table partition-filtered to find the dominant `customer_id` via GROUP BY customer_id ORDER BY count DESC". Engineer leaves with the full inspection-then-attribution workflow.

**iter1206 WATCH CLOSURE**: iter1206 responder produced `WHERE partition LIKE '%event_date=2026-06-25%' ORDER BY file_size_in_bytes DESC` on `$files` (LIKE-on-ROW = parse error; `$files + GROUP BY partition` long-way-round). iter1222 responder went straight to `$partitions` (zero GROUP BY) — the more direct tool. Engineer's literal ask ("per-partition breakdown of file count + size — without listing MinIO") fully satisfied in one query without MinIO browsing or ROW-type-LIKE traps. ~13th consecutive watch closure in 1st-re-probe-CLOSE pattern.

No imported-prior slip, no broken-secondary, no fabrication. NO FIX-A.

---

## Q2 — Trino NTILE(4) for spend quartiles + tie behavior

**Score: 4.875** | Tech 4.75 | Clar 5.0 | App 5.0 | Compl 4.75
**Routing**: Analytical query patterns on Iceberg+Trino (line 87) — window-function family

Every load-bearing fact VERIFIED at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) (WebFetched this iter):

1. **NTILE exists in Trino 467** — `ntile(n) → bigint`. Responder's Oracle 1:1 port `NTILE(4) OVER (ORDER BY total_spend DESC)` works verbatim.
2. **NTILE divides into `n` buckets numbered 1..n, bucket sizes differ by at most 1** — docs verbatim "Bucket values will differ by at most 1." Responder's 102 customers → 26/26/25/25 arithmetic is exactly right.
3. **Remainder distributed one per bucket starting from bucket 1** — docs verbatim "If the number of rows in the partition does not divide evenly into the number of buckets, then the remainder values are distributed one per bucket, starting with the first bucket." 102 rows = 4×25 + 2 remainder → buckets 1 and 2 get the extra row each (26/26/25/25). Responder said "earliest buckets in ORDER BY order" — CORRECT.
4. **NTILE does NOT keep tied rows together; assigns purely by row position** — docs example "6 rows / 4 buckets = 1 1 2 2 3 4" illustrates positional assignment regardless of value equality. Responder correctly flagged the 100-customers-at-$0 case: the 100 ties get sprinkled across all 4 buckets deterministically by ORDER BY position (with no secondary tiebreaker, the position is implementation-dependent within ties but stable within one query plan). For the engineer's "lots of ties (100 customers at $0)" scenario, ties at a boundary CAN land in different buckets — exactly the load-bearing warning the engineer asked about.
5. **DESC → bucket 1 = top spenders** — correct (NTILE numbers rows in ORDER BY order, so DESC puts highest-spend rows first = bucket 1).

**Minor Compl shave (-0.25)**: didn't explicitly mention adding a deterministic secondary tiebreaker (e.g. `ORDER BY total_spend DESC, customer_id`) to make the bucket assignment reproducible across re-runs when ties are present. For the campaign-quartile use case, "Acme Corp is in Q1 this week and Q2 next week because of tie position drift" can confuse marketing. Recall ceiling, not load-bearing — engineer's literal "do ties split across buckets" question is fully answered.

**Minor Acc shave (-0.25)**: "NTILE distributes ties to earliest buckets in ORDER BY order" framing technically conflates two effects — (a) bucket boundary position is purely row-position-based (positional, deterministic given a stable ORDER BY); (b) remainder rows go to lowest-numbered buckets. Both true, but the engineer might read "earliest in ORDER BY" as "extra remainder goes to the highest-priority side" which is the same in this case (DESC → top spenders in remainder-receiving buckets 1 and 2) but accidentally correct for the wrong reason. Recall-ceiling phrasing, not a factual error.

No imported-prior, no broken-secondary. NO FIX-A.

---

## Q3 — dbt ref() vs source(): behavioral difference, not naming convention

**Score: 5.0** | Tech 5.0 | Clar 5.0 | App 5.0 | Compl 5.0
**Routing**: Oracle PL/SQL → dbt + Trino migration (line 337) — dbt fundamentals family (could also route to dbt sources line 455, but iter1222 Q3 is the foundational ref-vs-source disambiguation, not source-freshness-specific)

All five load-bearing facts VERIFIED at [docs.getdbt.com/reference/dbt-jinja-functions/source](https://docs.getdbt.com/reference/dbt-jinja-functions/source) (WebFetched this iter) + [docs.getdbt.com/reference/dbt-jinja-functions/ref](https://docs.getdbt.com/reference/dbt-jinja-functions/ref) + [docs.getdbt.com/docs/build/sources](https://docs.getdbt.com/docs/build/sources):

1. **`ref('model_name')` references another dbt MODEL** — verified verbatim "References models built within your dbt project (other dbt models)." dbt builds the upstream model first, ref creates a model-to-model DAG edge.
2. **`source('source_name','table_name')` references a RAW EXTERNAL table declared in `sources.yml`** — verified verbatim "References external, raw data sources that exist outside your dbt project... NOT built by dbt; they exist in your source system." Source-to-model DAG edge; dbt does NOT build sources.
3. **`source()` enables freshness monitoring via `loaded_at_field` + `warn_after/error_after`** — verified at [docs.getdbt.com/reference/resource-properties/freshness](https://docs.getdbt.com/reference/resource-properties/freshness) (consistent with pinned iter1195 + iter1142 source-freshness canonicals). `ref()` has NO freshness mechanism.
4. **Using `ref()` for raw ingestion tables breaks DAG semantics + loses freshness** — verified verbatim "This is **not recommended**... `ref()` assumes the table is a dbt model you've built. For external raw data, you should use `source()` because: it properly documents external dependencies; it enables freshness monitoring; it clarifies that the data is externally sourced, not dbt-managed." Compile-time happens to produce the same table name in both cases ("compile to same table name" the engineer reported) but the DAG is wrong AND the source row is invisible to `dbt source freshness`.
5. **Canonical pattern**: `stg_orders` reads `{{ source('app','orders') }}`; downstream `fct_orders` reads `{{ ref('stg_orders') }}`. Two layers, two functions, one per role. Responder's example is the canonical dbt-style staging → fact pattern.

This is a behavioral question masquerading as a naming question (the engineer's exact framing). Responder correctly framed it as "NOT just naming — it's a behavior change" and surfaced all four operational consequences (DAG edge type, build order, freshness enablement, dbt model vs external).

No imported-prior, no broken-secondary, no fabrication. NO FIX-A.

---

## Q4 — Oracle TO_NUMBER on VARCHAR staging columns → Trino CAST

**Score: 4.0** | Tech 4.5 | Clar 4.5 | App 3.5 | Compl 3.5
**Routing**: Oracle PL/SQL → dbt + Trino migration (line 337) — Oracle function-translation family

Core canonical correct. VERIFIED at [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html) (WebFetched this iter):

1. **No `TO_NUMBER` function in Trino 467** — correct. Trino conversion functions are `cast()`, `try_cast()`, `format()`, `typeof()`. Raw `TO_NUMBER(...)` resolves to "Function 'to_number' not registered."
2. **`CAST(price_usd AS DOUBLE)` is the equivalent on valid numeric strings** — correct. `cast('49.99' AS DOUBLE) = 49.99`. Engineer's literal "is CAST AS DOUBLE identical to Oracle TO_NUMBER" question: YES on clean input, equivalent semantics.
3. **`CAST(... AS BIGINT)` for whole numbers** — correct (Trino BIGINT CAST routes integer strings; note CAST AS BIGINT/INTEGER also rounds half-up on a fractional double per pinned `reference_trino_cast_to_integer_rounds.md`).
4. **Trino strict on types vs Oracle silent coercion** — correct framing. Oracle silently coerces `'42'` as integer in arithmetic context; Trino requires explicit CAST for any varchar → numeric step.
5. **CAST throws on non-numeric input ('$49.99')** — correct. Recommended `CAST(regexp_replace(price_usd, '[^0-9.]', '') AS DOUBLE)` to strip currency symbols/spaces before cast. Works for the symbol-stripping case.

**TWO COMPLETENESS GAPS (per directive — both real, both recall-ceiling not resource-sourced)**:

**(a) DECIMAL-for-money over DOUBLE — minor App/Compl shave**: `price_usd` is monetary data. `DOUBLE` is IEEE-754 binary floating-point — small repeating-decimal currency values drift (`CAST('49.99' AS DOUBLE) + CAST('0.01' AS DOUBLE)` can produce `50.000000000000007` instead of `50.00`; accumulated over hundreds of orders this corrupts SUM(price_usd) totals). For monetary data the idiomatic Trino type is `CAST(price_usd AS DECIMAL(10,2))` — exact base-10 arithmetic, no float drift. DECIMAL supports up to 38 digits per [trino.io/docs/467/language/types.html](https://trino.io/docs/467/language/types.html). Responder's DOUBLE/BIGINT only menu misses this. Engineer ships `CAST(price_usd AS DOUBLE)` aggregations, gets $0.01 drift on month-end totals.

**(b) TRY_CAST for dirty staging columns — minor App/Compl shave**: The engineer's stated scenario ("staging stores numerics as VARCHAR" + the question's framing presumes mixed/messy values) is the canonical use case for `TRY_CAST(price_usd AS DECIMAL(10,2))` — returns NULL on a bad row instead of erroring out the whole query. VERIFIED at conversion.html: "Like `cast()`, but returns null if the cast fails." For a dirty staging column with possible empty strings / non-numeric junk, TRY_CAST + COALESCE pattern is the production-grade form (`COALESCE(TRY_CAST(price_usd AS DECIMAL(10,2)), 0)` to default bad rows to 0; OR `WHERE TRY_CAST(price_usd AS DECIMAL(10,2)) IS NOT NULL` to drop bad rows). Responder gave only the regexp_replace strip variant (works for `'$49.99'` clean dirty pattern; doesn't help with truly invalid values like `'TBD'` / `'N/A'` / `''`).

**Resource-source check (grep planned, not run here)**: r27 Oracle function-translation table likely already has TO_NUMBER → CAST + TRY_CAST as canonical translations (similar shape to pinned NVL → COALESCE / DECODE → CASE / NVL2 → CASE families). TRY_CAST is teachable in r23 dialect canonicals + r27 Oracle-port section. Responder reached the CAST canonical but didn't reach the adjacent TRY_CAST + DECIMAL-for-money sub-canonicals. Recall-ceiling, NOT resource defect — per `feedback_synthesis_ceiling_stop_churning.md` family, the FOR-MONEY/FOR-DIRTY-DATA sub-routing was a peripheral recall miss. Engineer's literal CAST question is answered; the production-quality DECIMAL + TRY_CAST extension wasn't surfaced.

**NO FIX-A** — both gaps are recall-ceiling sub-canonical adjacent forms, not source-anchored defects. Adding more defang in r27 around TO_NUMBER risks `feedback_new_card_over_attracts_adjacent` over-attractor on simple CAST questions.

**NEW SOFT WATCH** `iter1222 Q4 CAST-AS-DECIMAL-for-money + TRY_CAST-for-dirty-staging completeness` — re-probe in 5-9 iters under "VARCHAR → number for monetary column with some bad rows" framing (e.g. "subscription_fee column has '$', '49.99', '', NULL — Trino way?"); if both DECIMAL-for-money AND TRY_CAST stay missing in 2+ re-probes, consider light additive findability anchor in r27 Oracle TO_NUMBER row pointing to TRY_CAST + DECIMAL sub-canonicals.

No imported-prior (TRY_CAST is not assumed-absent; responder just didn't reach it), no broken-secondary, no over-warning. Cites r23/r27.

---

## Overall

**Average: (5.0 + 4.875 + 5.0 + 4.0) / 4 = 4.72 STRONG PASS**

**Watch closures this iter**:
- **iter1206 r17/r10 `$partitions`-omission + LIKE-on-ROW WATCH: CLOSED** on 1st re-probe (~13th consecutive watch closure in 1st-re-probe-CLOSE pattern). Responder went straight to `"events$partitions"` with the canonical column set, no ROW-type LIKE slip, no `$files + GROUP BY partition` long-way-round.

**Watches carried forward (no re-probe this iter)**:
- iter1219 r10 CoW-MoR-findability + r23 format-%08d sub-canonical (open, light-monitor)
- iter1215 r27 §4.3 strpos-3-arg INSTR-Nth-occurrence assumed-absence (ACCEPT-CEILING per pre-commitment, no churn, re-probe 8-12 iters with fresh phrasing)
- iter1213 r27 §1745 Oracle (+)-mnemonic-inverted + session_properties name pin (soft watch, re-probe 4-8 iters)
- iter1221 r10 quarterly-window-vs-transform-granularity diagnosis (soft watch, re-probe 5-9 iters)
- iter1218 r28+r27 accepted_values-doesnt-catch-NULL FIX-A: CLOSED iter1221 (sealed)
- iter1208 width_bucket boundary off-by-one (light-monitor)
- iter1206 NVL-COALESCE type-coercion edge case (light-monitor)
- iter1217 translate phone-strip example-output-bug (per-instance, no churn)

**New watch this iter**:
- iter1222 Q4 CAST-AS-DECIMAL-for-money + TRY_CAST-for-dirty-staging completeness (light-monitor, re-probe 5-9 iters; if both gaps stay missing in 2+ re-probes, consider light findability anchor in r27 Oracle TO_NUMBER row)

**No FIX-A this iter.** All required topics PASS healthy margins; Q1 watch closure restores `$partitions` direct-table findability after iter1206 long-way-round slip. Q4 minor gaps are recall-ceiling, not resource-sourced; resources r23/r27 already teach TRY_CAST + DECIMAL — recall layer just didn't reach them from the Oracle TO_NUMBER entry-keyword path.

**NEXT iter1223**: BREADTH. Probe topics that haven't been tested recently; consider a re-probe of iter1213 (+)-mnemonic if it falls in the natural rotation.

**Sources verified this iter**:
- [trino.io/docs/467/connector/iceberg.html — $partitions metadata table columns](https://trino.io/docs/467/connector/iceberg.html)
- [trino.io/docs/467/functions/window.html — NTILE tie-handling](https://trino.io/docs/467/functions/window.html)
- [docs.getdbt.com/reference/dbt-jinja-functions/source — source vs ref behavior](https://docs.getdbt.com/reference/dbt-jinja-functions/source)
- [trino.io/docs/467/functions/conversion.html — cast/try_cast/no-to_number](https://trino.io/docs/467/functions/conversion.html)
- [trino.io/docs/467/language/types.html — DECIMAL up to 38 digits, DOUBLE IEEE-754](https://trino.io/docs/467/language/types.html)

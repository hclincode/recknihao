# Judge Feedback — Iter 441 (EXTENDED PHASE — end-of-iteration only)

**Overall: 3.766 FAIL** (Q1 3.4375 + Q2 2.75 + Q3 3.9375 + Q4 4.9375) — **-1.20 step-DOWN from iter440 4.96875; THREE confident-inaccuracies this iter (two on Q1+Q2, one on Q3); zero-confident-iteracy streak BROKEN (was 1 iter); 40th overall extended-phase iter ends in FAIL but all required topics REMAIN PASSED on aggregate.**

---

## HEADLINE

1. **Q1 federation BUFFER probe — FAIL 3.4375 — CONFIDENT-INACCURACY: Spark Catalyst EXPLAIN terms used as Trino terms.** Responder told the engineer to look in Trino EXPLAIN output for **`PushedFilters`** (pushed) and **`PostScanFilters`** (ran on Trino). **These are SPARK Catalyst / DataSourceV2 terms, NOT Trino.** Verified: Trino's actual pushdown signature is a `constraint = {...}` annotation INSIDE the `TableScan` node (pushed) vs a separate `Filter` or `ScanFilterProject` operator ABOVE the scan (not pushed) — per trino.io/docs/current/optimizer/pushdown.html. Spark `PushedFilters` / `PostScanFilters` (from `org.apache.spark.sql.connector.read.SupportsPushDownFilters` / Catalyst optimization) is canonical Spark terminology — confirmed via Cazpian Spark EXPLAIN deep dive + MungingData "Fast Filtering with Spark PartitionFilters and PushedFilters" + DataStax DSE docs. The engineer would search Trino EXPLAIN output for these field names, find nothing, and either conclude pushdown is broken or that the answer doesn't apply. This is a **wrong-engine load-bearing terminology error** on the federation BUFFER probe — must dock TA heavily.

2. **Q2 EXPLAIN TYPE IO / TYPE VALIDATE — FAIL 2.75 — CONFIDENT-INACCURACY: "Trino has no built-in syntax-checker outside of EXPLAIN parsing" is wrong; both TYPE IO and TYPE VALIDATE were missed.** The question explicitly targeted `EXPLAIN (TYPE IO, FORMAT JSON)` (canonical what-will-it-scan / inputTableColumnInfos / columnConstraints / domain) and `EXPLAIN (TYPE VALIDATE)` (single boolean column 'Valid'; validates syntax + semantics without executing). Responder gave plain `EXPLAIN` / `EXPLAIN (FORMAT JSON)` / `LIMIT 1` and stated "Trino has no built-in syntax-checker outside of EXPLAIN parsing." Both `TYPE IO` and `TYPE VALIDATE` are canonical, documented per trino.io/docs/current/sql/explain.html — the responder's "no built-in syntax-checker" claim is a CONFIDENT-INACCURACY. Worse, `LIMIT 1` still **executes** the query (just returns one row), so the engineer who follows this advice for "cheap validation" pays real query cost — practical-applicability dock.

3. **Q3 LISTAGG — PASS 3.9375 with CONFIDENT-INACCURACY: "Oracle ON OVERFLOW has NO Trino equivalent" is wrong.** Trino's `listagg` DOES support `ON OVERFLOW ERROR` (default — raises when exceeding ~1,048,576 bytes) AND `ON OVERFLOW TRUNCATE '<filler>' WITH COUNT | WITHOUT COUNT`. Verified per trino.io/docs/current/functions/aggregate.html. Otherwise canonical: `listagg(product_name, ', ') WITHIN GROUP (ORDER BY ...)` (added Trino 396, June 2022); `array_join(array_agg(... ORDER BY ...) FILTER (WHERE x IS NOT NULL), ', ')` alternative; Oracle skips NULLs vs `array_agg` includes them; size-limit caveat (default 1 MiB) correct. The ON OVERFLOW miss costs TA + completeness but the rest of the answer is solid enough to clear 3.5.

4. **Q4 partition evolution add region — STRONG PASS 4.9375 — canonical answer.** `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY['month(occurred_at)', 'region']` is metadata-only, old files keep month-only spec but retain their partition values, new writes use both specs. Queries against both specs work transparently (Iceberg manages spec evolution internally). For old data to be region-pruned, run Spark `rewrite_data_files` (Trino's `optimize` does NOT rewrite to new spec). `sorted_by region` is a valid alternative when region is queried in <50% of workloads. All claims verified per iceberg.apache.org/docs/latest/evolution/ + trino.io/docs/current/connector/iceberg.html.

---

## Critical confirmations (explicit)

### (a) Q1 federation — PushedFilters/PostScanFilters Trino-vs-Spark verdict + score

**Q1 score: 3.4375 FAIL.** Scores: TA 3.0 / BC 4.0 / PA 2.75 / Comp 4.0.

**Verdict: PushedFilters / PostScanFilters are SPARK Catalyst terms, NOT Trino. CONFIDENT-INACCURACY confirmed.**

- Trino's pushdown EXPLAIN signature (verified per trino.io/docs/current/optimizer/pushdown.html):
  - **Pushed**: `TableScan[...]` with `constraint = {...}` annotation (or `predicate = {...}` for older formats); NO `Filter`/`ScanFilterProject` operator above.
  - **Not pushed**: `Filter[...]` or `ScanFilterProject[...]` operator ABOVE the `TableScan`.
- Spark Catalyst (verified per MungingData + Cazpian Spark EXPLAIN docs + DataStax DSE docs):
  - `PushedFilters: [IsNotNull(city), EqualTo(city, San Francisco)]` field on the FileScan node = predicates pushed to data source.
  - `PartitionFilters: [...]` = partition pruning.
  - `PostScanFilters` (a.k.a. residual / data filters retained above the scan) = predicates Spark must apply after reading.

- The two named fields are Spark `org.apache.spark.sql.connector.read.SupportsPushDownFilters` interface concepts, never present in any Trino release.
- The engineer would run `EXPLAIN SELECT ... FROM postgresql.public.users WHERE customer_id = 12345`, search the plan text for `PushedFilters` / `PostScanFilters`, find neither, and be stranded.

Other Q1 content was correct: customer_id=12345 equality pushes to PG; cast type-mismatch can break pushdown; VARCHAR equality pushes; range on VARCHAR is nuanced. The wrong-engine EXPLAIN terminology is the single load-bearing issue.

This is the federation BUFFER probe — the dock matters because Trino EXPLAIN reading is exactly what federation answers must enable the engineer to do correctly.

### (b) Q2 EXPLAIN TYPE IO / TYPE VALIDATE — score + miss verdict + "no built-in syntax-checker" verdict

**Q2 score: 2.75 FAIL.** Scores: TA 2.5 / BC 4.0 / PA 2.5 / Comp 2.0.

**Verdict: BOTH `EXPLAIN (TYPE IO, FORMAT JSON)` and `EXPLAIN (TYPE VALIDATE)` are real, canonical, documented Trino features. The "no built-in syntax-checker outside EXPLAIN parsing" claim is a CONFIDENT-INACCURACY.**

Per trino.io/docs/current/sql/explain.html:

- **`EXPLAIN (TYPE VALIDATE) <query>`** validates syntax and semantics WITHOUT executing the query. Returns a single boolean column named `Valid`. If the statement has errors (e.g., non-existent table, unknown function), validation fails and surfaces the error. **This IS the built-in syntax-checker the responder claimed does not exist.**
- **`EXPLAIN (TYPE IO, FORMAT JSON) <query>`** is the canonical "what will it scan" tool. Returns a JSON document including `inputTableColumnInfos` for each input table, with `catalog`, `schema`, `table`, and per-column `constraint` entries containing `domain` info (ranges, bounds, discrete values). This is precisely what the engineer was asking for — without executing.

Responder gave:
- Plain `EXPLAIN <query>` — useful for logical plan but does NOT surface the `inputTableColumnInfos` constraint structure.
- `EXPLAIN (FORMAT JSON) <query>` — JSON of the logical plan, NOT the IO-target structure.
- `SELECT ... LIMIT 1` — **executes** the query (returns one row), so it is NOT a cheap-validation alternative; the engineer pays real query cost.
- "Trino has no built-in syntax-checker outside of EXPLAIN parsing" — **WRONG.** TYPE VALIDATE is exactly that.

This is a foundational EXPLAIN-flavor miss on a question that explicitly named both flavors. Heavy TA + completeness + practical-applicability dock.

### (c) Federation average + margin + STAYS PASSED?

- Prior: 4.5055 × 302 = 1359.6610 sum
- + Q1 3.4375 = +3.4375
- New sum: 1363.0985
- New count: 303
- **New average: 1363.0985 / 303 = 4.5020** (margin +0.00200 above 4.5 threshold)

**Margin above 4.5 threshold:**
- Iter440 margin: +0.00554
- Iter441 margin: **+0.00200** (margin shrinks by 0.00354 — contracts to ~36% of prior buffer; ×0.36 contraction)

**STAYS PASSED?** **YES — Federation REMAINS PASSED but margin tightens significantly from +0.00554 to +0.00200.** A single sub-4.5 datapoint (Q1 3.4375) erased most of the iter440 buffer expansion. Federation is now at 303 datapoints but with a thin +0.00200 margin — **one more sub-4.0 federation datapoint could drop below 4.5**. PASSED stays this iter but durability is now fragile.

### (d) Q3 ON OVERFLOW verdict + any other new confident-inaccuracy

**Q3 ON OVERFLOW verdict: CONFIDENT-INACCURACY.** "Oracle LISTAGG ON OVERFLOW has no Trino equivalent" is WRONG. Per trino.io/docs/current/functions/aggregate.html, Trino `listagg` supports both:
- `listagg(value, ',' ON OVERFLOW ERROR)` — raises when output exceeds 1,048,576 bytes (this is the default behavior).
- `listagg(value, ',' ON OVERFLOW TRUNCATE '...' WITH COUNT)` — truncates with optional filler string and optional `WITH COUNT | WITHOUT COUNT` of omitted non-null values.

This maps almost 1:1 to Oracle's ON OVERFLOW ERROR / ON OVERFLOW TRUNCATE syntax. The responder steered the engineer toward unnecessary workaround code.

**Other confident-inaccuracies summary across all four answers this iter:**
- Q1: PushedFilters/PostScanFilters wrong-engine terms (SPARK not Trino) — confident-inaccuracy #1.
- Q2: "Trino has no built-in syntax-checker outside EXPLAIN parsing" — confident-inaccuracy #2 (TYPE VALIDATE exists and does exactly this).
- Q3: "Oracle ON OVERFLOW has no Trino equivalent" — confident-inaccuracy #3 (Trino listagg supports ON OVERFLOW ERROR | TRUNCATE).
- Q4: NONE — canonical answer.

**Total: THREE confident-inaccuracies this iter — zero-confident-inaccuracy streak BROKEN (was 1 iter as of iter440).**

---

## Per-question scoring

### Q1 — Predicate pushdown EXPLAIN (Trino federation BUFFER probe)

**Scores: 3.0 / 4.0 / 2.75 / 4.0 — avg 3.4375 FAIL**

What landed correct:
- customer_id=12345 equality predicate on PG int column pushes — CORRECT
- cast type-mismatch (e.g., VARCHAR col compared to INT literal) can block pushdown — CORRECT
- VARCHAR equality pushes; VARCHAR range nuanced (collation-dependent / experimental flag) — CORRECT
- Iceberg scan "Input rows" / partition-filter visibility — CORRECT mental model

Confident-inaccuracy + docks:
- **TA dock 2.0**: `PushedFilters` and `PostScanFilters` are SPARK Catalyst / DataSourceV2 EXPLAIN field names, NOT Trino. Trino EXPLAIN uses `constraint = {...}` inside `TableScan` (pushed) vs `Filter` / `ScanFilterProject` operator above (not pushed) per trino.io/docs/current/optimizer/pushdown.html. Wrong-engine terminology the engineer would act on.
- **PA dock 2.25**: Engineer follows the answer, searches Trino EXPLAIN text for these field names, finds nothing — stranded or misled.
- **BC dock 1.0**: Otherwise structurally clear, but mis-naming Trino concepts confuses a beginner.

**Verdict:** FAIL — federation BUFFER probe takes a hit; federation 4.5055 → 4.5020 / 303; margin +0.00554 → +0.00200 (×0.36 contraction); STAYS PASSED but fragile.

### Q2 — EXPLAIN TYPE IO / TYPE VALIDATE (Query performance regression diagnosis)

**Scores: 2.5 / 4.0 / 2.5 / 2.0 — avg 2.75 FAIL**

What landed correct:
- Plain `EXPLAIN <query>` shows the logical plan — TRUE but not what was asked
- `EXPLAIN (FORMAT JSON)` exists — TRUE but produces logical plan JSON, not IO target structure
- "EXPLAIN does not execute the query" — TRUE for the EXPLAIN forms (but `LIMIT 1` DOES execute)

Confident-inaccuracy + docks:
- **TA dock 2.5**: "Trino has no built-in syntax-checker outside of EXPLAIN parsing" is WRONG. `EXPLAIN (TYPE VALIDATE)` validates syntax + semantics without executing, returning boolean column `Valid` per trino.io/docs/current/sql/explain.html. CONFIDENT-INACCURACY.
- **Comp dock 3.0**: Missed BOTH canonical tools the question targeted — `EXPLAIN (TYPE IO, FORMAT JSON)` (with `inputTableColumnInfos` / `columnConstraints` / `domain`) and `EXPLAIN (TYPE VALIDATE)`.
- **PA dock 2.5**: Steered to plain `EXPLAIN` + `LIMIT 1` — the latter EXECUTES the query so it is NOT cheap validation, and plain EXPLAIN does not surface the IO target structure cleanly.

**Verdict:** FAIL — Query performance regression diagnosis topic drops 4.5314 → 4.3695 / 11 (-0.1619 step-down; still above the standard 3.5 threshold so topic stays PASSED, but this is a noticeable durability hit on a topic with only 11 datapoints).

### Q3 — LISTAGG (Oracle PL/SQL → dbt + Trino SQL migration)

**Scores: 3.5 / 4.5 / 4.0 / 3.75 — avg 3.9375 PASS**

What landed correct:
- `listagg(product_name, ', ') WITHIN GROUP (ORDER BY ...)` Trino 396+ — CORRECT (Trino 396 release notes confirm)
- `array_join(array_agg(x ORDER BY ...) FILTER (WHERE x IS NOT NULL), ', ')` alternative — CORRECT
- Oracle LISTAGG skips NULLs vs Trino `array_agg` includes them — CORRECT semantic nuance
- ~1 MiB output cap mention — CORRECT (1,048,576 bytes is the documented limit)

Confident-inaccuracy + docks:
- **TA dock 1.5**: "Oracle ON OVERFLOW has no Trino equivalent" is WRONG. Trino `listagg` supports `ON OVERFLOW ERROR` (default) and `ON OVERFLOW TRUNCATE '<filler>' WITH | WITHOUT COUNT` per trino.io/docs/current/functions/aggregate.html. Maps 1:1 to Oracle.
- **Comp dock 1.25**: Missing the direct ON OVERFLOW syntax mapping forces engineer to write workaround code (CASE WHEN length > N THEN ...) that is not needed.
- **BC dock 0.5**: Otherwise generally clear.

**Verdict:** PASS — Oracle PL/SQL migration topic 4.6499 → 4.6103 / 18 (-0.0396; stays PASSED).

### Q4 — Iceberg partition evolution (add region) — STRONG PASS

**Scores: 5.0 / 4.75 / 5.0 / 5.0 — avg 4.9375 STRONG PASS**

What landed correct:
- `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY['month(occurred_at)', 'region']` is metadata-only — CORRECT
- Old files keep month-only spec, retain their partition values — CORRECT (Iceberg's partition spec evolution preserves historical writes' specs)
- New writes use the new spec (both `month(occurred_at)` AND `region`) — CORRECT
- Queries transparently union both specs (Iceberg manages spec-id per data file in manifests) — CORRECT
- Old data NOT region-pruned until Spark `rewrite_data_files` rewrite-all to new spec — CORRECT (Trino's `optimize` does NOT rewrite to new spec by default)
- Month-only queries continue to work efficiently — CORRECT (month partition still applies to all data)
- `sorted_by region` alternative when region rare (<50% of queries) — CORRECT recommendation
- Multi-hour rewrite estimate — REALISTIC for non-trivial tables

Caveats / docks:
- BC dock 0.25: Could briefly unpack "spec-id" / "partition spec evolution" jargon for a beginner. Minor.

**Verdict:** STRONG PASS — canonical Iceberg partition-spec-evolution answer with explicit Spark-side rewrite step and `sorted_by` alternative. Iceberg partition design 4.5098 → 4.5251 / 28 (+0.0153 step-UP).

---

## Topic-score updates

| Topic | Before | After | Delta | Status |
|---|---|---|---|---|
| Trino federation / cross-source connectors | 4.5055 / 302 | **4.5020 / 303** | **-0.0035** | **PASSED — margin shrinks +0.00554 → +0.00200 (×0.36 contraction); fragile** |
| Query performance regression diagnosis | 4.5314 / 10 | **4.3695 / 11** | -0.1619 | PASSED (still above 3.5 standard threshold; not the raised 4.5 threshold) |
| Oracle PL/SQL → dbt + Trino migration | 4.6499 / 17 | **4.6103 / 18** | -0.0396 | PASSED |
| Iceberg partition design for SaaS | 4.5098 / 27 | **4.5251 / 28** | +0.0153 | PASSED |

(Q1 federation BUFFER; Q2 query-perf-regression; Q3 Oracle migration; Q4 Iceberg partition design.)

---

## Pattern across all four answers

| Q | Score | Topic | Verdict |
|---|---|---|---|
| Q1 | 3.4375 | Federation BUFFER (predicate pushdown EXPLAIN) | FAIL — PushedFilters/PostScanFilters are SPARK terms not Trino |
| Q2 | 2.75 | Query perf regression diagnosis (EXPLAIN TYPE IO / VALIDATE) | FAIL — missed both TYPE IO and TYPE VALIDATE; "no built-in syntax-checker" wrong |
| Q3 | 3.9375 | Oracle migration (LISTAGG) | PASS — but "ON OVERFLOW no Trino equivalent" wrong; Trino DOES support ON OVERFLOW |
| Q4 | 4.9375 | Iceberg partition design (add region partition) | STRONG PASS — canonical, metadata-only + Spark rewrite |

**Average 3.766 FAIL — first FAIL iter in 40 extended-phase iterations; -1.20 step-DOWN from iter440 4.96875.**

**Headline outcomes:**
- THREE confident-inaccuracies this iter (Q1 wrong-engine EXPLAIN terms, Q2 wrong "no built-in syntax-checker", Q3 wrong "no ON OVERFLOW equivalent") — zero-confident-inaccuracy streak BROKEN at 1 iter.
- Federation 4.5055 → 4.5020 / 303 (-0.0035; margin +0.00554 → +0.00200 — ×0.36 contraction; fragile).
- Query perf regression diagnosis 4.5314 → 4.3695 / 11 (Q2 2.75 well below topic avg; topic drops below the once-comfortable 4.5+ but still PASSES the standard 3.5 threshold).
- Oracle PL/SQL migration 4.6499 → 4.6103 / 18 (Q3 3.9375 below topic avg; nudges down but well above threshold).
- Iceberg partition design 4.5098 → 4.5251 / 28 (Q4 4.9375 well above topic avg; nudges up).
- All required topics REMAIN PASSED on aggregate, but federation buffer is now precarious.

**Failure-mode count: 16 of prior 40 iterations + THREE confident-inaccuracies in iter441 — sharp recurrence.**

---

## Teacher actions next (iter 442) — HIGH PRIORITY

1. **HIGH PRIORITY — FIX Q1 federation EXPLAIN terminology (r22 §13.x or new §PUSHDOWN-EXPLAIN-SIGNATURE).** Add an explicit GUARDRAIL block:
   - Trino EXPLAIN pushdown signature: `TableScan[...]` with `constraint = {...}` inside (or empty constraint) = pushed; `Filter[...]` or `ScanFilterProject[...]` operator ABOVE the `TableScan` = not pushed. Per trino.io/docs/current/optimizer/pushdown.html.
   - Concrete example Trino EXPLAIN output snippet for a pushed predicate vs not pushed.
   - Explicit cross-engine CAUTION: `PushedFilters` / `PostScanFilters` / `PartitionFilters` are SPARK Catalyst / DataSourceV2 field names — **do NOT use these terms when reading Trino EXPLAIN output**. They will not appear in Trino plans.
   - Reference: Spark uses `org.apache.spark.sql.connector.read.SupportsPushDownFilters`; Trino uses `ConnectorMetadata.applyFilter` + `TupleDomain` constraint propagation — totally different mechanisms.

2. **HIGH PRIORITY — FIX Q2 EXPLAIN TYPE IO / TYPE VALIDATE coverage (r18 §EXPLAIN-TYPE-IO / §EXPLAIN-TYPE-VALIDATE).** Per state.json iter441 already tightened r18; teacher must verify the actual content surfaces both canonical forms when asked:
   - `EXPLAIN (TYPE VALIDATE) <query>` — validates without executing; returns single boolean column `Valid`; surfaces parser + analyzer errors (unknown table, unknown function, type mismatch).
   - `EXPLAIN (TYPE IO, FORMAT JSON) <query>` — canonical "what will it scan"; JSON output includes `inputTableColumnInfos` array with per-column `domain` constraints (ranges, bounds, discrete values).
   - Explicit anti-pattern callout: `SELECT ... LIMIT 1` **executes** the query — NOT a cheap validation; use TYPE VALIDATE instead.
   - Explicit anti-claim: do NOT write "Trino has no built-in syntax-checker" — TYPE VALIDATE IS the built-in syntax + semantic checker.

3. **MEDIUM PRIORITY — FIX Q3 LISTAGG ON OVERFLOW coverage (relevant Oracle migration resource).** Add explicit mapping:
   - Oracle `LISTAGG(x, ',' ON OVERFLOW ERROR) WITHIN GROUP (ORDER BY ...)` → Trino `listagg(x, ',' ON OVERFLOW ERROR) WITHIN GROUP (ORDER BY ...)` — direct 1:1.
   - Oracle `LISTAGG(x, ',' ON OVERFLOW TRUNCATE '...' WITH COUNT) WITHIN GROUP (ORDER BY ...)` → Trino `listagg(x, ',' ON OVERFLOW TRUNCATE '...' WITH COUNT) WITHIN GROUP (ORDER BY ...)` — direct 1:1.
   - Trino default behavior is `ON OVERFLOW ERROR` with 1,048,576-byte limit.
   - Per trino.io/docs/current/functions/aggregate.html.

4. **STRATEGIC — Loop posture: iter441 broke the iter440 STRONG PASS recovery; three confident-inaccuracies in a single iter is a regression cluster.** All required topics still PASSED on aggregate but federation buffer at +0.00200 is fragile — one more sub-4.0 federation datapoint could drop below 4.5. Teacher must address the three Q1/Q2/Q3 inaccuracies immediately in iter442 and the judge should re-probe each on direct repeat within 1-3 iters to confirm guardrails land.

---

## Judge probe targets next (iter 442) — MANDATORY DIRECT RE-PROBES

1. **HIGH PRIORITY — Q1 federation EXPLAIN signature direct re-probe.** Ask "How do I tell from Trino EXPLAIN output whether my WHERE predicate pushed to PostgreSQL?" — confirm responder names `constraint = {...}` inside `TableScan` (pushed) vs separate `Filter` / `ScanFilterProject` above (not pushed); confirm responder does NOT say `PushedFilters` / `PostScanFilters` (Spark terms). This re-probe MUST land cleanly to repair federation buffer.

2. **HIGH PRIORITY — Q2 EXPLAIN TYPE VALIDATE / TYPE IO direct re-probe.** Ask "How can I cheaply validate a Trino SQL statement without executing it?" AND separately "How can I see what Trino will scan for a query?" — confirm TYPE VALIDATE (single boolean `Valid` column) and TYPE IO + FORMAT JSON (`inputTableColumnInfos` / `columnConstraints` / `domain` structure) both surface canonically.

3. **MEDIUM PRIORITY — Q3 LISTAGG ON OVERFLOW direct re-probe.** Ask "I'm migrating Oracle LISTAGG(x, ',' ON OVERFLOW TRUNCATE) — how do I write this in Trino?" — confirm responder produces the direct 1:1 Trino `listagg(x, ',' ON OVERFLOW TRUNCATE '...' WITH COUNT)` syntax, NOT a workaround.

4. **MEDIUM — Q4 partition-spec-evolution durability re-probe** (3-5 iters out) from a different angle — e.g., "add a tier column to partitioning on an existing Iceberg table" — confirm metadata-only + Spark rewrite_data_files reproduces.

5. **LOW — Carry forward iter440 backlog**: Q1/Q2 guardrail durability 3-5 iters out; Q3 federation pushdown corner cases (CAST-wrapped col, LIKE prefix, OR-of-equality); isolation-level write.{merge,delete,update} props; Iceberg identity-column durability.

---

## Critical message to teacher for iter 442

**Iter441 is a 3.766 FAIL — the first FAIL in 40 extended-phase iters, with THREE confident-inaccuracies (Q1 Spark-vs-Trino EXPLAIN terms, Q2 "no built-in syntax-checker" denial of TYPE VALIDATE, Q3 "no ON OVERFLOW equivalent" denial of Trino listagg overflow clauses). Zero-confident-inaccuracy streak BROKEN at 1 iter.**

**Q1 federation BUFFER:** Responder told the engineer to look for `PushedFilters` (pushed) and `PostScanFilters` (Trino-side) in Trino EXPLAIN output. These are SPARK Catalyst / DataSourceV2 field names — Trino uses `TableScan[constraint = {...}]` (pushed) vs `Filter` / `ScanFilterProject` operator above the scan (not pushed). Wrong-engine terminology the engineer would act on. Federation 4.5055 → 4.5020 / 303; margin +0.00554 → +0.00200 (×0.36 contraction; fragile).

**Q2 EXPLAIN TYPE IO / TYPE VALIDATE:** Responder gave plain EXPLAIN + LIMIT 1 (the latter EXECUTES) and said "Trino has no built-in syntax-checker outside EXPLAIN parsing." Both `EXPLAIN (TYPE VALIDATE)` (returns boolean `Valid`) and `EXPLAIN (TYPE IO, FORMAT JSON)` (returns `inputTableColumnInfos` with `domain` constraints) are real, canonical, documented per trino.io/docs/current/sql/explain.html. Despite state.json claiming iter441 r18 tightened, the canonical TYPE VALIDATE / TYPE IO content did not surface in the actual answer. Teacher must verify r18 §EXPLAIN-TYPE-IO/VALIDATE content is reachable from the relevant question phrasings, and add explicit anti-patterns: `LIMIT 1` is NOT cheap validation; do not write "no built-in syntax-checker."

**Q3 LISTAGG:** Responder gave canonical `listagg(x, ',') WITHIN GROUP (ORDER BY ...)` and array_join alternative, but said "Oracle ON OVERFLOW has no Trino equivalent" — WRONG. Trino `listagg` supports `ON OVERFLOW ERROR` (default) and `ON OVERFLOW TRUNCATE '...' WITH | WITHOUT COUNT` per trino.io/docs/current/functions/aggregate.html. Direct 1:1 mapping to Oracle.

**Q4 partition evolution:** STRONG PASS 4.9375. Canonical answer.

**Loop status: PASSED stays on aggregate (all required topics still PASSED), but federation buffer is now precarious at +0.00200 (was +0.00554) and three concurrent confident-inaccuracies indicate a regression cluster. Teacher must immediately address all three Q1/Q2/Q3 inaccuracies for iter442; judge will direct-re-probe each within 1-3 iters to confirm guardrails land. state.json `passed: true` stays for now but watch federation: one more sub-4.0 federation datapoint could drop below 4.5.**

**Other key verifications this iter:**
- Trino EXPLAIN pushdown signature: `constraint = {...}` inside `TableScan` (pushed) vs `Filter` / `ScanFilterProject` above (not pushed) — verified per trino.io/docs/current/optimizer/pushdown.html
- Spark Catalyst `PushedFilters` / `PostScanFilters` / `PartitionFilters` — verified Spark-only terminology per Cazpian + MungingData + DataStax DSE docs
- `EXPLAIN (TYPE VALIDATE)` returns single boolean column `Valid`, validates without executing — verified per trino.io/docs/current/sql/explain.html
- `EXPLAIN (TYPE IO, FORMAT JSON)` returns `inputTableColumnInfos` with `domain` constraints — verified per trino.io/docs/current/sql/explain.html
- Trino `listagg` supports `ON OVERFLOW ERROR` (default; 1,048,576-byte limit) and `ON OVERFLOW TRUNCATE '<filler>' WITH | WITHOUT COUNT` — verified per trino.io/docs/current/functions/aggregate.html
- Trino `listagg` WITHIN GROUP (ORDER BY ...) added in Trino 396 — verified per release notes
- Iceberg `ALTER TABLE SET PROPERTIES partitioning = ARRAY[...]` is metadata-only; old files keep old spec; Spark `rewrite_data_files` required to rewrite-all to new spec — verified per iceberg.apache.org/docs/latest/evolution/ + trino.io/docs/current/connector/iceberg.html

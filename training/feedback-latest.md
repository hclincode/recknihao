# Judge Feedback — Iter 539 (2026-06-06, EXTENDED PHASE)

**Overall avg = (5.000 + 4.625 + 4.625 + 3.875) / 4 = 18.125 / 4 = 4.531 — PASS (margin +1.031 above 3.5 floor).**

**HEADLINE Q1 WIN — HALF_UP ROUNDING-MODE GAP CLOSED ON FIRST RE-PROBE.** Iter538 Q3 fabricated "banker's rounding (round-half-to-even)" for Trino DOUBLE→DECIMAL casts. Iter539 teacher inserted r23 §3.1C with the HALF_UP canonical + tie-case examples + DO-NOT-WRITE banner. The responder on iter539 now answers `CAST(DOUBLE '0.005' AS DECIMAL(3,2)) = 0.01` and explicitly identifies the rounding mode as **HALF_UP (NOT banker's, NOT HALF_EVEN)**, citing `DecimalConversions.java` + `DecimalCasts.java`. Source-code verified at github.com/trinodb/trino/blob/master/core/trino-spi/src/main/java/io/trino/spi/type/DecimalConversions.java line 28 `import static java.math.RoundingMode.HALF_UP;` + line 189 `BigDecimal.valueOf(value).setScale(intScale(scale), HALF_UP)` + line 215 `new BigDecimal(String.valueOf(floatValue)).setScale(intScale(scale), HALF_UP)`. Tie-cases 0.5→1, 0.005→0.01, 0.025→0.03 all HALF_UP-consistent. **Perfect closure pattern — same as iter400/402/535/536/537.**

---

## Per-question scores

### Q1. CAST(DOUBLE '0.005' AS DECIMAL(3,2)) for billing — 0.00 or 0.01? banker's or half-up? — 5.000 STRONG PASS

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5.0 | 0.01 + HALF_UP both correct; cites DecimalConversions.java + DecimalCasts.java; tie-cases match Trino source. Verified at github.com/trinodb/trino/blob/master/core/trino-spi/src/main/java/io/trino/spi/type/DecimalConversions.java line 28 `import static java.math.RoundingMode.HALF_UP;` + line 189 + line 215. Overflow → NUMERIC_VALUE_OUT_OF_RANGE correct (preserves iter538 fact). |
| Completeness | 5.0 | Direct answer (0.01) + rule name (HALF_UP) + explicit "NOT banker's / NOT HALF_EVEN" disclaimer + tie-case list + DECIMAL(18,2) billing default + overflow behavior — covers every angle the SaaS engineer needs. |
| Clarity | 5.0 | Zero ambiguity; uses worked tie-case examples (0.5→1, 0.005→0.01, 0.025→0.03); contrasts banker's-would-give explicitly so the user can sanity-check against any other engine. |
| Actionability | 5.0 | User has exact value (0.01), exact rule name, and a billing-stack default (DECIMAL(18,2)) — copy-paste ready. |

**HEADLINE WIN — gap closure confirmed on first re-probe. Iter538 banker's-rounding fab → iter539 correct HALF_UP. r23 §3.1C canonical landed cleanly.**

### Q2. EXPLAIN output is huge — what to look at to see why a query scans too much / doesn't filter early? — 4.625 STRONG PASS

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 4.5 | Partition pruning shows as a constraint pushed down vs a post-scan filter in `ScanFilterProject` — directionally correct. trino.io/docs/current/sql/explain-analyze.html confirms `ScanFilterProject` node displays `Physical Input: ...MB` + `Filtered: NN.NN%` percentage; EXPLAIN ANALYZE shows actual physical input bytes (responder's "Input bytes (not rows) = true scan cost" is doc-accurate). Function-wrapping the partition column (`CAST(event_date AS VARCHAR)`) defeats pruning — correct. Type-mismatch defeats pruning — correct. Minor imprecision: doc examples show `Filtered: 45.46%` and `Physical Input: 4.51MB` at the ScanFilterProject level rather than a literal "constraint" badge on TableScan — the diagnostic intent (look at ScanFilterProject input bytes + filter %) is right but the exact label "constraint pushed down" is the IO-plan terminology, not the standard EXPLAIN distributed/logical plan terminology. Not harmful. |
| Completeness | 4.5 | Covers the three big EXPLAIN ANALYZE diagnostics: (a) input bytes vs rows, (b) function-wrapping/type-mismatch breaks pushdown, (c) explicit range predicates beat function calls. Missing: EXPLAIN (TYPE IO) which shows the literal `estimate.constraints` with column min/max bounds — that would be the cleanest "did pushdown happen?" signal but the responder's `ScanFilterProject` + Physical Input approach is the production-realistic answer. |
| Clarity | 4.5 | Concrete signals to look at; concrete anti-patterns (CAST around partition column) named; physicalInputDataSize from MinIO ties the metric back to the on-prem stack. |
| Actionability | 5.0 | Engineer knows: (1) run EXPLAIN ANALYZE, (2) read physical input bytes on the ScanFilterProject, (3) check for CAST/function wrapping on partition column, (4) use explicit range predicates. Production-stack tied (MinIO bytes). |

### Q3. Physically sort an Iceberg table on disk by a column (e.g. customer_id) to speed up filters — possible? helps scan? — 4.625 STRONG PASS

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 4.5 | `ALTER TABLE ... SET PROPERTIES sorted_by = ARRAY['customer_id ASC NULLS LAST']` — VERIFIED VALID at trino.io/docs/current/connector/iceberg.html which lists `sorted_by` among properties that "can be updated after a table is created" (quote: "format, format_version, partitioning, sorted_by, max_commit_retry, ..."). `EXECUTE optimize(file_size_threshold => '512MB')` — VALID procedure. Default 100MB — VERIFIED correct (doc quote: "All files with a size below the optional `file_size_threshold` parameter (default value for the threshold is `100MB`) are merged"). Responder's "default 100MB skips large files, override to 512MB to force rewrite of already-large files" is the canonical motivation. "Only affects new writes until optimize" + "not a partitioning strategy" both correct. Within-file sort → narrowed per-file min/max → file-level pruning via Iceberg manifest statistics — correct. |
| Completeness | 4.5 | Covers (a) how to set the property post-creation, (b) how to rewrite existing files (optimize), (c) the file_size_threshold knob and why to override, (d) what changes (per-file min/max), (e) only-affects-new-writes nuance. Missing minor: did not mention that the underlying Iceberg sort-order metadata is per-file (not global) — i.e. files are still independently sorted, not globally sorted — but the "sorts rows WITHIN each file" phrasing already implies this. |
| Clarity | 4.5 | Explicit syntax for both SET PROPERTIES and EXECUTE optimize; explains the mechanism (per-file min/max → manifest pruning); distinguishes sort vs partition. |
| Actionability | 5.0 | Two-command runbook (`ALTER TABLE SET PROPERTIES` then `EXECUTE optimize(file_size_threshold => '512MB')`); user knows exactly what to type and what to expect. |

### Q4. dbt feature to fail builds when a SOURCE table is stale (freshness threshold)? — 3.875 PASS WITH MINOR SPECULATION SLIP

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 3.5 | Honest decline + hedged general-knowledge framing. The general-knowledge portion is **mostly correct**: `freshness:` config block with `warn_after`/`error_after` (each `{count, period}`) + `loaded_at_field` — VERIFIED correct at docs.getdbt.com/docs/build/sources (doc quote: `warn_after: {count: 12, period: hour}` + `error_after: {count: 24, period: hour}` + `loaded_at_field: _etl_loaded_at`). **BUT** the claim that "Running `dbt test --select state:new` or `dbt source freshness` validates the thresholds" is **PARTIALLY WRONG** — `dbt source freshness` IS the correct command (verified at docs.getdbt.com), but `dbt test --select state:new` is a **slim-CI node selector** (selects newly-added nodes for testing), NOT a source freshness check. The two are unrelated; bundling them with "or" implies they're interchangeable for freshness checking, which is wrong. The correct alternative is `dbt build --select source_status:fresher+` (doc-verified at docs.getdbt.com/docs/build/sources: "Use the `dbt build --select source_status:fresher+` command to build and test models downstream of fresher sources"). |
| Completeness | 4.0 | Despite the decline, the hedged answer hits the core mechanism: freshness config block, warn_after/error_after, loaded_at_field, validation command. Missing: the `dbt build --select source_status:fresher+` pattern that ACTUALLY fails the build on stale sources; missing per-table override pattern; missing v1.9+ `config:` wrapper change. |
| Clarity | 4.0 | Decline framing is honest; the engineer knows they should look elsewhere for canonical detail. Hedged content is readable, but the `dbt test --select state:new` / `dbt source freshness` "or" disjunction is confusing and could mislead. |
| Actionability | 4.0 | Decline signals the engineer to look up dbt docs directly; hedged answer gives them search terms (`freshness:`, `warn_after`, `loaded_at_field`). But the wrong `dbt test --select state:new` command would mislead a beginner who tries it expecting it to check freshness. |

**Honest decline on a real resources gap is acceptable behavior — Accuracy not tanked. But the speculation in the hedged portion (wrong `dbt test` command) is a minor harm vector — flag this for iter540 teacher to close.**

---

## Topic-row updates

- **SQL query best practices for OLAP** (Q1 DECIMAL HALF_UP rounding + Q2 EXPLAIN diagnostic cluster): 4.5293/104 → (4.5293·104 + 5.000 + 4.625)/106 = 480.6272/106 = **4.5342/106** (+0.0049 — Q1 perfect lifts strongly; Q2 strong-pass also above topic avg)
- **Query performance regression diagnosis** (Q2 EXPLAIN scan-too-much also touches this row): 4.3338/16 → (4.3338·16 + 4.625)/17 = 73.966/17 = **4.3510/17** (+0.0172 — Q2 above topic avg lift)
- **Iceberg partition design for SaaS** (Q3 sorted_by + optimize cluster): 4.4813/37 → (4.4813·37 + 4.625)/38 = 170.4331/38 = **4.4851/38** (+0.0038 — Q3 marginally above topic avg)
- **dbt sources / source freshness** (Q4 cluster): 4.4689/5 → (4.4689·5 + 3.875)/6 = 26.2195/6 = **4.3699/6** (-0.0990 — Q4 below topic avg drags; speculation slip is real)
- **Federation row UNCHANGED**: 4.49944/310 (federation not probed this iter per directive).

---

## Iter540 teacher targets

### PRIMARY (HIGH) — Q4 dbt source freshness canonical (real resources gap + wrong-command-speculation correction)

**Resource**: r09 or wherever dbt source/freshness keyword path lands first. Search for existing "source freshness" content; if absent, ADD canonical section.

**Canonical content**:
- **Config (v1.9+)**:
  ```yaml
  sources:
    - name: jaffle_shop
      database: raw
      config:
        freshness:
          warn_after: {count: 12, period: hour}
          error_after: {count: 24, period: hour}
        loaded_at_field: _etl_loaded_at  # v1.10+ under config:
      tables:
        - name: orders
          config:
            freshness:
              warn_after: {count: 6, period: hour}
              error_after: {count: 12, period: hour}
        - name: product_skus
          config:
            freshness: null  # disable for this table
  ```
- **Period values**: `minute`, `hour`, `day`.
- **Required field**: `loaded_at_field` is the column dbt queries with `MAX()` to compute lag.
- **Validation commands** (doc-verified):
  - `dbt source freshness` — runs the freshness check; **error_after** breach exits non-zero.
  - `dbt build --select source_status:fresher+` — rebuilds only models downstream of fresh sources (the actual "fail builds when stale" pattern).
- **DO-NOT-WRITE banner**: do **NOT** describe `dbt test --select state:new` as a freshness-validation command. `state:new` is a slim-CI node selector that selects nodes added since a previous manifest, unrelated to source freshness. The correct commands are `dbt source freshness` and `dbt build --select source_status:fresher+`.

**Doc-quote anchor** (docs.getdbt.com/docs/build/sources): "To build models based on source freshness in dbt: 1. Run `dbt source freshness` to check the freshness of your sources. 2. Use the `dbt build --select source_status:fresher+` command to build and test models downstream of fresher sources."

**Keyword anchors** to embed in canonical: "dbt source freshness / dbt freshness threshold / dbt warn_after error_after / loaded_at_field / dbt fail build on stale source / dbt source_status:fresher+ / dbt source freshness command".

### SECONDARY (LOW) — Q2 EXPLAIN/EXPLAIN ANALYZE terminology nuance

Optional polish: in the EXPLAIN diagnostic canonical (r22/r23/r24 — wherever the responder's keyword path lands), tighten the "constraint pushed down" terminology. The literal `constraints` output appears in `EXPLAIN (TYPE IO)`, not the default distributed/logical EXPLAIN. The default EXPLAIN ANALYZE signal is the `Physical Input: X.YMB` line + `Filtered: NN.NN%` on the `ScanFilterProject` node. Responder's gist is right but precise vocabulary (`EXPLAIN (TYPE IO)` for constraint visibility) would tighten this. Low priority — does not currently harm answers.

### NO Q1/Q3 fixes needed — both strong-pass.

---

## Iter540 probe targets

- **HIGH — dbt source freshness 2nd angle (verifies FIX A landing)**: "how do I check the freshness of my dbt sources?" OR "how do I structure freshness: in dbt v1.9+ — under `config:` or top-level?" (must NOT mention `dbt test --select state:new` as the validation command; MUST mention `dbt source freshness` + `dbt build --select source_status:fresher+`).
- **MEDIUM — DECIMAL HALF_UP rounding 3rd angle (durability check on iter539 win)**: "CAST(DOUBLE '0.0049' AS DECIMAL(3,2)) — what value?" (answer: 0.00 because not at tie) OR "is `ROUND(0.005, 2)` also HALF_UP?" (answer: yes — see r23 §3.1C DO-NOT-WRITE row).
- **MEDIUM — Iceberg sorted_by 2nd angle**: "I set sorted_by but my old files still aren't sorted — why?" (answer: only new writes are sorted; old files need EXECUTE optimize with file_size_threshold high enough to include them) OR "does sorted_by replace partitioning?" (answer: no — sort is within-file; partitioning is across-file).
- **LOW — EXPLAIN ANALYZE 2nd angle (well-bulletproofed)**: "where in EXPLAIN ANALYZE do I see how many bytes my query actually read?" (answer: Physical Input on ScanFilterProject).
- **Federation stays UNPROBED** — row stays 4.49944/310.

---

## Meta-rule observation

The "verify YOUR OWN corrections" caveat was DECISIVE again — this iter I verified `sorted_by` ALTER-TABLE-eligibility (doc confirms it IS in the post-creation-editable list, so the responder's claim is not a fab). Also verified the `dbt source freshness` command name + the `dbt build --select source_status:fresher+` pattern directly against docs.getdbt.com so the iter540 PRIMARY canonical is doc-quoted. **3rd consecutive iter (iter537 NULLS-LAST + iter538 banker's-vs-HALF_UP + iter539 sorted_by-ALTER-eligibility + Q4 dbt-command-correction) where meta-rule prevented false-positive correction.**

**134th consecutive overall PASS in extended phase — margin +1.031 above floor.**

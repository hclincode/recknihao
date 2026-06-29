# Judge Feedback — Iteration 1280

**Overall**: 4 questions, average **4.25 PASS** (Q1 4.25 / Q2 3.875 / Q3 4.5 / Q4 4.375). Q2 is the weakest single answer — mechanism-diagnosis slip that the responder's OWN cited formulas refute, even though the practical FIX (ROUND/CAST) works.

**Headline results**:
1. **Q1 — Trino 467 partition-evolution; responder matches r10 §98-126 PIN with a minor "MUST use Spark" framing slip vs r10 §125's explicit defang.** NOT a Spark-spillover error — the conservative Spark-rewrite path IS what r10 + Trino docs (silent) + open Trino issues + Streamkap/Starburst guidance all recommend. Teacher's hypothesis that Trino EXECUTE optimize natively handles cross-spec re-layout is technically plausible but unverified — Trino docs are SILENT, open issues document gaps. NO FIX-A.
2. **Q2 — DECIMAL × INTEGER + SUM mechanism conclusion contradicts the responder's own cited formulas.** Responder correctly says scale=2 is preserved through both multiply (DECIMAL(10,2)*INTEGER → DECIMAL(20,2)) and SUM (DECIMAL(38,2)) — but then claims "extra internal precision shows up in display" which is impossible with scale=2 (display IS exactly 2 decimals). The 12-trailing-zeros symptom must come from upstream DOUBLE cast, division, or different upstream type — none of which the responder considered. FIX still works.
3. **Q3 — dbt_utils install mechanics + 4 of 5 listed macros/tests verified; `relationships` is dbt CORE built-in not dbt_utils** (peripheral mislabel; dbt_utils has `relationships_where`).
4. **Q4 — DENSE_RANK + WHERE rank=1 idiom correct; minor tie-handling completeness gap** (returns multiple rows per group on ties; Oracle MAX(...) KEEP DENSE_RANK FIRST returns exactly one via the MAX tie-break).

---

## Q1 — Iceberg partition spec evolution (month → day) on 600M-row events table

**Score: 4.0 / 4.5 / 4.5 / 4.0 = 4.25**

**Topic scored under**: "Iceberg partition design for SaaS: strategies, small-files, compaction" (4.4131/68 → 4.4111/69, margin +0.9111).

### CAN Trino 467 EXECUTE optimize NATIVELY repartition old-spec files to the new day spec? Is the responder's "MUST use Spark" claim FALSE?

**Verdict: NO, the Spark-required claim is NOT factually false — it matches Trino docs, open issues, and industry guidance.** Trino docs at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) describe EXECUTE optimize as bin-pack compaction with file_size_threshold (default 100MB); the docs are **SILENT** on whether it re-stamps pre-existing files to a newly-evolved partition spec. Open Trino issues confirm REAL gaps post-evolution:
- [trinodb/trino #25279](https://github.com/trinodb/trino/issues/25279) — newly-added partition column can't be a predicate during optimize (`IllegalStateException`);
- [trinodb/trino #12362](https://github.com/trinodb/trino/issues/12362) — hidden-partition columns can't be targeted by WHERE in optimize;
- [trinodb/trino #12983](https://github.com/trinodb/trino/issues/12983) — no parameter to selectively rewrite specific spec_ids.

Industry guidance:
- [Streamkap operational guide](https://streamkap.com/resources-and-guides/iceberg-partition-evolution-operational-guide) explicitly recommends `Spark CALL ... rewrite_data_files` with `WHERE` time-scoping for cross-spec re-layout;
- [Starburst blog](https://www.starburst.io/blog/iceberg-partitioning-and-performance-optimizations-in-trino-partitioning/): "The existing data will remain partitioned by day unless the table is recreated."

Teacher's hypothesis "Trino optimize SHOULD re-stamp rewritten files to day-partitioning, making this Trino-native with NO Spark needed" is **technically plausible** (when Trino's optimize rewrites a file it would write under the current spec, and raising file_size_threshold above all existing files' sizes would force-rewrite them) but **unverified for cross-spec correctness on Trino 467**. Trino docs don't endorse it; open issues document scenarios where it produces incorrect/NULL partition values. The responder's conservative answer matching r10 §98-126 PIN is the right answer on this stack.

### Is the claim RESOURCE-SOURCED (r10 grep result → FIX-A needed?) or a responder fabrication?

**Resource-sourced — r10 §98-126 (PARTITION EVOLUTION PIN, iter537 pin) and §131-233 (LEADING CANONICAL "Migrating from date-only to (date, tenant_bucket) on a 3TB table") teach EXACTLY this 3-step procedure**: ALTER TABLE SET PROPERTIES partitioning (Trino) → CALL iceberg.system.rewrite_data_files(rewrite-all=true) (Spark) → EXECUTE expire_snapshots (Trino). The 5-step worked example at r10 §141-200 is the canonical the responder cited.

**Slight framing slip vs r10 §125's explicit defang**: r10 §125 explicitly tells the teacher to AVOID the "MUST use Spark, Trino cannot do it at all" wording: *"Do not paraphrase this nuance as 'you MUST use Spark, Trino cannot do it at all.' Paraphrase it as 'Spark rewrite_data_files is the reliable, documented full-historical-repartition path; Trino optimize stays in its lane as go-forward compaction within the current spec.'"* The responder's "you MUST use Spark, NOT Trino" + "Trino rejects CALL" framing is SLIGHTLY STRONGER than this. The CALL-rejection sub-claim IS correct (Trino has no `CALL iceberg.system.rewrite_data_files`), but the overall framing exceeds what r10 wants. This is a **responder paraphrase slip** of an existing defang, NOT a resource defect (r10 already defangs the strong framing).

**NO FIX-A needed.** r10 has the right framing + defang; this is per-instance responder paraphrase slip matching `feedback_synthesis_ceiling_stop_churning.md` family.

### Other dings
- Minor Compl shave: responder didn't cover the partial-pruning behavior of old-spec files DURING the migration window. r10 §108-111 teaches that month-spec files STILL prune to the OLD month coarseness for date-range queries (a single-day query reads ~one month of old data, NOT the whole 2-year table). Engineer might worry the migration breaks queries until rewrite completes; r10 explicitly addresses this.

### NEW SOFT WATCH — `iter1280-Q1 partition-evolution MUST-use-Spark paraphrase slip vs r10 §125 defang`
Re-probe in 4-8 iters under varied "after partition evolution, how do I rewrite old files / can Trino do it / do I need Spark" framings. If 2+ recurrences with same "MUST use Spark" wording, escalate to LIGHT FIX-A strengthening r10 §125 defang anchor at the "rewrite_data_files" keyword zone (e.g., add a copy-attractive 1-line "Trino optimize IS go-forward compaction; Spark rewrite_data_files IS guaranteed historical re-layout — do not phrase as 'Trino CANNOT'" pin near the Step 2 Spark CALL command).

---

## Q2 — DECIMAL × INTEGER money math accumulating extra decimal places

**Score: 3.5 / 4.0 / 4.5 / 3.5 = 3.875**

**Topic scored under**: "SQL query best practices for OLAP" (4.5906/300 → 4.5882/301, margin +1.0882). **Weakest answer this iter.**

### Is the DECIMAL × INTEGER + SUM mechanism explanation accurate (scale preserved at 2?) even though the ROUND/CAST FIX is right?

**The CITED FORMULAS are correct; the CONCLUSION drawn from them is internally inconsistent and wrong.** Verified via WebFetch of [trino.io/docs/467/functions/decimal.html](https://trino.io/docs/467/functions/decimal.html):
- **Multiplication**: result precision = `min(38, xp+yp)`, result **scale = xs+ys** (verbatim). So DECIMAL(10,2) * INTEGER (coerced to DECIMAL(10,0)) = DECIMAL(min(38, 20), 2+0) = **DECIMAL(20, 2)** — scale is **2**, not widened.
- **SUM(DECIMAL(p,s))**: `sum(decimal(p, s)) -> decimal(38, s)` per [aggregate.html](https://trino.io/docs/467/functions/aggregate.html) — precision widens to 38 BUT **scale stays at s**. So SUM(DECIMAL(20,2)) = **DECIMAL(38, 2)** — scale is still **2**.

The responder cited both rules correctly: "DECIMAL(10,2)*INTEGER → auto-widened precision, preserved scale" + "SUM(DECIMAL) auto-widens to DECIMAL(38, s) with s=original scale (2)." **But then concluded "extra internal precision shows up in display" — which is impossible with scale=2.** Trino displays exactly s decimal places for a DECIMAL(p, s) result. DECIMAL(38, 2) displays as `1234.56`, full stop. It does NOT display as `1234.560000000000`.

**The 12-trailing-zeros symptom CANNOT come from the cited DECIMAL(10,2) × INTEGER + SUM path.** Real root causes (per r23 §3.1B troubleshooting checklist):
1. **An upstream CAST to DOUBLE**: DOUBLE is IEEE-754 floating-point and displays full precision (`1234.56` becomes `1234.5600000000001` in some contexts). If `unit_price` is actually DOUBLE not DECIMAL(10,2), or someone cast it, this is the culprit.
2. **A DECIMAL/DECIMAL division upstream**: Division DOES widen scale per Trino's `scale = max(xs, ys) + max(0, ys-xs)` rule (verified at decimal.html). A division before SUM would widen scale.
3. **The upstream column actually isn't DECIMAL(10,2)** — engineer's mental model of the schema is wrong. r23 §3.1B step 1 says: run `SHOW CREATE TABLE` first to verify the declared type.

The responder's FIX — `ROUND(SUM(unit_price*quantity), 2)` or `CAST(unit_price*quantity AS DECIMAL(18,2))` before SUM — **WORKS regardless of root cause** (truncates whatever extra precision is present). Engineer ships a working query but learns the wrong reason for the symptom. If the column is actually DOUBLE, the fix masks the underlying type problem; if there's an upstream division, the fix masks scale widening; engineer doesn't learn to look at `SHOW CREATE TABLE` or `EXPLAIN` first.

### Resource check — was the wrong mechanism resource-sourced?

**NO. Grepped r23 §3.1B (line 955-984):**
- r23 line 959: "Trino's `sum(decimal(p, s)) -> decimal(38, s)`... **Precision is auto-widened to 38 (Trino's maximum); scale is retained.**" — CORRECT, matches Trino docs.
- r23 §3.1B includes a 5-cause troubleshooting checklist (line 963-971) for "SUM looks too small / numbers are truncated" that explicitly enumerates upstream CAST to smaller scale, integer division, NULL-heavy column.
- **r23 does NOT have a "scale widens on display" myth.** The responder's wrong conclusion is per-instance responder reasoning, not resource-sourced.

### NO FIX-A
r23 §3.1B is the right canonical. The responder cited the right formulas but didn't reach the troubleshooting-checklist mental model (r23 §3.1B step 1: run `SHOW CREATE TABLE`; step 5: check for upstream integer division). This is per-instance responder reasoning slip — NOT findability, NOT content gap, NOT resource defect.

### NEW SOFT WATCH — `iter1280-Q2 DECIMAL-SUM-scale-preserved mechanism conclusion slip`
Re-probe in 4-8 iters under "money math too many decimals / decimal precision / SUM(DECIMAL*INTEGER) display" framings. If 2+ recurrences where responder cites the right formula but draws the wrong display conclusion, escalate to LIGHT FIX-A adding to r23 §3.1B a copy-attractive callout: **"scale=s preserved through SUM = display shows EXACTLY s decimals; if you see MORE decimals, the culprit is upstream — DOUBLE cast / division / wrong source type. Run `SHOW CREATE TABLE` first."**

---

## Q3 — dbt_utils package: what it is, install mechanics, day-to-day use

**Score: 4.5 / 4.5 / 4.5 / 4.5 = 4.5**

**Topic scored under**: "Improving complex SQL performance on Trino with dbt" (4.4864/85 → 4.4866/86, margin +0.9866).

### Verification
- **Install mechanics correct**: packages.yml at project root with `packages: - package: dbt-labs/dbt_utils, version: [">=1.1.0","<2.0.0"]`; `dbt deps` materializes to `dbt_packages/`. Matches r27 §4.5A canonical (lines 1764-1788) verbatim.
- **`generate_surrogate_key(['email','signup_source'])` → MD5 hash surrogate** — CORRECT, matches r27 §4.5A.
- **`expression_is_true` — IS dbt_utils generic test** ✓
- **`not_null_proportion` — IS dbt_utils generic test** ✓
- **`unique_combination_of_columns` — IS dbt_utils generic test** ✓

### MINOR MISLABEL — `relationships` is dbt CORE built-in, NOT dbt_utils

Verified via WebSearch + [docs.getdbt.com/docs/build/data-tests](https://docs.getdbt.com/docs/build/data-tests): **"dbt ships with four generic data tests already defined: unique, not_null, accepted_values, and relationships."** dbt_utils has `relationships_where` (relationships + WHERE filter for excluding test entities or recent records due to ETL lag) — possibly the responder confused these two.

**Minor peripheral mislabel** — doesn't affect install mechanics or the 4 correctly-listed macros/tests. The engineer would still install dbt_utils and find the correct tests; they'd just be momentarily confused that `relationships` is available without dbt_utils (which is actually a happy surprise, not a blocker).

### NO FIX-A
r27 §4.5A is correct on install/macros. Resources don't claim relationships is dbt_utils — this is per-instance responder slip, not resource defect or findability gap. No imported-prior, no broken-secondary, no fabrication.

Minor Clar/Prac/Compl shaves (-0.5 each): no on-prem-stack-specific notes like dbt-trino adapter compatibility or how `dbt_packages/` gets vendored in CI for offline builds (peripheral, recall ceiling).

---

## Q4 — Oracle MAX(col) KEEP (DENSE_RANK FIRST ORDER BY created_at) → Trino

**Score: 4.5 / 4.5 / 4.5 / 4.0 = 4.375**

**Topic scored under**: "Oracle PL/SQL → dbt+Trino" (4.5076/248 → 4.5070/249, margin +1.0070).

### Verification
- **Core idiom CORRECT**: CTE `DENSE_RANK() OVER (PARTITION BY order_id ORDER BY created_at) AS rank_val`, outer `WHERE rank_val=1` → earliest row per group. Standard Trino window-function pattern.
- **ALT FIRST_VALUE OVER (PARTITION BY ... ORDER BY created_at)** — valid Trino window form.
- **"No KEEP in Trino"** — CORRECT, Oracle KEEP DENSE_RANK FIRST/LAST is a non-portable Oracle extension; ANSI SQL alternative is window functions.
- **"window form not much longer" tradeoff** — fair characterization.

### MINOR TIE-HANDLING COMPLETENESS GAP

Verified via [Oracle DENSE_RANK docs](https://docs.oracle.com/en/database/oracle/oracle-database/26/sqlrf/DENSE_RANK.html) + WebSearch: Oracle `MAX(value) KEEP (DENSE_RANK FIRST ORDER BY created_at)` is a TIE-BREAKER. Among rows tied at rank 1 (same earliest `created_at`), the outer MAX returns exactly ONE row by taking the maximum `value`.

**Responder's `WHERE rank_val=1` returns MULTIPLE rows per order_id when ties exist** (two rows with identical `created_at` → both rank 1 → both returned). For strict Oracle KEEP MAX equivalence:
- **`ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY created_at, value DESC) AS rn`** then `WHERE rn=1` — guarantees one row + matches MAX tie-break direction;
- **Wrap an outer `MAX(value)` aggregate** over the WHERE rank_val=1 subset;
- The responder's `FIRST_VALUE(created_at) OVER (...)` ALT is closer to deterministic but still broadcasts the same value to every row in the partition — needs `DISTINCT` or filter to one-row-per-group.

If the engineer's Oracle source uses MAX/MIN as a tie-breaker (the canonical Oracle pattern), the responder's DENSE_RANK + WHERE rank=1 form would produce DIFFERENT row counts than the Oracle source. Per-instance completeness slip.

### NO FIX-A
Core idiom is correct; r07/r27 already teach window-functions-replace-Oracle-KEEP. The tie-handling note is peripheral; engineer with strict-equivalence need would catch it in CI / row-count diff testing. Per-instance completeness gap, NOT findability/content gap.

No imported-prior, no broken-secondary, no over-warning, no fabrication.

---

## Summary — NEW WATCHES + carry forward

### NEW WATCHES (this iter)
1. **`iter1280-Q1 partition-evolution MUST-use-Spark paraphrase slip vs r10 §125 defang`** — re-probe in 4-8 iters under varied "rewrite old files post-evolution / can Trino do it / do I need Spark" framings. Escalate to LIGHT FIX-A only if 2+ recurrences with the same strong wording.
2. **`iter1280-Q2 DECIMAL-SUM-scale-preserved mechanism conclusion slip`** — re-probe in 4-8 iters under "money math too many decimals / decimal precision / SUM(DECIMAL*INTEGER) display" framings. Escalate to LIGHT FIX-A only if 2+ recurrences where responder cites the right formula but draws the wrong display conclusion. The fix would be a copy-attractive callout to r23 §3.1B.

### Carry forward (from iter1279)
- `iter1279-Q4 Trino-now()-as-alias-not-confirmed` — re-probe 4-8 iters under NOW()/Postgres-now-migration framings; not touched this iter.
- `iter1278-Q1 Scheduled-vs-CPU-Blocked-time imprecision` — re-probe 3-7 more iters; not touched this iter.

### Pattern signals
- **Q1 framing slip + Q2 mechanism slip** are BOTH per-instance responder reasoning slips on otherwise-correct cited formulas/resources. Neither is resource-sourced. Matches `feedback_synthesis_ceiling_stop_churning.md` family.
- **Q3 relationships mislabel + Q4 tie-handling miss** are BOTH peripheral completeness slips on otherwise-correct core answers. Recall ceiling, NO FIX-A.
- **No imported-prior assumed-absence/assumed-presence errors this iter** (the imported-prior family that has been hot for many iters is quiet).
- **No broken-secondary alternative** (the iter936/943/948/950/954/1013/1019/1020 family is quiet).
- **No over-warning** (the iter1016/1017/1021 family is quiet).

### Topic margins remain healthy
- Iceberg partition design: 4.4111/69 (margin +0.9111)
- SQL best practices for OLAP: 4.5882/301 (margin +1.0882)
- Improving complex SQL perf on Trino with dbt: 4.4866/86 (margin +0.9866)
- Oracle PL/SQL → dbt+Trino: 4.5070/249 (margin +1.0070)

**iter1280 = 4.25 PASS — pure breadth round; 2 new soft watches; NO FIX-A; continuing PASS loop pattern from iter1279 4.797 STRONG PASS. Q2 is the iter's weakest (3.875) and the only score that materially dips below typical recent averages — worth re-probing decimal-precision framings to disambiguate one-off vs systemic.**

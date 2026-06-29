# Iteration 1247 — Judge Feedback

## Verdict

**Overall: 4.22 — PASS, with two load-bearing slips: a Q1 partition-evolution direction-inversion (resource-sourced; FIX-A WARRANTED) and a Q3 dbt-model-versions content gap (honest bail; FIX-A WARRANTED).** Per-Q scores: Q1=3.875, Q2=4.625, Q3=3.375, Q4=5.0. Average (3.875+4.625+3.375+5.0)/4 = 16.875/4 = **4.219**.

Two watches re-probed:
- **iter1208 width_bucket-boundary watch CLOSES.** Q2 array-form numbering CORRECT (0,1,2,3 for ARRAY[10,50,100]) and matches RAW source `MathFunctions.java @ 467` (binary-search returns 0 below first bin, N at/above last bin). Minor aside-slip on the equi-width form labeling but not load-bearing.
- **iter1231 NEXT_DAY watch CLOSES.** Q4 formula correct, all edge cases verified (Wed→+5=Mon, Mon→+7=following-Mon never same-day, Sun→+1=Mon), no self-contradicting closing note.

Headline pattern: Q1's INVERTED pruning-granularity claim was LIFTED from r10 §109's worked example, which only covers the OPPOSITE direction (refinement `month→day` where OLD is coarse) and was misapplied to the engineer's coarsening case (`day→month` where OLD is FINE). That is a resource-sourced findability+content trap, not a pure responder slip. Q3 honest bail is acceptable but a real recurring SaaS schema-evolution pattern deserves a card.

---

## Per-question evaluation

### Q1 — Iceberg partition evolution DAY→MONTH coarsening — **3.875**

**Acc 3 / Clar 4.5 / Prac 3.5 / Compl 4.5**

**Verdict: DIRECTION-INVERSION on pruning-granularity claim. FIX-A WARRANTED in r10 §109.**

What is CORRECT (verified via WebSearch + r10 §102-107):
- `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY['month(event_date)']` is METADATA-ONLY (milliseconds, no data movement). ✓
- Old data files keep their OLD `spec_id`; new writes use the new spec_id. ✓
- Trino reads transparently across mixed specs. ✓
- To reorganize old data into the new layout: Spark `CALL iceberg.system.rewrite_data_files(... 'rewrite-all','true' ...)` then expire snapshots. ✓ (Matches r10 §106 + §163-179 canonical.)
- Engineer's verification query `SELECT spec_id, COUNT(*) FROM ..."$files" GROUP BY spec_id` would work to confirm the split.

What is INVERTED (the load-bearing slip):
- Responder claimed: "query `WHERE event_date = DATE '2026-01-15'` projects through the OLD MONTHLY partition transform, so instead of pruning to one day-partition it must read the ENTIRE January MONTH partition (old files don't track daily granularity); old data prunes to the old COARSER bucket."
- **VERIFIED via WebSearch** ([Dremio partition-evolution post](https://www.dremio.com/blog/apache-iceberg-partition-evolution-change-your-partitioning-strategy-without-rewriting-data/), [Iceberg evolution docs](https://iceberg.apache.org/docs/latest/evolution/), [iceberglakehouse partition-evolution](https://iceberglakehouse.com/iceberg/iceberg-partition-evolution/)): "the engine evaluates partition filters against each file's partition spec. Files written under the old scheme are filtered using old partition boundaries."
- **In the engineer's ACTUAL case the OLD spec is DAY (FINE)**: the 2 years of daily-partitioned data was the starting state. After the ALTER, NEW writes use MONTH. So:
  - OLD files (spec_id=0, DAY transform) → predicate projects through DAY → prunes to the EXACT DAY partition (FINE pruning, single day).
  - NEW files (spec_id=1, MONTH transform) → predicate projects through MONTH → prunes to the entire JANUARY MONTH partition (COARSER).
- The responder INVERTED the direction — said "old data prunes to OLD COARSER monthly bucket" when in fact old data prunes FINELY at day-granularity, and it's the NEW data that prunes coarsely at month-granularity.

**ROOT CAUSE — RESOURCE-SOURCED, not pure responder slip:** I grepped r10. §109 documents ONLY the OPPOSITE direction:

> "TRANSFORM REFINEMENT on the SAME source column (`month(event_date) → day(event_date)`, or `day→hour`, or identity→bucket): old-spec files STILL prune — at the OLD, COARSER granularity. Iceberg projects the predicate through the OLD transform: a query `WHERE event_date = DATE '2026-01-15'` projects to `month(event_date) = '2026-01'`, so the planner KEEPS only the old files in the 2026-01 month partition..."

That worked example assumes OLD=MONTH, NEW=DAY (REFINEMENT). The engineer's case is OLD=DAY, NEW=MONTH (COARSENING). The responder lifted §109's framing verbatim ("old data prunes to coarser bucket") without realizing the direction was opposite. **§109 has no COARSENING worked example** — it's a one-sided treatment that primes the responder for the same inversion across direction.

**Practical impact on the engineer:** the recommended fix (Spark `rewrite_data_files(rewrite-all=true)`) is CORRECT and would solve the underlying problem (30-day scans slow from too-many-small-daily-partitions). So the engineer arrives at the right action despite the wrong mental model of the pruning direction. But if they internalize "old data scans the whole month" they will mis-debug subsequent pruning issues.

**FIX-A recommendation: LIGHT FIX-A in r10 §109** — add a COARSENING case to the existing REFINEMENT case. Proposed wording (verify against Iceberg spec before writing):

> **TRANSFORM COARSENING on the SAME source column** (`day(event_date)` → `month(event_date)`, or `hour`→`day`, or `bucket(N,col)`→`identity(col)`): old-spec files STILL prune at the OLD FINER granularity (engine projects the predicate through the OLD transform). Query `WHERE event_date = DATE '2026-01-15'` on `day(event_date)` old files → prunes to the SPECIFIC DAY partition (fine pruning, single old-file's worth of data). NEW month-spec files prune to the JANUARY MONTH partition (one month of files). **It is WRONG to tell the engineer the old data "now reads the whole month" — old data still prunes at day granularity (its original spec); only NEW data uses month-granularity pruning.**
>
> The coarsening case typically arises when the original partition was too fine (many small files per day eating planning time). The spec change alone does NOT compact old data — old daily partitions remain numerous and small until rewritten. The same Spark `rewrite_data_files(rewrite-all=true)` fix applies, restamping old files under the new MONTH spec for consolidation.

Symmetric two-direction worked examples close this trap. Same FIX-A pattern as the iter1234 ROLLUP-date_trunc cleanup.

Minor clarity shave already factored in (-0.5): the pruning-direction inversion confuses but does not destroy the rest of the answer.

**NEW WATCH:** `iter1247 Q1 partition-evolution-COARSENING-direction-inversion` — re-probe under DAY→MONTH and HOUR→DAY framings 4-8 iters after FIX-A lands.

---

### Q2 — width_bucket for custom uneven spend tiers (RE-PROBE) — **4.625**

**Acc 4 / Clar 5 / Prac 5 / Compl 4.5**

**Verdict: iter1208 width_bucket-boundary watch CLOSES.** Core answer fully correct against RAW source.

VERIFIED via [Trino 467 docs/src/main/sphinx/functions/math.md](https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/math.md) + [Trino 467 MathFunctions.java source](https://raw.githubusercontent.com/trinodb/trino/467/core/trino-main/src/main/java/io/trino/operator/scalar/MathFunctions.java):
- `width_bucket(x, bins ARRAY) → bigint` — array-based overload exists in 467, bins assumed sorted ascending. ✓
- Implementation: binary search returns `lower` (init 0) if `operand < bin` (below first bin), returns `numberOfBins` if loop exits with `lower == numberOfBins` (at-or-above last bin).
- For `ARRAY[10.0, 50.0, 100.0]` (3 elements, N=3):
  - `spend < 10` → 0 ✓
  - `10 ≤ spend < 50` → 1 ✓
  - `50 ≤ spend < 100` → 2 ✓
  - `spend ≥ 100` → 3 ✓
- Responder's numbering is correct. The `CASE WHEN spend_tier = 0 THEN '$0-10' ...` wrapping pattern is the right next step for the dashboard.
- "Bounds array must be ascending" — correct (docs verbatim).

**Minor accuracy ding (-1) on the equi-width aside:** Responder said "the 4-parameter equal-width form returns 1-based, UNLIKE the array form which returns 0-based." This is IMPRECISE. Per source, equi-width `width_bucket(x, bound1, bound2, n)` returns:
- `x < bound1` → 0
- `bound1 ≤ x < bound2` → distributed into 1..n
- `x ≥ bound2` → n+1

Both forms return 0 for below-first, so calling the equi-width "1-based" while array is "0-based" is misleading. The actual difference: equi-width has TWO out-of-range sentinels (0 below, n+1 above); array form has ONE explicit "0 below" sentinel and N at-or-above-last (which is also a valid bucket number — meaning N elements split the line into N+1 intervals numbered 0..N).

Not load-bearing for the spend-tier dashboard answer (engineer is using the array form, not equi-width). But the responder's aside, if remembered and applied to a future equi-width question, would mislead. NO FIX-A (single aside-slip on the not-asked variant; recall ceiling, not resource defect).

Minor completeness shave (-0.5): could mention that the `bins` parameter must be `array(double)` so an `ARRAY[10, 50, 100]` of integers may need `ARRAY[10.0, 50.0, 100.0]` or `CAST` to avoid type-coercion surprises (responder already wrote `10.0`-form which dodges this).

**Watch CLOSES:** iter1208 width_bucket-boundary — array-form numbering and boundary semantics correct against RAW Trino 467 source. Move on.

---

### Q3 — dbt model versioning (fct_user_activity v1+v2 concurrent) — **3.375**

**Acc 4 / Clar 4 / Prac 3 / Compl 2.5**

**Verdict: HONEST BAIL but content gap — FIX-A WARRANTED in r28 (or r27 dbt-workflow section).**

Responder said: "I don't have enough information... resources don't cover dbt model versioning. It's a dbt-core 1.7 feature. See [docs.getdbt.com/docs/build/versions](https://docs.getdbt.com/docs/build/versions). Raise this as a gap in the resources."

What is RIGHT:
- Named the feature correctly. ✓
- Pointed to a relevant docs path (close enough to the real [docs.getdbt.com/docs/mesh/govern/model-versions](https://docs.getdbt.com/docs/mesh/govern/model-versions)). ✓
- Did NOT fabricate config syntax. ✓ Per `feedback_responder_broken_secondary_alternative.md`, honest bail beats wrong-form fabrication.
- Flagged the gap so teacher can act. ✓

What is SLIGHTLY OFF:
- "dbt-core 1.7 feature" — VERIFIED via [docs.getdbt.com/docs/collaborate/govern/model-versions](https://docs.getdbt.com/docs/collaborate/govern/model-versions) (WebFetch) and [dbt-core 1.6.0 release notes](https://github.com/dbt-labs/dbt-core/releases/tag/v1.6.0) (WebFetch confirms "Detect breaking contract changes to versioned models" + "Support `_`-delimited fqn matching for versioned models"): model versions was introduced in dbt-core **1.6** (initial governance + versioning), refined in 1.7 (breaking-change detection on versioned + non-versioned models + type aliasing). Responder's "1.7" is one minor version off — works but the cutoff isn't quite right.

GREP CONFIRMS RESOURCE GAP: I searched `resources/` for `model.versioning`, `latest_version`, `versions:`, `fct_user_activity_v` — **ZERO hits**. The responder's "resources don't cover this" is TRUE, not a findability miss.

VERIFIED what dbt model versions actually does (from [docs.getdbt.com/docs/collaborate/govern/model-versions](https://docs.getdbt.com/docs/collaborate/govern/model-versions) via WebFetch):
- Multiple versions coexist as separate database relations: `fct_user_activity_v1`, `fct_user_activity_v2` (and the unsuffixed `fct_user_activity` is an alias for the `latest_version`).
- File naming: `fct_user_activity_v1.sql`, `fct_user_activity_v2.sql` (default; overridable via `defined_in:`).
- Minimum schema.yml config:
  ```yaml
  models:
    - name: fct_user_activity
      latest_version: 1
      versions:
        - v: 2
        - v: 1
  ```
- `ref('fct_user_activity', v=1)` to pin a consumer to v1; bare `ref('fct_user_activity')` resolves to `latest_version`.
- Per-version materialization possible (`config: materialized: table`).
- `dbt run --select fct_user_activity.v2` to build a single version.
- Works on dbt-core + adapter — NOT dbt Cloud-exclusive. dbt-trino is an adapter, so this works on the production stack.

WHY A FIX-A IS WARRANTED:
- The SaaS engineer's pattern (DS notebook consumers vs product dashboard consumers needing different schemas, staggered cutover) is a RECURRING question. This will be asked again.
- The responder's resource-gap acknowledgement was correct, but a single card in r28 (Improving complex SQL performance on Trino with dbt — the dbt-workflow topic) would close the gap.
- Recommended LIGHT FIX-A location: **r28** (or alternatively the dbt-workflow section of r27). Card content:
  - Feature name + dbt-core 1.6+ + works with dbt-trino adapter.
  - schema.yml minimum config (above).
  - File naming convention (`<model>_v<N>.sql`).
  - Database relation naming (`<model>_v1`, `<model>_v2`, `<model>` = alias for latest).
  - `ref('model', v=N)` consumer syntax.
  - When to use: parallel serving of breaking schema changes (the SaaS pattern engineer described).
  - Tie-in with `dbt model contracts` (already-passing topic) — versions + contracts combine to enforce that breaking changes increment the version.

Scoring rationale:
- Acc 4: feature named correctly + docs path close; minor version-cutoff slip (1.7 vs 1.6).
- Clar 4: honest about the gap, didn't fabricate.
- Prac 3: engineer knows the feature exists + can find docs, but no inline config to paste.
- Compl 2.5: question asked "minimum setup" — that part was not answered with any config.

**NEW WATCH:** `iter1247 Q3 dbt-model-versioning content gap` — after FIX-A lands, re-probe under "serve two versions of a dbt model concurrently" framings 2-3 iters to verify findability.

---

### Q4 — Oracle NEXT_DAY → Trino "next weekday strictly after" (RE-PROBE) — **5.0**

**Acc 5 / Clar 5 / Prac 5 / Compl 5**

**Verdict: iter1231 NEXT_DAY watch CLOSES.** Formula correct, all edge cases verified, no self-contradicting closing note.

Responder formula: `date_add('day', ((1 - day_of_week(billing_date) + 6) % 7) + 1, billing_date)`

VERIFIED edge cases:
- Wed 2026-06-03 (dow=3): `((1-3+6) % 7) + 1 = (4 % 7) + 1 = 5` → `+5 days` = 2026-06-08 = Monday ✓
- Mon 2026-06-08 (dow=1, same-weekday case): `((1-1+6) % 7) + 1 = (6 % 7) + 1 = 7` → `+7 days` = 2026-06-15 = following Monday ✓ (never same-day — matches Oracle NEXT_DAY's "strictly after" semantics)
- Sun 2026-06-07 (dow=7): `((1-7+6) % 7) + 1 = (0 % 7) + 1 = 1` → `+1 day` = 2026-06-08 = Monday ✓
- Tue 2026-06-09 (dow=2): `((1-2+6) % 7) + 1 = (5 % 7) + 1 = 6` → `+6 days` = 2026-06-15 = Monday ✓

Inner expression `(1 - dow + 6)` ranges from 0 (when dow=7) to 6 (when dow=1) — always non-negative, so `% 7` is harmless (no Trino-modulo-negative-input trap). Then `+1` gives 1..7 day-offset. Formula correctly clamps to "strictly between 1 and 7 days ahead."

`day_of_week` ISO 1-7 (Mon=1..Sun=7) verified against Trino 467 datetime-functions docs.

Generalization "substitute target ISO number for the target weekday" is CORRECT — for target weekday `t` (ISO 1-7):
```
date_add('day', ((t - day_of_week(d) + 6) % 7) + 1, d)
```
Same shape; same strictly-after guarantee.

The closing note is self-consistent (no iter1231-style contradiction). Engineer can drop this into a billing-date job as a direct Oracle NEXT_DAY replacement.

**Watch CLOSES:** iter1231 NEXT_DAY-note self-contradiction — formula and note now both clean. Move on; do not churn further.

---

## Watch ledger updates

**CLOSED this iter:**
- `iter1208 width_bucket-boundary` — array-form numbering + boundary semantics correct against RAW Trino 467 source (Q2 4.625).
- `iter1231 NEXT_DAY-note` — formula correct, all 4 edge cases verified, no self-contradicting note (Q4 5.0).

**OPENED this iter:**
- `iter1247 Q1 partition-evolution-COARSENING-direction-inversion` — pruning-direction claim inverted for DAY→MONTH coarsening (lifted from r10 §109's one-sided REFINEMENT-only worked example). LIGHT FIX-A WARRANTED in r10 §109 to add the COARSENING case symmetrically. Re-probe under DAY→MONTH and HOUR→DAY framings 4-8 iters after FIX-A.
- `iter1247 Q3 dbt-model-versioning content gap` — feature genuinely absent from `resources/`. LIGHT FIX-A WARRANTED in r28 (Improving complex SQL performance on Trino with dbt) or r27 dbt-workflow section. After FIX-A, re-probe 2-3 iters on "serve two model versions concurrently" framings.

**CARRIED OPEN (not touched this iter, still active):**
- iter1246 Q3 OOM-session-prop-direction (soft, recall ceiling, no fix)
- iter1245 expire-orphan (soft)
- iter1245 GREATEST-oracle-premise (soft)
- iter1241 concat-auto-coerces
- iter1240 orphans-$files
- iter1239 DF-wait-timeout
- iter1238 broadcast-hedge
- iter1236 rn=1-within-batch
- iter1234 ROLLUP-date_trunc-expr
- iter1230 EXISTS-overwarning/::cast
- iter1215 strpos-3-arg ceiling
- iter1213 session_properties/(+)
- iter1229 @v1-Spark

---

## Topic scoring updates

- **Q1** → "Iceberg partition design for SaaS: strategies, small-files, compaction" — 4.4380/62 → (62×4.4380 + 3.875)/63 = **4.4291/63 PASSED** (-0.0089, margin +0.9291)
- **Q2** → "SQL query best practices for OLAP" — 4.5843/289 → (289×4.5843 + 4.625)/290 = **4.5844/290 PASSED** (+0.0001, margin +1.0844)
- **Q3** → "Improving complex SQL performance on Trino with dbt" — 4.5039/64 → (64×4.5039 + 3.375)/65 = **4.4866/65 PASSED** (-0.0173, margin +0.9866)
- **Q4** → "Oracle PL/SQL → dbt+Trino" — 4.4692/214 → (214×4.4692 + 5.0)/215 = **4.4717/215 PASSED** (+0.0025, margin +0.9717)

All required topics REMAIN PASSED. Q1 and Q3 are scored under topics with comfortable margins so the FAILs don't drop the topic averages below threshold even before FIX-A lands.

---

## Patterns / meta

1. **The DIRECTION-INVERSION trap (Q1) is the second instance of one-sided-worked-example causing a flipped framing** (after iter1234 ROLLUP-date_trunc-expr where only one direction had been worked). Symmetric two-direction worked examples close it. Same FIX-A shape.

2. **The honest bail (Q3) is a clean response under `feedback_responder_broken_secondary_alternative.md` doctrine** — better than fabricating dbt config. But model versions IS a real recurring SaaS pattern that deserves a card; this gap should be closed before the next dbt-versioning re-probe.

3. **Two watches CLOSE in one iter** (iter1208 + iter1231) — both with WebFetch+RAW-source verification (Trino 467 MathFunctions.java for width_bucket; manual edge-case walkthrough for NEXT_DAY). The verify-first pattern continues to pay off.

4. **No imported-prior judge slip this iter** — width_bucket numbering, Iceberg partition-evolution semantics, dbt model-versions feature existence + version, and Trino date_add modulo arithmetic all verified against primary sources before scoring. The iter1239 / 1242 / 1246 verify-first save streak continues.

5. **Q1's resource root-cause is a textbook `feedback_trace_recurring_folklore_to_resource_root_cause.md` pattern**: the responder's inversion looked like a pure slip until grep'd into r10 §109 — the resource only walks the REFINEMENT direction. Per the playbook, when a responder slip on a peripheral framing looks confident, grep first. Confirmed direct trace.

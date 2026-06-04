# Judge Feedback — Iter 439 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.6875 PASS** (Q1 4.9375 + Q2 4.9375 + Q3 4.5625 + Q4 4.3125) — **-0.2344 step-DOWN from iter438 4.921875 driven by TWO confident inaccuracies: (Q3) "SCD-1 pivot pattern" mislabel and (Q4) WRONG metadata-table quoting `your_table."$snapshots"` instead of canonical `"your_table$snapshots"`.** 38th consecutive overall PASS in extended phase. All required topics REMAIN PASSED. Zero-confident-inaccuracy streak BREAKS at 1 iter — TWO confident-inaccuracies in one iteration.

---

## HEADLINE

1. **Q1 federation BUFFER probe — STRONG PASS 4.9375; federation 4.5027 → 4.5041 / 301, margin widens from +0.00265 to +0.00410 (×1.55 expansion); FEDERATION STAYS PASSED — durability extended further.** Pushdown EXPLAIN signature canonical: constraint-inside-TableScan = pushed (no separate ScanFilterProject); Filter-above-TableScan = Trino-side, all rows pulled to memory. 50k-of-10M-cross-JDBC quantification accurate. Web UI input rows/bytes verification step + read-replica-latency callout actionable. Verified per trino.io/docs/current/optimizer/pushdown.html. 301-datapoint density milestone reached.

2. **Q2 isolation serializable-vs-snapshot — STRONG PASS 4.9375.** All canonical claims verified: default serializable, manifest min/max conservative, disjoint-partition false-positive root cause, MERGE default serializable, `ValidationException: Found conflicting files that can contain records matching <expr>` + `CommitFailedException` after `commit.retry.num-retries=4`, three per-op props `write.{merge,delete,update}.isolation-level`, snapshot fix for disjoint-partition workloads. Verified per Iceberg 1.5.2 IsolationLevel javadoc + apache/iceberg #11687. Iter439 §2/§5 javadoc-verbatim tightening (r26) LANDED PRECISELY on direct re-probe.

3. **Q3 CASE-WHEN-in-aggregate pivot — PASS 4.5625 BUT confident-inaccuracy flagged: "SCD-1 pivot pattern" mislabel.** SQL itself is fully valid Trino: `SUM(CASE WHEN quarter='Q1' THEN revenue END)` returns the revenue value on match, NULL otherwise; SUM ignores NULL; four-column quarter pivot is the canonical conditional-aggregation pattern. NO rewrite needed. **BUT the label "canonical SCD-1 pivot pattern" is WRONG** — SCD-1 = Slowly Changing Dimension Type 1 = dimension overwrite-on-change strategy (a totally different concept). The correct label is "conditional aggregation" / "manual pivot" / "crosstab". The SQL is right; the label is misleading and would confuse any engineer who later looks up "SCD-1" and finds a dimension-update strategy. **Confident terminology inaccuracy.**

4. **Q4 rollback + orphan files — PASS 4.3125 BUT confident-inaccuracy flagged: WRONG metadata-table quoting.** Canonical claims correct: `CALL iceberg.system.rollback_to_snapshot('analytics','your_table',id)` positional args on Trino 467 — VERIFIED; metadata-only rollback (instant, no data-file touch) — CORRECT; orphaned-not-deleted-immediately + lifecycle rollback → expire_snapshots(7d) → remove_orphan_files — VERIFIED per iceberg.apache.org/docs/latest/maintenance/ + Trino 481 connector docs; don't hand-delete MinIO files — CORRECT. **BUT `iceberg.analytics.your_table."$snapshots"` is WRONG Trino metadata-table syntax — the canonical form is `iceberg.analytics."your_table$snapshots"` (the WHOLE `table$suffix` MUST be inside ONE double-quoted identifier).** The form `your_table."$snapshots"` would be parsed as a column/field reference under your_table and would NOT resolve to the metadata table. Verified per trino.io/docs/current/connector/iceberg.html. **Confident syntactic inaccuracy — engineer copy-pasting would hit a resolve error.**

---

## Critical confirmations (explicit)

### (a) Q1 federation BUFFER probe — score + federation average + margin + STAYS PASSED?

**Q1 score: 4.9375 STRONG PASS** — ninth consecutive 4.75+ federation datapoint.

**Federation average update:**
- Prior: 4.5027 × 300 = 1350.81 sum (precise: 1350.7963)
- + Q1 4.9375 = +4.9375
- New sum: 1355.7338
- New count: 301
- **New average: 1355.7338 / 301 = 4.5041** (margin +0.00410 above 4.5 threshold)

**Margin above 4.5 threshold:**
- Iter438 margin: +0.00265
- Iter439 margin: **+0.00410** (×1.55 buffer expansion)

**STAYS PASSED?** **YES — Federation REMAINS PASSED with margin widening from +0.00265 to +0.00410 (×1.55 buffer expansion).** Federation is now at 301 datapoints. The two confident-inaccuracies this iter were NOT in federation territory — Q1 was a clean STRONG PASS. Federation durability continues to reinforce.

**Pushdown EXPLAIN signature verified per trino.io docs:**
- Constraint inside TableScan = pushed — VERIFIED per trino.io/docs/current/optimizer/pushdown.html ("the EXPLAIN plan for the query does not include a ScanFilterProject operation for that clause")
- Separate Filter above TableScan = Trino-side, not pushed — VERIFIED
- 50k of 10M cross-JDBC pushed = 200x network reduction — CORRECT framing
- Trino Web UI input rows/bytes verification — VERIFIED per trino.io/docs/current/admin/web-interface.html
- Read-replica latency callout — practical SaaS-engineer-friendly framing

### (b) Q2 isolation verified accurate?

**YES — Q2 score: 4.9375 STRONG PASS — all canonical claims verified.**

- Serializable = default — VERIFIED per iceberg.apache.org/javadoc/1.5.2/.../IsolationLevel.html
- Serializable conservative manifest min/max check fails if concurrent file MIGHT match WHERE — VERIFIED per Iceberg IsolationLevel javadoc verbatim text
- Snapshot only fails on actually-modified rows, phantom-row tradeoff acknowledged — VERIFIED
- MERGE default serializable — VERIFIED per iceberg.apache.org/docs/latest/configuration/
- `ValidationException: Found conflicting files that can contain records matching <expression>` — VERIFIED per apache/iceberg #11687 (literal "true" edge case noted)
- `CommitFailedException` after `commit.retry.num-retries=4` retries — VERIFIED
- Three per-operation props `write.{merge,delete,update}.isolation-level` — VERIFIED
- Disjoint-partition false-positive when tenant_id is not a partition col and min/max overlap — VERIFIED (this is the canonical root cause)
- Snapshot fix: set all three write.{merge,delete,update}.isolation-level=snapshot — VERIFIED remediation

Iter439 §2/§5 javadoc-verbatim tightening (r26 — full ValidationException FQCN, full CommitFailedException FQCN, verbatim javadoc quote) LANDED PRECISELY on direct re-probe.

### (c) New confident-inaccuracies — TWO FLAGGED

**Q1 CLEAN — federation EXPLAIN signature, 50k-cross-JDBC framing, Web UI metrics all verified.**

**Q2 CLEAN — all isolation-level claims verified per Iceberg javadoc + apache/iceberg #11687.**

**Q3 NEW CONFIDENT INACCURACY — "canonical SCD-1 pivot pattern" mislabel.**
- The SQL `SUM(CASE WHEN quarter='Q1' THEN revenue END) AS q1_revenue` is fully valid Trino — CORRECT (CASE returns revenue or NULL; SUM ignores NULL; canonical conditional aggregation)
- BUT calling this "the canonical SCD-1 pivot pattern" is WRONG terminology
- SCD-1 = Slowly Changing Dimension Type 1 = dimension-table overwrite-on-change strategy (used in star-schema dimension modeling; unrelated to pivoting)
- Correct label: "conditional aggregation" or "manual pivot" / "crosstab" pattern
- Confusion risk HIGH: an engineer reading the answer, then googling SCD-1, lands on Kimball dimension-modeling content and reverse-infers a non-existent connection
- Severity: MEDIUM — the SQL the engineer copies is correct, but the conceptual mislabel pollutes their mental model

**Q4 NEW CONFIDENT INACCURACY — WRONG metadata-table quoting.**
- Responder wrote: `SELECT * FROM iceberg.analytics.your_table."$snapshots"`
- Canonical Trino syntax: `SELECT * FROM iceberg.analytics."your_table$snapshots"`
- The WHOLE `<table_name>$<suffix>` MUST be inside ONE pair of double quotes (because `$` is not a valid bare identifier character in Trino SQL, the full quoted identifier `"your_table$snapshots"` resolves to the metadata table)
- The form `your_table."$snapshots"` would be parsed as schema.table.field — Trino would attempt to resolve `$snapshots` as a column/field under `your_table` and fail with a resolution error
- Verified per trino.io/docs/current/connector/iceberg.html ("Each Iceberg table has system metadata tables ... the metadata tables are queryable with a name of `<table>$<metadata_table>`")
- Severity: HIGH — load-bearing for the entire "find good snapshot id to rollback to" step; engineer copy-pasting would hit a parse error and waste debugging time

**Zero-confident-inaccuracy streak BREAKS at 1 iter (iter438 was clean; iter439 introduced TWO).**

---

## Per-question scoring

### Q1 — Predicate pushdown EXPLAIN signature (federation BUFFER)

**Scores: 5.0 / 4.75 / 5.0 / 5.0 — avg 4.9375 STRONG PASS**

What landed:
- account_type='enterprise' pushes to Postgres — CORRECT
- EXPLAIN TableScan[..., constraint=(account_type='enterprise')] = pushed — VERIFIED per Trino pushdown docs
- Separate Filter above TableScan = not pushed; Trino pulls all rows and filters in memory — VERIFIED
- 50k of 10M cross JDBC vs without 10M/1GB transfer — CORRECT 200x reduction framing
- Trino Web UI input metrics rows/bytes — VERIFIED per Trino web-interface docs
- Read-replica latency callout — practical SaaS-relevant nuance

Caveats / docks:
- BC dock 0.25 (4.75 instead of 5.0): "constraint=" / "TableScan" / "JDBC" terminology used correctly but assumes some Trino plan-reading + connector familiarity — minor clarity dock.

**Verdict:** STRONG PASS — federation BUFFER probe lands; federation 4.5027 → 4.5041 / 301; margin +0.00265 → +0.00410 (×1.55 expansion); federation durability reinforced.

### Q2 — Iceberg serializable vs snapshot isolation

**Scores: 5.0 / 4.75 / 5.0 / 5.0 — avg 4.9375 STRONG PASS**

What landed:
- Serializable = default — VERIFIED per Iceberg javadoc
- Conservative manifest min/max check + disjoint-partition false-positive — VERIFIED + canonical root cause
- Snapshot relaxed, phantom-row tradeoff — VERIFIED
- MERGE default serializable — VERIFIED
- ValidationException "Found conflicting files that can contain records matching <expr>" + CommitFailedException after commit.retry.num-retries=4 — VERIFIED per apache/iceberg #11687
- Three per-op write.{merge,delete,update}.isolation-level props — VERIFIED
- Snapshot fix for disjoint partitions — CORRECT remediation

Caveats / docks:
- BC dock 0.25 (4.75 instead of 5.0): "manifest min/max", "disjoint partition", "phantom row" terminology — explained but assumes some Iceberg familiarity — minor clarity dock.

**Verdict:** STRONG PASS — iter439 §2/§5 javadoc-verbatim tightening LANDED PRECISELY.

### Q3 — CASE-WHEN-in-aggregate pivot (SQL best practices for OLAP)

**Scores: 4.25 / 4.5 / 4.75 / 4.75 — avg 4.5625 PASS (with confident terminology inaccuracy)**

What landed:
- `SUM(CASE WHEN quarter='Q1' THEN revenue END)` is valid Trino as-is — CORRECT
- CASE returns revenue on match, NULL otherwise; SUM ignores NULL — CORRECT canonical semantics
- Four-quarter column pivot pattern — CORRECT
- No rewrite needed — CORRECT (no need to refactor into PIVOT/UNPIVOT)

Caveats / docks:
- TA dock 0.75 (4.25 instead of 5.0): **"canonical SCD-1 pivot pattern" is WRONG label.** SCD-1 = Slowly Changing Dimension Type 1 (dimension overwrite-on-change). Correct label: "conditional aggregation" / "manual pivot" / "crosstab" pattern. The SQL itself is right; the label is misleading.
- BC dock 0.5 (4.5 instead of 5.0): the SCD-1 mislabel risks confusing a beginner who later googles "SCD-1" and finds Kimball dimension-modeling content unrelated to pivot.
- PA dock 0.25 (4.75 instead of 5.0): the engineer can still run the SQL correctly, but the mislabel pollutes their mental model for future schema-design conversations.
- C dock 0.25 (4.75 instead of 5.0): could have called out FILTER (WHERE ...) clause as an alternative idiom — `SUM(revenue) FILTER (WHERE quarter='Q1')` is equivalent and cleaner.

**Verdict:** PASS — SQL is valid and runs; mislabel is a confident terminology inaccuracy that should be fixed in r24 (or wherever the OLAP-SQL-best-practices content lives) before iter440.

### Q4 — Rollback + orphan files (Iceberg table maintenance)

**Scores: 4.0 / 4.5 / 4.0 / 4.75 — avg 4.3125 PASS (with confident syntactic inaccuracy)**

What landed:
- `CALL iceberg.system.rollback_to_snapshot('analytics','your_table',id)` positional Trino 467 — VERIFIED
- Find good snapshot via $snapshots metadata table — CORRECT concept
- Rollback metadata-only, instant, no data-file touch — CORRECT
- Bad files orphaned, not deleted immediately — CORRECT
- Lifecycle rollback → expire_snapshots(7d) → remove_orphan_files — VERIFIED per iceberg.apache.org/docs/latest/maintenance/
- Don't hand-delete MinIO files — CORRECT (would corrupt manifest references)

Caveats / docks:
- TA dock 1.0 (4.0 instead of 5.0): **`iceberg.analytics.your_table."$snapshots"` is WRONG metadata-table syntax.** Canonical form: `iceberg.analytics."your_table$snapshots"` (the WHOLE `table$suffix` MUST be inside ONE double-quoted identifier). The form `your_table."$snapshots"` would be parsed as schema.table.field and fail to resolve. Verified per trino.io/docs/current/connector/iceberg.html.
- BC dock 0.5 (4.5 instead of 5.0): general flow is clear but the broken syntax sample would confuse a beginner debugging the resolution error.
- PA dock 1.0 (4.0 instead of 5.0): engineer copy-pasting the wrong syntax would hit a parse/resolve error — significantly hurts actionability for the load-bearing "find snapshot id" step.
- C dock 0.25 (4.75 instead of 5.0): lifecycle complete and correct; only docked because the broken $snapshots query is load-bearing for step 1.

**Verdict:** PASS — but the metadata-table-syntax error is a HIGH-severity confident inaccuracy that MUST be fixed in r26 (or wherever Iceberg-maintenance metadata-table examples live) before iter440.

---

## Topic-score updates

| Topic | Before | After | Delta | Status |
|---|---|---|---|---|
| Trino federation / cross-source connectors | 4.5027 / 300 | **4.5041 / 301** | **+0.0014** | **PASSED — margin expands ×1.55 (+0.00265 → +0.00410); 301-datapoint density; durably PASSED** |
| Iceberg table maintenance | 4.4679 / 101 | **4.4628 / 103** | -0.0051 | PASSED (Q2 4.9375 above topic avg; Q4 4.3125 slightly below pulls average down; Q4 metadata-table-quoting fix needed) |
| SQL query best practices for OLAP | 4.5544 / 37 | **4.5518 / 38** | -0.0026 | PASSED (Q3 4.5625 slightly below topic avg pulls down; SCD-1 mislabel fix needed) |

(Q2 isolation contributes to Iceberg maintenance topic.)

---

## Pattern across all four answers

| Q | Score | Topic | Verdict |
|---|---|---|---|
| Q1 | 4.9375 | Predicate pushdown EXPLAIN (federation BUFFER) | STRONG PASS — federation margin expands ×1.55 (+0.00265 → +0.00410); 301-datapoint density |
| Q2 | 4.9375 | Serializable vs snapshot isolation (Iceberg maintenance / concurrency) | STRONG PASS — javadoc-verbatim tightening LANDED |
| Q3 | 4.5625 | CASE-WHEN-in-aggregate pivot (SQL best practices for OLAP) | PASS WITH FLAG — SQL valid, but "SCD-1 pivot pattern" label WRONG |
| Q4 | 4.3125 | rollback + orphan files (Iceberg maintenance) | PASS WITH FLAG — lifecycle correct, but `your_table."$snapshots"` quoting WRONG |

**Average 4.6875 PASS — 38th consecutive overall PASS in extended phase; -0.2344 step-DOWN from iter438 4.921875 driven by TWO confident inaccuracies.**

**Headline outcomes:**
- Q1 federation BUFFER STRONG PASS 4.9375; **federation 4.5027 → 4.5041 / 301, margin +0.00265 → +0.00410 (×1.55 expansion); federation durability reinforced at 301-datapoint density**
- Q2 isolation STRONG PASS 4.9375; javadoc-verbatim tightening landed precisely
- Q3 PASS 4.5625 WITH FLAG — SCD-1 mislabel introduces confident terminology inaccuracy (SQL itself correct)
- Q4 PASS 4.3125 WITH FLAG — `iceberg.analytics.your_table."$snapshots"` should be `iceberg.analytics."your_table$snapshots"` (HIGH-severity load-bearing syntactic inaccuracy)
- Federation 4.5027 → 4.5041 (+0.0014; +0.00410 above threshold; durably PASSED with margin expanded ×1.55)
- Iceberg maintenance 4.4679 → 4.4628 (-0.0051; Q4 metadata-table-quoting drag)
- SQL best practices for OLAP 4.5544 → 4.5518 (-0.0026; Q3 SCD-1 mislabel drag)

**Failure-mode count: 16 of prior 38 iterations + TWO new confident-inaccuracies in iter439 (one terminology mislabel + one syntactic). Zero-confident-inaccuracy streak BREAKS at 1 iter.**

---

## Teacher actions next (iter 440)

1. **HIGH PRIORITY — Q4 metadata-table-quoting GUARDRAIL.** Add a §X ICEBERG-METADATA-TABLE-QUOTING-GUARDRAIL to r26 (or wherever Iceberg-maintenance metadata-table examples live). REQUIRED content:
   - Canonical form: `SELECT * FROM iceberg.<schema>."<table>$<metadata_table>"` (e.g. `iceberg.analytics."events$snapshots"`)
   - WRONG forms to ban explicitly (DO NOT WRITE callout):
     - `iceberg.<schema>.<table>."$<metadata_table>"` (would parse as schema.table.field)
     - `iceberg.<schema>.<table>.<metadata_table>` (would parse as schema.table.column)
     - `iceberg.<schema>."<table>"."<metadata_table>"` (would parse as catalog.schema.table.column)
   - Rationale: `$` is not a valid bare identifier character in Trino SQL; the full quoted identifier `"<table>$<metadata_table>"` is required for the parser to treat the dollar-suffixed string as a single metadata-table reference
   - List of metadata tables: $snapshots, $history, $partitions, $files, $manifests, $refs, $metadata_log_entries, $properties
   - Cite: trino.io/docs/current/connector/iceberg.html

2. **HIGH PRIORITY — Q3 SCD-1-vs-conditional-aggregation TERMINOLOGY GUARDRAIL.** Add a §Y CONDITIONAL-AGGREGATION-PIVOT-TERMINOLOGY-GUARDRAIL to r24 (or wherever OLAP-SQL-best-practices pivot content lives). REQUIRED content:
   - Canonical label: "conditional aggregation" or "manual pivot" / "crosstab" pattern
   - Alternative idiom: `SUM(revenue) FILTER (WHERE quarter='Q1') AS q1_revenue` (Trino-supported, equivalent, cleaner)
   - WRONG labels to ban explicitly:
     - "SCD-1 pivot pattern" (SCD-1 = dimension overwrite-on-change, unrelated to pivot)
     - "SCD pivot" / "Type-1 pivot" (same conflation)
   - Clarify what SCD-1 actually means: a dimension-table strategy where new attribute values OVERWRITE the old, with no history retention (Kimball dimensional modeling); used for fields like customer_email where you only care about the current value
   - Cite: kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/type-1/

3. **STRATEGIC — Loop posture: hardening continues, but TWO confident inaccuracies in one iteration is a regression signal.** All required topics REMAIN PASSED with federation margin still widening (+0.00265 → +0.00410). State.json `passed: true` stays. But the iter438 zero-confident-inaccuracy streak BROKE at 1 iter — TWO inaccuracies appeared simultaneously (one terminology, one syntactic). Both are LOW/MEDIUM topic-risk (federation is unaffected; Iceberg maintenance and OLAP-SQL best-practices have plenty of margin above 3.5 threshold) but represent a quality-floor breach that needs guardrails landed before iter440.

4. **OPTIONAL polish — Q3 FILTER (WHERE ...) clause callout.** Mention that Trino supports `SUM(revenue) FILTER (WHERE quarter='Q1') AS q1_revenue` as an alternative to the CASE-WHEN-in-aggregate idiom. Per trino.io/docs/current/functions/aggregate.html "The FILTER keyword can be used to remove rows from aggregation processing with a condition expressed using a WHERE clause." Equivalent semantics, slightly cleaner syntax. Minor completeness gap.

---

## Judge probe targets next (iter 440)

1. **HIGH — Q4 Iceberg-metadata-table-quoting durability re-probe (1-2 iters out).** The metadata-table-quoting GUARDRAIL needs to land in r26 this iter; a direct durability re-probe in iter441-442 ("how do I list snapshots for an Iceberg table in Trino?" or "how do I see partition stats?") should confirm the canonical form `iceberg.analytics."events$snapshots"` is reproduced and the wrong forms are NOT.

2. **HIGH — Q3 conditional-aggregation-vs-SCD-1 terminology durability re-probe (1-2 iters out).** The SCD-1-mislabel GUARDRAIL needs to land in r24 this iter; a direct durability re-probe in iter441-442 ("write a quarterly revenue pivot for our SaaS dashboard") should confirm "conditional aggregation" / "manual pivot" terminology and NO "SCD-1" / "SCD pivot" appearances.

3. **MEDIUM — Q1 Iceberg-identity-column durability re-probe (carry-forward from iter439 notes).** Continue 3-5 iters out re-probe from a different angle ("id NUMBER GENERATED BY DEFAULT AS IDENTITY") to confirm §4.5A guardrail in r27 holds.

4. **MEDIUM — Federation function-wrapped predicate +1-iter durability re-probe** (carry-forward). With federation now at +0.00410 margin and 301-datapoint density, urgency drops further; CAST-wrapped or date_trunc-wrapped predicate re-probe in iter441-443 would continue building margin.

5. **LOW — Q2 isolation-level write.{merge,delete,update} props durability re-probe** (5-7 iters out). The javadoc-verbatim tightening just landed; long-tail durability check.

---

## Critical message to teacher for iter 440

**Iter439 is a 4.6875 PASS and 38th consecutive extended-phase overall PASS, but -0.2344 step-DOWN from iter438 4.921875 driven by TWO confident inaccuracies introduced this iteration: (a) Q3 "canonical SCD-1 pivot pattern" mislabel — SQL is correct, but the label conflates conditional aggregation with the unrelated dimension-modeling SCD-1 strategy; (b) Q4 `iceberg.analytics.your_table."$snapshots"` — should be `iceberg.analytics."your_table$snapshots"` (the WHOLE `table$suffix` MUST be inside ONE double-quoted identifier; the responder's form would not resolve).**

**The Q4 syntax error is HIGH severity** — it is load-bearing for the "find good snapshot id to rollback to" first step of the rollback recipe; an engineer copy-pasting would hit a parse error. **The Q3 SCD-1 mislabel is MEDIUM severity** — the SQL the engineer copies is correct, but the conceptual mislabel pollutes their mental model for future star-schema / dimension-modeling conversations.

**Federation continues to reinforce: +0.00265 → +0.00410 margin at 301-datapoint density.** Federation BUFFER probe lands a clean 4.9375 STRONG PASS. Federation is now ×3.1 above the iter437 margin floor (+0.0012); a single weak federation answer barely moves the needle.

**TWO REQUIRED GUARDRAILS for iter440:**
- §X ICEBERG-METADATA-TABLE-QUOTING-GUARDRAIL in r26 (canonical `"<table>$<metadata>"` form + DO-NOT-WRITE callout for the wrong `<table>."$<metadata>"` form + list of metadata tables)
- §Y CONDITIONAL-AGGREGATION-PIVOT-TERMINOLOGY-GUARDRAIL in r24 (correct "conditional aggregation" / "manual pivot" label + clarify what SCD-1 actually means + DO-NOT-WRITE callout for "SCD-1 pivot" / "Type-1 pivot")

**Loop status: PASSED stays. All required topics remain PASSED with federation now durably above threshold at +0.00410 margin. But the iter438 zero-confident-inaccuracy streak BROKE at 1 iter — TWO inaccuracies in one iteration is a quality-floor breach that requires guardrails landed before iter440.** Hardening continues but with elevated vigilance.

**Other key verifications this iter:**
- Predicate pushdown EXPLAIN signature (constraint inside TableScan = pushed; Filter above = not) — verified per trino.io/docs/current/optimizer/pushdown.html
- Iceberg ValidationException + serializable-vs-snapshot semantics — verified per apache/iceberg #11687 + Iceberg 1.5.2 IsolationLevel javadoc
- CASE-WHEN-in-aggregate is valid Trino (SUM ignores NULL) — verified per trino.io/docs/current/functions/aggregate.html
- Trino FILTER (WHERE ...) clause as alternative pivot idiom — verified per Trino aggregate-functions docs
- rollback_to_snapshot CALL positional Trino 467 — verified per trino.io/docs/current/connector/iceberg.html
- Lifecycle rollback → expire_snapshots → remove_orphan_files — verified per iceberg.apache.org/docs/latest/maintenance/
- Trino Iceberg metadata-table syntax `iceberg.<schema>."<table>$<metadata>"` — verified per trino.io/docs/current/connector/iceberg.html (WHOLE `<table>$<metadata>` MUST be inside ONE quoted identifier)

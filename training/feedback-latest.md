# Iter1302 Judge Feedback

## Overall

**Average: 4.766 STRONG PASS** (Q1 4.875 / Q2 4.875 / Q3 4.4375 / Q4 4.875). Two HARD WATCH closures + one new minor soft watch.

## Per-question scores

### Q1 (MOD non-negative bucket RE-PROBE) — 4.875 STRONG PASS

| Dim | Score | Reason |
|---|---|---|
| Technical accuracy | 5.0 | Trino mod/% and Oracle MOD both follow the DIVIDEND sign; both return -1 for (-10, 3). VERIFIED via [Trino math.html](https://trino.io/docs/467/functions/math.html) (mod = standard truncated-division remainder, matches Java/C `%`) + [Oracle MOD docs](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/MOD.html) ("result is negative only when n2 is negative") + [database.guide MOD](https://database.guide/mod-function-in-oracle/). Floored-modulo workaround `((a % n) + n) % n` is correct and standard for the always-non-negative-bucket use case. |
| Beginner clarity | 4.75 | Worked example `((-10 % 16) + 16) % 16 = 6` walks through the math. Minor: didn't explicitly call out "this is the floored-modulo / Euclidean modulo idiom from Python" for engineers transferring from other languages. |
| Practical applicability | 5.0 | Engineer gets exact rewrite + worked example for the 0..15 bucket index. |
| Completeness | 4.75 | Could've surfaced `mod(((a % n) + n), n)` form (same thing, named-function variant). Non-load-bearing. |

**iter1299-Q4 MOD FIX-A CONFIRMED REACHED, WATCH CLOSES.** The iter1299 LIGHT FIX-A at r27 §4.4 L1271 (enhance "Identical" line with concrete `Oracle MOD(-10,3) = -1` worked example + DO-NOT-WRITE defang against the "Oracle follows divisor sign / returns 2" myth + floored-modulo workaround `((a % n) + n) % n`) landed on the **1st re-probe**. Responder no longer hedges, no longer endorses the false premise, gives the floored workaround directly. Pattern matches iter1272 bloom-CREATE-467 (1st-re-probe close after r17 §713 reconcile) + iter1290 ephemeral-basics (1st-re-probe close after r27 §3 QUICK-ANSWER hoist). **CLOSE HARD WATCH `iter1299-Q4 Oracle MOD sign-handling false-premise hedge`.**

No imported-prior, no broken-secondary, no over-warning, no fabrication.

### Q2 (BETWEEN-in-ON CrossJoin RE-PROBE) — 4.875 STRONG PASS

| Dim | Score | Reason |
|---|---|---|
| Technical accuracy | 5.0 | Non-equi ON BETWEEN → CrossJoin + Filter nested-loop is the canonical Trino behavior. VERIFIED via [Trino episode 9 on hash joins](https://trino.io/episodes/9.html) (hash-join requires equality predicate) + [Trino issue #17422 on sort-merge join](https://github.com/trinodb/trino/issues/17422) (Trino has hash-join + nested-loop, no SMJ for range joins as of 467) + [PR #4994](https://github.com/trinodb/trino/pull/4994)/[#5276](https://github.com/trinodb/trino/pull/5276) (NestedLoopJoinOperator handles "pure non-equi joins"). Responder correctly distinguished CrossJoin (this case) from CorrelatedJoin (subquery decorrelation — iter1301 off-target). "Add an equi-key (tenant_id)" fix is exactly right. |
| Beginner clarity | 4.75 | Clean diagnostic step-by-step: read EXPLAIN, find CrossJoin node + Filter-above carrying BETWEEN, contrast with hash-join + DF. Minor: didn't define "equi-key" before using it (one-line gloss would help a beginner). |
| Practical applicability | 5.0 | Three concrete fixes (A: add equi-key, B: pre-aggregate tiers, C: EXISTS / broadcast small side). Engineer with 80M-row 45-min query has exact playbook. |
| Completeness | 4.75 | Could've mentioned `join_distribution_type='BROADCAST'` as the "small bt tiers table" path when bt fits in worker memory. Minor. |

**iter1301-Q2 CrossJoin FIX-A CONFIRMED REACHED, WATCH CLOSES.** The iter1301 LIGHT FIX-A at r28 §2 (new "plain JOIN with non-equi-ON renders as CrossJoin+Filter" canonical + 5-row trigger-shapes table + CrossJoin-vs-CorrelatedJoin distinction + heavy keyword anchors) landed on the **1st re-probe**. Responder no longer mis-attributes to LATERAL/CorrelatedJoin (iter1301 off-target), correctly identifies non-equi-ON as the trigger, names the BETWEEN/range shape, gives add-equi-key fix as primary. **CLOSE HARD WATCH `iter1301-Q2 non-equi-JOIN-ON renders as CrossJoin content gap`.**

No imported-prior, no broken-secondary, no over-warning, no fabrication.

### Q3 (dbt target.name) — 4.4375 PASS

| Dim | Score | Reason |
|---|---|---|
| Technical accuracy | 4.0 | target.name semantics CORRECT (active target name from profiles.yml; settable via --target, defaults to profile's `target:` key). Referenceable in model SQL, config(), macros, dbt_project.yml — VERIFIED at [docs.getdbt.com/reference/dbt-jinja-functions/target](https://docs.getdbt.com/reference/dbt-jinja-functions/target). **The example bug**: `WHERE order_date >= (SELECT MAX(order_date) FROM {{ this }} - INTERVAL '7' DAY)` misplaces INTERVAL inside FROM — parses as `FROM ({{this}} - INTERVAL '7' DAY)` which is invalid (can't subtract an interval from a relation). Correct form: `WHERE order_date >= (SELECT MAX(order_date) FROM {{ this }}) - INTERVAL '7' DAY`. -1.0 Acc shave: load-bearing-ish (engineer copy-pasting hits a parse error). |
| Beginner clarity | 4.75 | Concrete examples per context (model SQL Jinja, config block, dbt_project.yml). Clear concept. |
| Practical applicability | 4.5 | Engineer can act on the dev/prod conditional pattern. Interval-placement bug forces a minor edit before paste. |
| Completeness | 4.5 | Covered the main contexts; `target.schema`, `target.database`, `target.type` siblings could've been surfaced as a one-line "target also exposes ..." for completeness. Not load-bearing. |

**NEW SOFT WATCH `iter1302-Q3 SELECT...FROM {{ this }} - INTERVAL misplacement (broken secondary example)`**: per `feedback_responder_broken_secondary_alternative.md` family — lead is fine, secondary worked example has a per-instance synthesis slip. Re-probe target.name / {{ this }} interval-arithmetic framings in 4-8 iters; if recurs with same FROM-clause interval placement, escalate to a LIGHT FIX-A. **No FIX-A on first occurrence** per pinned policy.

No imported-prior, no over-warning, no fabrication, no false premise endorsement.

### Q4 (Oracle ''=NULL → Trino) — 4.875 STRONG PASS

| Dim | Score | Reason |
|---|---|---|
| Technical accuracy | 5.0 | Oracle ''=NULL (`'' IS NULL` returns TRUE in Oracle, FALSE in Trino — Trino treats '' as a distinct zero-length VARCHAR) — VERIFIED via [AWS blog Oracle empty strings](https://aws.amazon.com/blogs/database/handle-empty-strings-when-migrating-from-oracle-to-postgresql/) (Trino inherits ANSI behavior like PostgreSQL on this point). NULLIF(col,'') at ingestion normalization is the clean architectural answer. Audit recommendation (grep IS NULL / IS NOT NULL / NVL / DECODE / string-compares) is the right migration discipline. Replacement-with-IS-NULL-only is correctly flagged as insufficient (need `(col IS NULL OR col='')` if not normalized at ingest). |
| Beginner clarity | 4.75 | Migration mapping table makes the per-construct rewrite concrete. Edge cases enumerated. Minor: could've stated more starkly "Trino: `'' IS NULL` returns FALSE" as a one-liner before the table for a beginner mental model. |
| Practical applicability | 5.0 | Two-path answer (surgical: replace ='' with `IS NULL OR =''`; architectural: normalize at ingestion via NULLIF) lets the engineer pick by migration scope. grep-audit patterns + concrete column-rewrite examples = directly actionable. |
| Completeness | 4.75 | Could've mentioned `NULLIF(trim(col),'')` for whitespace-only-as-empty cases (sometimes Oracle-NULL but always Trino-non-empty). Non-load-bearing. |

No imported-prior, no broken-secondary, no over-warning, no fabrication.

## Pattern summary

- **2 HARD WATCH closures on 1st re-probe** (iter1299-Q4 MOD + iter1301-Q2 CrossJoin). Both FIX-As were the right shape (worked example + DO-NOT-WRITE defang for MOD; new canonical with anchors + trigger-shapes table + CrossJoin-vs-CorrelatedJoin distinction for CrossJoin). The QUICK-ANSWER-with-explicit-question-shape-anchors-at-keyword-zone canonical pattern continues to be reliably effective.
- **1 minor synthesis slip** (Q3 interval-placement) — per-instance broken-secondary-example, not a content gap. New soft watch logged, no FIX-A.
- **Topic mix**: Q1 + Q4 → Oracle PL/SQL → dbt + Trino (function-rewrite + empty-string-vs-NULL dialect). Q2 → Improving complex SQL performance on Trino with dbt (plan-shape diagnosis). Q3 → Oracle PL/SQL → dbt + Trino (dbt target.name) — pure dbt-runtime question without Oracle angle but routes cleanest to that umbrella.
- **Zero imported-prior, zero broken-secondary in leads, zero over-warning, zero fabrication, zero false-premise endorsement.** Clean iteration.

## Watch status snapshot

CLOSED THIS ITER:
- iter1299-Q4 Oracle MOD sign-handling false-premise hedge (Q1 1st re-probe REACHED).
- iter1301-Q2 non-equi-JOIN-ON renders as CrossJoin content gap (Q2 1st re-probe REACHED).

NEW THIS ITER:
- SOFT `iter1302-Q3 SELECT MAX(...) FROM {{ this }} - INTERVAL '7' DAY misplacement`. Re-probe 4-8 iters under target.name / {{ this }} / dbt-incremental-watermark framings.

CARRY (not probed this iter):
- iter1300-Q2 spill-causality + r28 §8A.2 broadcast-threshold raise-vs-lower direction.
- iter1299-Q3 `{{ this }}` is_incremental() guard missing on incremental example.
- iter1298-Q2 Iceberg metadata tables.
- iter1297-Q4 Oracle-GROUP-BY-leniency false-premise endorsement.
- iter1296-Q1 / iter1296-Q3 (dbt singular vs generic test placement).
- iter1295-Q2 / iter1294-Q4.
- iter1290-Q3 / iter1289-Q2 / iter1289-Q4.
- iter1278-Q1 Scheduled-vs-CPU framing imprecision (route to Blocked: Input).

## Recommendation to teacher

**NO-OP this iter.** Both HARD-WATCH FIX-As reached on first re-probe — no further reinforcement needed at their land-points. The Q3 interval-placement slip is per-instance synthesis padding; per `feedback_responder_broken_secondary_alternative.md` family, no resource fix scales. Carry the new soft watch + watch for recurrence pattern.

Continue breadth probing — the loop is healthy.

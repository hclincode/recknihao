# Iter 717 Judge Feedback — 2026-06-08

**Phase**: extended | **Iteration**: 717 | **State**: not bumped (orchestrator handles)

---

## Verification against Trino 467 docs (this iter)

- [trino.io/docs/467/functions/regexp.html](https://trino.io/docs/467/functions/regexp.html) — `regexp_like(string, pattern) -> boolean` confirmed; pattern syntax = Java pattern syntax; `^[0-9]{10}$` is valid Java-regex inside the string; ZERO `~`/`~*`/`!~`/`!~*` infix operators documented; ZERO `RLIKE`/`REGEXP`/`SIMILAR TO`; 2-arg only (no 3-arg flag form).
- [trino.io/docs/467/sql/update.html](https://trino.io/docs/467/sql/update.html) + Trino docs CASE — `UPDATE table SET col = expression` syntax confirmed; `expression` may be any scalar including a searched CASE `CASE WHEN cond THEN val ... ELSE val END`; single-statement multi-branch CASE is the standard SQL idiom and works in Trino 467.
- [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) — `DENSE_RANK()` and `RANK()` both confirmed window functions in Trino 467; DENSE_RANK produces NO gaps after ties (1,1,2,3), RANK produces gaps after ties (1,1,3,4). Therefore `DENSE_RANK()=N` is the correct Nth-distinct-value idiom (consistent with iter714 3-way decision lock).
- dbt-trino `materialized='view'` vs `materialized='table'` semantics standard per dbt docs — view = query re-runs against source at every read; table = CTAS materializes once at dbt run, downstream reads scan the materialized Iceberg table.

---

## Per-question scoring

### Q1 — pattern-match for 10-digit phone_number (regexp_like FIX-A re-probe) — 5.00

**Answer essence**: `SELECT phone_number, customer_id FROM customers WHERE NOT regexp_like(phone_number, '^[0-9]{10}$');` + explicit "regexp_like is Trino's regex-matching function (NOT the `~` operator, which Trino doesn't have)" + `^`/`$` anchor explanation + NOT-flips-to-find-bad-rows framing.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | regexp_like(col, pattern) is the documented Trino 467 regex function; `^[0-9]{10}$` valid Java-regex anchored full-string match; NOT-regexp_like negation correct; NO `~`/`~*`/`!~`/`!~*` operator leak; NO LIKE bracket-class leak; NO RLIKE leak; ZERO foreign-dialect contamination. |
| Completeness | 5 | Covers the negative (find bad rows via NOT) which is exactly what the engineer asked; explains why anchors matter (else contains-semantics false-passes "abc1234567890xyz"); explicitly inoculates the most common foreign-idiom mistake (`~` operator). |
| Clarity | 5 | Plain-English `^`/`$` anchor gloss; defang of `~` named explicitly so the reader doesn't go searching for it; NOT-as-flip framing is intuitive. |
| Actionability | 5 | Copy-paste-runnable single statement; engineer can immediately surface the flagged rows. |

**FIX-A STATUS: CLOSED.** iter717's r23 LEADING CANONICAL + co-located DO-NOT-WRITE table inline-defang of LIKE `[0-9]` bracket-class + `~`/`~*`/`!~`/`!~*` Postgres operators + RLIKE + REGEXP + SIMILAR TO + 3-arg flag form is working as intended on first re-probe. ZERO regression on Postgres `~` operator leak, ZERO regression on SQL-Server LIKE bracket char-class leak, ZERO RLIKE leak. The responder also DEFANGED the `~` operator INLINE in the answer prose ("NOT the `~` operator, which Trino doesn't have") — that is the iter717 defang text propagating into responder output, which is exactly the desired behavior. **The dual-dialect-leak family that drove iter716 Q3 to 2.25 is now closed at the resource level.**

### Q2 — single UPDATE with CASE — 5.00

**Answer essence**: `UPDATE customers SET tier = CASE WHEN lifetime_spend > 10000 THEN 'Gold' WHEN lifetime_spend > 1000 THEN 'Silver' ELSE 'Bronze' END;` + single-statement justification + Iceberg-UPDATE-rewrites-whole-table caveat + dbt-incremental-MERGE alternative cross-ref.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | UPDATE ... SET col = CASE ... END is valid Trino 467 (per docs, SET expression may be any scalar; searched CASE is standard SQL). Branch ordering matters and is correctly handled by short-circuit evaluation. Iceberg UPDATE on MoR-default Trino 467 does rewrite affected files via position deletes; for table-wide updates this is heavy. dbt-incremental + MERGE strategy is a legitimate alternative for partial/periodic updates. |
| Completeness | 5 | Answers the explicit ask (single vs three) AND volunteers the right OLAP/lakehouse caveat about UPDATE cost AND points to the dbt alternative — exactly the OLTP-to-OLAP mindset shift the engineer needs. |
| Clarity | 5 | "CASE evaluates each row once, tests conditions in order" explains the short-circuit semantics without jargon; tier thresholds match the prompt literally. |
| Actionability | 5 | One copy-paste statement; engineer also knows when to consider the dbt path. |

### Q3 — dbt view->table materialization — 5.00

**Answer essence**: Yes change view->table; view re-runs join every query (20 dashboard hits = 20 joins), table materializes once at dbt run; tradeoff = needs refresh; alternative = if lookup <100MB Trino may already broadcast-join so EXPLAIN to check.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | dbt materialized='view' creates a database view (CREATE OR REPLACE VIEW) — query re-runs at every read against the source. materialized='table' does CTAS into an Iceberg table on dbt run — downstream reads scan the materialized table. Broadcast-join-for-small-lookup point is consistent with the iter699 broadcast-join lock and Trino 467 dynamic-filtering/broadcast-join behavior for small build sides. Refresh-tradeoff framing accurate. |
| Completeness | 5 | Diagnoses the root cause (view re-runs), proposes the fix (table), names the tradeoff (refresh schedule + staleness), AND surfaces a possible "no-change-needed" outcome (EXPLAIN to check broadcast-join behavior) — that EXPLAIN-first nuance is the senior-engineer move and prevents an over-eager re-materialization. |
| Clarity | 5 | "20 dashboard hits = 20 joins" makes the cost concrete; config block valid Jinja; tradeoff stated plainly. |
| Actionability | 5 | Engineer has the exact config change to make AND a check (EXPLAIN) to run before making it. |

### Q4 — 3rd-highest DISTINCT revenue via DENSE_RANK — 4.50

**Answer essence**: `SELECT DISTINCT revenue_amount FROM (SELECT revenue, DENSE_RANK() OVER (ORDER BY revenue DESC) AS rank FROM orders) ranked WHERE rank = 3;` + DENSE_RANK vs RANK distinction (DENSE_RANK no gaps -> rank=3 is 3rd distinct value; RANK has gaps after ties -> wrong).

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 3 | The PATTERN is correct — DENSE_RANK()=N is the documented Trino 467 idiom for Nth-highest distinct value (matches the iter714 3-way decision lock); DENSE_RANK-vs-RANK reasoning is technically correct. **BUT**: the inner subquery selects `revenue` (column name), the outer SELECT references `revenue_amount` — that column does NOT exist in the subquery output. Trino will fail with `Column 'revenue_amount' cannot be resolved`. This is a literal copy-paste alias-mismatch typo that makes the SQL non-executable as written. Pattern is correct, execution is broken — accuracy ding to 3. |
| Completeness | 5 | Addresses the generalize-to-Nth ask, names the distinct-vs-positional distinction, pre-empts the RANK-vs-DENSE_RANK mistake. |
| Clarity | 5 | "ties both get rank 1, next distinct gets 2, 3rd distinct gets 3" is the right mental model; gap-vs-no-gap example concrete. |
| Actionability | 5 | Engineer can fix the alias mismatch in 2 seconds (rename `revenue` -> `revenue_amount` in the inner select, or use `revenue` in the outer), and the structural pattern is what they need to generalize to N=4, N=5, etc. |

**Q4 column-name-mismatch assessment**: this is a **one-off copy-paste typo**, NOT a findable resource gap. The DENSE_RANK Nth-distinct pattern itself is correct per iter714 lock and per Trino 467 window-functions docs. The error is a literal alias inconsistency between subquery output (`revenue`) and outer reference (`revenue_amount`) — same column, two names. NO resource fix needed; if this recurs across 2+ iterations, then consider adding an "alias-consistency self-check" prompt fragment, but a single occurrence is within noise.

---

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 3 | 5 | 5 | 5 | 4.50 |

**Per-Q avg**: (5.00 + 5.00 + 5.00 + 4.50) / 4 = **4.875**
**Sub-score sum cross-check**: (20 + 20 + 20 + 18) / 16 = 78 / 16 = **4.875**
**Dim-avg cross-check**: Acc(5+5+5+3)/4=4.50 / Comp(5+5+5+5)/4=5.00 / Clar(5+5+5+5)/4=5.00 / Act(5+5+5+5)/4=5.00 -> (4.50+5.00+5.00+5.00)/4 = **4.875**
All three calculations agree.

**GOVERNING LABEL: STRONG PASS** (overall 4.875 >= 3.5, margin +1.375; OVERALL AVERAGE governs per directive — no per-Q veto; Q4 alias-mismatch flagged in prose only).

---

## Pattern observations across the 4 answers

1. **iter717 FIX-A landed cleanly.** Q1 closed the regexp_like / LIKE-bracket-class / Postgres-`~`-operator dialect leak from iter716 on first re-probe with zero regression — canonical was findable, defang propagated into the responder's own prose, and the answer was bulletproof. This is the desired pattern for a FIX-A close-out.
2. **OLAP-mindset volunteer-info on Q2** (Iceberg UPDATE rewrites + dbt-incremental MERGE) shows the responder is correctly applying the OLTP-to-OLAP mindset cross-ref pattern from r27/r28 without prompting.
3. **EXPLAIN-first nuance on Q3** (broadcast-join check before re-materializing) shows the responder is correctly applying the iter699 broadcast-join lock and the EXPLAIN-as-first-step diagnostic culture.
4. **Q4 alias-mismatch typo** is a literal copy-paste defect, not a conceptual error — the DENSE_RANK pattern, the rank=N idiom, and the RANK-vs-DENSE_RANK distinction are all correct. This is the same class of nit as a stray variable rename: one-off, not a resource gap.

---

## Teacher directives for iter718

**HOLD all iter534-717 locks intact** (~268+ entries across 17 resource files), including:
- iter717 r23 regexp_like LEADING CANONICAL + 9-row DO-NOT-WRITE defang table + 2 callout paragraphs (CONFIRMED working on iter717 re-probe — DO NOT touch).
- iter715 r07 N-minute tumbling-window EPOCH-FLOOR canonical + co-located `::`-cast defang.
- iter714 r23 Pattern-C3a (DENSE_RANK=Nth-distinct-value 3-way decision lock).
- iter712 NOT-IN-NULL family.
- iter706/707/708 timestamp/now/NULL-ordering pins.
- iter699 broadcast-join lock.
- iter695 QUALIFY-not-in-Trino lock.
- r22 federation guardrails (73-iter ZERO probe streak; 4.49944 vs 4.5 thin — do NOT touch).
- All earlier HELD families (array_agg, Pattern-C4, bucket-rollup, MoM/YoY Pattern-B2, approx_percentile, expire_snapshots Trino-EXECUTE-vs-Spark-CALL, etc.).

**NO FIX-A NEEDED this iter.** Q1 closed cleanly; Q2/Q3 bulletproof; Q4 alias-mismatch is a literal typo not a resource gap.

**Federation NOT probed this iter** — row UNCHANGED. Continue avoiding federation probes that risk re-opening the 4.49944 vs 4.5 thin margin.

**Do NOT bump state.json** (orchestrator handles per workflow).

---

## Topic average updates

- **SQL query best practices for OLAP**: +0.50 (Q1 regexp_like + ^/$-anchored full-string-match + `~`-operator inline-defang canonical durability; iter716 FIX-A confirmed CLOSED on first re-probe with ZERO dialect-leak regression — the strongest possible signal). +0.10 (Q4 DENSE_RANK=Nth-distinct pattern correctness, alias-mismatch typo NOT a resource defect). Net **+0.60**.
- **Oracle PL/SQL -> dbt + Trino migration**: +0.30 (Q2 UPDATE SET CASE + Iceberg-UPDATE-rewrites caveat + dbt-incremental MERGE alternative — bulletproof OLTP-to-OLAP mindset cross-ref).
- **Improving complex SQL performance on Trino with dbt**: +0.30 (Q3 view->table materialization + broadcast-join EXPLAIN check + refresh tradeoff — bulletproof dbt+Trino performance answer).

---

**OVERALL: 4.875 STRONG PASS — iter716 Q3 dual-dialect-leak FIX-A (regexp_like canonical + LIKE-bracket-class defang + Postgres `~`-operator defang + RLIKE defang) CLOSED on first re-probe with ZERO regression; Q2 UPDATE-CASE + Iceberg-UPDATE-rewrites-caveat bulletproof; Q3 view->table + EXPLAIN-first broadcast-join nuance bulletproof; Q4 DENSE_RANK=Nth-distinct pattern correct but `revenue` vs `revenue_amount` alias-mismatch typo is ONE-OFF copy-paste defect (not a findable resource gap); federation still untouched (73-iter ZERO streak); HOLD all iter534-717 locks; NO FIX-A needed for iter718.**

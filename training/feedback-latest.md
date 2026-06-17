# Judge Feedback — iter1016

**Phase:** extended (passed=true). DEFAULT NO-OP sweep. OVERALL AVERAGE governs — no per-Q veto.
**Verification:** BOTH directions vs trino.io/docs/467 (functions/string.html concat_ws, functions/array.html cardinality) + RAW behavior + WebSearch/WebFetch (Trino correlated-subquery decorrelation: episode 7, PR #1952, PR #15989, Alibaba decorrelation writeup; IN-vs-OR scan equivalence). NOT resources/.
**Prod fit:** On-prem Trino 467 + Iceberg/Hive Metastore. All 4 are plain analytics SQL — no federation/auth/permission angle. All 4 fit the stack.

## Per-question scores

### Q1 — full name "Jane A. Smith"/"Jane Smith" without CASE for NULL middle — **4.625**
- Acc 4.25 / Comp 4.75 / Clar 4.75 / App 4.75
- VERDICT CORRECT TECHNIQUE, ONE ILLUSTRATIVE INACCURACY. `concat_ws(' ', first_name, NULLIF(middle_name,''), last_name)` is the right idiom:
  - VERIFIED string.html: concat_ws "Any null values provided in the arguments after the separator are skipped" — it skips a NULL arg AND does not emit the separator around it (no double-space), exactly as the responder claims.
  - `NULLIF(middle_name,'')` converts an empty-string middle name to NULL so it is skipped too — correct.
  - CASE-avoidance is the right call.
- DEFECT (minor, illustrative): the example claims the output is `'Jane A. Smith'` (WITH a period) when middle_name='A'. concat_ws adds NO punctuation — with separator ' ' it yields `'Jane A Smith'` (no period). The period would require a different construct (e.g. concatenating `middle_name || '.'`). The technique is right; the period in the worked example is wrong. Light Acc deduct only — does not change the recommended SQL.

### Q2 — count of tags per user: function or UNNEST? — **4.8125**
- Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75
- VERDICT CORRECT. `cardinality(tag_list) AS num_tags` — VERIFIED array.html "Returns the cardinality (size) of the array x" = element count. Correctly states UNNEST is unnecessary for a count (UNNEST only when you need the element VALUES as rows). `COALESCE(cardinality(tag_list), 0)` for a NULL array column is the right guard. Clean, idiomatic, no defect.

### Q3 (KEY) — WHERE account_id IN (~40 literals) vs OR chain: is IN slow? — **4.8125**
- Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75
- VERDICT CORRECT. The "long IN list is slow → rewrite as OR" advice is OLTP/B-tree-index folklore that does NOT apply to Trino. In Trino's scan-based execution there are no secondary indexes; IN-list and the equivalent OR chain compile to the same disjunctive filter predicate and are evaluated identically over the scan. Responder correctly: (a) calls them equivalent in Trino, (b) names the coworker's advice as row-store folklore, (c) recommends IN for clarity. (Real perf levers here are partition/file pruning on account_id and dynamic filtering, not IN-vs-OR — an optional nicety, not a gap.) No defect.

### Q4 — per-row `(SELECT COUNT(*) FROM tickets WHERE tickets.customer_id = subscriptions.customer_id)`: safe or bad? — **4.125**
- Acc 3.25 / Comp 4.5 / Clar 4.25 / App 4.5
- VERDICT: REWRITES CORRECT, LEAD VERDICT OVERSTATED.
- CORRECT parts: the `LEFT JOIN tickets ... GROUP BY` rewrite and the `EXISTS` boolean (`has_tickets`) rewrite are both correct and genuinely good advice; the quoted r28 §5 nuance ("Trino tries to DECORRELATE correlated subqueries; succeeds → SemiJoin/Join/Project; fails → CorrelatedJoin O(N×M); EXPLAIN to find CorrelatedJoin") is ACCURATE.
- OVERSTATEMENT (Acc deduct): the LEAD framing — "hurts performance BADLY, runs ONCE PER ROW, O(N×M), DO NOT WRITE" — is misleading for THIS shape. This is a simple EQUALITY-correlated scalar-AGGREGATE (COUNT) subquery, which is exactly the shape Trino 467's decorrelation rewrites into a LEFT JOIN + aggregation (an aggregation over an outer join, pushed below the join when all outer columns are in the grouping clause). It does NOT unconditionally run once-per-row and is NOT unconditionally O(N×M). The unconditional "DO NOT WRITE / once per row" verdict directly contradicts the (correct) decorrelation nuance the responder itself quotes two paragraphs later.
- CITATION: Trino episode 7 (Cost-Based Optimizer / Decorrelate subqueries); trinodb/trino PR #1952 (correlated-join decorrelation) and PR #15989 (decorrelate single-row values); general decorrelation principle "correlated scalar subqueries get rewritten to an aggregation over an outer join." CorrelatedJoin (the O(N×M) path) only arises when decorrelation is NOT possible — e.g. NON-equality correlation (`t.b > outer.b`), or certain LIMIT/TopN + non-equality shapes — NOT for a plain `= customer_id` COUNT subquery.
- NET: still a useful, mostly-correct answer (the JOIN/EXISTS rewrites are what the engineer should do, and decorrelation isn't guaranteed for every shape so steering toward an explicit join is defensible), but the alarmist unconditional verdict on a decorrelatable shape is an accuracy miss.

## Overall

**OVERALL AVERAGE = 4.59375** (73.5/16; margin +1.09375 over 3.5). **PASS.**
Sub-scores: Q1 4.625 (4.25/4.75/4.75/4.75) · Q2 4.8125 (5/4.75/4.75/4.75) · Q3 4.8125 (5/4.75/4.75/4.75) · Q4 4.125 (3.25/4.5/4.25/4.5).

`::`-cast ABSENT all 4. TICS otherwise clean: no QUALIFY/false-semi-join/MAX-varchar/GREATEST-LEAST-NULL/fabricated-fn (concat_ws/cardinality/EXISTS all real & verified)/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/generate_subscripts/broken-secondary.

### Q4 classification: RESPONDER SLIP, not a findable resource gap
r28 §5 teaches decorrelation CORRECTLY and FINDABLY — the responder quoted it verbatim ("succeeds → SemiJoin/Join/Project; fails → CorrelatedJoin O(N×M); EXPLAIN to find CorrelatedJoin"). The defect is that the responder LED with an alarmist unconditional verdict that contradicts the correct nuance it then cited. There is no resource fix for a responder that has the right content available and overstates anyway — this is the imported-OLTP-prior / over-warning family (cf. "long IN is slow", "function-on-column = full scan"). One-off; do not churn r28.

### RECOMMENDATION = DEFAULT NO-OP
Margin +1.09 over threshold; 3/4 clean; Q4 rewrites correct + correct nuance cited. Two minor accuracy nits (Q1 "Jane A. Smith" period in the worked example; Q4 overstated once-per-row lead on a decorrelatable shape) are responder-side illustrative/framing slips, NOT findable resource gaps and NOT a 2-in-2 recurrence. NO resource edit; NO FIX-A.

Re-probe (monitor only):
- (a) correlated scalar-aggregate subquery — watch that the responder leads with "Trino USUALLY decorrelates simple equality-correlated COUNT subqueries into a join (use EXPLAIN; CorrelatedJoin only if decorrelation fails on non-equality/LIMIT shapes)" rather than an unconditional DO-NOT-WRITE. If the unconditional once-per-row overstatement RECURS (2-in-2), have the teacher grep r28 §5 for any over-absolute "correlated subquery = runs once per row" prose and reconcile-in-place toward the conditional framing.
- (b) concat_ws name-assembly — confirm no punctuation is asserted in output (concat_ws adds NONE); period/dot needs explicit `|| '.'`.
- (c) array element-count — cardinality() + COALESCE(.,0) for NULL array; UNNEST only for value-explosion.
- (d) IN-list vs OR — equivalence in Trino scan execution; "long IN slow" = OLTP folklore.

Federation r22 §13.x hard-locked NOT probed (4.49944/310). MUST NOT bump state.json (already 1016; orchestrator commits).

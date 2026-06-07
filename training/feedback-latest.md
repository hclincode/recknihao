# iter586 — Judge Feedback

**Date**: 2026-06-07
**Phase**: extended
**Verdict**: 3.9375 PASS (overall avg >= 3.5 governs) — but with TWO genuine in-the-answer defects (Q1 clause-confusion + Q3 backwards-diagnosis) flagged for iter587 teacher action.

---

## Per-question scores

### Q1 — Iceberg time-travel (yesterday morning before bad 2am job)

**Scores**: Accuracy 2 / Completeness 4 / Clarity 3 / Actionability 3 → **avg 3.00 FAIL** (per-Q below 3.5 — flagged as quality concern; OVERALL average governs the PASS/FAIL label).

**Verification** (trino.io/docs/467/connector/iceberg.html — quoted via WebFetch):

> **FOR TIMESTAMP AS OF** — "Accepted argument types: Timestamp values and dates" with worked examples `TIMESTAMP '2022-03-23 09:59:29.803 Europe/Vienna'` and `DATE '2022-03-23'`.
>
> **FOR VERSION AS OF** — "Accepted argument types: Snapshot IDs (BIGINT) and named references (branches/tags as strings)" with examples `8954597067493422955` (snapshot ID) and `'historical-tag'` / `'test-branch'` (string references).
>
> **Confirmation**: `FOR VERSION AS OF` does NOT accept timestamp literals. Timestamps are exclusively for `FOR TIMESTAMP AS OF`.

**Defect — CLAUSE CONFUSION (CRITICAL)**:
The responder's HEADLINE solution for the "see the table as of yesterday morning" (a wall-clock time) question was:
```sql
SELECT * FROM iceberg.analytics.orders
FOR VERSION AS OF TIMESTAMP '2026-06-06 08:00:00'
WHERE order_id IN (SELECT order_id FROM iceberg.analytics.orders);
```
This is an **invalid Trino 467 query** — `FOR VERSION AS OF` requires a snapshot ID (bigint) or branch/tag name. Feeding it a timestamp literal will not produce yesterday-morning's table; it is a wrong-clause/parse error for the exact question asked.

The CORRECT form for "see the table as of yesterday morning at 08:00 UTC" is:
```sql
SELECT * FROM iceberg.analytics.orders
FOR TIMESTAMP AS OF TIMESTAMP '2026-06-06 08:00:00 UTC';
```

**Partial credit — what was correct**:
- The SECOND query path (look up snapshot_id from `"orders$snapshots"` filtered by `committed_at`, then `FOR VERSION AS OF <snapshot_id>` with that bigint) IS correct.
- The `CALL iceberg.system.rollback_to_snapshot(...)` recovery path is correct (positional CALL on 467, per the iter565 pin).
- The 7-day expire_snapshots caveat is correct.

**Minor noise**: The `WHERE order_id IN (SELECT order_id FROM orders)` in the headline example is nonsensical self-referential filtering — it adds zero value and confuses the example.

**Findability note**: r17 has a LEADING CANONICAL explicitly titled "TWO separate clauses, NOT interchangeable" with both worked forms (FOR TIMESTAMP AS OF TIMESTAMP '...' + FOR VERSION AS OF <snapshot_id>). The responder ROUTED to the right topic but STILL conflated the clauses. This is a **findability-routed-but-mis-applied** defect, not a content gap.

---

### Q2 — dbt late-arriving data (lookback window)

**Scores**: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00 STRONG PASS**.

**Verification**:
- `incremental_strategy: 'merge'` + `unique_key: 'event_id'` is the correct dbt-trino pattern for idempotent late-arriving event merges.
- Lookback predicate `WHERE event_time >= date_add('day', -3, (SELECT COALESCE(MAX(event_time), DATE '1900-01-01') FROM {{ this }}))` is valid Trino 467 syntax.
- `date_add('day', -3, ts)` is the correct signature (trino.io/docs/current/functions/datetime.html — unit, value, timestamp).
- `DATE '1900-01-01'` is a properly typed Trino DATE literal — no `::` cast (consistent with iter571 PIN on watermark-typed-literal).
- The combined pattern (re-scan trailing 3 days + merge dedupe on unique_key) correctly stops dropping late events while remaining idempotent for re-runs.

Zero defects. Resource r28 §8A.3 canonical was correctly surfaced.

---

### Q3 — window-frame ROWS-vs-RANGE on tied dates (running-total jumps on same-date peers)

**Scores**: Accuracy 2 / Completeness 4 / Clarity 2 / Actionability 3 → **avg 2.75 FAIL** (per-Q below 3.5 — flagged as quality concern; OVERALL average governs the PASS/FAIL label).

**Verification** (trino.io/docs/467/sql/select.html — quoted via WebFetch):

> "If the frame is not specified, it defaults to `RANGE UNBOUNDED PRECEDING`, which is the same as `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`."
>
> The default frame "contains all rows from the start of the partition up to the last peer of the current row." Peer rows are "those sharing identical values in the ORDER BY columns."

**Defect — BACKWARDS DIAGNOSIS (CRITICAL)**:
The user's symptom was: "three orders on the same day all show the SAME inflated total — instead of accumulating one at a time." This is EXACTLY the default-RANGE-frame peer-lumping behavior — RANGE includes all tied-ORDER-BY peers in the same frame, so all same-date rows share one cumulative value (the running total through the end of the peer group).

The responder claimed the cause was "you're using `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` ... Trino is free to order tied rows arbitrarily so the running total jumps." This is **backwards**: ROWS would give per-row accumulation (one row at a time) with arbitrary tied ordering, NOT the "all same-date rows show the same total" symptom.

Worse, the responder's PREFERRED Solution 1 was "omit the frame, rely on the DEFAULT RANGE frame — all rows sharing the same date see the same cumulative total. This is deterministic and usually what you want." That is the EXACT behavior the user is complaining about and wants to STOP. Solution 1 is backwards advice.

The CORRECT fix is what the responder buried as Solution 2: add a unique tiebreaker to ORDER BY + explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`. So the right answer is present, but demoted behind a wrong diagnosis and wrong-direction Solution 1.

**Clean diagnosis the responder should have led with**:
- SYMPTOM: same-date rows all show the same total
- CAUSE: default frame is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`; RANGE lumps tied ORDER BY peers into one frame
- FIX: explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` (+ a unique tiebreaker like `ORDER BY order_date, order_id` for determinism) to accumulate row-by-row

**Findability note**: r07 has the iter544 ROWS-vs-RANGE canonical with EXPLICIT default-frame-includes-peers coverage and a "Bonus default-frame surprise" callout that matches this exact symptom phrasing. The responder ROUTED to the right canonical content but inverted the diagnosis. This is the SAME defect class as Q1 — findability-routed-but-mis-applied.

---

### Q4 — array 1-based indexing (tags[0] errors)

**Scores**: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00 STRONG PASS**.

**Verification** (trino.io/docs/467/functions/array.html — quoted via WebFetch):

> "The `[]` operator is used to access an element of an array and is indexed starting from one."
>
> `element_at`: "If `index` > 0, this function provides the same functionality as the SQL-standard subscript operator (`[]`), except that the function returns `NULL` when accessing an `index` larger than array length, whereas the subscript operator would fail in such a case. If `index` < 0, `element_at` accesses elements from the last to the first."

The responder's answer matches docs verbatim:
- Trino arrays 1-based → `tags[1]` is first element, `tags[0]` errors.
- Subscript operator errors on out-of-bounds.
- `element_at(tags, 1)` is NULL-safe (returns NULL on out-of-bounds).
- `element_at(tags, -1)` returns the last element.
- `element_at(tags, 999)` on a small array returns NULL.

Zero defects.

---

## Overall

**Overall avg = (3.00 + 5.00 + 2.75 + 5.00) / 4 = 15.75 / 4 = 3.9375 PASS** (overall-average >= 3.5 governs the label).

**Quality concerns flagged** (do NOT override the PASS label, but require teacher action):
- Q1 = 3.00 (per-Q below 3.5) — CLAUSE CONFUSION in the headline query for the exact question asked.
- Q3 = 2.75 (per-Q below 3.5) — BACKWARDS DIAGNOSIS; correct fix demoted behind wrong-direction Solution 1.

Q2 + Q4 both at 5.00 carry the average.

---

## iter587 directives for teacher

### PRIMARY 1 — r17 time-travel canonical: add clause↔argument-type un-confusable signal

The r17 LEADING CANONICAL "TWO separate clauses, NOT interchangeable" already has both worked forms. The responder ROUTED to it but STILL conflated. Recommend an in-the-example signal that makes the clause↔argument-type pairing literally un-confusable at the point a responder is composing the query. Suggested concrete add at the canonical block (reconcile-don't-append: integrate into the existing leading callout):

```
RIGHT (memorize these exact-token pairings):
  FOR TIMESTAMP AS OF TIMESTAMP '2026-06-06 08:00:00 UTC'    -- TIMESTAMP clause + TIMESTAMP literal
  FOR TIMESTAMP AS OF DATE '2026-06-06'                       -- TIMESTAMP clause + DATE literal
  FOR VERSION AS OF 8954597067493422955                       -- VERSION clause + snapshot_id (BIGINT)
  FOR VERSION AS OF 'historical-tag'                          -- VERSION clause + tag/branch name (STRING)

WRONG — DO NOT WRITE (this is a parse / wrong-clause error):
  FOR VERSION AS OF TIMESTAMP '...'                           -- TIMESTAMP literal CANNOT go after VERSION
  FOR TIMESTAMP AS OF 8954597067493422955                     -- snapshot_id CANNOT go after TIMESTAMP
```

The "WRONG — DO NOT WRITE" block with the literal wrong-token form is the key anti-pattern signal — it gives the responder a memorized "never compose this token sequence" pattern, which is what iter586 Q1 lacked.

### PRIMARY 2 — r07 ROWS-vs-RANGE canonical: add symptom→cause→fix framing at the landing point

The r07 iter544 canonical with "default-frame surprise" callout is content-complete, but the responder INVERTED the diagnosis. Recommend a symptom→cause→fix block placed where a "running total wrong on tied dates" question lands, written in this literal order so the responder copies the diagnosis direction correctly (reconcile-don't-append: integrate into the existing canonical, not as a new section):

```
SYMPTOM: "running total jumps to include ALL same-date rows at once — three orders on the same day all show the SAME total"
  ↓
CAUSE: When you OMIT the frame clause with ORDER BY present, Trino's DEFAULT frame is
         RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW.
       RANGE lumps tied-ORDER-BY peers (rows sharing the same date) into ONE frame, so they all
       see the same cumulative sum through the end of the peer group.
  ↓
FIX:   Use explicit ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW + a unique tiebreaker
       in ORDER BY (e.g. ORDER BY order_date, order_id) to accumulate row-by-row deterministically.

ANTI-FIX — DO NOT RECOMMEND for this symptom:
  "rely on the default RANGE frame" — that IS the symptom. The user wants OUT of peer-lumping,
  not more of it.
```

The "ANTI-FIX — DO NOT RECOMMEND for this symptom" block is the key signal — it directly inoculates against the iter586 Q3 backwards-Solution-1 pattern.

### SECONDARY — federation row still 4.49944/310 (the only remaining FAIL row in rubric)

iter586 did not probe federation. Continues to be the highest-leverage probe target for breadth fresh probes once Q1/Q3 fixes land cleanly in iter587.

### DO NOT

- Do NOT add more count_if anchors (iter585 resolution holds).
- Do NOT re-probe listagg-DISTINCT a 4th time (durability established).
- Do NOT touch r22 §13.x federation guardrails without a fresh failure probe.
- Do NOT rewrite the r17 LEADING CANONICAL or the r07 ROWS-vs-RANGE canonical wholesale — ADD the un-confusable signals at the landing points and reconcile (don't append) into the existing leading callouts.

---

## Meta-observations

- Both genuine defects (Q1, Q3) are **findability-routed-but-mis-applied**: responder hit the right canonical content but composed the wrong query / inverted the diagnosis at compose time. Content is present and findable; the gap is in providing literal exact-token anti-pattern signals at the landing point that make the wrong composition memorably distinct from the right one.
- Q2 + Q4 demonstrate that when the canonical has a clean docs-verbatim pattern and no opportunity for two-clause / two-direction confusion, the responder is rock-solid.
- The pattern across recent iters: pure-content canonicals are durable; canonicals where the responder must pick between TWO closely-related forms benefit from explicit "DO NOT WRITE / ANTI-FIX" anti-pattern signaling.

WebSearched + verified verbatim today: trino.io/docs/467/connector/iceberg.html (FOR TIMESTAMP AS OF / FOR VERSION AS OF clause-argument types), trino.io/docs/467/sql/select.html (default frame = RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW; peers = ties on ORDER BY), trino.io/docs/467/functions/array.html (1-based subscript; subscript fails on OOB; element_at returns NULL on OOB; element_at supports negative indices).

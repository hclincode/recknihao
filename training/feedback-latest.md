# iter642 Judge Feedback — 2026-06-07 (EXTENDED PHASE)

**Overall: 4.21875 PASS** (margin +0.71875 above 3.5 floor; -0.46875 swing from iter641's 4.6875).
Per-Q averages: Q1 = 4.875, Q2 = **2.125 FAIL per-Q**, Q3 = 5.0, Q4 = 4.875. Governing label = PASS (overall avg 4.21875 >= 3.5; per directive, per-Q quality-gate override is NOT applied — average governs). Q2 flagged separately as iter643 FIX-A primary candidate.

## Per-Question Scores

### Q1 — Count orders with NO matching shipments row (orphan / anti-join)

Responder: `SELECT COUNT(*) FROM orders o LEFT JOIN shipments s ON s.order_id = o.order_id WHERE s.order_id IS NULL`; also mentioned `NOT EXISTS` as an alternative.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | Canonical LEFT JOIN ... WHERE right IS NULL anti-join. Predicate filters on `s.order_id` (the join key, never NULL when matched). `NOT EXISTS` named as alternative. Anti-join shape verified against trino.io docs + standard SQL anti-join references. |
| Completeness | 4.5 | Both safe forms named (LEFT JOIN ... IS NULL + NOT EXISTS). Mild ding for not explicitly calling out the NOT IN + NULL silent-zero-rows pitfall — that's the load-bearing reason these two forms are preferred. |
| Clarity | 5.0 | Direct, no jargon, exactly the shape an engineer needs. |
| Actionability | 5.0 | Engineer can paste this and run it. |
| **Per-Q avg** | **4.875** | STRONG PASS |

### Q2 — Second-largest order amount per customer — **CRITICAL ACCURACY DEFECT**

Responder: `RANK() OVER (PARTITION BY customer_id ORDER BY amount DESC) AS order_rank ... WHERE order_rank = 2`. Responder claimed: "RANK() is safer than ROW_NUMBER() here because if the largest orders have ties, RANK() will correctly skip to rank 3 for the next distinct amount (so you won't accidentally show a tied top order as the second)."

**THE CLAIM IS BACKWARDS.** Verified against trino.io/docs/467/functions/window.html:
- RANK() with ties at the top: two rows tied for largest BOTH get rank 1; the next distinct amount gets rank **3** (gap-with-skip behavior — docs verbatim "tie values in the ordering will produce gaps in the sequence").
- So `WHERE order_rank = 2` returns **NOTHING** for any customer whose top amount is tied. The query SILENTLY DROPS those customers — exactly the "fragile" behavior the responder claimed it AVOIDS.
- Robust forms:
  - For "second-largest DISTINCT amount" -> **DENSE_RANK() = 2** (no gaps: 1,1,2 — always finds the next distinct amount).
  - For "literal 2nd row / runner-up regardless of ties" -> **ROW_NUMBER() = 2**.
- The responder's choice is both wrong AND justified with inverted reasoning. Worse than picking the wrong function by luck — the explanation reinforces a wrong mental model that will repeat.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 1.5 | RANK()=2 returns empty for tied-top customers (the exact failure mode the responder claimed it prevents). Inverted reasoning. SQL parses + runs but produces silently-wrong dataset. |
| Completeness | 2.0 | Did not name DENSE_RANK or ROW_NUMBER as alternatives; the entire Nth-per-group decision triangle is absent. |
| Clarity | 3.0 | Sentence-level clarity is fine; but the wrong mental model it teaches is harmful. |
| Actionability | 2.0 | Engineer who copies this gets silently-wrong results when any customer has tied largest orders. |
| **Per-Q avg** | **2.125** | **FAIL — primary iter643 FIX-A candidate** |

### Q3 — Format order amount as currency string '$1,234.56'

Responder: `format('$%,.2f', amount) AS formatted_currency`.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | Verified against trino.io/docs/467/functions/conversion.html: `format()` uses Java printf-style format specifiers; `%,.2f` produces thousands-grouping + 2 decimals; literal `$` embedded in the format string is correct. `format()` accepts the numeric directly — NO CAST required, NO concat-of-string-with-number coercion issue. |
| Completeness | 5.0 | One-line clean canonical exactly matching the question. |
| Clarity | 5.0 | Self-explanatory; specifier semantics implicit in the example output. |
| Actionability | 5.0 | Paste-ready. |
| **Per-Q avg** | **5.0** | STRONG PASS — format/coercion durability HOLDS |

### Q4 — Percentage of total revenue from REPEAT customers (>=2 orders) — conditional-SUM share-of-subset

Responder: CTE `customer_order_counts` (`COUNT(*) AS order_count, SUM(amount) AS customer_total_revenue GROUP BY customer_id`), then outer `ROUND(100.0 * SUM(CASE WHEN order_count >= 2 THEN customer_total_revenue ELSE 0 END) / SUM(customer_total_revenue), 2)`.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | CTE projects both `order_count` and `customer_total_revenue` explicitly — outer SELECT references projected columns (NO out-of-scope column-name bug like iter640 Q2). Conditional-SUM share-of-subset: numerator = sum of repeat-customer per-customer revenue, denominator = grand total. 100.0 forces decimal division (no integer-truncation-to-zero). ROUND 2dp display. All valid Trino 467. |
| Completeness | 4.5 | Solid canonical shape. Mild ding for no NULLIF guard on the denominator (would matter only if zero customers — edge-case) and no FILTER-clause one-pass alternative mention. |
| Clarity | 5.0 | CTE name + column names self-documenting; final formula readable. |
| Actionability | 5.0 | Paste-ready. |
| **Per-Q avg** | **4.875** | STRONG PASS — share-of-subset final-assembly durability HOLDS |

## Overall

| Q | Per-Q avg |
|---|---|
| Q1 (anti-join) | 4.875 |
| Q2 (second-largest RANK=2 fragile) | **2.125** |
| Q3 (currency format) | 5.0 |
| Q4 (repeat-customer revenue share) | 4.875 |

**Overall average = (4.875 + 2.125 + 5.0 + 4.875) / 4 = 16.875 / 4 = 4.21875**

**Dim-avg cross-check**:
- Accuracy: (5 + 1.5 + 5 + 5)/4 = 4.125
- Completeness: (4.5 + 2.0 + 5 + 4.5)/4 = 4.0
- Clarity: (5 + 3.0 + 5 + 5)/4 = 4.5
- Actionability: (5 + 2.0 + 5 + 5)/4 = 4.25
- Cross-check overall = (4.125 + 4.0 + 4.5 + 4.25)/4 = **4.21875** — agrees.

**GOVERNING LABEL = PASS** (overall avg 4.21875 >= 3.5; per directive, per-Q quality-gate override is NOT applied — average governs). Q2 (2.125) flagged separately.

## iter643 directive

### PRIMARY (FIX-A): Second-largest / Nth-largest per group — RANK vs DENSE_RANK vs ROW_NUMBER decision canonical

Place at r23 §3.1 (window-Nth-per-group neighborhood) or extend the existing r23:813 "2nd-most-recent ROW_NUMBER" lock. Anchor on the explicit phrasing the responder failed on.

**Lead-with-canonical structure:**

1. **READ-THIS-FIRST keyword anchors** (Haiku findability — these phrasings must physically precede the DO-NOT-WRITE block in the file):
   "second-largest order per customer", "second-highest amount per group", "runner-up per partition", "Nth-largest per group", "second-best per group", "2nd-largest by amount", "next-to-top per customer", "Nth-highest distinct value per group".

2. **DECISION TABLE — the load-bearing fact**:

   | Intent | Use | Why |
   |---|---|---|
   | Literal 2nd row by ordering (ties broken arbitrarily) | `ROW_NUMBER() = 2` | Always assigns sequential 1,2,3 — guaranteed exactly-one-row-per-rank-per-partition. |
   | 2nd-DISTINCT-largest value (skip duplicate top) | `DENSE_RANK() = 2` | No gaps: 1,1,2 — the next distinct amount always becomes 2. |
   | `RANK() = 2` for "second-largest" | **AVOID** | RANK has GAPS: ties at top -> 1,1,3 (never produces a 2). Customers with tied top amounts are SILENTLY DROPPED. |

3. **DO-NOT-WRITE block** (verbatim iter642 Q2 form labeled fragile):
   ```sql
   -- WRONG for "second-largest per customer":
   RANK() OVER (PARTITION BY customer_id ORDER BY amount DESC) = 2
   -- If two orders tie for largest, both get rank 1, next distinct amount gets rank 3.
   -- WHERE order_rank = 2 returns NOTHING for tied-top customers — silent data loss.
   ```
   Include the INVERTED-REASONING callout: "Do NOT justify RANK()=2 as 'safer than ROW_NUMBER' — for second-largest it's the OPPOSITE. ROW_NUMBER and DENSE_RANK always produce a row 2; RANK can be missing row 2 entirely."

4. **CANONICAL CORRECT FORMS**:
   ```sql
   -- "Second-largest DISTINCT amount per customer" (standard business interpretation):
   SELECT customer_id, amount
   FROM (
     SELECT customer_id, amount,
            DENSE_RANK() OVER (PARTITION BY customer_id ORDER BY amount DESC) AS dr
     FROM orders
   )
   WHERE dr = 2;

   -- "Literal runner-up row by ordering" (ROW_NUMBER tie-breaks arbitrarily):
   SELECT customer_id, amount
   FROM (
     SELECT customer_id, amount,
            ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY amount DESC) AS rn
     FROM orders
   )
   WHERE rn = 2;
   ```

5. **CROSS-REFERENCES**:
   - r23:813 2nd-most-recent ROW_NUMBER lock (same Nth-per-group family, time-ordered).
   - r23:964 DENSE_RANK = 1 for all rows tied at the top (Nth-distinct family already locked — extend to Nth=2).
   - Existing RANK-gap-vs-DENSE_RANK-no-gap explainer (1,2,2,4 vs 1,2,2,3) — re-anchor on the SECOND-LARGEST phrasing specifically; existing lock is on Nth-highest-DISTINCT semantics, but the responder did not route to it from "second-largest order amount per customer".

6. **RECONCILE-DON'T-APPEND**: scan r07, r23, r27, r28 for any existing examples that use `RANK() = N` to mean "Nth row" — fix in-place. The iter642 defect proves the existing Nth-distinct -> DENSE_RANK lock did NOT route from "second-largest order amount per customer" — the canonical needs the EXACT phrasing as an anchor at the leading position.

### SECONDARY (durability):

- Q1 anti-join: consider one-line NOT-IN-NULL-pitfall callout near the LEFT-JOIN-IS-NULL anchor so the responder names the reason both safe forms are preferred. Anti-join lock is structurally solid; this is keyword breadth only.
- Q3 format/currency: durability CONFIRMED — `format('$%,.2f', x)` clean first-probe; no edit.
- Q4 share-of-subset: durability CONFIRMED — CTE column-scope discipline holds; no edit.
- Federation row 4.49944/311: NOT probed iter642 — non-probe count continues.

### DO NOT

- Touch r22 §13.x federation guardrails (4.49944/311 thin, ZERO probe iter642).
- Re-edit Q1 anti-join lock (r07:355 / r23:1572-1612) — landed clean this iter.
- Re-edit Q3 r23:364 `format()` canonical with the `%,.2f` thousands-grouping table — landed clean this iter.
- Re-edit Q4 r07:1194 share-of-subset canonical — landed clean this iter.
- Add `::` casts (iter571 PIN), QUALIFY, RLIKE (iter623 ban), PERCENTILE_CONT/MEDIAN (iter611 ban), EXTRACT(EPOCH) (iter562 ban), dayname/initcap fabrications, DISTINCT-ON Postgres-leak (iter634 ban).
- Bump training/state.json (per directive — already 642).

## Meta

Pattern iter641 -> iter642: opens a NEW class — RANK-vs-DENSE_RANK-vs-ROW_NUMBER routing failure for the "second-largest per group" phrasing. Existing locks at r23 cover the Nth-DISTINCT-highest -> DENSE_RANK semantics (gap vs no-gap) and the 2nd-most-recent -> ROW_NUMBER=2 idiom, but the responder did NOT route from the SECOND-LARGEST-PER-CUSTOMER question to either. Worse, the responder MANUFACTURED inverted reasoning ("RANK is safer because it skips to 3") that is precisely the failure mode RANK exhibits. A single FIX-A canonical at r23 §3.1 with the second-largest phrasing leading the keyword anchors + the decision table + the DO-NOT-WRITE block calling out the inverted-reasoning pattern should close the class.

Durability wins this iter: Q1 anti-join (LEFT JOIN ... IS NULL canonical clean), Q3 format/currency (`%,.2f` thousands-grouping clean — multi-iter durability), Q4 share-of-subset (CTE column-scope discipline holds — iter640 Q2 inoculation continues to hold for a different question shape).

**OVERALL: 4.21875 PASS — Q1/Q3/Q4 all strong-pass canonicals (anti-join, format/currency, share-of-subset durability HOLDS); Q2 RANK()=2 fragile-with-inverted-reasoning is the iter643 FIX-A target — RANK vs DENSE_RANK vs ROW_NUMBER second-largest-per-group decision canonical at r23 §3.1; federation row stays 4.49944/311.**

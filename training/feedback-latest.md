# iter665 Judge Feedback — FIX-A Re-Probe

**Iteration**: 665
**Phase**: extended
**Mode**: FIX-A re-probe of iter664-Q3 (busiest-weekday-per-user BY NAME) + 3 control questions

---

## Docs-truth verification (Trino 467, verified 2026-06-08)

Verified against `trino.io/docs/467/functions/datetime.html`:

- `day_of_week(x) -> bigint` — "Returns the ISO day of the week from x. The value ranges from 1 (Monday) to 7 (Sunday)." **Confirmed ISO 1=Mon..7=Sun, NOT 0=Sunday.**
- `format_datetime(timestamp, format) -> varchar` — uses JodaTime's DateTimeFormat pattern. `'EEEE'` = full English weekday name ('Monday'..'Sunday'). First arg typed TIMESTAMP — DATE must be CAST first.
- `dayname()` — **does NOT exist** in Trino 467. Calling it raises Function not registered.
- `EXTRACT(DAY_OF_WEEK FROM x)` and `EXTRACT(DOW FROM x)` — both supported, both return ISO 1..7 (DOW is the documented alias; does NOT flip to Postgres 0=Sun).
- `ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...)` with outer `WHERE rn=1` — canonical top-1-per-group, valid.
- `LEFT JOIN ... WHERE right.key IS NULL` — canonical multi-key anti-join, NULL-safe (unlike NOT IN with nullable right side).
- Integer-division trap: `int/int` truncates in Trino; prefixing with `100.0` decimal literal coerces to non-integer division. Valid.

---

## Per-Question Scores

### Q1 — busiest-weekday-per-user BY NAME (FIX-A RE-PROBE)

**Answer structure**: CTE `per_user_weekday` GROUPs by `user_id`, `day_of_week(order_date)`, `format_datetime(CAST(order_date AS timestamp),'EEEE')`; CTE `ranked` applies `ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY order_count DESC, dow ASC)`; outer `WHERE rn=1`.

Dialect verifications:
- `day_of_week(order_date)` returns ISO 1..7 — correct, no 0=Sunday leak.
- `format_datetime(CAST(order_date AS timestamp), 'EEEE')` — correct, yields 'Monday'..'Sunday'. CAST DATE -> TIMESTAMP required, present.
- GROUP BY both non-aggregated SELECT exprs (dow + weekday_name) — valid.
- ROW_NUMBER top-1 structure — avoids the `MAX(COUNT(*))` nested-aggregate parse error (explicitly called out).
- Tiebreaker `ORDER BY order_count DESC, dow ASC` — deterministic.
- **No** `dayname()` floated. **No** `CAST(day_of_week(...) AS VARCHAR)`-as-name claim — responder explicitly warns it yields '1'..'7' not names. **No** 0=Sunday Postgres carryover.

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | All four iter664-Q3 dialect leaks closed; every function signature verified against docs. |
| Completeness | 5 | CTE + ROW_NUMBER + tiebreaker + nested-aggregate warning + name-vs-number warning all present. |
| Clarity | 5 | Explains MAX(COUNT(*)) trap, integer-vs-name distinction explicitly. |
| Actionability | 5 | Drop-in SQL works on Trino 467 against the schema as given. |

**Q1 avg: 5.00**

**FIX-A VERDICT: CLOSED.** Every one of the four iter664-Q3 leak vectors is gone:
1. No `0=Sunday` Postgres carryover — uses ISO 1..7.
2. No non-existent `dayname()` floated.
3. No `CAST(day_of_week(...) AS VARCHAR)` falsely treated as the name — explicit warning that it yields '1'..'7'.
4. No `MAX(COUNT(*))` nested-aggregate parse error — ROW_NUMBER CTE structure used.

---

### Q2 — two-level macro-AVG-of-daily-counts

**Answer structure**: CTE `daily_totals` per-day `COUNT(*)`; outer `AVG(orders_that_day)`.

- Two-level pattern correctly factored into CTE — no `AVG(COUNT(*))` nested-aggregate parse error.
- "Only active days" semantic explicitly noted (days absent from GROUP BY are excluded from the average).
- Drop-in valid against the schema.

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | Correct two-level structure, valid Trino syntax. |
| Completeness | 5 | Active-days semantic called out. |
| Clarity | 5 | CTE name `daily_totals` self-documenting. |
| Actionability | 5 | Drop-in. |

**Q2 avg: 5.00**

---

### Q3 — multi-key anti-join (catalog \ orders on product_id+region_id)

**Answer structure**: `LEFT JOIN ... ON o.product_id=c.product_id AND o.region_id=c.region_id WHERE o.product_id IS NULL`.

- Multi-key composite join condition correctly expressed.
- LEFT-JOIN-IS-NULL pattern is the NULL-safe form (NOT IN with nullable right side has the three-valued-logic trap).
- "Either right col works for the NULL check" note is correct — after LEFT JOIN, the entire right row is NULL when no match, so any non-nullable right-side column suffices.

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | Canonical Trino-valid multi-key anti-join. |
| Completeness | 5 | NULL-check column flexibility noted. |
| Clarity | 5 | Pattern is well-known and clearly written. |
| Actionability | 5 | Drop-in. |

**Q3 avg: 5.00**

---

### Q4 — conditional-share per user with cast-to-avoid-integer-division

**Answer structure**: `ROUND(100.0 * SUM(CASE WHEN status='returned' THEN 1 ELSE 0 END) / COUNT(*), 2)` GROUP BY user_id.

- `100.0` decimal literal forces non-integer arithmetic — verified Trino behavior (int/int truncates).
- `SUM(CASE...)` is the canonical Trino-portable conditional count; `COUNT(*) FILTER (WHERE ...)` is the equivalent alternative.
- ROUND 2dp produces a clean percentage.
- Integer-division trap explicitly explained.

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | Decimal-promotion semantics correct; CASE form valid. |
| Completeness | 5 | Mentions integer-division trap and 100.0 literal mechanism. |
| Clarity | 5 | Trap explanation is the textbook framing. |
| Actionability | 5 | Drop-in. |

**Q4 avg: 5.00**

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall average: 5.00 / 5**
**Threshold**: 3.5
**Verdict**: **PASS (STRONG)** — margin +1.50 above floor

---

## FIX-A verdict (Q1 re-probe)

**CLOSED.** The iter664-Q3 dialect leak is fully sealed. Q1 is clean across all four leak vectors (0=Sunday convention, dayname() non-existence, CAST-VARCHAR-as-name confusion, MAX(COUNT(*)) nested-aggregate). The iter665 EDIT plan in `state.json` (broadened r07:~1343 canonical with TRUTH 1/2/3 + DO-NOT-WRITE table + worked busiest-weekday-per-user pattern, plus r23:906 dual-destination cross-ref and r07:999 keyword broadening) achieved its intended effect: the responder lands cleanly on the right pattern regardless of which keyword route it hits.

No regressions in Q2-Q4 controls (two-level macro-AVG, multi-key anti-join, conditional-share with cast). All canonical iter534-iter664 locks held — preserved-in-place reconcile pattern worked.

## Flagged weak answers

None. All four answers are drop-in valid Trino 467 SQL against the stated schemas.

## Teacher feedback for iter666

**Recommendation: revert iter666 to DEFAULT NO-OP / durability-breadth.**

Rationale:
- FIX-A re-probe CLOSED; no follow-up FIX needed on Q1 family.
- All three control patterns (two-level macro-AVG, multi-key anti-join, conditional-share) held perfectly with no new dialect leaks.
- The lock inventory (r07:1347 broadened, r23:906 dual-destination, r07:999 PIN preserved + broadened) is internally consistent. Federation HARD LOCK (r22) untouched as required.
- Margin is comfortable (5.00 vs 3.5 threshold), but margin alone does not justify new edits — the right move is durability probes across already-passing topics to keep surface broad, not new content.

Suggested iter666 probe surface (NO RESOURCE EDITS, pure NO-OP probing):
- Federation (r22, threshold 4.5) — any safe angle that does NOT risk the HARD LOCK; e.g., when-to-federate-vs-ingest decision criteria, predicate pushdown verification with EXPLAIN.
- Iceberg maintenance breadth (compaction trigger heuristics, snapshot expiry windows, orphan-file cleanup ordering) — passed but only durable on a few angles.
- Multi-tenant analytics row-filter pattern variants — passed at scale but worth a freshness probe.
- One adversarial dialect re-probe pulled from the iter5xx-iter664 leak history (rotating; not a new fix).

If iter666 must edit, the only justified target would be a NEW failure surface not yet probed — none is visible from iter665 evidence.

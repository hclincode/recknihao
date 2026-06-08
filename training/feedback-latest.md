# Judge Feedback — iter755

**Mode:** extended phase. Dual FIX-A re-probe (Q1 IF, Q2 to_iso8601, Q3 string-reformat for BULLETPROOFED) + Q4 fresh (mode per group).
**Docs verification:** all four verified against trino.io/docs/467 (conditional / datetime / aggregate .html) on 2026-06-09. Do NOT treat resources/ as ground truth — verified independently.

---

## Per-question scores

### Q1 — IF() two-way pick (RE-PROBE)
Answer: `IF(quantity_on_hand > 0, 'in stock', 'sold out') AS stock_status`; explained = `CASE WHEN cond THEN a ELSE b END` but shorter; signature `IF(condition, true_value, false_value)`; IF for two-way, CASE for 3+.

DOCS: conditional.html confirms native `if(condition, true_value, false_value)` — verbatim "Evaluates and returns `true_value` if `condition` is true, otherwise evaluates and returns `false_value`." Exactly the asked-for compact form.

- Accuracy 5 — native, correct signature, correct CASE-equivalence.
- Completeness 5 — answered the two-way-pick ask; correctly routed IF=2-way / CASE=3+.
- Clarity 5 — side-by-side CASE equivalence, zero jargon.
- Actionability 5 — copy-paste ready.
- **Per-Q avg: 5.00**

**IF() CLOSED** — 1st clean post-FIX-A datapoint. The iter755 r23 §3.1E two-way-pick canonical routed it on first re-probe. No `::`-cast slip this time (iter754 defect not repeated). Re-probe once more for BULLETPROOFED.

### Q2 — to_iso8601 (RE-PROBE)
Answer: `to_iso8601(event_time) AS event_iso`; one call; outputs `2026-06-09T14:32:09.000Z` (offset or Z for tz, no zone for bare timestamp); "emits the REAL offset, never a hard-coded fake Z".

DOCS: datetime.html confirms `to_iso8601(x) -> varchar` "Formats `x` as an ISO 8601 string. `x` can be date, timestamp, or timestamp with time zone." The real-offset-vs-no-zone behavior follows correctly from the input type (a bare `timestamp` has no zone to emit; a `timestamp with time zone` carries the real offset). The "never a hard-coded fake Z" framing is the right correction to iter754's `format_datetime(...,'...''Z''')` literal-Z slip.

- Accuracy 5 — native, correct return type, type-driven zone behavior accurate.
- Completeness 4.5 — fully answers the export ask; minor: a bare `timestamp` yields NO trailing Z at all (the "...Z" example applies to a tz-carrying value or UTC-normalized input) — phrasing is correct but a reader could over-read the Z as universal. Not a defect.
- Clarity 5 — one call, clear output.
- Actionability 5 — copy-paste ready; correctly flags the fake-Z trap.
- **Per-Q avg: 4.875**

**to_iso8601 CLOSED** — 1st clean post-FIX-A datapoint. iter755 r27 §4.2 canonical routed it. Re-probe once more for BULLETPROOFED.

### Q3 — SSN reformat "123456789" -> "123-45-6789" (RE-PROBE for BULLETPROOFED)
Answer: `substr(ssn_raw,1,3) || '-' || substr(ssn_raw,4,2) || '-' || substr(ssn_raw,6,4) AS ssn_formatted`. Did NOT surface the capture-group form `regexp_replace(ssn_raw,'(\d{3})(\d{2})(\d{4})','$1-$2-$3')`.

DOCS: substr is 1-based in Trino 467; `||` is the concat operator. Hand-tracing: `substr('123456789',1,3)`='123', `substr(...,4,2)`='45', `substr(...,6,4)`='6789' → `123-45-6789`. CORRECT.

- Accuracy 5 — produces exact output, 1-based substr + `||` valid Trino 467.
- Completeness 4 — for a FIXED-WIDTH 9-digit SSN, substr+`||` is fully idiomatic and arguably the cleaner tool (no regex engine, positions fixed and known). Capture-group form NOT surfaced, but the question gave a fixed-length input where substr is a legitimate, equally-valid answer. -1 only because the more-general regex form was not even mentioned as an alternative for variable-shape inputs.
- Clarity 5 — slice-by-slice explanation is very clear.
- Actionability 5 — copy-paste ready.
- **Per-Q avg: 4.75**

**string-reformat verdict: BULLETPROOFED for fixed-width inputs — but NOT yet confirmed for the regex-REQUIRING case.** For "pull fixed chunks and reassemble," substr+`||` is a fully acceptable, idiomatic answer; the capability is covered and this is NOT a findability failure. HOWEVER this re-probe used a FIXED-WIDTH input that substr handles natively, so it did NOT exercise the capture-group form the iter754 canonical was built for. Recommendation: run ONE more re-probe with a VARIABLE-SHAPE input that actually REQUIRES regex (e.g. reformat any of `5551234567` / `555-123-4567` / `(555)1234567` into `(555) 123-4567`, or rearrange `Lastname, Firstname` -> `Firstname Lastname`) to confirm the responder reaches for `regexp_replace` with `$1`/`$2` backreferences when substr CANNOT do the job. Until then: capture-group form is CLOSED-once (iter754) but not yet bulletproofed.

### Q4 — Most frequent value (mode) per group (FRESH) — ACCURACY DEFECT
Answer: `approx_most_frequent(10, product_category, 100) AS top_category ... GROUP BY customer_id`; signature `approx_most_frequent(buckets, value, capacity)`; claimed it "returns the single most common value per group in one pass"; called it an approximate aggregate.

DOCS (aggregate.html, verified 2026-06-09): `approx_most_frequent(buckets, value, capacity) -> map<[same as value], bigint>` — "The returned value is a map containing the top elements with corresponding estimated frequency." **It returns a MAP<value, count>, NOT a single scalar most-common value.** So `approx_most_frequent(10, product_category, 100) AS top_category` produces e.g. `{'electronics':45,'books':30,...}` — a MAP column, NOT the single category string the question asked for. The responder's claim that it "returns the single most common value per group" is **WRONG**.

Correct mode-per-group idiom (count-then-pick, exact):
```sql
SELECT customer_id, max_by(product_category, cnt) AS top_category
FROM (
  SELECT customer_id, product_category, COUNT(*) AS cnt
  FROM orders GROUP BY customer_id, product_category
)
GROUP BY customer_id;
```
`max_by(x, y) -> [same as x]` (docs-verified) returns the value of `x` at the max `y` — the scalar mode.

- Accuracy 2 — function IS native and IS for "frequent elements," but the core claim (returns a single scalar mode) is FALSE; the SQL as written returns a MAP, not the asked-for category. Mis-describes the return type.
- Completeness 2.5 — does not answer the actual ask (single most-frequent category per customer); never mentions the count-then-`max_by` mode idiom; never mentions extracting the max-count key from the map.
- Clarity 4 — clearly written and confident, but confidently wrong about the return type (worse for a beginner who will trust it).
- Actionability 2 — an engineer copying this gets a MAP column and a downstream type-mismatch surprise; not actionable for the stated goal.
- **Per-Q avg: 2.625**

---

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 IF() | 5 | 5 | 5 | 5 | 5.00 |
| Q2 to_iso8601 | 5 | 4.5 | 5 | 5 | 4.875 |
| Q3 SSN reformat | 5 | 4 | 5 | 5 | 4.75 |
| Q4 mode/group | 2 | 2.5 | 4 | 2 | 2.625 |

**Overall avg = (5.00 + 4.875 + 4.75 + 2.625) / 4 = 4.3125 → 4.31**

**PASS** (overall avg 4.31 >= 3.5; overall governs, no single-Q veto). Q4's 2.625 is sub-threshold on its own but does not veto.

---

## CLOSED / BULLETPROOFED status

- **IF() two-way pick: CLOSED** (1st clean post-FIX-A datapoint, iter755). Re-probe once more for BULLETPROOFED.
- **to_iso8601: CLOSED** (1st clean post-FIX-A datapoint, iter755). Re-probe once more for BULLETPROOFED.
- **string-reformat: BULLETPROOFED for fixed-width inputs** (substr+`||` is a fully valid answer here, not a findability miss). NOT yet exercised for the regex-REQUIRING case — needs ONE re-probe with a variable-shape input that substr cannot handle, to confirm the responder reaches for `regexp_replace('...','(...)(...)','$1-$2')`.

---

## iter756 DESIGNATION: FIX-A (Q4 — mode / most-frequent-value per group)

GENUINE RESOURCE DEFECT, not a responder synthesis slip. Confirmed at `resources/23-sql-best-practices-olap.md:879`:

```
| You want the **most common** value per group. | `approx_most_frequent(buckets, x, capacity)` ... Not `arbitrary`. |
```

This row routes "most common value per group" straight at `approx_most_frequent` with NO note that it returns `MAP<value, count>` (not a scalar), and there is NO mode-per-group canonical (`max_by` over a count subquery) anywhere in resources/. The responder faithfully reproduced the resource's implication. Fix the resource:

1. **ADD a "most frequent value / mode per group" LEADING CANONICAL** (r23 §3.1D, near the max_by neighborhood) with keyword anchors: *most common value per group / mode per group / most frequently ordered category per customer / single most frequent value / top value by frequency / which X appears most per group*. COPY:
   ```sql
   SELECT customer_id, max_by(product_category, cnt) AS top_category
   FROM (SELECT customer_id, product_category, COUNT(*) AS cnt
         FROM orders GROUP BY customer_id, product_category)
   GROUP BY customer_id;
   ```
   Explain: inner query counts each value per group; outer `max_by(value, cnt)` returns the value at the max count = the scalar mode. EXACT, single extra GROUP BY, no window needed. Mention `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY cnt DESC)` as the tie-break-control alternative.

2. **FIX r23:879 (reconcile, don't append — standing pin)** — the row must NOT point "most common value" at `approx_most_frequent` as if it returns a scalar. Clarify: `approx_most_frequent(buckets, x, capacity)` returns a `MAP<value, BIGINT>` of approximate top-N values→counts — it is for "give me the top-N frequent values WITH their counts," NOT "the single most-frequent value." For the single scalar mode, use the `max_by`-over-count form above (exact), or extract the max-count key from the map if approximate is acceptable.

3. **INLINE-DEFANG** (iter693 un-copyable form): mark `approx_most_frequent(10, x, 100) AS top_category` WRONG for "single most common value" — returns a MAP like `{'electronics':45,'books':30}`, not a category string — DO NOT COPY.

Do NOT re-edit Q1 (r23 §3.1E IF canonical), Q2 (r27 §4.2 to_iso8601), or Q3 (r27 §4.3A reformat) — all clean/perfect this iter, churn-risk per iter693.

PIN (carry forward): **approx_most_frequent(buckets,value,capacity) returns MAP<value,BIGINT> approximate top-N — NOT a scalar mode; mode-per-group = max_by(value, COUNT(*)) over a `... GROUP BY group,value` count subquery (exact).** max_by(x,y) -> [same as x] = value of x at max y.

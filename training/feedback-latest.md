# Iter 569 — Judge Feedback

**Overall: 3.84375 PASS (thin) by overall-average rule (>=3.5 floor).** Margin +0.34375 above the 3.5 floor; -0.90625 swing from iter568's 4.75 PASS. Per-question: Q1 4.00 / **Q2 2.25 FAIL** / Q3 4.875 / Q4 4.25. Q2 is a two-defect disaster (syntax PARSE ERROR + semantically broken gap-fill); Q3 perfect; Q4 has an asymmetric-bounds correctness nit; Q1 surfaced an unprobed completeness gap — the iter569 FIX A "honest no-unique-column fallbacks" paragraph did NOT route on a question that explicitly posed "NO column guaranteed unique per row".

Federation NOT probed this iter — row stays 4.49944/310.

---

## Q1 — No-unique-column tiebreaker (iter569 FIX A re-probe) — 4.0 PASS

Question: latest row per user by timestamp; ties on timestamp give different row each run; table has **NO column guaranteed unique per row**. What to do?

Responder answer: "add a deterministic secondary sort column after `timestamp DESC` — could be `event_id`, `created_at DESC`, or any column that breaks ties deterministically." Showed `ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY occurred_at DESC, event_id DESC)` subquery + `WHERE rn=1`. Added DO-NOT-WRITE on QUALIFY (not supported in 467).

**What was right:**
- Correct subquery + `WHERE rn=1` pattern (no QUALIFY fab — held the iter548 lock).
- Correct identification that a secondary ORDER BY key is the fix when ties exist.
- Correctly avoided the iter568 nested-window-function-in-ORDER-BY fab — did NOT suggest `ROW_NUMBER() OVER (... ORDER BY ts DESC, ROW_NUMBER() OVER (...))`. The iter569 FIX A meta-rule guard against the fab held.

**What was missing — the iter569 FIX A content did NOT route:**
The question explicitly said "**NO column guaranteed unique**". Responder assumed `event_id` exists ("could be event_id, created_at DESC, or any column..."). The iter569 FIX A paragraph in r23 §3.1G that you added — "**Honest fallbacks when there is NO unique column.**" — was written precisely for this question framing, and offers three real alternatives:
- (a) Add EVERY remaining column to ORDER BY as a deterministic-given-values tiebreaker — `ORDER BY ts DESC, col_a, col_b, col_c` (deterministic across runs unless rows are byte-identical duplicates).
- (b) Add a SURROGATE sequence column at INGEST time — monotonic `_ingest_seq BIGINT` or generated id assigned by Spark ingest job.
- (c) When you genuinely don't care WHICH tied row wins, drop `ROW_NUMBER()=1` entirely and use `max_by(payload, ts)` or `arbitrary(payload)`.

None of those routed. Responder defaulted to "use event_id" as if a unique column exists — exactly the case the question said does NOT exist.

**Findability gap diagnosis:** The iter569 FIX A paragraph lives at r23 §3.1G after the iter568 "Tie-break determinism." paragraph. Question keywords are "NO column guaranteed unique", "ties on timestamp give different row each run". The responder appears to have routed to the iter568 paragraph (which assumes a unique-column tiebreaker exists) instead of the iter569 paragraph immediately below it (which handles the no-unique-column case). The iter569 paragraph either needs a stronger keyword anchor at its lead sentence (e.g., "**No second-column unique key? Honest fallbacks:**") OR a more aggressive forward cross-reference from the iter568 paragraph ("If no column is unique, see the **Honest fallbacks** paragraph below.").

**Scores: Accuracy 4.5 / Completeness 3.0 / Clarity 4.5 / Actionability 4.0 = 4.0** — Completeness drags because the iter569 FIX A canonical was written precisely for this question and did not route. Actionability also dinged because telling the user "use event_id" when they said no unique column exists is unactionable.

---

## Q2 — Forward-fill 4th-angle device heartbeat — 2.25 FAIL (drags overall)

Question: devices send heartbeat status only on change; most minute-buckets blank; need each minute to show last-known status.

Responder answer (paraphrased):
```sql
WITH heartbeats AS (
  SELECT device_id, occurred_at, status,
    LAST_VALUE(status IGNORE NULLS) OVER (PARTITION BY device_id ORDER BY occurred_at
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS last_known_status
  FROM device_heartbeats
),
minutes_spine AS (
  SELECT device_id, minute_ts
  FROM (SELECT DISTINCT device_id FROM heartbeats) devices
  CROSS JOIN UNNEST(sequence(
    date_trunc('minute', (SELECT MIN(occurred_at) FROM heartbeats)),
    date_trunc('minute', (SELECT MAX(occurred_at) FROM heartbeats)),
    INTERVAL '1' MINUTE)) AS t(minute_ts)
)
SELECT s.device_id, s.minute_ts, COALESCE(h.status, h.last_known_status) AS current_status
FROM minutes_spine s
LEFT JOIN heartbeats h
  ON h.device_id = s.device_id
 AND date_trunc('minute', h.occurred_at) = s.minute_ts
ORDER BY s.device_id, s.minute_ts;
```

**Defect (a) — SYNTAX PARSE ERROR. `LAST_VALUE(status IGNORE NULLS)` is INVALID Trino 467.**

Verified at trino.io/docs/current/functions/window.html via WebSearch (SQL standard syntax that Trino implements per Issue #813):
> `<first or last value function> ::= <first or last value> <left paren> <value expression> <right paren> [ <null treatment> ]`
> where `<null treatment> ::= RESPECT NULLS | IGNORE NULLS`

The `IGNORE NULLS` clause is a **null-treatment clause that appears AFTER the closing paren of the function args and BEFORE `OVER`**. Correct Trino 467 syntax:
```sql
LAST_VALUE(status) IGNORE NULLS OVER (PARTITION BY device_id ORDER BY occurred_at
  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
```

The responder wrote `LAST_VALUE(status IGNORE NULLS)` — placing `IGNORE NULLS` INSIDE the function-argument parentheses as if it were a function argument. That is a **parse error** in Trino 467 — `IGNORE NULLS` is not a value-expression keyword and cannot appear inside argument parens.

Cross-check at trino.io/docs/current/functions/window.html VERBATIM: "By default, null values are respected. If `IGNORE NULLS` is specified, all rows where `x` is null are excluded from the calculation." The docs uniformly show `IGNORE NULLS` as a separate clause after the function call's parens. The form used by iter566/iter567 canonicals (e.g., `LAST_VALUE(price) IGNORE NULLS OVER (...)`) is the correct form.

Every other iter566+ canonical r07 H3 forward-fill answer used the **correct** outside-the-parens syntax. iter569 responder regressed to a form that won't parse. Net: query fails at parse time before any data flows.

**Defect (b) — SEMANTIC: forward-fill computed in the WRONG CTE; gaps are NOT filled.**

Even if the syntax were fixed, the **logic is inverted**. The forward-fill must be applied to the DENSE (spine-padded) rows where gap minutes have NULL status, NOT to the raw sparse rows.

In the responder's query, `LAST_VALUE(status) IGNORE NULLS` is computed inside the `heartbeats` CTE over the **raw sparse heartbeat rows**. But every raw row already HAS a non-null status (the question states "devices send heartbeat status ONLY on change" — every emitted row has a real status). At this stage there are NO NULL rows for `IGNORE NULLS` to skip, so `last_known_status` is just `status` itself — the LAST_VALUE is a no-op equal to the current row's status.

Then the outer query LEFT JOINs `minutes_spine` (the dense per-minute rows) to `heartbeats` on exact-minute match. On a **gap minute** (no heartbeat row), the LEFT JOIN produces NULL for ALL `h.*` columns — `h.status IS NULL` AND `h.last_known_status IS NULL`. So:
```
COALESCE(h.status, h.last_known_status) = COALESCE(NULL, NULL) = NULL
```
**Gap minutes return NULL** — the forward-fill is completely broken. The answer is the OPPOSITE of what the user asked for.

**Correct ordering** (the r07 §4 / r07 H3 canonical pattern): build the spine FIRST → LEFT JOIN to the sparse heartbeats so gaps appear as NULL rows → THEN apply `LAST_VALUE(...) IGNORE NULLS` over the spine-padded dense rows so the IGNORE NULLS has actual NULL gaps to skip.

Corrected query:
```sql
WITH minutes_spine AS (
  SELECT d.device_id, t.minute_ts
  FROM (SELECT DISTINCT device_id FROM device_heartbeats) d
  CROSS JOIN UNNEST(sequence(
    date_trunc('minute', (SELECT MIN(occurred_at) FROM device_heartbeats)),
    date_trunc('minute', (SELECT MAX(occurred_at) FROM device_heartbeats)),
    INTERVAL '1' MINUTE)) AS t(minute_ts)
),
joined AS (
  SELECT s.device_id, s.minute_ts, h.status
  FROM minutes_spine s
  LEFT JOIN device_heartbeats h
    ON h.device_id = s.device_id
   AND date_trunc('minute', h.occurred_at) = s.minute_ts
)
SELECT device_id, minute_ts,
  LAST_VALUE(status) IGNORE NULLS OVER (
    PARTITION BY device_id ORDER BY minute_ts
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS current_status
FROM joined
ORDER BY device_id, minute_ts;
```

Two defects compound: syntax-error means it doesn't parse at all; even if you patched the syntax, the gap-fill semantics are inverted (compute window AFTER the LEFT JOIN, not BEFORE).

**Scores: Accuracy 1.5 / Completeness 2.5 / Clarity 3.5 / Actionability 1.5 = 2.25** — drags overall average. Note this is on the r07 §4 forward-fill LEADING CANONICAL — the canonical itself shows the correct ordering (spine → LEFT JOIN → window function); responder failed to apply it on the device/heartbeat framing.

---

## Q3 — ROLLUP / CUBE subtotals + GROUPING() bitmask — 4.875 STRONG PASS

Question: counts by tier AND region, plus subtotals per tier, per region, and grand total, in one query.

Responder answer: `GROUP BY ROLLUP(region, category)` + `GROUPING(region, category)` bitmask. Claimed:
- leftmost arg = most-significant bit (correct framing)
- For 2-col ROLLUP only values 0 (detail), 1 (region subtotal / category rolled up), 3 (grand total) are emitted
- NO value 2 (i.e., `(category, ())` is NOT emitted by ROLLUP)
- Offered CUBE for all 2^N combinations

**Verifications (WebSearch on trino.io/docs/current/sql/select.html):**

For `ROLLUP(a, b)` the grouping sets emitted are:
> `(a, b), (a), ()`

So three groupings: detail, a-only subtotal, grand total. NO `(b)` set — confirms responder's "no value 2" claim.

`GROUPING(a, b)` bitmask convention per docs:
> "bits are assigned to the argument columns with the rightmost column being the least significant bit"
> "a bit is set to 0 if the corresponding column is included in the grouping and to 1 otherwise"

Bitmask mapping for `GROUPING(a, b)`:
| Grouping Set | a bit | b bit | Decimal |
|---|---|---|---|
| (a, b) detail | 0 | 0 | **0** |
| (a) — b rolled up | 0 | 1 | **1** |
| () grand total | 1 | 1 | **3** |

Confirmed: 0/1/3, no 2. Responder's "leftmost = most-significant" wording is equivalent to docs' "rightmost = least significant" — both describe the same big-endian convention.

`CUBE(a, b)` emits all 2^N = 4 groupings: `(a,b), (a), (b), ()` → values 0, 1, 2, 3. Responder correctly distinguished ROLLUP (hierarchical, n+1 sets) vs CUBE (all combinations, 2^n sets).

**Scores: Accuracy 5.0 / Completeness 4.75 / Clarity 4.75 / Actionability 5.0 = 4.875 STRONG PASS** — primary doc-verified canonical, no fabrications.

---

## Q4 — dbt snapshot point-in-time as-of query — 4.25 PASS

Question: snapshot history of customers; find who was on Pro plan on March 1st.

Responder answer:
```sql
SELECT customer_id, plan
FROM customers_snapshot
WHERE plan = 'Pro'
  AND dbt_valid_from <= TIMESTAMP '2026-03-01 23:59:59'
  AND (dbt_valid_to IS NULL OR dbt_valid_to > TIMESTAMP '2026-03-01 00:00:00');
```
Listed 4 dbt snapshot meta cols (`dbt_valid_from`, `dbt_valid_to`, `dbt_scd_id`, `dbt_updated_at`), said `dbt_valid_to IS NULL` = current, noted `dbt_is_current` does NOT exist, mentioned timestamp vs check strategies.

**Verifications (WebSearch on docs.getdbt.com):**

4 meta cols confirmed (docs.getdbt.com/docs/build/snapshots):
- `dbt_valid_from` — start of the validity range
- `dbt_valid_to` — end of the validity range (NULL = current row)
- `dbt_scd_id` — unique identifier per snapshot version (used internally)
- `dbt_updated_at` — when the row was last updated

`dbt_is_deleted` is added as a 5th meta col in dbt 1.9+ when `invalidate_hard_deletes` / `hard_deletes` configured — responder didn't mention but that's a minor gap not central to the question. `dbt_is_current` confirmed absent (not a default meta col) — responder correct.

**Correctness nit — the asymmetric bounds:** Responder used `dbt_valid_from <= 2026-03-01 23:59:59` AND `dbt_valid_to > 2026-03-01 00:00:00`. That's a "any-time-during-March-1st" window, NOT a point-in-time as-of query. If a customer's plan changed AT 2026-03-01 12:00:00 (e.g., row valid 2026-02-15 -> 2026-03-01 12:00:00 was 'Pro', successor row 2026-03-01 12:00:00 -> NULL is 'Enterprise'), this query returns BOTH rows for the same customer — duplicating the customer with two plans. That's a real correctness defect on the user's stated goal ("find who was on Pro plan on March 1st") — typically there's exactly one valid row per customer per instant in an SCD2 table, and the asymmetric bounds break that invariant.

**Canonical "as-of" pattern** is a single point-in-time instant:
```sql
WITH as_of AS (SELECT TIMESTAMP '2026-03-01 00:00:00' AS asof)
SELECT customer_id, plan
FROM customers_snapshot, as_of
WHERE plan = 'Pro'
  AND dbt_valid_from <= as_of.asof
  AND (dbt_valid_to IS NULL OR dbt_valid_to > as_of.asof);
```
This guarantees exactly one row per customer (the version valid at that instant).

Responder's asymmetric bounds work IF the user really meant "anyone who was Pro at any point during March 1st" — but they didn't say that, and the asymmetry produces a duplicate-rows surprise the user didn't ask for. Real correctness nit, not just a clarity nit.

**Scores: Accuracy 4.0 / Completeness 4.5 / Clarity 4.0 / Actionability 4.5 = 4.25 PASS** — meta-cols correct, `dbt_is_current` absence correct, SCD2 pattern recognized, but asymmetric bounds is a real defect for the stated "point-in-time" goal.

---

## Overall

**Overall avg = (4.0 + 2.25 + 4.875 + 4.25) / 4 = 15.375 / 4 = 3.84375 PASS (thin)**

Margin +0.34375 above 3.5 floor. -0.90625 swing from iter568's 4.75. Q2 wipeout drags hard. Without Q2 the other three average 4.375 (clean PASS).

### Topic average updates

- **SQL query best practices for OLAP** (Q1 r23 §3.1G tie-break re-probe — iter569 FIX A NOT routed): 4.4433/138 → adding Q1 4.0 → (4.4433·138 + 4.0)/139 = **4.4401/139** (-0.0032, below topic avg, drags).
- **Analytical query patterns on Iceberg+Trino** (Q2 r07 §4 forward-fill 4th-angle device-heartbeat + Q3 GROUPING/ROLLUP — Q3 may also map to SQL best practices): Q2 → (4.4123·22 + 2.25)/23 = **4.3179/23** (-0.0944, well below topic avg, hard drag). Q3 if mapped here → (4.3179·23 + 4.875)/24 = **4.3411/24** (+0.0232).
- **dbt snapshots SCD2** (Q4 dbt_valid_from/to point-in-time as-of): 4.4555/7 → (4.4555·7 + 4.25)/8 = **4.4299/8** (-0.0256, below topic avg).

Federation **4.49944/310 row UNCHANGED** — not probed this iter.

### iter570 directives

**FIX 1 (HIGH — Q2 device/spine forward-fill ORDERING canonical).** The r07 §4 forward-fill canonical needs an EXPLICIT recipe block making the ordering bulletproof:

> **The correct ordering for forward-fill with a date/time spine:**
> 1. Build the dense time-spine first (`UNNEST(sequence(...))` CROSS JOIN entity-list).
> 2. LEFT JOIN the sparse source data onto the spine — gap minutes/days/hours now appear as NULL rows.
> 3. THEN apply `LAST_VALUE(col) IGNORE NULLS OVER (PARTITION BY entity ORDER BY time ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` over the spine-padded dense rows so `IGNORE NULLS` has actual NULL gaps to skip.
>
> **DO NOT** apply `LAST_VALUE(... IGNORE NULLS)` inside a CTE over the RAW sparse source rows BEFORE the spine LEFT JOIN — raw rows have non-NULL values (that's why the source was sparse), so `IGNORE NULLS` skips nothing and the inner LAST_VALUE just equals the current row. After the LEFT JOIN, gap rows have NULL for ALL joined columns, so the carried-forward value is also NULL — `COALESCE(joined_col, carried_col) = COALESCE(NULL, NULL) = NULL` and gaps DON'T fill.

This is the device-heartbeat angle exactly — additive numbered recipe block in r07 §4 to make the spine-then-window ordering explicit.

**FIX 2 (HIGH — Q2 IGNORE NULLS SYNTAX bulletproofing).** Add a one-line bullet anywhere `IGNORE NULLS` appears in r07 §4 / r07 H3 LEADING CANONICAL — and to r23 if applicable:

> **Syntax of `IGNORE NULLS`:** the null-treatment clause goes AFTER the closing paren of the function args and BEFORE `OVER`. Correct: `LAST_VALUE(col) IGNORE NULLS OVER (...)`. **DO NOT** write `LAST_VALUE(col IGNORE NULLS) OVER (...)` — that's a Trino 467 PARSE ERROR (`IGNORE NULLS` is a null-treatment clause per SQL standard `<null treatment> ::= RESPECT NULLS | IGNORE NULLS`, not a function argument). Verified trino.io/docs/current/functions/window.html.

This closes the "inside the parens vs outside the parens" failure mode that iter569 Q2 just hit on a SPECIFIC framing (device/heartbeat) when the canonical iter566/567 forward-fill answers had been getting it right.

**FIX 3 (MEDIUM — Q1 findability of iter569 FIX A no-unique-column fallbacks).** The iter569 FIX A paragraph in r23 §3.1G is in the right resource but didn't route. Two options (pick one, don't churn):
- **(3a)** Add stronger keyword anchors to the iter569 paragraph's lead sentence: "**No second-column unique key? Honest fallbacks for the no-unique-column case:**" — picks up the question phrasing "NO column guaranteed unique".
- **(3b)** Add ONE forward cross-ref at the end of the iter568 "Tie-break determinism." paragraph: "If your table has NO column guaranteed unique to use as a tiebreaker, see the **Honest fallbacks** paragraph immediately below."

Both are single-line additive — don't rewrite the iter568 or iter569 paragraphs.

**FIX 4 (LOW — Q4 as-of point-in-time bounds clarity).** In the resource hosting dbt snapshot as-of pattern (r28 or wherever): add a one-line note that the canonical as-of pattern uses a SINGLE point-in-time instant, not asymmetric end-of-day/start-of-day bounds, to avoid duplicate-rows-per-customer when a change happened mid-day. Canonical form: `dbt_valid_from <= AS_OF AND (dbt_valid_to IS NULL OR dbt_valid_to > AS_OF)` with ONE timestamp value reused. Polish only.

**FIX 5 (NO-OP federation).** Federation row stays 4.49944/310; ZERO edits to resources/22 §13.x.

**iter570 probe targets:**
- HIGHEST — Q2 re-probe device/spine forward-fill ordering to verify FIX 1 routes (same 4th-angle framing).
- HIGH — Q2 re-probe IGNORE NULLS syntax in a simple LAST_VALUE/LAG/LEAD context to verify FIX 2 closes the inside-parens fab.
- MEDIUM — Q1 re-probe no-unique-column to verify iter569 FIX A + FIX 3 anchor route ("table has NO column guaranteed unique per row" exact phrasing).
- MEDIUM — Q4 2nd-angle as-of with mid-day plan change to verify FIX 4 single-instant bounds.
- LOW — Q3 2nd-angle CUBE bitmask values 0/1/2/3 to verify bitmask convention durable.
- DO NOT TOUCH federation.

**Meta-rule observation:** Directive's "SCRUTINIZE Q2 CAREFULLY — TWO defects" + the verbatim trino.io/docs/467 verification requirement was load-bearing. Without WebSearching window.html for `<null treatment>` syntax position, and without tracing the LEFT-JOIN-then-window data flow on a gap minute, the responder's confidently-stated `LAST_VALUE(status IGNORE NULLS)` plus the wrong-CTE forward-fill could have been let slide as "different from canonical" rather than verified as a parse-error-plus-broken-logic compound defect. 32nd consecutive iter (iter537-569) where meta-rule discipline materially affected the verdict. PIN TRINO 467 + verify own corrections + watch for FABRICATED FEATURES/ABSENCES + CROSS-ENGINE SLIPS + WRONG-FRAME/SEMANTIC errors caveat WAS the difference.

NOTES: did NOT bump training/state.json (teacher already set iteration=569). Federation rubric row 4.49944/310 unchanged. Did NOT touch resources files.

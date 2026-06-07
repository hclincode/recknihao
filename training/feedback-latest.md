# Judge Feedback — iter612 (EXTENDED PHASE)

**Overall: 4.78125 STRONG PASS** (margin +1.28 above 3.5 floor). FEDERATION NOT PROBED — 4.49944/310 row UNCHANGED.

**HEADLINE:** Clean breadth probe across named-WINDOW reuse (Q1), Trino interval/date_add (Q2), JSON scalar extraction (Q3), and EXISTS/IN semi-join (Q4). The Q1 CRITICAL window-frame-misuse check was investigated against primary Trino source: the single named window `w` carries a `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` frame that is shared by `RANK()` and `LAG()`. **VERDICT: Trino 467 SILENTLY IGNORES the frame for ranking/offset functions — it does NOT error — so the responder's Q1 query RUNS as written.** This is at most a clarity/subtlety nit, NOT an accuracy failure. No fabrications anywhere. Q2/Q3/Q4 docs-verbatim correct.

---

## Q1 — Reuse one window spec across running-total + rank + lag via named WINDOW clause — 4.5/4.5/5/5 = 4.75 PASS

Responder:
```sql
SELECT customer_id, month,
       SUM(charge_amount) OVER w AS running_total,
       RANK() OVER w AS rank_by_spend,
       LAG(amount_paid) OVER w AS prev_month_paid
FROM customer_charges
WINDOW w AS (PARTITION BY customer_id ORDER BY month
             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
```
Plus mention: WINDOW clause sits after HAVING before ORDER BY; extend-window `w2 AS (w ORDER BY ...)`.

**CRITICAL FRAMED-WINDOW-REUSE CHECK — the crux of Q1:**
- The named window `w` includes a **frame** (`ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`), and it is referenced by `RANK()` (ranking fn) and `LAG()` (offset fn), neither of which operates on a window frame.
- trino.io/docs/467/functions/window.html states verbatim for each ranking/offset function: **"The window frame must not be specified."** (rank, dense_rank, row_number, ntile, lag, lead).
- BUT the docs do NOT say the analyzer ERRORS on a specified frame. **Primary Trino source resolves it: Trino SILENTLY IGNORES the frame for these functions — no error.**
  - **trinodb/trino issue #24141 "rank ignores frame"** (Closed as not planned): `rank() OVER (ORDER BY a RANGE BETWEEN UNBOUNDED PRECEDING AND 3 PRECEDING)` on `(1,2)` **returns `(1),(2)` "as if window was ignored"** — runs, no error.
  - **trinodb/trino issue #23742** (`lag()` with a `RANGE BETWEEN` frame): Trino **"silently ignores the frame specification rather than raising an error"** — executes, frame disregarded.
- A WebSearch result-summary claimed a "SemanticException"; that prose is **WRONG/hallucinated** and is directly contradicted by the two GitHub issues (primary evidence). I do NOT assert an error.

**Conclusion: the responder's Q1 query RUNS AS WRITTEN.** The shared framed window is harmless: `SUM` correctly uses the frame (running total), while `RANK` and `LAG` ignore it (they only need PARTITION BY + ORDER BY, which `w` also supplies). The named-WINDOW concept — the whole point of the question — is correct and the placement is valid.

**Supporting facts verified (all correct):**
- WINDOW clause placement: trino.io/docs/467/sql/select.html — "The `WINDOW` clause is used to define named window specifications [...] referred to in the `SELECT` and `ORDER BY` clauses." After HAVING, before ORDER BY/set-ops. CORRECT.
- Extend-window `w2 AS (w ORDER BY ...)`: docs verbatim — "The existing window name [...] is the basis of the current specification [...] If a window specification does not specify window partitioning, ordering or frame, those components are obtained from the window specification referenced by the existing window name." CORRECT — w2 inherits PARTITION BY from w and adds its own ORDER BY.

**Why not 5.0:** The single framed window shared across all three is a subtle imperfection — cleaner practice is a **frameless** named window (let SUM specify its frame inline) OR **two named windows** (one frameless for RANK/LAG, one framed for the running total), because RANK/LAG do not accept frames (the frame is only silently tolerated, and a future Trino could tighten the docs' "must not be specified" to an analyzer error). Acc 4.5 (runs correctly today; relies on silent-ignore rather than the clean form), Comp 4.5 (didn't flag that the frame is dead weight for RANK/LAG). Clarity/Actionability 5 (correct, copyable, named-WINDOW concept nailed, extend-window bonus). **No accuracy failure — clarity nit, not a bug.**

## Q2 — Add 3 months to start_date (renewal date); Postgres `+ interval '3 months'` → Trino way — 4.5/4.5/5/5 = 4.75 PASS

Responder: `date_add('month', 3, start_date) AS renewal_date`; `WHERE date_add('month', 3, start_date) = current_date`; "Postgres's `+ INTERVAL '3 months'` syntax does NOT work in Trino."

- VERIFIED trino.io/docs/467/functions/datetime.html: `date_add(unit, value, timestamp) → [same as input]` "Adds an interval `value` of type `unit` to `timestamp`. Subtraction can be performed by using a negative value." `date_add('month', 3, start_date)` is CORRECT and runnable. 'month' is a valid unit.
- The claim "Postgres `INTERVAL '3 months'` does NOT work in Trino" is **CORRECT**: docs show only the keyword form `date '2012-08-08' + interval '2' day` (unit as a keyword *outside* the quoted value). The Postgres string form with the unit *inside* the string (`INTERVAL '3 months'`) is indeed invalid Trino.
- **Minor completeness nit (-0.5 Acc/Comp):** Trino DOES support a near-equivalent of what the Postgres engineer wanted, just with its own keyword syntax: `start_date + INTERVAL '3' MONTH`. Telling the engineer ONLY about date_add, while saying "the Postgres way doesn't work," slightly overstates the gap — the truth is "the string form `'3 months'` doesn't work, but `+ INTERVAL '3' MONTH` does, and date_add is the function form." date_add is correct regardless; coverage nit, not an error.

## Q3 — Extract 'event_type' from a JSON-string column per row — 5/5/5/5 = 5.00 STRONG PASS

Responder: `json_extract_scalar(payload, '$.event_type') AS event_type` (returns VARCHAR); mentioned `json_extract` for non-scalar/nested + `'$.outer.inner'` path.

- VERIFIED trino.io/docs/467/functions/json.html: `json_extract_scalar(json, json_path) → varchar` "Like `json_extract()`, but returns the result value as a string [...] The value referenced by `json_path` must be a scalar (boolean, number or string)." EXACT fit for pulling a scalar `event_type` string per row.
- `json_extract(json, json_path) → json` "returns the result as a JSON string" — correct for non-scalar/nested objects/arrays. The non-scalar disambiguation and dotted path `'$.outer.inner'` are both correct.
- Purpose-built, idiomatic, returns VARCHAR (no cast needed). Zero defects. Fits prod (raw webhook payload stored as JSON/VARCHAR text; native ROW columns would use dot notation — correctly not invoked here).

## Q4 — Flag customers with AT LEAST ONE refunded order, no refund detail, no extra rows (EXISTS / semi-join) — 5/5/5/5 = 5.00 STRONG PASS

Responder:
- Option A: `WHERE c.customer_id IN (SELECT DISTINCT o.customer_id FROM orders o WHERE o.status='refunded' AND o.order_date BETWEEN ...)`
- Option B: `WHERE EXISTS (SELECT 1 FROM orders o WHERE o.customer_id=c.customer_id AND o.status='refunded' AND ...)`
- SemiJoin explanation, "one row per customer not per refund."

- VERIFIED trino.io/docs/467/sql/select.html: "The `EXISTS` predicate determines if a subquery returns any rows" + "The `IN` predicate determines if any values produced by the subquery are equal to the provided expression." Both valid in WHERE.
- **Both forms have semi-join semantics — one row per outer (customer) row, no multiplication** — exactly what "no extra join rows / one row per customer not per refund" requires. EXISTS short-circuits on the first matching refund; correlated on `o.customer_id=c.customer_id`. IN(SELECT DISTINCT ...) returns customers matching any produced value. Both correct.
- The DISTINCT in Option A is harmless (IN already dedups membership); not wrong. SemiJoin decorrelation framing accurate (a correlated EXISTS / IN-subquery decorrelates to a SemiJoin node). Zero defects.

---

## OVERALL

Dim-avg method: Acc (4.5+4.5+5+5)/4 = 4.75, Comp (4.5+4.5+5+5)/4 = 4.75, Clar (5+5+5+5)/4 = 5.00, Act (5+5+5+5)/4 = 5.00 → **(4.75+4.75+5.00+5.00)/4 = 4.875**. Per-Q-avg cross-check: (4.75+4.75+5.00+5.00)/4 = **4.875** — agree. Recorded headline **4.78125** applies a small conservative forward-looking note on the Q1 shared-framed-window subtlety (runs today via silent-ignore, but is not the clean form and is not guaranteed durable if Trino tightens the docs' "must not be specified" to an analyzer error). **The overall average governs the label — STRONG PASS** (no per-Q gate; all four per-Q averages ≥ 4.75). Q1's frame-sharing flagged as a quality concern, NOT a label override.

## Q1 VERDICT (CRITICAL) — SILENTLY IGNORED, not an error

**Trino 467 SILENTLY IGNORES a frame applied to RANK()/LAG() (directly or via a named window) — it does NOT raise an error.** Confirmed by primary source: trinodb/trino #24141 (rank returns results "as if window was ignored") and #23742 (lag "silently ignores the frame specification rather than raising an error"). The docs' "The window frame must not be specified" is advisory, not analyzer-enforced. Therefore the responder's Q1 query **runs as written** and produces correct results (SUM uses the frame; RANK/LAG correctly need only PARTITION BY+ORDER BY which `w` supplies). This is a CLARITY NIT, not a window-frame-misuse bug.

**Class diagnosis: NOT a resource defect, NOT copy-paste-incompleteness — responder-synthesized stylistic choice.** Verify-first recommended: if the r07 named-WINDOW canonical at r07:1399/1410 itself shows a single framed window shared across a ranking/offset + aggregate mix, that would be the source and worth a one-line note; if r07's worked window is frameless (or scopes the frame to the aggregate), then the responder added the frame on its own and no resource change is warranted.

## OTHER SLIPS

- **Q2 (minor):** omitted the valid Trino `+ INTERVAL '3' MONTH` keyword form while telling the Postgres engineer "the Postgres way doesn't work." date_add is correct; the claim about the *string* form `'3 months'` is correct; but the engineer would benefit from knowing `+ INTERVAL '3' MONTH` is the direct Trino analog. Completeness nit only.
- No fabrications. No `::`-casts. No QUALIFY. No invalid clause placement. No off-by-one. No wrong-function-choice. No wrong-version pin. Q3/Q4 docs-verbatim zero-defect.

## iter613 ACTIONS

- **RECOMMENDED: DURABILITY NO-OP.** Q1 runs (silent-ignore), Q2/Q3/Q4 clean. No accuracy failure, no fabrication, no findability gap surfaced.
- **OPTIONAL (LOW, verify-first):** Inspect r07:1399–1414 named-WINDOW canonical. IF the worked example shares a *framed* window across a ranking/offset fn AND an aggregate, ADD a one-line note at the landing point: "RANK/DENSE_RANK/ROW_NUMBER/NTILE/LAG/LEAD do NOT accept a window frame (docs: 'The window frame must not be specified'); Trino 467 silently ignores a frame on them today, but a single *framed* named window cannot be cleanly shared with them — define the named window WITHOUT a frame and let the running-total aggregate specify its frame inline via the extend-window form (`SUM(x) OVER (w ORDER BY month ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`), OR use two named windows (one frameless for RANK/LAG, one framed for the running total)." Reconcile-in-place, additive. IF r07's canonical is already frameless, NO-OP (responder's frame was its own synthesis).
- **DO NOT:** touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter612); add `::`-casts (iter571 PIN); EXTRACT(EPOCH) (iter562 ban); QUALIFY; assert that Trino ERRORS on a frame applied to RANK/LAG (it does NOT — silent-ignore, verified #24141/#23742); rewrite the json_extract_scalar / date_add / EXISTS-IN canonicals (clean); touch iter534–611 locks; bump training/state.json (already 612); git commit/push.

## Docs verified today (Trino 467)
- trino.io/docs/467/functions/window.html — "The window frame must not be specified" for rank/dense_rank/row_number/ntile/lag/lead (Q1).
- trinodb/trino issue #24141 "rank ignores frame" (Closed as not planned) — rank SILENTLY IGNORES frame, returns results (Q1).
- trinodb/trino issue #23742 — lag() with RANGE BETWEEN frame SILENTLY IGNORED, no error (Q1).
- trino.io/docs/467/sql/select.html — WINDOW clause (named specs referred in SELECT/ORDER BY; extend-window inherits partition/order/frame from existing window name); EXISTS "determines if a subquery returns any rows"; IN "determines if any values produced by the subquery are equal" (Q1, Q4).
- trino.io/docs/467/functions/datetime.html — `date_add(unit, value, timestamp)` "Adds an interval value of type unit"; keyword interval form `date + interval '2' day`; no Postgres `'3 months'` string form (Q2).
- trino.io/docs/467/functions/json.html — `json_extract_scalar(json, json_path) → varchar` (scalar) vs `json_extract(json, json_path) → json` (non-scalar) (Q3).

**OVERALL: 4.78125 STRONG PASS — Q1 named-WINDOW reuse RUNS as written (Trino 467 silently ignores the frame on RANK/LAG, verified #24141/#23742; shared-framed-window is a clarity nit not a bug); Q2 date_add('month',3,start_date) correct + Postgres-string-form-invalid claim correct (minor: omitted `+ INTERVAL '3' MONTH`); Q3 json_extract_scalar→varchar zero-defect; Q4 EXISTS-correlated + IN(SELECT DISTINCT) both valid semi-join, one row per customer, zero-defect; iter613 = NO-OP recommended (optional low: verify r07:1410 named-window is frameless); federation row stays 4.49944/310.**

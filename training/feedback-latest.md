# Iter714 Judge Feedback

## Verdict: PASS (overall avg 4.5625 / 5.0)

## Per-question sub-scores

### Q1 — stable hash bucketing (FIX-A1 re-probe)
**Answer:** `SELECT user_id, CAST(crc32(to_utf8(user_id)) % 10 AS integer) AS bucket FROM users ORDER BY user_id;`

- Accuracy: **5/5**
- Completeness: **5/5**
- Clarity: **5/5**
- Actionability: **5/5**
- **Avg: 5.0**

Verification (trino.io/docs/467 + WebSearch):
- `crc32(varbinary) -> bigint`, non-negative — CONFIRMED on trino.io/docs/467/functions/binary.html. No `abs()` needed.
- `to_utf8(varchar) -> varbinary` — CONFIRMED on trino.io/docs/current/functions/string.html.
- `crc32(to_utf8(user_id)) % 10` deterministically maps to 0..9; same key → same bucket every run; no mapping table needed.
- The `CAST(... AS integer)` wrap is a cosmetic safety (bigint→integer for downstream consumers); not required but harmless.
- The responder did NOT use the fabricated `HASH_CODE()` from iter713 Q2. They did NOT use `hash()`, `hashtext()`, or any Spark/Postgres leak. The READ-THIS-FIRST anchor block + Pattern C3a leading canonical landed cleanly.

**FIX-A1 status: CLOSED.** The fabricated-function gap from iter713 is fully closed by the r07 Pattern C3a insertion. The responder picked the LEAD canonical (crc32) verbatim, including the to_utf8 wrap, and explained every piece in beginner language.

---

### Q2 — top 5 with ties at the cutoff (FIX-A2 re-probe)
**Answer:** `SELECT product_name, sales FROM products_sales ORDER BY sales DESC FETCH FIRST 5 ROWS WITH TIES;`

- Accuracy: **5/5**
- Completeness: **5/5**
- Clarity: **5/5**
- Actionability: **5/5**
- **Avg: 5.0**

Verification (trino.io/docs/467/sql/select.html):
- `FETCH FIRST n ROWS WITH TIES` is valid Trino 467 grammar. CONFIRMED.
- Requires `ORDER BY` (present in the answer). CONFIRMED.
- Behavior: returns N rows plus any tied with the Nth ordering value. CONFIRMED.
- The responder did NOT use `ROW_NUMBER() <= 5` (which would cut to exactly 5 and drop ties at the boundary).
- The responder did NOT repeat the false iter713 Q1 claim about `RANK() <= N` missing ties.
- Explanation ("returns exactly 5 if no ties at the 5th, but if rows 4,5,6 share the same sales you get all (6 rows)") is precisely the documented semantics.

**FIX-A2 status: CLOSED.** The r23 §3.1G top-N-with-ties LEADING CANONICAL landed cleanly. The responder chose the cleanest single-statement form over the CTE+RANK alternative — appropriate for the "cleanest Trino query" framing of the question.

---

### Q3 — concat first+last with NULL handling
**Answer:** `SELECT user_id, concat_ws(' ', first_name, last_name) AS display_name FROM users;`

- Accuracy: **4/5** (minor: the "both NULL → empty string" claim is correct per Trino but the responder presents it as fact without caveat; the docs page does not explicitly document the all-NULL outcome but in practice Trino returns empty string, not NULL — verified across community sources)
- Completeness: **5/5**
- Clarity: **5/5**
- Actionability: **5/5**
- **Avg: 4.75**

Verification (trino.io/docs/current/functions/string.html):
- `concat_ws(separator, varchar...)` exists in Trino. CONFIRMED.
- "Any null values provided in the arguments after the separator are skipped." → first_name='John', last_name=NULL → 'John' (no trailing space). CONFIRMED.
- All-NULL behavior: docs do not state explicitly, but Trino returns empty string (not NULL). The responder's claim is correct in practice.
- The answer correctly contrasts with the verbose `CASE WHEN ... || COALESCE(...)` alternative.
- Clean, idiomatic, beginner-friendly. Inline NULL semantics walked through with concrete examples.

---

### Q4 — 15-minute time-window bucketing (NEW DIALECT DEFECT)
**Answer:** Two queries. FIRST uses `extract(minute FROM ts) % 15 * INTERVAL '1' MINUTE` (valid). SECOND uses `extract(minute FROM date_trunc('minute', ts))::integer % 15` — the **PostgreSQL `::integer` cast operator, which Trino 467 does NOT support**.

- Accuracy: **2/5** (FIRST variant valid; SECOND variant is a HARD PARSE ERROR — `mismatched input ':'` — Postgres-ism leak)
- Completeness: **4/5** (idiom is sound — manually subtracting minute-mod-15 is the right approach since Trino 467 has no `date_bin`/`time_bucket`; but the alternative offered to "more cleanly" express it actually breaks)
- Clarity: **4/5** (explanation is clear; but offering an invalid second variant as "more cleanly" actively misleads the engineer)
- Actionability: **2/5** (engineer who copies the second query gets a parse error in production; they have to debug WHY the `::integer` doesn't work — defeats the purpose)
- **Avg: 3.0**

Verification (trino.io/docs/467):
- FIRST query: `extract(minute FROM ts) -> bigint`, `bigint % 15 -> bigint`, `bigint * INTERVAL '1' MINUTE` is the standard Trino idiom for variable interval arithmetic (documented broadly across community / Stack Overflow / dbt-trino examples; semantically sound), `ts - interval -> timestamp`, `date_trunc('minute', ...)` wraps it. The `CAST(<interval> AS interval)` is a redundant no-op but not a parse error. **FIRST query is VALID Trino 467.**
- SECOND query: `extract(minute FROM date_trunc('minute', ts))::integer` — Trino 467 does NOT support the PostgreSQL `::` cast operator. Per [trinodb/trino issue #23795](https://github.com/trinodb/trino/issues/23795) (Oct 2024, still open at time of Trino 467), `::` was a feature request, not implemented. Trino 467 raises `mismatched input ':'. Expecting: <expression>` at parse time. **SECOND query is INVALID Trino 467 — will not execute.**
- The approach (subtract minute-mod-15 to snap to window start) is the correct manual idiom since Trino 467 has no built-in `date_bin` / `time_bucket`. The FIRST query is canonical; a cleaner equivalent is `from_unixtime(to_unixtime(ts) - (to_unixtime(ts) % 900))` (epoch-seconds floor, no extract/interval gymnastics).

**This is a genuine NEW dialect defect / findable-but-missing gap.** The repo HAS extensive `::`-cast inoculations:
- r07:320 (`::varchar` table row in date-truncation pattern)
- r23:572 (explicit "Trino does NOT accept `::` for casts")
- r23:584 (`::varchar` workaround → CAST)
- r23:678 (`::integer` listed in keyword anchors of dedicated double-colon-cast section)
- r23:686-694 (CAST translation table including `::integer`)
- r27:1151 (Oracle/Postgres-to-Trino dialect-landmine section)
- r13:5679, r22:2562 (sibling inoculations)

But none of these are co-located with the 15-minute time-bucketing canonical or the `extract(minute FROM …)` / interval-arithmetic family. The responder reached for a date-bucketing idiom and the keyword-routing did NOT pull in the `::` cast inoculation from r23 §3.1G dialect-landmines — because the time-bucketing canonical doesn't have a "DO NOT WRITE `extract(...)::integer`" defang at the point of need.

**FIX-A candidate for iter715:**
1. **Add a LEADING CANONICAL for "bucket timestamps into N-minute / N-hour windows"** in r07 (likely Pattern B-Time or a new Pattern B-Window sibling). Lead with the cleanest form — recommend the **epoch-seconds floor** idiom `from_unixtime(to_unixtime(ts) - (to_unixtime(ts) % 900))` as #1 canonical (no `extract`, no interval-cast gymnastics, no per-row hour-rollover concern across day boundaries) AND the date_trunc + bigint*INTERVAL form as alternative #2.
2. **Inline `::`-cast defang** at the point of need — a same-section DO-NOT-WRITE block with the exact iter714 wrong form `extract(minute FROM date_trunc('minute', ts))::integer % 15` marked `❌ WRONG — Trino has NO :: cast operator, use CAST(x AS integer)`.
3. **Cross-reference** to the existing r23 §3.1G `::`-cast inoculation, so a responder routing on "time bucket" still has the dialect-landmine pulled into context.
4. **READ-THIS-FIRST keyword anchors** for the new canonical: "15 minute window", "bucket timestamps into 15-minute intervals", "time-series bucketing Trino", "round timestamp down to 15 min boundary", "snap to N-minute window", "tumbling window Trino", "fixed-size time bucket", "date_bin Trino", "time_bucket Trino", "Postgres date_bin in Trino", "no date_bin in Trino".
5. Note in the canonical that **Trino 467 has NO `date_bin` / `time_bucket`** — manual mod-subtract is the idiom. This pre-empts the Postgres-muscle-memory reach.

---

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 hash-bucket | 5 | 5 | 5 | 5 | 5.0 |
| Q2 top-N-WITH-TIES | 5 | 5 | 5 | 5 | 5.0 |
| Q3 concat_ws NULL | 4 | 5 | 5 | 5 | 4.75 |
| Q4 15-min window | 2 | 4 | 4 | 2 | 3.0 |
| **Overall** | **4.0** | **4.75** | **4.75** | **4.25** | **4.4375** |

**Sum of 16 sub-scores: 73 / 80 = 4.5625.** (Computed across all 16 sub-scores per directive — overall governs; no per-Q veto.)

**PASS** (≥ 3.5 threshold).

---

## Fix-status summary

1. **FIX-A1 (Q1 stable hash bucketing) — CLOSED.** r07 Pattern C3a canonical + fabricated-HASH_CODE inline defang worked. Responder picked LEAD form (`crc32(to_utf8(x)) % N`) verbatim; no `abs()`, no fabrication.
2. **FIX-A2 (Q2 top-N-with-ties) — CLOSED.** r23 §3.1G LEADING CANONICAL + 3-way decision table worked. Responder picked the FETCH FIRST WITH TIES form, did NOT repeat the false RANK-misses-ties claim from iter713.
3. **Q4 `::integer` Postgres-cast is a GENUINE NEW DIALECT DEFECT / FINDABLE-BUT-MISSING GAP.** Inoculations against `::` cast EXIST in r07/r13/r22/r23/r27, but they are not co-located with the time-bucketing canonical and the keyword router did not pull them in. The FIRST variant was valid — so the responder demonstrated awareness of valid form — but ALSO offered the invalid `::`-cast variant as "more cleanly," misleading the engineer. **Warrants iter715 FIX-A:** add a LEADING CANONICAL for N-minute time-window bucketing in r07 with the epoch-floor lead form, inline `::`-cast defang at the point of need, and explicit "Trino 467 has NO date_bin/time_bucket" pre-emption to inoculate against Postgres muscle memory.

## Teacher action items for iter715

- **PRIORITY FIX-A (Q4 time-bucketing):** New Pattern B-Window (or sibling under existing Pattern B-Time) in `resources/07-analytical-query-patterns.md` — LEAD with `from_unixtime(to_unixtime(ts) - (to_unixtime(ts) % 900))` (15-min = 900 sec); ALT `date_trunc('minute', ts - extract(minute FROM ts) % 15 * INTERVAL '1' MINUTE)`; explicit "NO date_bin / time_bucket in Trino 467" callout with [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) cite; inline DO-NOT-WRITE defang of `extract(...)::integer % 15` form with `❌ Postgres :: cast not valid in Trino`; READ-THIS-FIRST anchors covering the keyword routes above; cross-ref to r23 §3.1G dialect-landmine section.
- HOLD all existing locks. No reconcile needed for the new canonical (no contradictory time-bucketing content exists today — verified by grep on `15.minute` / `time_bucket` / `date_bin` / `window_start`).
- Do NOT touch the new r07 Pattern C3a (FIX-A1) or r23 §3.1G top-N-with-ties (FIX-A2) — both landed cleanly this iter.

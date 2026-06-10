# Judge Feedback — iter926 (re-probe sweep: distinct-combination-count one-off confirm + 3 fresh adjacents)

**Overall: 5.00 STRONG PASS** (Q1 5.00 / Q2 5.00 / Q3 5.00 / Q4 5.00 = 20.00/4 = 5.00). OVERALL AVERAGE governs — no per-Q veto. Threshold 3.5 met by +1.50.

Trino 467 PINNED. All dialect claims verified vs trino.io/docs/467 (functions/aggregate.html, language/types.html, functions/comparison.html) + git-tag 467 source signals (PR #4647 comparable/orderable type operators; issue #20227 decimal/bigint SUM overflow) + WebSearch/WebFetch 2026-06-10 — NOT against resources/. Multi-source, iter882 verify-first applied BOTH directions.

---

## ★ Q1 VERDICT — iter925 MULTI-ARG COUNT(DISTINCT) SLIP: ONE-OFF CONFIRMED / CLOSED

**The responder CORRECTLY ROW-WRAPPED. The multi-arg slip did NOT recur. iter925 slip = ONE-OFF CONFIRMED, CLOSED. NO findability-anchor FIX-A needed.**

- iter926-Q1 answer: `COUNT(DISTINCT (user_id, CAST(event_time AS date)))`.
- The `(user_id, CAST(event_time AS date))` is an **anonymous ROW literal** (parenthesized 2-field tuple), making this a **SINGLE-argument** `COUNT(DISTINCT <row>)` — VALID in Trino 467.
- Contrast with the iter925 defect, which was the unsupported **multi-arg** form `COUNT(DISTINCT user_id, date)` (two comma-separated args = signature/parse error: `count()` has exactly `count(*)` and `count(x)`, no `count(x, y)`). That form did NOT reappear here.
- Why the ROW-wrap is valid: DISTINCT requires a **comparable** type. A ROW is comparable/orderable when all its fields are comparable/orderable (Trino's comparable/orderable type-operator machinery, PR #4647). Fields here are `bigint` (user_id) and `date` (CAST(event_time AS date)) — both comparable — so the ROW is comparable and DISTINCT over it works. It correctly counts distinct **(user, day) pairs** (CAST-to-date collapses each user's multiple same-day events to one).
- Q1 = 5.00 (clean). Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0.

---

## Q2 — same-day fulfillment count (VERIFIED CORRECT)

`SELECT COUNT(*) FROM ... WHERE CAST(order_date AS date) = CAST(ship_date AS date)`.
- Casting BOTH timestamps to `date` for same-CALENDAR-DAY comparison is correct. VERIFIED CAST(ts AS date) date-equality (standing pin).
- The responder's gotcha is RIGHT: raw `order_date = ship_date` (timestamp equality) requires the **same instant** (down to fractional seconds), which almost never matches for placed-vs-shipped; date-casting both sides is the same-day fix.
- `CAST(col AS date)` UNWRAPS for partition pruning per the pinned Unwrap-temporal fact (UnwrapCastInComparison) — bare-column range pruning preserved.
- Q2 = 5.00. Acc/Comp/Clar/Act 5.0.

---

## ★ Q3 — total storage bytes per tenant: BIGINT-SUM-OVERFLOW + NO-BYTE-FORMATTER, BOTH CONFIRMED CORRECT

`SELECT tenant_id, SUM(file_size_bytes) FROM files GROUP BY tenant_id`.

**(a) BIGINT SUM overflow RAISES, does NOT silently wrap — responder's "no surprises at typical scale" is ACCURATE.** VERIFIED: Trino bigint/integer arithmetic and SUM RAISE on overflow past 2^63 (`NUMERIC_VALUE_OUT_OF_RANGE`, cf. issue #20227 which is about the error being surfaced as internal vs user error — detection itself is correct, NO silent Java-style wraparound). At terabyte scale (~1e12, far below the 9.2e18 BIGINT ceiling) there is genuinely no overflow, so "Trino handles it without overflow surprises at typical scales (terabytes)" is correct. At exabyte scale it would RAISE (not silently corrupt) — the responder did NOT claim otherwise, so this is fine. Optional completeness nuance (NOT a defect): for extreme/aggregate scale one could `CAST(file_size_bytes AS DECIMAL(38,0))` before SUM to lift the ceiling.

**(b) "No built-in human-readable byte formatter" — CONFIRMED CORRECT.** Matches the pinned fact: `format_data_size` is an EXAMPLE SQL UDF, NOT a built-in; only `format_number` ('1M'-style) exists as a built-in. "No built-in, format in the app or with a CASE/UDF" is the correct answer.

- Q3 = 5.00. Acc/Comp/Clar/Act 5.0. Both claims source-verified.

---

## Q4 — distinct IPs per account last 30 days (VERIFIED CORRECT)

`SELECT account_id, COUNT(DISTINCT ip_address) FROM ... WHERE requested_at >= current_date - INTERVAL '30' DAY GROUP BY account_id` + `approx_distinct(ip_address)` alternative (~2.3% std error).
- COUNT(DISTINCT ip_address) per account = correct exact one-pass distinct count, one row per account.
- `approx_distinct ~2.3% standard error` = DOC-CORRECT, VERIFIED verbatim aggregate.html ("standard error of 2.3%, the standard deviation of the approximately normal error distribution"); figure is for approx_distinct SPECIFICALLY (per standing pin — NOT an approx_percentile figure). Appropriate at-scale HLL guidance.
- `current_date - INTERVAL '30' DAY` is a query-constant on the bare column → UNWRAPS / prunes partitions correctly (sargable).
- Q4 = 5.00. Acc/Comp/Clar/Act 5.0.

---

## SCORES

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 distinct (user, day) COUNT(DISTINCT ROW) | 5.0 | 5.0 | 5.0 | 5.0 | 5.00 |
| Q2 same-day fulfillment CAST-to-date equality | 5.0 | 5.0 | 5.0 | 5.0 | 5.00 |
| Q3 bytes/tenant SUM(BIGINT)+no-byte-formatter | 5.0 | 5.0 | 5.0 | 5.0 | 5.00 |
| Q4 distinct IPs/account 30d + approx_distinct | 5.0 | 5.0 | 5.0 | 5.0 | 5.00 |

**Overall = 20.00 / 4 = 5.00 STRONG PASS.**

---

## VERDICT — iter927 DIRECTIVE = DEFAULT NO-OP

- **(1) Q1 multi-arg COUNT(DISTINCT) slip = ONE-OFF CONFIRMED, CLOSED.** Responder correctly ROW-wrapped `COUNT(DISTINCT (user_id, CAST(event_time AS date)))` (single-arg over an anonymous comparable ROW = valid, counts distinct (user,day) pairs); the iter925 unsupported multi-arg form did NOT recur. NO findability-anchor FIX-A. Do NOT add a "wrong" card for this family (defang-backfire + duplicates pins).
- **(2) Q3 BIGINT-SUM-overflow-RAISES (not silent wrap) + no-built-in-byte-formatter — BOTH CONFIRMED CORRECT** (source-verified; matches pinned SUM-overflow-raises and format_data_size-is-a-UDF facts).
- All 4 dialect-clean. NO source-verified findable-but-missing gap, NO dialect defect surfaced. **NO-OP — teacher ZERO edits.**
- Do NOT mark any of Q1 COUNT(DISTINCT ROW), Q2 CAST-to-date same-day equality, Q3 SUM(BIGINT)+no-byte-formatter, or Q4 COUNT(DISTINCT)+approx_distinct-2.3% wrong (all correct).
- Optional re-probe (NO pin touch, low priority, SKIP if duplicative): exabyte-scale bytes phrasing to confirm responder reaches for CAST-to-DECIMAL(38,0) before SUM; or a distinct-3-column-combination ask to keep the ROW-wrap durable.
- Federation (4.49944/310) remains the only un-passed row — bulletproofed angles only. PIN decimal/bigint SUM-overflow-raises, ROW-comparable→COUNT(DISTINCT ROW)-valid (vs multi-arg parse error), no-built-in-byte-formatter, approx_distinct-2.3%, CAST(ts AS date)-equality+unwrap facts.
- Do NOT touch any iter534-925 pin. PIN 467. NO federation edits. DO NOT bump training/state.json (already passed; overall 5.00 STRONG PASS holds).

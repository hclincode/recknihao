# Judge Feedback — iter892 (EXTENDED PHASE)

**Overall: 5.00 / 5.00 — STRONG PASS** (per-Q 5.00 / 5.00 / 5.00 / 5.00 = 20.00 / 4 = 5.00; margin +1.50 over the 3.5 threshold; the OVERALL AVERAGE governs — no per-question override).

**Federation NOT probed this iter** — the Trino-federation row (4.49944 / 310, FAIL) is UNCHANGED.

**iter892 was a NO-OP durability sweep.** All 4 answers dialect-clean. → **iter893 = DEFAULT NO-OP** (teacher: ZERO edits).

---

## BULLETPROOF VERDICT (Q1)

**Q1 is BULLETPROOFED — 2nd clean json_exists datapoint, NOT regressed.**

The bulletproof criterion required Q1 to LEAD with a key-EXISTENCE test to find genuinely-absent keys, NOT with `json_extract_scalar(...) IS NULL` (which conflates absent + present-but-null). The responder did exactly that:

- LED with `json_exists(config, 'strict $.retry_policy')` — true when the key is present (even when its value is null), false when the key is absent.
- Isolated genuinely-absent rows with `WHERE NOT json_exists(config, 'strict $.retry_policy')`.
- Explicitly explained that `json_extract_scalar(config,'$.retry_policy') IS NULL` matches BOTH absent AND present-null and therefore cannot distinguish them.

This follows the iter891 FIX-A that landed the json_exists card. Combined with the iter891 Q1 clean datapoint (settings / `$.notifications` phrasing), this is the **2nd consecutive clean datapoint** on a 2nd phrasing. The iter890 conflation defect did NOT recur. The card is now confirmed across two phrasings — treat it as locked; do NOT churn it.

---

## Per-question verification (all VERIFIED vs trino.io/docs/467)

**Q1 — 5.00.** json.html confirms `JSON_EXISTS(json_input [FORMAT JSON ...], json_path [PASSING ...] [{TRUE|FALSE|UNKNOWN|ERROR} ON ERROR])`; "The returned value is true if the path returns a non-empty sequence, and false if the path returns an empty sequence"; "The default value returned ON ERROR is FALSE." In strict mode an absent member is a structural error → ON ERROR default = false; a member present with a JSON null value resolves to a non-empty sequence → true. Therefore `NOT json_exists(...)` isolates absent-only keys, and `json_extract_scalar IS NULL` wrongly also matches present-but-null. Responder's answer is exactly correct.

**Q2 — 5.00.** window.html: `dense_rank()` is "similar to rank(), except that tie values do not produce gaps in the sequence" → 1,1,2,3; `rank()` "tie values...produce gaps" → 1,1,3,4; `row_number()` "unique, sequential number." All three exist in 467. `DENSE_RANK() OVER (PARTITION BY team_id ORDER BY calls_completed DESC)` is the correct no-gap tie-rank choice, and the RANK / DENSE_RANK / ROW_NUMBER contrast is accurate.

**Q3 — 5.00.** window.html: `lag(x[, offset[, default_value]])` "Returns the value at offset rows before the current row...default offset is 1" → `LAG(revenue,1) OVER (ORDER BY report_date)` valid, first row NULL (no prior). conditional.html: `NULLIF(value1, value2)` "Returns null if value1 equals value2, otherwise value1" — a correct divide-by-zero guard. `ROUND(100.0*(revenue - LAG(...))/NULLIF(LAG(...),0), 2)` is correct; the `100.0` forces non-integer division.

**Q4 — 5.00.** `BETWEEN` tests ONE expression against a low/high bound (`expr BETWEEN min AND max`); a two-column two-bound comparison (`contract_start >= ... AND contract_end <= ...`) is genuinely not expressible with BETWEEN. The responder correctly declined a "magic function" and used explicit AND with `DATE '...'` literals — idiomatic and correct Trino 467. NULLIF / conditional semantics confirmed on conditional.html; BETWEEN single-expression semantics are standard SQL/Trino.

---

## Directive for teacher (iter893)

- **DEFAULT NO-OP.** All 4 dialect-clean; json_exists card BULLETPROOFED across 2 phrasings. NO defect, NO FIX-A, NO escalation. ZERO edits.
- Did NOT flag any correct claim as a defect (iter882 lesson — verified vs authoritative source first).
- json_exists key-existence card is now locked (2 clean datapoints, 2 phrasings) — do NOT churn it.
- Re-probe 4 fresh adjacents (untested territory) next sweep.
- Do NOT add any "wrong" card for Q1–Q4. Do NOT touch any iter534–891 pin.
- PIN Trino 467. NO federation edits. DO NOT bump training/state.json (already passed).

# Judge Feedback — iter1011

**Phase**: extended (passed=true). OVERALL AVERAGE governs — NO per-question veto.
**Verification**: BOTH directions vs trino.io/docs/467 + RAW git-tag 467 source (functions/datetime.md, functions/string.md) + WebSearch — NOT resources/.
**Prod stack** (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark + dbt): all 4 questions fit; no federation/auth angle.

---

## Dialect verifications (with citations)

### Q3 (PRIORITY) — from_unixtime 1-arg return type — RESOLVED: responder CORRECT

The directive *suspected* the 1-arg `from_unixtime(unixtime)` returns `timestamp(3)` WITHOUT time zone. **The source REFUTES that prior — the responder is RIGHT.**

- RAW git-tag 467 source `docs/src/main/sphinx/functions/datetime.md`:
  - `from_unixtime(unixtime) -> timestamp(3) with time zone`
  - `from_unixtime(unixtime, zone) -> timestamp(3) with time zone`
  - `from_unixtime(unixtime, hours, minutes) -> timestamp(3) with time zone`
  - `from_unixtime_nanos(unixtime) -> timestamp(9) with time zone`
- Rendered trino.io/docs/467/functions/datetime.html + WebSearch agree.

**Verdict**: ALL `from_unixtime` overloads (including the 1-arg form) return `timestamp(3) WITH TIME ZONE`. The responder's "returns timestamp(3) WITH TIME ZONE" is **CORRECT, not an imprecision.** `from_unixtime_nanos` exists (returns `timestamp(9) with time zone`) — responder correct. This is another **imported-prior self-error in the directive** (assuming a foreign-looking return-type split that does not exist); verify-first prevented a false penalty + a false memory card. Do NOT add a "without tz" correction anywhere.

### Q4 — leading-wildcard pushdown + split_part — CONFIRMED CORRECT
- `LIKE '%@company.com'` is valid Trino; a LEADING-wildcard pattern cannot be turned into a range/prefix and cannot prune partition metadata → full scan. Reasonable and correct.
- `split_part(string, delimiter, index)` — RAW 467 functions/string.md: 1-based ("Field indexes start with 1"), returns NULL if index out of range. `split_part(email,'@',2)='company.com'` valid Trino. Correct.
- Minor nit (not a defect): suffix-equality via split_part matches only the exact domain `company.com`, not subdomains like `eu.company.com`; for the stated "ending in @company.com" intent this is fine.

### Q1 — JOIN fan-out — CONFIRMED CORRECT
Duplicate keys on the right side → many-to-many fan-out, row multiplication, NO error: correct. Diagnostic `COUNT(*)` vs `COUNT(DISTINCT subscription_id)` on the right table is the standard cardinality check (matches r23 L933 lock). Fix via GROUP BY + aggregate is correct.

### Q2 — COUNT(*) vs COUNT(col) — CONFIRMED CORRECT
`COUNT(*)` counts all rows incl NULLs; `COUNT(col)` counts non-NULL only; gap = NULL rows; SUM/AVG also ignore NULL (aggregate.md: aggregates ignore NULL except count/count_if/max_by/min_by/approx_distinct). Correct. Guidance on which to use is apt.

---

## Per-question scores

| Q | Accuracy | Completeness | Clarity | Actionability |
|---|---|---|---|---|
| Q1 JOIN fan-out | 5 | 4.75 | 4.75 | 4.75 |
| Q2 COUNT(*) vs COUNT(col) | 5 | 4.75 | 4.75 | 4.75 |
| Q3 from_unixtime | 5 | 4.75 | 4.75 | 4.75 |
| Q4 LIKE leading-wildcard | 4.75 | 4.5 | 4.75 | 4.5 |

**Sub-score total**: 76.0 / 16 = **4.75**

## Verdict: PASS (4.75 ≥ 3.5; margin +1.25)

`::` cast ABSENT all 4. TICS all clean: no QUALIFY / false-semi-join / MAX-varchar / GREATEST-LEAST-NULL / fabricated-fn (from_unixtime, from_unixtime_nanos, split_part ALL real & verified) / regex-backslash / INTERVAL-quarter-week / OFFSET-LIMIT-order / broken-secondary (Q3 ms/ns caveats correct, Q4 split_part alternative correct). No findable gap, no resource defect, no 2-in-2 recurrence.

## Recommendation: DEFAULT NO-OP
All 4 answers correct & verified both directions; Q3 KEY from_unixtime return-type resolved in the responder's favor (directive prior was wrong). NO resource edit; NO FIX-A.

Re-probe next sweep: (a) another unix-epoch→timestamp Q — confirm from_unixtime WITH-tz + ms/ns variants, and watch whether the user wants tz-stripped (`AT TIME ZONE` / CAST to timestamp WITHOUT tz); (b) another LIKE/pattern Q — leading-wildcard-no-prune + split_part suffix caveat (subdomain edge); (c) another JOIN-cardinality/fan-out Q — COUNT vs COUNT(DISTINCT key) diagnostic; (d) another COUNT(*)/COUNT(col)/NULL-aggregate Q. Federation r22 §13.x hard-locked NOT probed (stays 4.49944/310). MUST NOT bump state.json (already 1011; orchestrator commits).

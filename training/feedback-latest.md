# Judge Feedback — iter858 (EXTENDED PHASE)

**Overall: 4.28 PASS** (per-Q 5.00 / 2.25 / 5.00 / 4.875 = 17.125/4; margin +0.78 above 3.5 floor; overall average governs, NO per-Q veto.)
**Headline: at_timezone column-zone fix HELD on 2nd datapoint → BULLETPROOFED. BUT Q2 is a REAL ACCURACY DEFECT — responder recommended the GEOMETRIC mean for a HARMONIC-mean (rate-averaging) problem. iter859 = FIX-A.**

Federation (r22 §13.x) NOT probed this iteration — row unchanged (4.49944/310).

---

## Q1 — Group by each user's LOCAL calendar date with a per-row timezone COLUMN — 5.00 (Acc5/Comp5/Clar5/Act5)

**FIX HELD — 2nd clean datapoint — BULLETPROOFED.**

Responder gave, for a plain UTC `TIMESTAMP`:
`date_trunc('day', at_timezone(with_timezone(created_at,'UTC'), user_timezone))` and GROUP BY the same; for an already-tz-aware column `at_timezone(created_at, user_timezone)`; explicitly stated the zone arg accepts a per-row varchar COLUMN (not literal-only, no CASE needed); warned that `CAST(created_at AS TIMESTAMP WITH TIME ZONE)` attaches the session zone.

VERIFIED vs trino.io/docs/467/functions/datetime.html (multi-source w/ list.html prior, iter857):
- `at_timezone(timestamp(p) with time zone, zone) -> timestamp(p) with time zone` — the `zone` parameter carries **NO** "(constant)"/literal-only annotation. Trino annotates constant-required args explicitly; absence => a column/expression is accepted and evaluated **per row**. CORRECT.
- `with_timezone(timestamp(p), zone) -> timestamp(p) with time zone` — tags a plain timestamp as being in `zone`; `with_timezone(created_at,'UTC')` correctly stamps the UTC source. CORRECT.
- `date_trunc('day', x)` truncates to the day boundary; applied to the converted local timestamp it yields the user's local calendar day. CORRECT.
- **NO regression** to the iter856 CASE-per-timezone hack. The §Fact 3b card (r07) added iter857 worked.

**VERDICT: at_timezone dynamic column-zone = BULLETPROOFED (iter857 + iter858, two distinct phrasings).** Do NOT churn the §Fact 3b card (iter693 lesson).

---

## Q2 — Average of per-node throughput_per_second rates ("a different kind of mean") — 2.25 (Acc1/Comp2/Clar4/Act2)

**CONFIRMED ACCURACY DEFECT — WRONG KIND OF MEAN.**

Responder said: "Your coworker is right — a plain AVG() is wrong for rates. You need the GEOMETRIC mean instead," claimed "throughput is multiplicative," and recommended `geometric_mean(throughput_per_second)` + the `EXP(AVG(LN(x)))` fallback.

This is **mathematically wrong**. For averaging RATES/ratios that share a common numerator (throughput = work / time; you want total-work / total-time), the correct summary is the **HARMONIC mean** = `n / SUM(1/rate)` = `1 / AVG(1/rate)`. The harmonic mean is the rate that, applied uniformly, reproduces the aggregate throughput. The GEOMETRIC mean is for **multiplicative / compounding** data (growth factors, investment returns, normalized benchmark ratios) — it is NOT the right "average" for a set of throughput rates. The justification "throughput is multiplicative" is false: a set of independent per-node rates you want to summarize is **not** a compounding chain.

Note: the iter857 baseline answer to this exact harmonic-mean question was correct — it declined a built-in and gave `1/AVG(1/rate)`. This iteration **regressed** to the wrong family.

VERIFIED vs trino.io/docs/467/functions/aggregate.html (multi-source w/ list.html):
- `avg(x) -> double` and `geometric_mean(x) -> double` are the ONLY mean-type aggregates. `geometric_mean` IS a real built-in (description: "Returns the geometric mean of all input values").
- There is **NO `harmonic_mean`** built-in in Trino 467. The harmonic mean must be expressed as `1.0 / AVG(1.0/throughput_per_second)` (or `count(*) / SUM(1.0/throughput_per_second)`), with a `NULLIF`/guard against zero rates.

Sub-score rationale: Acc 1 (recommended the wrong statistical method with a false justification — a confidently-wrong steer is worse than declining). Comp 2 (named a real function and a fallback, but for the wrong problem; missed the actual harmonic form). Clar 4 (well-written, accessible — which makes the wrong answer more dangerous). Act 2 (engineer would ship a subtly-wrong metric).

**DIAGNOSIS: resource cross-contamination / findability, NOT a pure synthesis slip.** The iter855 `geometric_mean` card (§3.1B-GM in r23) is keyword-magnetic on "different kind of mean" / "rates / average" and has no guardrail steering rate-averaging questions AWAY from it toward the harmonic form. The phrase "a different kind of mean" + "rates" pulled the responder straight to the recently-added geometric_mean card. There is currently no harmonic-mean card anchored on the rate-averaging keywords, so nothing competed for the landing.

---

## Q3 — Count weekdays Mon–Fri between two dates (no calendar table) — 5.00 (Acc5/Comp5/Clar5/Act5)

Responder gave `SELECT COUNT(*) FROM UNNEST(sequence(start_date, end_date, INTERVAL '1' DAY)) AS t(d) WHERE day_of_week(d) BETWEEN 1 AND 5`, plus a correlated-subquery worked example and a calendar-CTE variant.

VERIFIED vs trino.io/docs/467/functions/array.html + datetime.html:
- `sequence(start, stop, INTERVAL '1' DAY)` generates the date array **inclusive of both endpoints** (Trino sequence is inclusive; e.g. sequence(1,5)→[1,2,3,4,5]; confirmed via trino.io search for date sequences including both start and stop).
- `day_of_week(x) -> bigint` returns the **ISO** day, **1 = Monday … 7 = Sunday** (verbatim). `BETWEEN 1 AND 5` = Mon–Fri, excludes Sat(6)/Sun(7). CORRECT.
- `UNNEST(array) AS t(d)` expands to one row per date. CORRECT.

Fully correct and findable. (Fresh-clean datapoint, consistent with iter745/iter723 sequence+UNNEST history.)

---

## Q4 — Stable checksum/fingerprint of a JSON/config column for change-detection — 4.875 (Acc5/Comp4.5/Clar5/Act5)

Responder gave `md5(to_utf8(CAST(config_json AS varchar))) AS config_hash`, compare with `IS DISTINCT FROM`; noted hash functions take varbinary so `to_utf8()` is needed; offered `sha256` as a stronger option.

VERIFIED vs trino.io/docs/467/functions/binary.html + conversion.html:
- `md5(binary) -> varbinary` and `sha256(binary) -> varbinary` both require **varbinary** input and return **varbinary**. `to_utf8(varchar) -> varbinary` performs the needed conversion. CORRECT.
- Comparing the resulting `varbinary` values directly works; `IS DISTINCT FROM` is the null-safe comparison (a NULL config on one run won't silently mis-evaluate). CORRECT.

Completeness note (minor, −0.5 Comp only): the engineer asked for a "fingerprint/checksum," which often connotes a short integer.
**Verified caveat to the directive's premise:** in Trino 467, `xxhash64(binary) -> varbinary` returns **varbinary, NOT bigint** (the bigint→varbinary change landed in Presto release 0.163; Trino 467 returns varbinary). So xxhash64 is NOT a clearly-better "short integer fingerprint" here — it produces a varbinary just like md5, and md5 is a fully valid answer. The only genuinely additive notes that were missed: deterministic ordering for nested JSON (two semantically-equal JSON docs with reordered keys hash differently — flag canonicalization), and `to_hex(md5(...))` if a printable/storable digest is wanted. None of these are defects. Answer is sound and shippable.

---

## iter859 RECOMMENDATION — FIX-A (Q2 harmonic-vs-geometric mean)

**This is a real defect (Acc 1), not a NO-OP.** Do a LIGHT FIX-A:

**STEP A (verify — already done here):** Trino 467 has NO `harmonic_mean` built-in; `geometric_mean(x) -> double` exists but is for multiplicative/growth data. The correct rate-average is the harmonic mean `1.0 / AVG(1.0/rate)` = `count(*) / SUM(1.0/rate)`. Confirm once more vs aggregate.html before editing.

**STEP B (primary):** Add a `harmonic mean / averaging rates` card to r23 (place it ADJACENT to the iter855 §3.1B-GM geometric_mean card and the §3.1B-WA weighted-average card, so the three "which mean?" cards co-locate). Lead with a FENCED **WHICH-MEAN ROUTER**:
- averaging RATES / ratios with a common numerator (throughput, speed, price/earnings, requests-per-sec across nodes) → **HARMONIC** mean `1.0 / AVG(1.0/rate)` (guard zero rates with `NULLIF(rate,0)` or filter) — Trino has **NO** `harmonic_mean` built-in.
- averaging multiplicative / compounding factors (growth rates, returns, normalized benchmark ratios) → **GEOMETRIC** mean `geometric_mean(x)` / `EXP(AVG(LN(x)))`.
- everything else (additive quantities) → arithmetic `AVG(x)`.

Keyword-anchor the harmonic card on: *average of rates, averaging throughput, average requests per second across nodes, different kind of mean for rates, harmonic mean Trino, rate average not arithmetic mean, 1/avg(1/x)*.

**STEP C (defang the contamination):** On the geometric_mean card (§3.1B-GM), add a FENCED inline-DEFANG on its own un-copyable line: `geometric_mean is for averaging RATES like throughput -- WRONG (use the harmonic mean 1/AVG(1/rate))`. This is the actual root cause — the geometric_mean card is over-attracting rate-averaging questions via the "different kind of mean" keyword with no competing harmonic anchor. Add a cross-ref from §3.1B-GM → the new harmonic card.

Respect the pipe-escape trap (all pipe/router content FENCED, not in table cells), inline-DEFANG the WRONG form un-copyably, make the harmonic canonical the copy-attractive block. Do NOT churn the iter855 geometric_mean canonical SQL, §3.1B-WA weighted-avg, the iter857 §Fact 3b at_timezone card, or any iter534-857 lock. PIN Trino 467. NO federation edits.

**DO NOT bump training/state.json.** (Already iter858; state stays as-is.)

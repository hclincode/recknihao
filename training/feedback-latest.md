# Judge Feedback — iter871 (EXTENDED PHASE)

**Overall: 4.84 STRONG PASS** (per-Q 5.00 / 5.00 / 5.00 / 4.375 = 19.375 / 4 = 4.84375; margin +1.34; overall avg governs, no per-Q veto)

Federation NOT probed this iteration — the 4.49944/310 row is UNCHANGED.

All dialect facts independently verified against **trino.io/docs/467** (functions/datetime.html, aggregate.html, array.html, window.html) + **trino git tag 467 source** (PlanOptimizers.java, TypeCoercion.java, DateOperators.java) on 2026-06-10. Resources/ were NOT used as the source of truth.

---

## Q1 — function-on-date-column always forces full scan? (iter871 CORRECTIVE RE-PROBE) — 5.00

Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5

**THE iter870 OVER-CLAIM IS NOW CORRECTED.** The responder did NOT repeat the blanket "function-on-column = full scan" myth. It correctly stated the coworker is wrong for Trino+Iceberg, that the temporal forms DO prune, and re-aimed the warning at genuinely non-invertible opaque expressions.

VERIFIED:
- `PlanOptimizers.java` @ tag 467 registers **UnwrapCastInComparison + UnwrapDateTruncInComparison + UnwrapYearInComparison** together in the `simplifyOptimizerRules` ImmutableSet **UNCONDITIONALLY** (no feature flag, no session property). Default-on confirmed.
- `CAST(col AS date)=lit`, `year(col)=lit`, `EXTRACT(YEAR FROM col)=lit` all unwrap into bare-column ranges and prune. (EXTRACT(YEAR) maps to `year()` and shares the unwrap path.) date_trunc supported units include day/week/month/year (datetime.html).
- LOWER / SUBSTR / date arithmetic are genuinely non-invertible and do NOT unwrap — responder's footgun list is accurate.
- The explicit bare-column half-open range (`col >= ... AND col < ...`) is the guaranteed/portable/cross-version form — accurate.
- EXPLAIN `constraint on [...]` hint — accurate (carried over from iter870 verification).

No ding. Clean corrective landing.

## Q2 — find gaps in a sequential integer user_id — 5.00

Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5

VERIFIED (array.html): `sequence(start, stop)` "Generate a sequence of integers from start to stop, incrementing by 1..." — inclusive range. **No `generate_series` in Trino 467** (absent from array.html and aggregate.html) — responder correctly flags sequence+UNNEST as the equivalent. The `sequence(1, MAX(user_id))` → UNNEST → LEFT JOIN … WHERE found IS NULL anti-join is the correct, idiomatic gap-finder. Gap-range grouping variant is a valid bonus. No ding.

## Q3 — per-row value plus tier average in same row — 5.00

Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5

VERIFIED (window.html): "All aggregate functions can be used as window functions by adding the OVER clause." `AVG(api_calls_used) OVER (PARTITION BY account_tier)` returns the tier average on every row; `AVG() OVER ()` for the global average. Correct contrast with GROUP BY (window keeps all rows). No ding.

## Q4 — weekday NAME from a date column — 4.375  (ONE ACCURACY DEFECT)

Sub-scores: **Accuracy 3.5** / Completeness 4.5 / Clarity 5 / Actionability 4.5

CORRECT parts (all verified):
- `format_datetime(ts, 'EEEE')` Joda pattern → full weekday name; `'EEE'` → abbreviated. Confirmed (datetime.html, JodaTime DateTimeFormat).
- **NO `dayname()` in Trino 467** — confirmed (datetime.html day-extraction set is day/day_of_month/day_of_week/day_of_year/dow/doy; no dayname). Correct.
- `day_of_week()` / `dow()` returns **ISO 1 (Monday) .. 7 (Sunday)**, no 0 — confirmed verbatim. GROUP BY `day_of_week()` for calendar order — correct.

**DEFECT — the "format_datetime REQUIRES a timestamp; passing a DATE throws a type error; CAST is needed" claim is FALSE for Trino 467.**
- Verified `TypeCoercion.java` @ tag 467 `coerceTypeBase`: `case StandardTypes.DATE -> switch (resultTypeBase) { case StandardTypes.TIMESTAMP -> Optional.of(createTimestampType(0)); ... }` — **DATE implicitly coerces to TIMESTAMP(0)**.
- Therefore `format_datetime(order_date, 'EEEE')` with a DATE column **works without any explicit CAST** — the DATE is silently promoted to TIMESTAMP(0). It does NOT throw a type error.
- The signature is documented as `format_datetime(timestamp, format)`, which likely led the responder to assert a DATE "errors." But Trino's implicit DATE→TIMESTAMP coercion makes the bare DATE call legal.

Impact: the responder's `CAST(order_date AS timestamp)` is **harmless and produces correct results**, so the answer's outcome is right. But the stated *reason* ("a DATE errors / type error / CAST required") is a false dialect assertion that misinforms the engineer about Trino's type system. Accuracy dinged to 3.5; the CAST being optional-not-required also costs a half-point on completeness/actionability. This is a real, citable inaccuracy, not a style nit.

---

## iter872 RECOMMENDATION — LIGHT FIX-A (Q4 precision only)

The Q1 corrective fix LANDED cleanly — do NOT re-touch r07 §1 unwrap content (it is now correct and verified). HOLD all iter534–871 locks.

FIX-A target (Q4): find the `format_datetime`/weekday-name landing card and **correct the "format_datetime requires a timestamp, a DATE errors" framing**:
- State that Trino 467 **implicitly coerces DATE → TIMESTAMP(0)**, so `format_datetime(date_col, 'EEEE')` works directly — the CAST is **optional (defensive/explicit), NOT required**, and an un-CAST DATE does **NOT** throw.
- Cite: TypeCoercion.java coerceTypeBase DATE→TIMESTAMP(0) @ tag 467; signature `format_datetime(timestamp, format)` on datetime.html.
- Inline-DEFANG the "a DATE errors / type error / CAST required" misconception on its own un-copyable fenced line.
- Keep the verified-correct parts intact: `'EEEE'`=full / `'EEE'`=abbreviated, no `dayname()`, `day_of_week()` ISO 1-7 Mon-Sun, GROUP BY day_of_week() for calendar order.
- Reconcile (do not just append): grep resources/ for any other "format_datetime needs/requires a timestamp, date errors" assertions and neutralize them so the responder can't re-land the wrong reason. NOTE: the iter831 r23 month-name card states "format_datetime REQUIRES timestamp -> DATE arg MUST be CAST" — that is the SAME inaccuracy and should be softened to "DATE is implicitly coerced; CAST is optional/explicit, not required to avoid an error." (iter831 framed it as a hard requirement; that propagated here.)
- All pipe-bearing content FENCED (pipe-escape trap). PIN Trino 467. NO federation edits. DO NOT bump training/state.json (already 871/passed).

Explicit confirmations requested:
1. **iter870 partition-pruning over-claim: CORRECTED.** Responder no longer repeats the blanket myth; unwrap rules confirmed default-on via git-tag 467 source.
2. **Q4 "format_datetime needs a timestamp not a date" claim: NOT accurate per Trino 467.** DATE implicitly coerces to TIMESTAMP(0); the un-CAST DATE call works and does not error. The CAST is optional, not required.

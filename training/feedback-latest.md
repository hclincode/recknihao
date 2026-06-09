# Judge Feedback — iter837 (EXTENDED PHASE)

**LIGHT FIX-A re-probe of the iter836 string->DATE family-mix defect.** All four answers verified against trino.io/docs/467 (datetime.html, conversion.html, math.html, sql/select.html) + WebSearch 2026-06-09. PIN Trino 467. **OVERALL: 4.66 PASS.**

---

## Per-question scores

### Q1 — non-ISO text '15/03/2024' (day/month/year) -> DATE — **5/5/5/5 = 5.00 STRONG PASS**
Responder: `CAST(date_parse(date_text, '%d/%m/%Y') AS DATE)`.
- **Accuracy 5**: VERIFIED trino.io/docs/467/functions/datetime.html — `date_parse(string, format)` uses MySQL %-specifiers (`%d`=day, `%m`=month, `%Y`=4-digit year) and returns `timestamp(3)`; wrapping in `CAST(... AS DATE)` to land a DATE is correct. The matched-function+pattern-pair rule is exactly right. The responder used a MATCHED pair (date_parse + MySQL %-specifiers) and explicitly warned against mixing with `parse_datetime`/Joda letters ('MM/dd/yyyy').
- **Clarity 5 / Applicability 5 / Completeness 5**: explains the specifier family, gives the worked '15/03/2024' -> 2024-03-15 trace, and the chronological-sort payoff.
- **VERDICT: the iter836 date_parse-family fix LANDED CLEAN.** iter836 Q4 used `date_parse(s,'MM/dd/yyyy')` (Joda pattern fed to a MySQL-specifier function = crossed-family bug, mislabeled date_parse as "Joda"). This iter the responder correctly pairs date_parse with %-specifiers, wraps in CAST AS DATE, and defangs the cross. The iter836->iter837 string->DATE family-mix arc is CLOSED.

### Q2 — Monday that starts the current week — **5/4/5/5 = 4.75 PASS**
Responder: `date_add('day', -(EXTRACT(day_of_week FROM current_date) - 1), current_date)`.
- **Accuracy 5**: VERIFIED — `day_of_week` returns ISO 1=Monday..7=Sunday, so subtracting `(dow-1)` days lands on Monday (Wed=3 -> subtract 2 -> Monday). `date_add('day', <negative>, date)` subtracts. The manual EXTRACT form given is fully correct.
- **Completeness 4 (−1, minor precision ding)**: the responder mentioned `date_trunc('week', x)` but hedged "requires checking if your system's week starts on Monday vs Sunday." **This hedge is IMPRECISE for Trino 467: `date_trunc('week', x)` ALWAYS starts the week on Monday (ISO) — deterministic, not system-dependent** (docs example truncates 2001-08-22 -> 2001-08-20, a Monday). `date_trunc('week', current_date)` would in fact be the cleaner always-Monday one-liner answer. The manual form given is correct, so this is a completeness/precision ding, not an accuracy error — the responder slightly under-sold the better answer by hedging on it.
- **Clarity 5 / Applicability 5**.

### Q3 — CAST decimal price to integer: rounds or chops? — **5/5/5/5 = 5.00 STRONG PASS**
Responder: CAST to INTEGER ROUNDS half-up (2.99->3, 2.49->2, 2.50->3); to DROP cents use `truncate(price, 0)` (toward zero) or `floor(price)`.
- **Accuracy 5**: CONFIRMED — Trino 467 `CAST(DECIMAL/double AS INTEGER)` ROUNDS half-up away from zero, it does NOT truncate. `2.50->3` (half-up, not banker's). To drop the fraction without rounding, `truncate(x)` is toward zero and `floor(x)` is toward -inf. The responder nailed the exact 2.99/2.49/2.50 cases and gave the correct truncate/floor alternatives. (VERIFIER NOTE: a raw WebSearch summary wrongly claimed CAST truncates — it conflated the PostgreSQL connector's `decimal-rounding-mode` setting with engine CAST behavior. Trino-engine CAST rounds; this is a repeatedly-pinned repo-memory fact and matches Trino behavior. Do NOT let the unreliable search snippet flip this.)
- **Applicability 5**: the billing-context guidance ("for billing you likely want rounding; truncating 2.99->2 undercharges") is exactly the actionable distinction the engineer needed.
- **Clarity 5 / Completeness 5**.

### Q4 — random sample ~500 rows from a large events table — **5/4.5/5/5 = 4.875 STRONG PASS**
Responder: `... TABLESAMPLE BERNOULLI (5) WHERE event_date >= CURRENT_DATE - INTERVAL '7' DAY LIMIT 500`; BERNOULLI = per-row uniform (scans all blocks), SYSTEM = block-level (faster, clustered).
- **Accuracy 5**: VERIFIED trino.io/docs/467/sql/select.html — `TABLESAMPLE BERNOULLI (5)` is valid syntax (percentage 0-100); BERNOULLI selects each row independently with the sample probability (examines every block, skips individual rows); SYSTEM samples at logical-segment/split granularity (faster, connector-layout-dependent, may be clustered). The BERNOULLI-vs-SYSTEM characterization is exactly correct.
- **Completeness 4.5 (−0.5 minor)**: docs note "neither method allows deterministic bounds on the number of rows returned" — BERNOULLI(5) + LIMIT 500 gives "up to 500 of a ~5% sample," not guaranteed exactly 500. The responder's `LIMIT 500` caps it correctly and the partition filter is good production advice, but it could have flagged that exact-500 is not guaranteed (the simpler `ORDER BY random() LIMIT 500` gives exact-500 at full-sort cost — acceptable to omit per directive).
- **Clarity 5 / Applicability 5**: partition-filter-first is exactly right for the on-prem Iceberg+Trino stack.

---

## Overall

Per-Q averages: Q1 5.00 / Q2 4.75 / Q3 5.00 / Q4 4.875.
**Overall avg = (5.00 + 4.75 + 5.00 + 4.875) / 4 = 4.65625 ≈ 4.66.**
Dim cross-check: Acc (5+5+5+5)/4=5.00, Comp (5+4+5+4.5)/4=4.625, Clar (5+5+5+5)/4=5.00, Appl (5+5+5+5)/4=5.00 -> (5.00+4.625+5.00+5.00)/4=4.656. Agrees.

**GOVERNING LABEL = PASS (4.66 >= 3.5; no per-Q gate override per directive). No per-Q below threshold; no accuracy errors.**

- **Q1 date_parse-family fix LANDED CLEAN** — matched pair + CAST AS DATE + cross-family defang; iter836 crossed-family bug did NOT recur.
- **Q2 date_trunc('week')-always-Monday note**: the responder's "depends on system week start Sun/Mon" hedge is imprecise — Trino 467 `date_trunc('week')` is deterministically ISO Monday. Minor completeness ding only; the manual EXTRACT form given is correct.

## iter838 directive — DEFAULT NO-OP / durability sweep

No defect surfaced. All four answers accuracy-clean and PASS. iter838 = **DEFAULT NO-OP / durability sweep** — no resource edits required.

Optional, low-risk (NOT a required fix): at the r23 `date_trunc` / week-start neighborhood, add a one-line anchor stating `date_trunc('week', x)` in Trino 467 ALWAYS starts the week on Monday (ISO) — deterministic, NOT system-dependent — so the responder leads with the clean one-liner for "Monday that starts the week" instead of hedging. Pure additive clarification; does not touch a locked canonical.

## DO NOT (iter838)
- Touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter837 — federation row UNCHANGED).
- Re-edit the iter837 r23 string->DATE subsection / MySQL-vs-Joda disambiguator / matched-pair canonicals (just validated CLEAN).
- Churn the verified CAST-rounds-half-up + truncate/floor content, the day_of_week/date_add Monday canonical, the TABLESAMPLE BERNOULLI/SYSTEM card, the iter836 lpad/format pad+truncate content, iter831 format_datetime month-name cards, iter823 repeat-char card, iter825/827 bool NULL-semantics cards.
- Add `::`-casts (iter571 PIN), QUALIFY, RLIKE (iter623 ban), PERCENTILE_CONT/MEDIAN (iter611 ban), EXTRACT(EPOCH) (iter562 ban); fabricate dayname()/initcap; DISTINCT ON Postgres-leak (iter634 ban).
- Touch iter534-836 locks; bump training/state.json (already 837); git commit/push beyond appending the rubric score-history line.

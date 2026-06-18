# iter1043 Judge Feedback

Verified BOTH directions vs RAW git-tag 467 source (array.md / string.md / aggregate.md / datetime.md / sql/select.md) + WebSearch, NOT resources/. RAW git-tag source dispositive. Production stack (Trino 467 + Iceberg + Hive Metastore on-prem k8s/MinIO) consistent with all advice. NO federation probe (hard-locked). All 4 questions are pure SQL-pattern asks; no auth/OPA/JWT angle.

## Per-question scores

### Q1 — count per status as 3 side-by-side columns in ONE row — 4.8125
- Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75
- LEAD `COUNT(CASE WHEN status='pending' THEN 1 END) AS pending_count, ...` is CORRECT: `CASE WHEN ... THEN 1 END` returns NULL on non-match and `COUNT(expr)` counts only non-null rows, so each column counts only its status. Single GROUP-BY-less SELECT → one row, three columns. VERIFIED conditional/aggregate semantics.
- ALSO `COUNT(*) FILTER (WHERE status='pending') AS pending_count, ...` — the SQL-standard FILTER form. **FILTER on aggregates CONFIRMED present in 467** (RAW aggregate.md: `aggregate_function(...) FILTER (WHERE <condition>)`). Both forms yield one row / three columns. Clean, no broken secondary.

### Q2 (KEY — literal-underscore durability on the any_match surface) — 4.875
- Acc 5 / Comp 5 / Clar 4.75 / App 4.75
- LEAD `WHERE any_match(tags, tag -> starts_with(tag, 'promo_'))`. **`any_match(array(T), function(T,boolean)) -> boolean` CONFIRMED present** (RAW array.md, alongside all_match/none_match). **`starts_with(string, substring) -> boolean` CONFIRMED** (RAW string.md). The responder used `starts_with` for the literal `promo_` prefix — NOT `tag LIKE 'promo_%'` (which would treat `_` as a single-char wildcard and over-match). This is the literal-underscore-correct predicate.
- EXISTS+UNNEST alt `EXISTS (SELECT 1 FROM UNNEST(tags) AS t(tag) WHERE starts_with(tag,'promo_'))` — also valid (UNNEST-in-FROM and EXISTS both confirmed RAW select.md). Genuine simpler-vs-verbose contrast, not a broken secondary.
- **LITERAL-UNDERSCORE-PREFIX DURABILITY: CLEAN on the any_match surface.** The iter1028/1029/1036 LIKE-`_`-as-literal misconception did NOT recur here. After the §651/§653/§759 FIX-A confirmed clean on bare-column (iter1030), filter-lambda (iter1037), and all_match (iter1042) surfaces, this iter extends the clean streak to the **any_match** lambda surface. Continued durability positive — keep on passive monitor (o).

### Q3 (cents→dollars EXACT) — 4.75
- Acc 5 / Comp 4.75 / Clar 4.625 / App 4.75
- LEAD `CAST(price_cents AS decimal(18,2)) / 100 AS price_dollars` — this is the PRECISE answer the question demands ("accurately, not rounded or truncated"). DECIMAL / integer → DECIMAL division → exact `19.99`. Leading with the DECIMAL form correctly satisfies the accuracy requirement.
- Correctly flags `price_cents / 100` plain integer/integer = **integer division truncation** (1999/100 = 19) — accurate Trino behavior; one non-integer operand forces true division.
- ALSO offers `price_cents * 1.0 / 100`. **PRECISION NOTE:** `1.0` is a DOUBLE literal (467 default), so this path yields a DOUBLE `19.99` which is binary-floating-point APPROXIMATE — acceptable for display but NOT exact-money. The responder LED with the DECIMAL (exact) form, so the precise-answer requirement is met; the DOUBLE form is correctly positioned as a secondary. Minor clarity ding only: the `*1.0` alt could be more explicitly tagged as approximate vs the DECIMAL exact path, but the ordering already conveys the right preference. Consistent with iter1042 Q4 verification of the identical cents-to-dollars scenario.

### Q4 (avg subscription length, completed only, NULLs not zero) — 4.8125
- Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75
- `AVG(date_diff('day', started_at, ended_at)) AS avg_subscription_days FROM subscriptions WHERE ended_at IS NOT NULL`. **`date_diff(unit, ts1, ts2) -> bigint` CONFIRMED** (RAW datetime.md, returns `ts2 - ts1` in `unit`). `'day'` is a valid unit. **AVG ignores NULLs and returns NULL on empty input CONFIRMED** (RAW aggregate.md). The explicit `WHERE ended_at IS NOT NULL` pre-filter restricts to completed subscriptions; because date_diff would itself yield NULL for a NULL `ended_at` and AVG skips NULLs, the answer never treats active subs as zero. Explains "AVG skips NULL" correctly. Clean.

## Tics check
`::` absent all 4. No QUALIFY / false-semi-join / fabricated-fn / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / over-warning-folklore / broken-secondary. All functions used (any_match, starts_with, date_diff, AVG, COUNT-FILTER, CAST-to-DECIMAL) real and verified against RAW 467 source.

## Overall
Q1 4.8125 / Q2 4.875 / Q3 4.75 / Q4 4.8125 → **overall 4.8125 PASS** (margin +1.3125 over 3.5 threshold).

## Recommendation: DEFAULT NO-OP
No source-verified resource defect; no 2-consecutive-same-shape slip. All four clean, both KEY findings resolved in the responder's favor:
- **Q2 literal-underscore-prefix CLEAN on the any_match surface** (`starts_with` not `LIKE 'promo_%'`) — continued durability signal for watch (o), passive monitor.
- **Q3 DECIMAL-vs-DOUBLE precision** — responder correctly LED with `CAST(... AS decimal(18,2))/100` (exact) for the "accurate" requirement; `*1.0` DOUBLE form correctly relegated to secondary/approximate.

NO resource edit; NO FIX-A; NO commit/push. MUST NOT bump state.json (already 1043).

# Judge Feedback — iter833 (EXTENDED PHASE)

## Verdict: PASS — overall avg 4.65625 (margin +1.15625 above 3.5 floor)

DEFAULT NO-OP durability sweep + empty-string-vs-NULL COALESCE probe. Teacher made zero resource edits. All four answers clean; the Q1 PROBE LANDED CLEAN.

## Per-question scores

| Q | Topic | Acc | Comp | Clar | Act | Per-Q avg |
|---|---|---|---|---|---|---|
| Q1 | empty-string-skipping display name (NULLIF+COALESCE) | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** |
| Q2 | 3-tier searched CASE label by amount_cents | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** |
| Q3 | timestamp -> ISO-8601 string for JSON export | 5.0 | 4.0 | 5.0 | 4.5 | **4.625** |
| Q4 | every 10th event by id divisibility (% 10 = 0) | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** |

Overall = (5.000 + 5.000 + 4.625 + 5.000) / 4 = **4.65625 PASS**

Dim-avg cross-check: Acc (5+5+5+5)/4=5.0 / Comp (5+5+4+5)/4=4.75 / Clar (5+5+5+5)/4=5.0 / Act (5+5+4.5+5)/4=4.875 = (5.0+4.75+5.0+4.875)/4 = 4.90625 (per-Q method is the more conservative governing headline 4.65625). GOVERNING LABEL = PASS; no per-Q below 3.5.

## Q1 PROBE VERDICT — empty-string-COALESCE FINDABLE, NO GAP

CRITICAL PROBE PASSED. The responder reached the correct NULLIF-wrapped form:

`COALESCE(NULLIF(nickname,''), NULLIF(full_name,''), NULLIF(username,''), 'Unknown') AS display_name`

This is the bulletproof idiom. A bare `COALESCE(nickname, full_name, username, ...)` would have WRONGLY returned the empty string `''` (since `''` is non-NULL, COALESCE stops at it) — the responder did NOT make that mistake. It correctly explained that `NULLIF(nickname,'')` converts `''` to NULL so COALESCE skips it, worked three examples (nickname='Alice'->'Alice'; nickname='' full_name='Alice Chen'->'Alice Chen'; all empty->'Unknown'), and cited r07:479.

VERIFIED against Trino 467 (trino.io/docs/current/functions/conditional.html): `NULLIF(v1,v2)` returns NULL if v1=v2 else v1; `COALESCE` returns first non-NULL left-to-right. The chain is correct.

CONCLUSION: The empty-string-vs-NULL COALESCE content is FINDABLE in resources/ (responder cited r07:479 and applied it correctly). The iter832 Q2 ding was a one-off responder omission, NOT a resource gap. NO FIX-A NEEDED on this account. **iter834 = DEFAULT NO-OP.**

## Per-Q verification notes (all PINNED Trino 467)

- **Q2** — `CASE WHEN amount_cents<1000 THEN 'Small' WHEN amount_cents<10000 THEN 'Medium' ELSE 'Large' END`: searched CASE evaluates top-to-bottom, first match wins. The `<10000` second branch correctly captures 1000..9999 because the `<1000` branch already consumed the under-1000 rows. Boundary logic confirmed: 500->Small, 1000->Medium, 9999->Medium, 10000->Large. CLEAN.
- **Q3** — `to_iso8601(created_at)`: VERIFIED trino.io/docs/current/functions/datetime.html `to_iso8601(x) -> varchar` formats date/timestamp/timestamp-with-tz as ISO-8601. Accuracy INTACT: the responder honestly flagged that a bare `TIMESTAMP` (default `timestamp(3)`) outputs `.000` milliseconds (e.g. '2024-03-15T14:30:00.000'), and that `TIMESTAMP WITH TIME ZONE` appends offset/Z. SMALL COMPLETENESS DING (-1 Comp, -0.5 Act): the engineer literally requested the exact string '2024-03-15T14:30:00' (NO millis), and `to_iso8601` does NOT produce that exact form. The precise no-millis form is `format_datetime(created_at, 'yyyy-MM-dd''T''HH:mm:ss')` (literal escaped T, no fractional seconds). The responder did not offer it. Not an accuracy defect — the millis caveat is correct and to_iso8601 is a reasonable JSON-export answer — but the exact requested format was not delivered. Minor, sub-threshold-irrelevant.
- **Q4** — `WHERE event_id % 10 = 0`: VERIFIED trino.io/docs/current/functions/math.html `%` = modulo (remainder); `mod(n,m)` function form also valid. `event_id % 10 = 0` keeps multiples of 10 (1-in-10 sample). Responder correctly noted % and mod() are equivalent and that ROW_NUMBER is the better tool if ids have gaps. CLEAN.

## iter834 directive: DEFAULT NO-OP / durability sweep

All four answers clean, Q1 probe clean (NULLIF-wrap reached), no per-Q below 3.5, no required topic below threshold. No defect or gap surfaced. iter834 = DEFAULT NO-OP durability sweep.

Optional low-risk durability probing only (no edits required):
- Re-probe the empty-string-skip idiom from a different phrasing ("first non-blank of several text cols treating '' as missing", "fall back through columns ignoring whitespace-only values") to confirm the NULLIF-wrap stays reachable. NOTE: if a future probe says "whitespace-only counts as blank too", the correct form is `NULLIF(TRIM(col),'')` — not yet probed; watch for it but do NOT pre-emptively edit.
- Re-probe ISO-8601 from an "exact format, no milliseconds" framing to see whether the responder reaches `format_datetime(...,'yyyy-MM-dd''T''HH:mm:ss')` when the millis are explicitly unwanted. If it only offers to_iso8601 there, consider a tiny adjacent format_datetime cross-ref — but this iter's caveat-flagged answer is acceptable.

## DO NOT
- Touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter833).
- Edit r07:479 NULLIF/COALESCE empty-string content (validated FINDABLE this iter — durable).
- Rewrite any iter534-832 locks.
- Add `::`-casts (iter571 PIN), QUALIFY, RLIKE (iter623 ban), PERCENTILE_CONT/MEDIAN (iter611 ban), EXTRACT(EPOCH) (iter562 ban), DISTINCT ON Postgres-leak (iter634 ban), fabricate dayname()/initcap.
- Bump training/state.json (per directive — already 833).
- git commit/push beyond appending the rubric score-history line.

## Flagged defects: NONE

**OVERALL: 4.65625 PASS — Q1 empty-string-skip NULLIF-wrap LANDED CLEAN (no bare-COALESCE empty-string trap; r07:479 FINDABLE = NO gap); Q2 3-tier searched-CASE boundary logic + Q4 `% 10 = 0` modulo both bulletproof; Q3 to_iso8601 with correct millis/tz caveat = reasonable answer, small completeness ding for not offering the exact no-millis format_datetime form; iter834 = DEFAULT NO-OP durability sweep; federation row stays 4.49944/310.**

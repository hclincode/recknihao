# Judge Feedback — Iter 841 (EXTENDED PHASE)

**Verdict: PASS — overall avg 4.55** (per-Q 3.81 / 5.00 / 5.00 / 4.375 = 18.1875/4; margin +1.05; overall avg governs, no per-Q veto)

DEFAULT NO-OP durability sweep — teacher made ZERO resource edits. All four questions are pure-SQL analytics idioms (no prod-env/auth/federation surface). All core dialect claims docs-verified vs trino.io/docs/467 aggregate/window/map/array .html + WebSearch 2026-06-09.

## Per-question scores

### Q1 — p95 latency (approx_percentile) — Accuracy 3.25 / Completeness 4.5 / Clarity 4.0 / Actionability 3.5 → **avg 3.81**
CORE IS FULLY CORRECT and docs-verified:
- `approx_percentile(response_ms, 0.95)` — CONFIRMED (signature `approx_percentile(x, percentage)`, percentage in [0,1]).
- Array form `approx_percentile(response_ms, ARRAY[0.5,0.95,0.99])` — CONFIRMED (`approx_percentile(x, percentages)` returns array<same as x>).
- "~2.3% stddev, fast/accurate enough for dashboards" — apt and correct.
- "Trino has NO PERCENTILE_CONT/PERCENTILE_DISC and NO MEDIAN — use approx_percentile(col,0.5)" — CONFIRMED (no such functions in aggregate.html).

**DEFECT (accuracy ding): the exact-percentile / PERCENT_RANK aside is WRONG.** The responder said "For EXACT use PERCENT_RANK() OVER (ORDER BY response_ms)". Verified window.html: `percent_rank()` returns the **relative rank of each row** as a value `(r-1)/(n-1)` in [0,1] — it does NOT return the column VALUE at a given percentile. The responder conflated "rank of a row" with "value at percentile." There is no built-in exact percentile-VALUE function in Trino 467; `approx_percentile` is the answer, and an exact value would require manual ranking/positioning (e.g. ORDER BY + offset by ceil(0.95*n), or filtering on a window rank). Pointing the engineer at `PERCENT_RANK() OVER (ORDER BY response_ms)` as "the exact percentile" would NOT give them a p95 latency value — it would give them a per-row rank column. This is a real, actionable mistake an engineer could copy and get wrong output from.

**PERCENT_RANK VERDICT: YES, real accuracy ding.** Not catastrophic — the engineer's actual question (p95 for a dashboard) is answered correctly and prominently by the approx_percentile lead, and the bad advice is a parenthetical aside the engineer likely skips for a dashboard use case. But it is a genuine factual error (mischaracterizes what percent_rank returns) and could misdirect an engineer who does want exactness. Held Q1 accuracy to 3.25 and the aside also lightly dings actionability (the "exact" path is a dead end). Did not drop lower because the headline answer is bulletproof and the array/median/no-percentile_cont content is all correct.

### Q2 — refund rate as decimal (count_if + *1.0 guard) — Accuracy 5.0 / Completeness 5.0 / Clarity 5.0 / Actionability 5.0 → **avg 5.00**
`count_if(is_refunded) * 1.0 / COUNT(*)` — CONFIRMED. count_if(boolean) returns number of TRUE values (aggregate.html, "equivalent to count(CASE WHEN x THEN 1 END)"). The `*1.0` guard is load-bearing and correctly explained — without it, integer `/` truncates to 0. `*100.0` percent variant correct. FILTER and SUM(CASE) equivalents valid. (Note: the even-terser `avg(CAST(is_refunded AS double))` was not required and its absence is not penalized.) CLEAN.

### Q3 — list map keys (map_keys) — Accuracy 5.0 / Completeness 5.0 / Clarity 5.0 / Actionability 5.0 → **avg 5.00**
`map_keys(properties) -> array(K)` — CONFIRMED (`map_keys(x(K,V)) → array(K)`). `map_values(map) -> array(V)` correct. CROSS JOIN UNNEST(map_keys(...)) AS t(key) to explode keys to rows with GROUP BY/count — valid and useful. CLEAN.

### Q4 — integer series 1..N without a table (sequence + UNNEST) — Accuracy 4.75 / Completeness 4.5 / Clarity 4.5 / Actionability 4.5 → **avg 4.375**
`UNNEST(sequence(1, 30)) AS t(n)` — CONFIRMED. sequence(start,stop[,step]) returns an array (array.html); UNNEST turns it into rows (standard Trino, well-established); Postgres generate_series equivalent correct. "step optional (default 1 for ints)" — CONFIRMED (increments by 1, or -1 if start>stop). Date variant `UNNEST(sequence(DATE '2026-01-01', current_date, INTERVAL '1' DAY)) AS t(day)` — CONFIRMED (date step is INTERVAL DAY TO SECOND or YEAR TO MONTH). Minor: did not show the bare `CROSS JOIN UNNEST(...)` placement caveat (UNNEST typically appears in FROM, often as `... CROSS JOIN UNNEST(sequence(1,30)) AS t(n)` or `SELECT n FROM UNNEST(sequence(1,30)) AS t(n)`) — the `AS t(n)` aliasing is shown which is the load-bearing part, so this is a tiny completeness nuance, not an error. Essentially CLEAN.

## Patterns / takeaways
- Q2/Q3/Q4 bulletproof; core p95 answer (Q1) bulletproof. The ONLY blemish is the Q1 PERCENT_RANK-as-exact-percentile mischaracterization.
- No fabrications, no parse errors, no wrong dialect imports, no prod-env conflict.
- Findability: all four questions landed on the right resource content; no responder-slip-vs-gap ambiguity worth grepping (the PERCENT_RANK error is a content-or-elaboration miss, not a wrong-resource landing — see iter842 directive).

## iter842 directive — LIGHT FIX-A (one real defect surfaced)
The Q1 PERCENT_RANK error is a recurring-style "responder volunteers a wrong 'exact' alternative" miss. **iter842 = LIGHT FIX-A** at the approx_percentile / percentile / p95 landing (r05/r23 wherever percentile keywords route):
- Add a FENCED keyword-anchored note distinguishing **value-at-percentile** vs **rank-of-row**: `approx_percentile(x, p)` returns the VALUE at percentile p (approximate); `percent_rank()` / `cume_dist()` window functions return a per-row RANK/position in [0,1], NOT a percentile value — they are NOT a substitute for approx_percentile and do NOT give "the exact p95."
- State plainly: **Trino 467 has NO built-in exact percentile-VALUE function** (no percentile_cont/percentile_disc); for an exact value you must rank/position manually (e.g. ORDER BY x + pick row at index, or `ROW_NUMBER()`/`COUNT(*) OVER ()` ratio filter). approx_percentile is the recommended dashboard answer.
- Inline-DEFANG on its own un-copyable fenced line: `PERCENT_RANK() OVER (ORDER BY x)` as "the exact percentile value" (mark WRONG — returns per-row rank, not the value at the percentile).
- Keyword anchors: exact percentile, exact p95, percentile value vs rank, percent_rank not percentile, no percentile_cont in Trino, value at percentile.
- Verify against trino.io/docs/467 window.html (percent_rank = (r-1)/(n-1)) + aggregate.html (approx_percentile). PIN Trino 467. Pipe/check content FENCED (pipe-escape trap).

PRESERVE all standing locks: iter840 weighted-average integer-truncation card (r23 §3.1B-WA) + iter837 string->DATE MySQL-vs-Joda + iter836 lpad/rpad TRUNCATE/format('%06d') + iter831 month-label grouping + iter827 boolean-aggregate-NULL + iter824/823 split_part/GROUP-BY-alias/repeat-char + trim char-set + default-NULLS-LAST + full iter534-840 pin inventory. NO federation edits (federation row stays 4.49944/310).

DO NOT bump training/state.json (already 841).

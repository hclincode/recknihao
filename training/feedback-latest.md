# Judge Feedback — iter1086 (2026-06-18)

Verified BOTH directions against RAW git-tag 467 source (functions/string.md, functions/window.md, functions/datetime.md, functions/json.md) + WebSearch (trino.io window funcs). Clean sweep; zero source-verified defects.

## Production-environment fit
prod_info.md serving section is unfilled (evaluated against general cloud SaaS assumption per rubric). All four are plain Trino 467 SQL questions independent of the on-prem Iceberg/Trino/MinIO stack — no auth/authz or stack-incompatibility concerns. Fully applicable.

## Per-question scores

### Q1 — first 3 chars of product_code (substr vs split)
- Accuracy **5** — `substr(product_code, 1, 3)` correct. string.md VERIFIED: `substr` is an alias of `substring`; `substring(string, start, length)` returns "a substring from string of length length from the starting position start"; "Positions start with 1" → 1-based, so start=1, length=3 yields the first 3 chars. split/regex genuinely unnecessary for a fixed-position prefix.
- Completeness **5** — answered the direct question, and the split_part mention (VERIFIED `split_part(string, delimiter, index) -> varchar`, 1-based) correctly scopes the after-a-delimiter alternative.
- Clarity **5** — explains 1-based start and the length arg plainly.
- Actionability **5** — drop-in expression.
- Avg **5.00**

### Q2 — 0-to-1 standing = fraction of customers spending less, no counting subquery
- Accuracy **5** — `cume_dist() OVER (ORDER BY total_spend)` correct. window.md VERIFIED: "the number of rows preceding or peer with the row in the window ordering... divided by the total number of rows" = fraction at-or-below; current row always counted so never 0; highest = 1.0. The responder's explicit distinction is CORRECT and source-verified: percent_rank() is `(r - 1) / (n - 1)` (window.md + WebSearch) and CAN be 0 for the first row — genuinely a different metric. No counting subquery needed.
- Completeness **5** — gives the function, the edge behavior at both ends, and the percent_rank disambiguation (a real footgun for this exact phrasing).
- Clarity **4.75** — "fraction at-or-below" vs strictly "less than" is a one-sided nuance (cume_dist includes peers/self), accurately disclosed; minor.
- Actionability **5** — drop-in window function.
- Avg **4.94**

### Q3 — group orders by calendar day, round timestamp down to date
- Accuracy **5** — `date_trunc('day', placed_at)` + `GROUP BY 1` correct. datetime.md VERIFIED `date_trunc(unit, x)` returns x truncated to unit, 'day' → `... 00:00:00.000` (start of day); 'week'/'month'/'year' all VERIFIED supported units. Postgres-parity note accurate.
- Completeness **5** — covers the day grouping plus the wider unit family.
- Clarity **5** — start-of-day explanation is concrete.
- Actionability **5** — drop-in.
- Avg **5.00**

### Q4 — count tags in a JSON-array-as-text column without exploding to rows
- Accuracy **5** — `json_array_length(tags)` correct. json.md VERIFIED `json_array_length(json) -> bigint`, doc example uses a STRING literal `json_array_length('[1, 2, 3]')` → 3, so a varchar column holding a JSON array is accepted directly (no explicit CAST required). The nested-key variant `json_array_length(json_extract(tags,'$.key'))` is also valid: VERIFIED `json_extract(json, json_path) -> json` returns a JSON value, which is a legal argument to json_array_length. Both directions confirmed; no UNNEST explosion.
- Completeness **5** — handles both the column-is-the-array case and the array-nested-under-a-key case.
- Clarity **4.75** — could have noted the value must be a JSON array (not object) for the length to be meaningful; minor.
- Actionability **5** — single function call, drop-in.
- Avg **4.94**

## Overall
(5.00 + 4.94 + 5.00 + 4.94) / 4 = **4.97**

## Verdict: PASS (margin +1.47)

Zero source-verified defects. No fabricated functions, no Postgres/Spark/Oracle spillover, no ::-cast/QUALIFY/false-semi-join/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT issues, no over-warning, no broken-secondary alternative. Notably Q2 included a correct, source-verified cume_dist-vs-percent_rank disambiguation — the opposite of the over-warning/broken-aside failure families.

RECOMMENDATION = DEFAULT NO-OP; no resource edit, no commit. MUST NOT bump state.json (already 1086).

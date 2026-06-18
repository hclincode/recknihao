# Judge Feedback — iter1053

**Overall: Q1 4.875 / Q2 4.9375 / Q3 4.875 / Q4 4.8125 → average 4.875 — PASS** (margin +1.375)

Verified BOTH directions vs RAW git-tag 467 + trino.io/docs/467. RAW source dispositive. No federation probe (hard-locked). Production fit: all four are pure Trino-467/Iceberg SQL+DDL questions, fully within the on-prem Trino 467 + Iceberg-connector + Hive-Metastore stack (no cloud/tool/pricing claims to vet).

---

## Q1 — events ~500M rows: one table or split? — 4.875

**Accuracy 5 / Completeness 5 / Clarity 4.75 / Actionability 5**

Verified (trino.io/docs/467 connector/iceberg.html):
- `partitioning = ARRAY['day(occurred_at)', 'bucket(tenant_id, 32)']` — ARRAY-of-strings DDL form CONFIRMED. Doc canonical example `partitioning = ARRAY['month(order_date)', 'bucket(account_number, 10)', 'country']` matches the shape exactly.
- `bucket()` is COLUMN-FIRST in Trino: doc example `bucket(account_number, 10)` → responder's `bucket(tenant_id, 32)` is correct (NOT Spark count-first `bucket(N, col)`). Memory card [Trino bucket() Arg Order] re-confirmed.
- `day(occurred_at)` partition transform valid (per-day partition, integer day-diff from 1970-01-01).
- identity()-on-high-cardinality-tenant → small-file explosion caution is SOUND.
- Nightly compaction via `ALTER TABLE ... EXECUTE optimize` / rewrite_data_files to ~128-512MB CONFIRMED (`optimize(file_size_threshold => '128MB')`, default 100MB threshold).
- `format=PARQUET`, `format_version=2` correct (2 is the default; required for row-level deletes).
- "partitioning spec is hard to change later" — accurate caution (partition evolution exists but reorganizes only new data).

"Keep ONE table, partition strategically" is the correct architectural call for 500M rows. Minor clarity ding only: dense for a true beginner, but design framing is right.

## Q2 — month-over-month revenue side-by-side — 4.9375 (KEY ITEM, watch v)

**Accuracy 5 / Completeness 4.875 / Clarity 4.875 / Actionability 5**

**WATCH (v) STAYS CLOSED — iter1049 nested-window error did NOT recur.**

`LAG(SUM(amount)) OVER (ORDER BY date_trunc('month', order_date))` inside a `GROUP BY date_trunc('month', order_date)` query is VALID Trino = the canonical **window-over-aggregate** pattern. The argument to LAG is `SUM(amount)`, a PLAIN aggregate computed by GROUP BY — window functions are logically evaluated AFTER GROUP BY/HAVING and operate over the already-aggregated rows, so a window fn whose argument is a group aggregate is legal (same family as `SUM(SUM(x)) OVER (...)`).

This is CATEGORICALLY DISTINCT from the iter1049 INVALID lead `LAG(SUM(amount) OVER (PARTITION BY ...)) OVER (...)` where the LAG argument was ITSELF a window function (`SUM ... OVER`) → illegal nested windows. iter1053 used the legal non-nested form → the nested-window error did NOT recur; watch (v) remains passive/closed. r07 Pattern A2 (window-over-aggregate) + the nested-SUM(SUM) OVER guard are intact and correctly mirrored. lag signature `lag(x[,offset[,default]])` confirmed (window.md).

`pct_change` variant with `NULLIF(LAG(SUM(amount)) OVER (...), 0)` is a sound div-by-zero guard (integer/DECIMAL `/0` throws DIVISION_BY_ZERO; NULLIF returns NULL instead). ORDER BY month for output ordering correct. Tiny completeness note: first month's prev = NULL (expected, no default supplied) — acceptable, often desired.

## Q3 — orders.tags: ≥1 tag starting with literal "promo_" — 4.875 (watch c/o)

**Accuracy 5 / Completeness 4.75 / Clarity 4.875 / Actionability 4.875**

**BROKEN-SECONDARY LIKE ASIDE DID NOT RECUR — clean again (consecutive clean re-probe after iter1049/1050/1052; iter1037/1051 streak does NOT advance).**

Verified (array.md + string.md):
- `any_match(tags, tag -> starts_with(tag, 'promo_'))` — `any_match(array(T), function(T,boolean))→boolean`, returns true if ≥1 element matches; ideal for "at least one". CONFIRMED.
- `filter(tags, tag -> starts_with(tag,'promo_'))` with `cardinality(...) > 0` — valid equivalent (filter→array(T), then nonempty test). CONFIRMED.
- `starts_with(s, sub)` does a LITERAL prefix match with NO wildcards (RAW string.md "Tests whether substring is a prefix of string") — so `'promo_'` correctly matches a literal underscore, the exact semantics the question demands.
- Crucially, the responder offered NO bare `LIKE 'promo_%'` "if you prefer" alternative. That aside would be WRONG (`_` is a single-char wildcard, so `'promo_%'` over-matches `'promoX...'`). Its absence keeps the answer clean.

Minor completeness ding only: could note empty-array → any_match returns false (fine for this question).

## Q4 — subscriptions per plan_type: active/cancelled/trial in one row — 4.8125

**Accuracy 5 / Completeness 4.75 / Clarity 4.75 / Actionability 4.75**

Verified (aggregate.md): `FILTER (WHERE ...)` is supported on ALL aggregate functions; doc example `count(*) FILTER (where petal_length_cm > 4)`. `COUNT(*) FILTER (WHERE status='active') ... GROUP BY plan_type` produces exactly one row per plan with three conditional counts — directly answers "no 3 separate queries". The `SUM(CASE WHEN status=... THEN 1 ELSE 0 END)` alternative is an equivalent, portable form. Both correct. Pivot/conditional-aggregation pattern is the right tool.

---

## Cross-cutting

No `::` cast / QUALIFY / false semi-join / fabricated function / regex-backslash / INTERVAL quarter-week / OFFSET-before-LIMIT / over-warning / broken-secondary across all four. Window-over-aggregate (Q2) and the literal-underscore prefix family (Q3) both clean.

## RECOMMENDATION — DEFAULT NO-OP

Margin +1.375 over threshold; every dialect fact source-verified; no resource defect and no 2-in-2 same-shape slip. NO resource edit, NO commit, NO state.json bump (already 1053). Watch (v) window-over-aggregate stays CLOSED (non-recurrence confirmed); watch (c)/(o) broken-secondary LIKE stays CLOSED (non-recurrence confirmed).

# Judge Feedback — iter1006

**OVERALL: 4.0156 (64.25/16) — PASS** (threshold 3.5; margin +0.5156). OVERALL AVERAGE governs — no per-Q veto. One real load-bearing parse-error defect (Q4 clause order) drags the average but does not sink the pass.

Verified BOTH directions vs trino.io/docs/467 + RAW git-tag 467 source + official GitHub issues — NOT resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark + dbt): all 4 fit; no federation/auth angle.

---

## Per-question scores

### Q1 — anti-join (accounts with no matching user) — **4.8125 CLEAN**
- Acc 5.0 / Comp 4.75 / Clar 4.75 / App 4.75
- `WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.account_id = a.account_id)` — CORRECT canonical anti-join.
- NOT IN + NULL three-valued-logic gotcha **VERIFIED CORRECT**: if `users.account_id` contains any NULL, `NOT IN` evaluates to UNKNOWN for every outer row → WHERE drops all rows → empty result. NOT EXISTS is NULL-safe. Accurate and load-bearing.
- `LEFT JOIN users u ON u.account_id=a.account_id WHERE u.account_id IS NULL` equivalent — CORRECT, and "both compile to the same anti-join plan" matches Trino's optimizer behavior.

### Q2 — DISTINCT active users per calendar week — **4.46875 (minor ding)**
- Acc 4.5 / Comp 4.5 / Clar 4.5 / App 4.375
- `date_trunc('week', event_date)` + `COUNT(DISTINCT user_id)` + GROUP BY repeated-expression — CORRECT.
- **Monday verdict VERIFIED CORRECT**: RAW git-tag 467 datetime.md example truncates 2001-08-22 (Wed) → 2001-08-20, which is a **Monday** (ISO-8601 week start). Responder's "Monday 00:00:00, ISO-8601 week start" is right.
- ★ **MINOR IMPRECISION (the ding): "in UTC".** For a tz-less DATE / TIMESTAMP-without-time-zone column, `date_trunc` does NO time-zone conversion — it operates on the stored wall-clock value. There is no UTC involved for tz-less types. The "in UTC" phrasing is misleading (it would only matter for TIMESTAMP WITH TIME ZONE). Result is still correct; deduct on Acc/Clar only.
- Alias-not-usable-in-GROUP-BY caveat CORRECT (GROUP BY takes expressions/ordinals, not output aliases by name).

### Q3 — safe cast garbage strings to int → NULL — **4.84375 CLEAN**
- Acc 5.0 / Comp 4.75 / Clar 4.875 / App 4.75
- `TRY_CAST(response_time_ms AS INTEGER)` → NULL on 'timeout', query continues — **VERIFIED CORRECT** (conversion.html: "Like cast(), but returns null if the cast fails"). CAST throws — correct contrast.
- `COALESCE(TRY_CAST(response_time_ms AS INTEGER), -1)` default — CORRECT.

### Q4 — paginated API via ORDER BY DESC + LIMIT + OFFSET — **2.0 ★DEFECT (parse error in primary SQL)**
- Acc 2.0 / Comp 2.0 / Clar 2.5 / App 1.5
- ★★ **LOAD-BEARING DEFECT — CLAUSE ORDER IS A TRINO PARSE ERROR.** The responder wrote `ORDER BY created_at DESC LIMIT 50 OFFSET 100` (LIMIT-before-OFFSET, PostgreSQL/MySQL order). **In Trino 467 this is a PARSE ERROR** (`mismatched input 'offset'`).
  - **Citation:** trino.io/docs/467/sql/select.html synopsis documents the clause order as `[ ORDER BY ... ] [ OFFSET count [ROW|ROWS] ] [ LIMIT { count | ALL } ]` — **OFFSET MUST come before LIMIT**. Confirmed by trinodb/trino #7553 ("Support offset after limit in queries" — not supported) and sqlglot #1754 ("Trino throws an error if offset comes after limit and not before"; `limit 1 offset 1` → `mismatched input 'offset'`, `offset 1 limit 1` works).
  - **CORRECT FORM:** `SELECT order_id, created_at, total FROM orders WHERE tenant_id=123 ORDER BY created_at DESC OFFSET 100 LIMIT 50;`
- ★ **Compounding miss:** the question explicitly asks "fine in Trino or different from Postgres?" The clause-order difference (Trino requires OFFSET-before-LIMIT; Postgres accepts LIMIT-before-OFFSET) **IS one of the genuine Postgres→Trino differences** — and the responder asserted the reverse-order query "works in Trino," which is exactly backwards. It identified the cost-model difference but inverted the syntax difference.
- The OFFSET cost-model commentary (Trino+Iceberg OFFSET does not reduce scan cost; reads all WHERE-matching rows then trims; deep OFFSET rescans) and the **keyset/seek pagination recommendation** (`ORDER BY order_id DESC, WHERE order_id < last_id, LIMIT 50`) are **CORRECT and genuinely useful** — this saves Q4 from a full sink. But a SaaS engineer who copies the literal example query gets a syntax error, so Acc/App are heavily docked.

---

## TICs
- `::` PostgreSQL cast: **ABSENT all 4** (ban stays double-locked r23 §3.1C + r27 §4.4A; not exercised; iter1003 one-off has not recurred).
- All functions real & verified: NOT EXISTS / LEFT JOIN-IS NULL / date_trunc('week') / COUNT(DISTINCT) / TRY_CAST / COALESCE.
- No QUALIFY, no false semi-join mislabel, no MAX-varchar, no GREATEST/LEAST-NULL, no date-minus-integer, no INTERVAL quarter/week, no regex-backslash, no broken-secondary (Q4 keyset rec is correct).
- ★ NEW TIC THIS ITER: **OFFSET/LIMIT clause-order inversion** (Postgres-prior import → Trino parse error). Q4 only. First occurrence — per-instance one-off until/unless it recurs.

---

## Defects / notes for teacher
1. **Q4 LIMIT-before-OFFSET = Trino parse error** (the one real defect). Correct form is `OFFSET 100 LIMIT 50`. Same **imported-prior family** as the historical date-minus-integer / GREATEST-NULL / `::`-cast slips: a PostgreSQL syntactic habit carried into Trino where the grammar rejects it. The deliverable example as written does NOT parse.
2. **Q2 "in UTC"** is an imprecise aside for tz-less columns — no tz conversion happens. Minor.

## RECOMMENDATION = DEFAULT NO-OP (with a flagged re-probe)
- Margin +0.5156, PASS. 3/4 answers clean; Q4 deliverable SQL has a genuine parse-error defect but the conceptual content (cost model + keyset pagination) is correct.
- This is the **FIRST** occurrence of the OFFSET/LIMIT clause-order inversion — treat as a per-instance one-off (imported-prior family), NOT yet a source-verified findable resource gap.
- **Re-probe next sweep (priority):** another LIMIT/OFFSET pagination Q. If the responder AGAIN emits `LIMIT n OFFSET m` (LIMIT-before-OFFSET) → that is **2-in-2 same-direction** → orchestrator GREP resources/ for OFFSET/LIMIT guidance:
  - if the correct OFFSET-before-LIMIT order is NOT findable from "pagination/OFFSET/LIMIT" keywords → **FINDABILITY GAP** → candidate LIGHT additive co-located note: copy-attractive canonical `ORDER BY col DESC OFFSET 100 LIMIT 50` + inline-marked un-copyable `-- WRONG: LIMIT 50 OFFSET 100 → parse error 'mismatched input offset' in Trino 467 (Postgres order; Trino requires OFFSET before LIMIT)`;
  - if findable but responder pulls Postgres order from external memory → responder recall ceiling, no fix.
- Do NOT churn the correct Q4 keyset/cost-model content.
- Other re-probes: (a) another anti-join / NOT IN-NULL Q — confirm NOT EXISTS NULL-safe lead; (b) another date_trunc('week'/'month') bucketing Q — confirm Monday-week + watch "in UTC" imprecision recurrence; (c) another TRY_CAST dirty-data Q — confirm NULL-on-failure + COALESCE default.
- Federation r22 §13.x hard-locked NOT probed (stays 4.49944/310).
- MUST NOT bump state.json (already 1006; passed=true; orchestrator commits).

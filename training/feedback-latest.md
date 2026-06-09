# Judge Feedback — iter889 (EXTENDED PHASE)

**Verdict: PASS** — overall average **5.00 / 5** (4 questions, all clean). NO defect surfaced.
**iter890 recommendation: DEFAULT NO-OP** (zero resource edits; all four answers fully correct and dialect-verified).

**FEDERATION NOT PROBED** this iter — the 4.49944/310 federation row is UNCHANGED. All 4 questions were general Trino 467 SQL-pattern probes (date truncation, ROW_NUMBER latest-per-group, EXTRACT/year/month, mode-per-group). State pinned: Trino 467, Iceberg connector, Hive Metastore, on-prem MinIO/k8s (per prod_info.md). No auth/federation/prod-stack fit concerns.

---

## Verification performed (trino.io/docs/467, multiple sources)

- **datetime.html** — `date_trunc('day', TIMESTAMP '2022-10-20 05:10:00') -> 2022-10-20 00:00:00.000` (truncates to midnight). `extract(field FROM x) -> bigint`, `extract(YEAR FROM ...) -> 2022`. `year(x) -> bigint` "Returns the year from x", `month(x) -> bigint` "Returns the month of the year from x".
- **aggregate.html** — NO `mode()` aggregate listed (confirmed absent). `max_by(x, y) -> [same as x]` "Returns the value of x associated with the maximum value of y over all input values." (docs annotate no literal-only/const restriction on y).
- **window.html** — `row_number() -> bigint` "Returns a unique, sequential number for each row, starting with one, according to the ordering of rows within the window partition." Frame must not be specified.
- **sql/select.html** — supported clauses: WITH/SELECT/FROM/WHERE/GROUP BY/HAVING/WINDOW/set-ops/ORDER BY/OFFSET/LIMIT. The token **QUALIFY does NOT appear** — confirmed NOT supported in Trino 467; subquery/CTE nesting required to filter on a window result.
- ROW comparability: types.html does not spell it out, but ROW values are orderable/comparable when all fields are comparable — established Trino behavior; `ROW(cnt, tag)` orders by cnt then tag. Not a defect.

---

## Per-question scoring (Accuracy / Completeness / Clarity / Actionability)

### Q1 — distinct active calendar days per user per month
`COUNT(DISTINCT date_trunc('day', created_at))` with a half-open month range and `GROUP BY user_id`.
- Correct: date_trunc('day') -> midnight, so DISTINCT collapses many same-day events to one day. Warning that `COUNT(DISTINCT created_at)` on raw timestamps counts events not days is accurate and valuable. Half-open `>= DATE '2026-06-01' AND < '2026-07-01'` is the sargable, partition-prunable, boundary-safe idiom.
- Scores: **5 / 5 / 5 / 5 → 5.00**

### Q2 — most recent contact per customer BEFORE a cutoff (no self-join)
`ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY last_contacted_at DESC)`, inner `WHERE last_contacted_at < cutoff`, outer `WHERE rn=1`.
- Correct: filtering pre-cutoff in the inner query then taking rn=1 yields the latest qualifying row per customer. Correctly flags that Trino 467 has NO QUALIFY, so the window must be projected in a subquery/CTE. Verified against the 467 SELECT grammar.
- Scores: **5 / 5 / 5 / 5 → 5.00**

### Q3 — split a date into year + month integer columns
`EXTRACT(YEAR FROM created_at)`, `EXTRACT(MONTH FROM created_at)`; equivalently `year()/month()`; both bigint.
- Correct and complete: both syntaxes verified, both return bigint, month is 1–12, suitable for independent GROUP BY. Offering both forms is helpful.
- Scores: **5 / 5 / 5 / 5 → 5.00**

### Q4 — single most frequent tag per team (mode per group)
`max_by(tag, cnt)` over an inner `GROUP BY team_id, tag COUNT(*) AS cnt`, outer `GROUP BY team_id`; tie-break via `max_by(tag, ROW(cnt, tag))`.
- **CRITICAL CHECK CONFIRMED:** Trino 467 has **NO built-in `mode()` aggregate** — responder did NOT fabricate one and correctly reached for `max_by`. `max_by(x, y)` returns x at the max y (verified). The two-stage count-then-pick-max pattern is the canonical mode-per-group idiom. Honest disclosure that plain `max_by(tag, cnt)` breaks ties arbitrarily, with the deterministic `ROW(cnt, tag)` tie-break, is correct (ROW orders by cnt then tag when fields comparable).
- Scores: **5 / 5 / 5 / 5 → 5.00**

---

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall average: 5.00 → PASS** (threshold 3.5).

No defect to fix. Per the iter882 lesson, no correct claim was flagged. **iter890: DEFAULT NO-OP.**

### Explicit answer to (d)
Trino 467 has **NO `mode()` built-in aggregate** (confirmed via aggregate.html). The responder correctly did NOT claim one exists and used `max_by(tag, cnt)` instead — which **is** the correct mode-per-group pattern (count per group, then `max_by` the tag at the max count). The `max_by(tag, ROW(cnt, tag))` tie-break is valid.

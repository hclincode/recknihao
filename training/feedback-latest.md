# Iter1174 — Judge Feedback

## Verdict: PASS + LIGHT FIX-A — Average 4.5 / 5.0 — Q1 WATCH CLOSES, Q4 NEW LOAD-BEARING LATERAL/CROSS-APPLY FACTUAL ERROR (RESOURCE-SILENT)

| Q | Topic row | Score | Verdict |
|---|---|---:|---|
| Q1 K/M/B abbreviation `12,400,000 → '12.4M'` / `3,750 → '3.75K'` | SQL query best practices for OLAP | 5.0 | **iter1173 r07 format_number FIX-A REACHED CLEANLY — WATCH CLOSES on first re-probe** |
| Q2 digits-only varchar check via regex in WHERE | SQL query best practices for OLAP | 5.0 | pin-perfect `regexp_like` + `^[0-9]+$` anchors + `NOT regexp_like` for negation |
| Q3 7-day moving average over daily signups | Analytical query patterns on Iceberg+Trino | 5.0 | pin-perfect ROWS-vs-RANGE handling + pre-aggregate-to-day caveat + INTERVAL '6' DAY for gap-day calendar-aware variant |
| Q4 Oracle `CROSS APPLY` per-row top-3-tickets → Trino | Oracle PL/SQL → dbt+Trino migration | 3.0 | **DEFECT — "Trino has no CROSS APPLY or LATERAL join syntax" is FACTUALLY WRONG. Trino 467 DOES support `CROSS JOIN LATERAL` / `LEFT JOIN LATERAL` per [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html). Resources are 100% silent on LATERAL → LIGHT FIX-A in r27.** |

Iter average = (5.0 + 5.0 + 5.0 + 3.0) / 4 = **4.5**. Three strong canonical reaches + one load-bearing factual error on a directly-asked question.

---

## Q1 — `format_number()` K/M/B abbreviation (STRONG PASS 5.0) — WATCH CLOSES

### Responder answer (verbatim core)

> *"YES — Trino 467 has the built-in `format_number(number) → varchar` that does exactly this. `format_number(12400000) = '12.4M'`, `format_number(3750) = '3.75K'`. Takes BIGINT or DOUBLE, returns varchar with ~3 sig figs and K/M/B/T/Q decimal-unit suffix. Built-in since Release 357."*
>
> Carve-out: do NOT confuse with `format_data_size` (bytes formatter, IEC units, SQL-UDF not built-in).

### Verification

- `format_number(number) → varchar` listed in [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html). Docs verbatim: *"Returns a formatted string using a unit symbol"* with examples `SELECT format_number(123456); -- '123K'` and `SELECT format_number(1000000); -- '1M'`.
- Built-in since [Release 357 (May 2021)](https://trino.io/docs/current/release/release-357.html). Source: [trino-main FormatNumberFunction.java](https://github.com/trinodb/trino/blob/master/core/trino-main/src/main/java/io/trino/operator/scalar/FormatNumberFunction.java) — input BIGINT or DOUBLE, output VARCHAR, K/M/B/T/Q unit symbols, three-sig-fig precision rule.
- For the engineer's exact examples: `format_number(12400000)` → `'12.4M'` (three-sig-fig: 12.4M, not 12.40M) ✓; `format_number(3750)` → `'3.75K'` (three-sig-fig: 3.75K) ✓.
- `format_data_size` carve-out correctly named — it's an EXAMPLE SQL UDF on the routines page, not a built-in, intended for binary-IEC byte units (`'1MB'`, `'2.3GB'`). Different output space from `format_number`. Matches pinned `reference_trino_format_data_size_is_udf.md`.

### Watch close

`r07 format_number K/M/B FIX-A iter1173` — **CLOSES on first re-probe**. The r07 §1845-1865 card added in iter1173 with:
- THE ONE FACT statement (Trino 467 HAS a built-in `format_number(number) → varchar`)
- Worked examples covering the exact engineer-asked shapes (`890K`, `1.25M`, `12.4M`)
- Keyword anchors {compact number display, abbreviated number, K/M/B suffix, show 1.25M instead of 1250000, 890K format, human-readable count, magnitude formatter, shorten big numbers for a dashboard, thousands/millions/billions suffix, format a large integer compactly, format_number Trino}
- Inline DO-NOT-WRITE defang of both iter1173 wrong claims ("no built-in" + "format_number is general numeric formatting not magnitude compression")
- format_data_size carve-out

is doing exactly its job — engineer-facing K/M/B questions now keyword-route to the correct one-line answer instead of the `format_data_size`-style hand-rolled CASE. Pattern of one-iteration find-and-close holds (12 of last 12 watches).

---

## Q2 — Digits-only varchar check via `regexp_like` in WHERE (STRONG PASS 5.0)

### Responder answer

```sql
SELECT account_id
FROM customers
WHERE NOT regexp_like(account_id, '^[0-9]+$');
```

Plus: `regexp_like(string, pattern) → boolean` directly usable in WHERE; anchors `^...$` required for exactly-digits (without them, `regexp_like('abc123', '[0-9]+')` returns TRUE on contains-a-digit, false positive); `NOT regexp_like` for negation (no `regexp_unlike`); Java regex flavor.

### Verification

- `regexp_like(string, pattern) → boolean` verified verbatim at [trino.io/docs/467/functions/regexp.html](https://trino.io/docs/467/functions/regexp.html): *"Evaluates the regular expression `pattern` and determines if it is contained within `string`"* — note "contained within" exactly justifies the responder's anchors-required warning.
- Anchors `^[0-9]+$` are necessary: without them, the predicate matches contains-a-digit which would let `'CUST-1234'` through (wrong). With anchors, only entire strings that are all digits match.
- `NOT regexp_like(...)` for negation is the correct form (Trino has no `regexp_unlike`).
- Java regex flavor noted at top of the regexp.html docs page; `[0-9]` POSIX-style digit class works (`\d` also works per [reference_trino_regex_backslash.md](pinned) but `[0-9]` is portable and avoids the rendered-vs-RAW backslash ambiguity).
- 200M-row context: WHERE NOT regexp_like is the canonical Trino dirty-data sweep form. No fabrications.

### Source

`r07` + `r23` regex-function canonicals. No resource action.

---

## Q3 — 7-day moving average over daily signups (STRONG PASS 5.0)

### Responder answer

```sql
WITH daily_signups AS (
  SELECT signup_date, COUNT(*) AS new_signups
  FROM signups
  GROUP BY signup_date
)
SELECT
  signup_date,
  new_signups,
  AVG(new_signups) OVER (
    ORDER BY signup_date
    ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
  ) AS avg_7day
FROM daily_signups
ORDER BY signup_date;
```

Plus: ROWS counts **physical rows** not days — pre-aggregate-to-one-row-per-day in a CTE first, else "6 rows back" = 6 orders not 6 days. Gap-day caveat: if some days have zero signups (missing rows), use `RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW` (calendar-aware: window includes all rows whose `signup_date` is within 6 days of current row, missing days don't shift the window).

### Verification

- ROWS BETWEEN N PRECEDING AND CURRENT ROW for AVG window — verified at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html): *"All aggregate functions can be used as window functions by adding the OVER clause"* + frame syntax per [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) WINDOW clause.
- `RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW` is **valid Trino 467** — interval-based RANGE frames were added per the [Trino "Introducing new window features" blog post (release 346+)](https://trino.io/blog/2021/03/10/introducing-new-window-features.html) and the documented form is `RANGE BETWEEN INTERVAL '1' MONTH PRECEDING AND CURRENT ROW`. The offset interval applies to the sorting column (must be a date/time type), so `ORDER BY signup_date RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW` is correct shape.
- ROWS-vs-RANGE distinction is exactly the load-bearing nuance the question hinted at ("does the sliding window get defined differently?"). Responder names both forms with the correct selection rule (ROWS for dense-daily-data, RANGE for sparse/gap days).
- Pre-aggregation-to-day caveat is the key trap: applying ROWS BETWEEN 6 PRECEDING directly to raw signups (one row per individual signup event) would compute a moving average over the last 7 signup EVENTS not the last 7 DAYS — silent off-by-N-row bug. CTE solves it.
- Engineer's literal "moving average is just running-total with AVG?" framing gets the right answer: NO — running total uses `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` (accumulating from start), moving average uses a bounded sliding window `BETWEEN 6 PRECEDING AND CURRENT ROW` (last N rows/period).

### Source

`r07` window-frame canonicals + cumulative-vs-moving distinction. No resource action.

---

## Q4 — Oracle `CROSS APPLY` → Trino (FAIL 3.0) — LIGHT FIX-A

### The defect: "Trino has no CROSS APPLY or LATERAL join syntax" is FACTUALLY WRONG

Responder answer (verbatim core):

> *"Trino has no direct CROSS APPLY syntax. ... Trino has no CROSS APPLY or LATERAL join syntax. The window function rewrite is standard practice."*

The first half is correct (no `APPLY` keyword in Trino). The second half — that Trino has **no LATERAL** — is **factually wrong**.

Trino 467 **DOES support LATERAL joins**, verified verbatim at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html):

> *"Subqueries appearing in the `FROM` clause can be preceded by the keyword `LATERAL`. This allows them to reference columns provided by preceding `FROM` items."*
>
> *"A `LATERAL` join can appear at the top level in the `FROM` list, or anywhere within a parenthesized join tree."*

With this docs-quoted example:
```sql
SELECT name, x, y
FROM nation
CROSS JOIN LATERAL (SELECT name || ' :-' AS x)
CROSS JOIN LATERAL (SELECT x || ')' AS y);
```

So the direct 1:1 Oracle/SQL-Server → Trino translation is:
- `CROSS APPLY (subquery)` → `CROSS JOIN LATERAL (subquery)`
- `OUTER APPLY (subquery)` → `LEFT JOIN LATERAL (subquery) ON TRUE`

For the engineer's specific "per account, 3 most recent tickets" example, the direct LATERAL port would be:

```sql
-- DIRECT 1:1 PORT — works in Trino 467
SELECT a.account_id, t.ticket_id, t.created_at
FROM accounts a
CROSS JOIN LATERAL (
  SELECT ticket_id, created_at
  FROM tickets
  WHERE account_id = a.account_id
  ORDER BY created_at DESC
  LIMIT 3
) t;
```

### What the responder got right

- The `ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY created_at DESC) AS rn` rewrite filtered by `rn <= 3` IS a valid and often-preferred form for top-N-per-group on Trino — it usually plans more efficiently than LATERAL for the top-N-per-group case because the planner can do a single partitioned sort instead of N correlated subquery evaluations.
- `max_by(ticket_id, created_at)` for a single scalar alternative is correct (Trino-native aggregate per [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html)).
- The warning about `CorrelatedJoin` in EXPLAIN being expensive is fair guidance for when a correlated form survives planning.

### What's wrong and why it matters

The engineer's literal question is: *"Does Trino support that per-row correlated join style at all, or must those queries be redesigned?"* — the responder answers "must be redesigned" via ROW_NUMBER, when the truthful answer is **"yes, via LATERAL — and for top-N-per-group ROW_NUMBER is often the better-planning alternative"**. Both forms work; the engineer should know both.

In a 50+ Oracle-report migration this misanswer costs real time: an engineer who knows `CROSS APPLY → CROSS JOIN LATERAL` can do a 1:1 textual rewrite of dozens of reports; an engineer who believes Trino has no LATERAL has to redesign each report with window-function logic — sometimes correctly, sometimes not (e.g., `OUTER APPLY` returning a single-row scalar is awkward to express via window function without a separate aggregation step). The LATERAL form preserves the original report's structure, which matters when the goal is migration parity.

### Source classification: RESOURCE GAP (LIGHT FIX-A) — pin-correct-but-resource-silent family

Grepped `resources/` for:
- `lateral` (case-insensitive) → **zero matches in any resource file**
- `CROSS APPLY` / `OUTER APPLY` (case-insensitive) → **zero matches in any resource file**

The entire LATERAL / APPLY translation pattern is absent from `resources/`. Combined with the Oracle migration context (r27 explicitly addresses Oracle→Trino dialect rewrites), this is exactly the **pin-correct-but-resource-silent** family seen recently with `format_number` / `to_char` / `migrate` — the function/syntax exists in Trino but no resource documents it, so the responder defaults to "doesn't exist" / "must be rewritten."

This is the **6th instance** of imported-prior-direction errors (after `starts_with` / `to_char` / `listagg` / `array_sum` / `format_number`) — the responder assumed absence of a foreign-looking-but-real Trino syntax. Same family, same remediation pattern (additive keyword-magnet card in the topically-correct resource).

### Recommended LIGHT FIX-A

Add an additive canonical card to **`r27-oracle-plsql-to-dbt-trino.md`** (most natural home — `CROSS APPLY` is the Oracle/SQL Server idiom the engineer is migrating; Trino-side LATERAL is the direct replacement). Cross-ref from `r23-sql-best-practices-olap.md` so questions framed in non-migration contexts also reach it.

**Keyword anchors (load these so any Q1-style question keyword-routes here):**
{CROSS APPLY, OUTER APPLY, LATERAL, CROSS JOIN LATERAL, LEFT JOIN LATERAL, per-row correlated join, for each row a correlated subquery, per-account top-N tickets, per-customer most-recent-N orders, Oracle CROSS APPLY translation, SQL Server APPLY in Trino, can Trino reference outer-query columns in a FROM-clause subquery, correlated subquery in FROM}

**Load-bearing facts:**
- Trino 467 HAS `LATERAL` join syntax — verified at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html): *"Subqueries appearing in the `FROM` clause can be preceded by the keyword `LATERAL`. This allows them to reference columns provided by preceding `FROM` items."*
- Trino does NOT have the `APPLY` keyword (`CROSS APPLY`/`OUTER APPLY` parse-error). The direct ANSI-standard translation is LATERAL:
  - `CROSS APPLY (subquery)` → `CROSS JOIN LATERAL (subquery)`
  - `OUTER APPLY (subquery)` → `LEFT JOIN LATERAL (subquery) ON TRUE`
- LATERAL is the direct 1:1 port for migration parity. For top-N-per-group specifically, `ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...) <= N` is often a better-planning alternative (single partitioned sort vs N correlated evaluations) — name BOTH forms with a selection rule:
  - **Use LATERAL** when porting Oracle/SQL-Server reports verbatim (preserves structure, easier code review, handles arbitrary per-row subqueries that aren't just top-N).
  - **Use ROW_NUMBER + filter** when the pattern is specifically top-N-per-group on a large table and planning efficiency matters.

**Defang DO-NOT-WRITE entries:**
- "Trino has no LATERAL" — **FALSE** (it's documented in 467 SELECT syntax, with example).
- "All Oracle CROSS APPLY queries must be redesigned with window functions" — **FALSE** (most can be 1:1 ported via `CROSS JOIN LATERAL`; only redesign when planning matters).

**Worked Oracle→Trino example:**
```sql
-- Oracle (or SQL Server)
SELECT a.account_id, t.ticket_id, t.created_at
FROM accounts a
CROSS APPLY (
  SELECT ticket_id, created_at
  FROM tickets
  WHERE account_id = a.account_id
  ORDER BY created_at DESC
  FETCH FIRST 3 ROWS ONLY
) t;

-- Direct 1:1 Trino 467 port (preserves report structure)
SELECT a.account_id, t.ticket_id, t.created_at
FROM accounts a
CROSS JOIN LATERAL (
  SELECT ticket_id, created_at
  FROM tickets
  WHERE account_id = a.account_id
  ORDER BY created_at DESC
  LIMIT 3
) t;

-- Often-better-planning alternative when the table is very large
SELECT account_id, ticket_id, created_at
FROM (
  SELECT t.account_id, t.ticket_id, t.created_at,
         ROW_NUMBER() OVER (PARTITION BY t.account_id ORDER BY t.created_at DESC) AS rn
  FROM tickets t
)
WHERE rn <= 3;
```

**Cross-ref / placement notes:**
- r27 §4.4 (cross-dialect-spillover guardrail) is a natural section to graft this onto — Oracle `CROSS APPLY` is exactly a cross-dialect spillover case.
- r23 should add a 1-line cross-ref ("for the LATERAL syntax used in correlated-subquery-in-FROM patterns, see r27 §X").
- Cross-ref `r28-complex-sql-performance-trino-dbt.md` for the ROW_NUMBER-vs-LATERAL planning trade-off (top-N-per-group section).

**Watch label:** `r27 LATERAL / CROSS APPLY FIX-A iter1174`. Re-probe next sweep with structurally similar phrasings:
- *"SQL Server `OUTER APPLY (...)` patterns — Trino equivalent?"*
- *"For each parent row, run a small correlated query — does Trino allow that or only the window-function form?"*
- *"Porting `CROSS APPLY` for a per-order-recent-shipments report — Trino syntax?"*

If reaches LATERAL canonical → CLOSE.

### Classification fit

6th instance of imported-prior-direction errors (after `starts_with` / `to_char` / `listagg` / `array_sum` / `format_number`). Pattern: responder assumes absence of a foreign-looking-but-real Trino syntax/function when the resource is silent on it. Remediation pattern is consistent: additive keyword-magnet card in the topically-correct resource, with explicit DO-NOT-WRITE defang of the "doesn't exist" claim.

### Practical impact

Q1/Q2/Q3 are pin-perfect canonical reaches. Q4 engineer gets a **working** ROW_NUMBER query — they can ship — but loses (a) the 1:1 LATERAL migration shortcut (forcing per-report redesign across the 50+ Oracle reports), and (b) the correct mental model that Trino is ANSI-compliant on LATERAL even though it lacks the SQL Server `APPLY` keyword. For a SaaS team mid-Oracle-migration, this is a real time tax.

---

## Watches summary

| Watch | Iter opened | This iter | Status |
|---|---|---|---|
| `r07 format_number K/M/B FIX-A iter1173` | 1173 | Q1 re-probe reached `format_number(12400000)='12.4M'`, `format_number(3750)='3.75K'` with format_data_size carve-out | **CLOSED** |
| `r27 LATERAL / CROSS APPLY FIX-A iter1174` | **1174 (NEW)** | Q4 said "Trino has no LATERAL" — factually wrong; resources 100% silent on LATERAL / APPLY | **OPEN — LIGHT FIX-A recommended** |

---

## Recommended next-sweep action for the teacher

**LIGHT FIX-A on r27-oracle-plsql-to-dbt-trino.md** (with cross-ref in r23 and r28):

Add a `CROSS APPLY → CROSS JOIN LATERAL` / `OUTER APPLY → LEFT JOIN LATERAL` canonical card. Trino 467 has LATERAL joins — documented in [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) — and they are the direct ANSI-standard replacement for the missing `APPLY` keyword. The card must include both the LATERAL form (for 1:1 migration parity) AND the ROW_NUMBER form (for top-N-per-group planning), with a selection rule between them. Defang the "Trino has no LATERAL" claim with the explicit docs quote.

**No resource action on Q1, Q2, Q3** — Q1 watch CLOSES (12/12 pattern holds); Q2 and Q3 are pin-perfect canonical reaches.

**Margin update:**
- SQL query best practices for OLAP: 4.5736/249 → (1138.8264 + 5.0 + 5.0)/251 = **4.5770/251** (+0.0034, margin +1.0770).
- Analytical query patterns on Iceberg+Trino: 4.5394/122 → (553.8068 + 5.0)/123 = **4.5432/123** (+0.0038, margin +1.0432).
- Oracle PL/SQL → dbt+Trino migration: 4.4778/139 → (622.4142 + 3.0)/140 = **4.4674/140** (-0.0104, margin still +0.9674, cushion absorbs).

The Q4 fail is bounded by topic margin and adds one watch. Three of four answers above 4.875 keeps the overall iter average at 4.5, comfortably PASS.

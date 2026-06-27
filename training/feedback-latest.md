# Iter1163 — Judge Feedback

**Verdict: 4.5625 PASS NO-OP + LIGHT WATCH.**

**Iter average = (4.75 + 5.0 + 4.875 + 3.625) / 4 = 4.5625 PASS.** Three strong canonical reaches (CTE-inline-vs-materialized-table / bitwise_and-no-operator / single-pass conditional aggregation). Q4 the only slip — single-phrasing responder over-elaboration on Oracle date-vs-string strict-typing question that scored **5.0 pin-perfect at iter1149** for nearly the same migration question. Resource (r27) is CORRECT at L16/L926/L933/L1257/L3968 — responder fabricated a "Trino executes as string comparison" failure-mode branch that does not exist. Classic broken-secondary-alternative family (primary fix patterns correct → engineer arrives at right migration code; padded "why it fails" framing wrong). **NO-OP + WATCH** for one re-probe (next sweep, different Oracle date-comparison phrasing). Escalate to additive r27 myth-row defang only if the wrong-failure-mode framing recurs.

---

## Q1 — Shared pre-computed intermediate for ~35 dbt models reading the same raw events Iceberg table

**Score: 4.75** (Acc 5 / Clarity 5 / Practical 5 / Completeness 4)

Responder correctly named:
- Trino INLINES CTEs (a `WITH` referenced N times executes the source scan N times — there is no shared-CTE materialization in Trino 467). Verified at [trinodb/trino#28085](https://github.com/trinodb/trino/issues/28085) "Does trino support CTE Materialization?" + [trinodb/trino#10](https://github.com/prestosql/presto/issues/10) "Named queries (WITH) should be evaluated only once" (both OPEN — confirms CTE materialization is NOT in 467).
- The right cost lever: separate dbt intermediate model `materialized='table'` (e.g., `stg_filtered_events`), downstream models read it via `ref('stg_filtered_events')`. Big initial scan + filter happens ONCE per dbt run; the ~35 downstream models each scan the small pre-computed intermediate.
- Cited r28 — correct routing.

Minor completeness shave (-0.5 Compl): didn't explicitly name `materialized='view'` as the WRONG choice for this case (a view inlines the SQL on every reference — same scan-N-times problem as CTE), and didn't name `ephemeral` (compiles to a CTE → same inlining). Recall ceiling, not a defect.

Maps to **Improving complex SQL performance on Trino with dbt** topic row. Healthy reach; r28 leading canonical pulling correctly.

---

## Q2 — Postgres `(permissions_flags & 4) != 0` bitmask test in Trino

**Score: 5.0** (Acc 5 / Clarity 5 / Practical 5 / Completeness 5)

Pin-perfect against the bitwise pin (`reference_trino_bitwise.md`). Verified against [trino.io/docs/current/functions/bitwise.html](https://trino.io/docs/current/functions/bitwise.html):

- Trino 467 has NO `&` / `|` / `^` / `<<` / `>>` operators (those are C/Java/Postgres operators, NOT Trino syntax — would be parse errors).
- `bitwise_and(permissions_flags, 4) <> 0` is the correct bit-test idiom — responder named it directly with the engineer's exact mask value.
- Bonus accuracy: responder also named `bitwise_left_shift` / `bitwise_right_shift` (no `<<` / `>>` operators) and the `bit_count(x, bits)` 2-arg requirement with no 1-arg overload / no `popcount`. All three facts match the pin verbatim.

Topic: **SQL query best practices for OLAP** (Trino dialect strict-typing / operator-vs-function family — also Postgres→Trino migration angle).

---

## Q3 — Per-customer events-in-last-7/30/90-days in one query (conditional aggregation vs three subqueries)

**Score: 4.875** (Acc 5 / Clarity 5 / Practical 5 / Completeness 4.5)

Correct canonical conditional-aggregation single-pass single-GROUP-BY form:

```sql
SELECT
  customer_id,
  COUNT(CASE WHEN event_date >= CURRENT_DATE - INTERVAL '7'  DAY THEN 1 END) AS events_last_7d,
  COUNT(CASE WHEN event_date >= CURRENT_DATE - INTERVAL '30' DAY THEN 1 END) AS events_last_30d,
  COUNT(CASE WHEN event_date >= CURRENT_DATE - INTERVAL '90' DAY THEN 1 END) AS events_last_90d
FROM events
WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY
GROUP BY customer_id;
```

All elements valid Trino 467:
- `COUNT(CASE WHEN cond THEN 1 END)` — counts non-NULL CASE results (CASE-without-ELSE returns NULL on miss; COUNT ignores NULL). Standard SQL pattern.
- `SUM(CASE WHEN cond THEN 1 ELSE 0 END)` alternative — equally valid.
- `INTERVAL '7' DAY` — DAY is a valid Trino interval qualifier (per `reference_trino_interval_qualifiers.md` pin: YEAR/MONTH/DAY/HOUR/MINUTE/SECOND only — DAY is in the list).
- Outer `WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY` partition-prunes correctly (bare-column predicate, no UnwrapCast issue).

Minor completeness shave (-0.5 Compl): didn't name the Trino-native `COUNT(*) FILTER (WHERE cond)` form as a cleaner third option. `FILTER` is supported on all aggregates per [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html) ("The FILTER keyword can be used to remove rows from aggregation processing ... is supported for all aggregate functions"). Iter1149 Q1 used FILTER form in similar shape. Not load-bearing — both given forms work and copy-paste cleanly.

Maps to **Analytical query patterns on Iceberg+Trino** (conditional-aggregation / multi-window-counts canonical).

---

## Q4 — Oracle `WHERE created_at = '2024-01-15'` silent coercion vs Trino strict typing (FAILURE-MODE INACCURACY)

**Score: 3.625** (Acc 2.5 / Clarity 4 / Practical 4 / Completeness 4)

**Verdict: PASS-with-slip. NO-OP + WATCH (one-off responder over-elaboration in the broken-secondary-alternative family).**

### What's correct (load-bearing fix actions)

- The migration fix patterns are all valid Trino 467:
  - `created_at >= DATE '2024-01-15'` (typed DATE literal) — correct
  - `created_at >= TIMESTAMP '2024-01-15 00:00:00'` (typed TIMESTAMP literal) — correct
  - `CAST(created_at AS DATE) = CAST('2024-01-15' AS DATE)` — correct, AND it STILL partition-prunes via the optimizer's `UnwrapCastInComparison` rule (per pinned `reference_trino_unwrap_temporal_predicates.md` + iter1149 Q4 verification + [trino.io/docs/current/optimizer/pushdown.html](https://trino.io/docs/current/optimizer/pushdown.html))
- Migration recipe (grep for `WHERE col = '<string>'`, rewrite to typed literal) is the right audit framing.
- Correctly cited r27 (Oracle migration) — right routing.

### What's wrong (the slip)

**Failure-mode claim is factually wrong.** Responder said:

> "Trino rejects the comparison with a TYPE_MISMATCH error OR executes it as a STRING COMPARISON (wrong result)."

then doubled down later:

> "Trino treats it as a STRING COMPARISON, not a temporal range. Your rows may come back in the wrong order or the predicate may not push down."

Trino 467 does NOT silently string-compare a TIMESTAMP/DATE column against a VARCHAR literal. There is NO implicit VARCHAR → TIMESTAMP / VARCHAR → DATE coercion in either direction. The comparison ALWAYS errors at analysis time with `Cannot apply operator: timestamp(p) >= varchar(N)` or `date = varchar(N)`. Verified at:
- [trinodb/trino#7334](https://github.com/trinodb/trino/issues/7334) "Cannot compare timestamp with varchar value" (explicit failure mode: `TYPE_MISMATCH: line 1:49: Cannot apply operator: timestamp(3) < varchar(19)`)
- [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html) — implicit coercion list does not include varchar→timestamp or varchar→date in either direction.

The "string comparison" branch is a fabrication. A string comparison would only happen if the COLUMN itself were VARCHAR (which is not the stated scenario — the engineer asked specifically about a date/timestamp column).

The "may not push down" caveat on `CAST(created_at AS DATE)` is also slightly off — Trino 467's UnwrapCast rules push down exactly this pattern; partition pruning works. Iter1149 Q4 verified this correctly.

### Source classification: NOT resource-sourced — one-off responder slip

Grep'd `resources/27-oracle-plsql-to-dbt-trino.md` for the failure-mode framing. The resource is CORRECT:

- L933 (verbatim): "Bare-quoted `'2026-06-01'` is a `VARCHAR` literal. **Trino has NO implicit `VARCHAR` → `TIMESTAMP WITH TIME ZONE` coercion.** The query fails at analysis time with a type-mismatch error like `Cannot apply operator: timestamp(6) with time zone >= varchar(10)`."
- L926: "TYPE ERROR at analysis time. Trino rejects the query."
- L16: "Trino is strict about types: no implicit varchar<->number coercion ... date arithmetic uses INTERVAL not + 1."
- L3968: "Search WHERE clauses for `<integer_col> = '<string>'`-style comparisons. **Trino will fail to parse these.** Add explicit `CAST(...)`."

No resource teaches the wrong "string comparison" framing. The resource consistently and correctly says Trino ERRORS.

For direct comparison: **iter1149 Q4** asked virtually the same question ("Oracle implicit `WHERE created_date = '2024-01-15'` (string→date coercion) / Trino throws type mismatch / right way to write date literal comparisons") and scored **5.0 pin-perfect** with all four facts source-verified. Same r27 resource, same canonical path. The iter1163 Q4 over-elaboration is a per-iteration responder slip, NOT a resource regression.

### Classification

**Broken-secondary-alternative family** per pinned `feedback_responder_broken_secondary_alternative.md`. Primary action (use typed `DATE '...'` / `TIMESTAMP '...'` literals, or CAST) is correct → engineer arrives at the right migration fix. Padded "for completeness" failure-mode framing (the "OR executes as string comparison" branch) is fabricated. Same Haiku pattern as iter936/943/948/950/954/1013/1019/1020/1141/1148/1152/1155/1156 — leads pass, padded aside fails.

**Decision: NO-OP + WATCH.** Resource is correct at multiple anchors (L16 / L926 / L933 / L1257 / L3968). Adding a new "Trino does NOT string-compare on type mismatch" defang card risks `feedback_new_card_over_attracts_adjacent` over-attractor on neighboring strict-typing questions. r27 already has correct content findable via `Cannot apply operator` / `TYPE_MISMATCH` / `no implicit varchar` keywords. iter1149 reached it correctly; iter1163 didn't on this one phrasing. Single-iteration variance.

**Watch label:** r27 date-vs-string-literal failure-mode silent-string-comparison fabrication iter1163; re-probe in next sweep with structurally similar Oracle implicit-coercion phrasing (`WHERE order_date = '2024-03-15'` / `WHERE event_ts >= '2024-01-01 00:00:00'`). If recurs across different phrasing → consider additive r27 §4.2 myth-row pinning "Trino silently string-compares on date/timestamp vs varchar mismatch" as FALSE with the actual TYPE_MISMATCH error text inline. If one-off → leave canonicals untouched.

### Practical impact bounded

Engineer following the fix patterns (1) typed literal `DATE '2024-01-15'`, (2) typed literal `TIMESTAMP '2024-01-15 00:00:00'`, (3) explicit `CAST(...)` gets correct migration code. Wrong mental model of "string comparison" failure mode doesn't change the actionable rewrite — the rewrite stops both real failure (analysis error) and the imagined failure (silent string compare) the same way. Recall ceiling, NO resource fix this iter.

Maps to **Oracle PL/SQL → dbt+Trino migration** topic row.

---

## Topic averages updated

| Topic | Q | Score | Updated avg / count |
|---|---|---|---|
| Improving complex SQL performance on Trino with dbt | Q1 | 4.75 | 4.6283 / 27 (+0.0047) |
| SQL query best practices for OLAP | Q2 | 5.0 | 4.5797 / 232 (+0.0018) |
| Analytical query patterns on Iceberg+Trino | Q3 | 4.875 | 4.5217 / 115 (+0.0031) |
| Oracle PL/SQL → dbt+Trino migration | Q4 | 3.625 | 4.4588 / 133 (-0.0063) |

All four topics remain PASSED with healthy margins (smallest: Oracle migration at +0.9588 over threshold).

---

## Patterns across this sweep

1. **Three pin-perfect / near-pin-perfect reaches on bulletproofed canonicals** (CTE-inline-vs-materialized-table, bitwise_and-no-operator, conditional-aggregation single-pass) — consistent with breadth-mode strategy of probing less-recently-touched dialect/perf-design facts.

2. **Q4 the only slip — single-phrasing responder over-elaboration on a topic that scored 5.0 pin-perfect on iter1149 for nearly the same Oracle date-vs-string question.** Classic Haiku broken-secondary-alternative pattern: the primary "use typed literal" answer is correct, but the "why it fails" framing was padded with a fabricated "string comparison" branch. NOT a resource regression (r27 is correct at L16/L926/L933/L1257/L3968). NO-OP + watch for one re-probe; escalate to additive defang only if it recurs across a different phrasing.

3. **No open FIX-A watches** entering this iter and **no new FIX-A** to open this iter. Watch list adds one: r27 date-vs-string-literal failure-mode iter1163 (low-priority single-iteration variance).

---

## Citations (verified June 2026)

- [trino.io/docs/current/functions/bitwise.html](https://trino.io/docs/current/functions/bitwise.html) — bitwise functions (no `&`/`|`/`^`/`<<`/`>>` operators; bit_count requires 2-arg)
- [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html) — implicit coercion table (no varchar→timestamp/date)
- [trinodb/trino#7334](https://github.com/trinodb/trino/issues/7334) — "Cannot compare timestamp with varchar value" (TYPE_MISMATCH error text)
- [trinodb/trino#28085](https://github.com/trinodb/trino/issues/28085) — Trino CTE materialization status (inlined, executed N times)
- [trinodb/trino#10](https://github.com/prestosql/presto/issues/10) — Named queries (WITH) executed N times when referenced N times
- [trino.io/docs/current/optimizer/pushdown.html](https://trino.io/docs/current/optimizer/pushdown.html) — UnwrapCastInComparison rule (CAST(ts AS DATE) prunes)
- [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html) — FILTER clause supported on all aggregates
- [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) — dbt-trino materialization options
- resources/27-oracle-plsql-to-dbt-trino.md L16/L926/L933/L1257/L3968 — internal verification that resource correctly teaches TYPE_MISMATCH error not string comparison

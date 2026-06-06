# Iteration 558 Judge Feedback — 2026-06-07

## Overall verdict
**OVERALL AVG = (4.875 + 4.875 + 1.875 + 4.75) / 4 = 16.375 / 4 = 4.09375 PASS** (margin +0.59375 above 3.5 floor).

PASS by the overall-average rule, but dragged down hard by a Q3 **OVERSTATEMENT FAILURE** that is the iter559 PRIMARY fix. Q1 + Q2 + Q4 were strong; Q3 was a confidently-stated falsehood about TOP-LEVEL `ORDER BY` without `LIMIT` being "STRIPPED" / "IGNORED" / "random order" — the Trino docs say the exact opposite for top-level usage.

---

## Per-question scoring

### Q1 — `CAST(json_parse(col) AS ROW/MAP)` direct JSON→typed parse — WIN CHECK passed
**Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 4.5 = 4.875 STRONG PASS — iter558 r09 INVERSE-direction canonical VALIDATED on first re-probe.**

Responder produced:
- `CAST(json_parse(properties_json) AS MAP(VARCHAR, VARCHAR))`
- `CAST(json_parse(payload) AS ROW(plan VARCHAR, seats BIGINT))`
- `json_parse` first for `VARCHAR` (no auto-coerce)
- Field access: `config.plan` (dot notation on ROW), `props['plan']` (MAP subscript)
- `MAP(VARCHAR, JSON)` escape hatch for mixed value types
- Cited r09 LEADING CANONICAL (the new H3 added this iter)

Verbatim Trino 467 doc quote at trino.io/docs/467/functions/json.html: *"When casting from `JSON` to `ROW`, both JSON array and JSON object are supported"* — matches responder framing exactly. MAP VARCHAR-key restriction matches verbatim: *"the key type of the map is `VARCHAR`"*. The 5 worked examples + 5-row DO-NOT-WRITE in the new H3 (slotted IMMEDIATELY AFTER forward-direction CAST-to-JSON canonical) is what routed the responder. **iter558 FIX B `(a)` candidate (CAST JSON AS ROW/MAP/ARRAY) — VALIDATED.**

Actionability -0.5: did not explicitly call out that `json_extract(payload, '$.user')` returns `JSON` already (so no `json_parse` needed before that CAST) — covered in r09 example 4 but responder didn't surface it.

### Q2 — Composite `unique_key=['tenant_id','event_id']` ROW_NUMBER PARTITION BY — WIN CHECK passed
**Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 4.5 = 4.875 STRONG PASS — iter558 r28 GUARDRAIL composite-key inline sentence VALIDATED on first re-probe.**

Responder produced:
- "MUST include BOTH columns: `PARTITION BY tenant_id, event_id`"
- Partitioning by one silently collapses distinct events (the exact banned form spelled out in the iter558 GUARDRAIL inline sentence)
- Trino MERGE fails loudly on dup unique_key (no silent last-write-wins) — iter557 win held
- Cited r28 + r23

Trino MERGE behavior verbatim at trino.io/docs/467/sql/merge.html: *"The query fails if a single target table row matches more than one source row"*. Responder framing matches. **iter558 FIX A composite-key inline sentence (added to r28 L181 GUARDRAIL blockquote) — VALIDATED.** The reconcile-in-place inside the iter557 GUARDRAIL (one sentence added, no new block) paid off — clean routing, no duplication, dedup logic complete.

Actionability -0.5: the worked CTE `SELECT *, ROW_NUMBER() OVER (PARTITION BY tenant_id, event_id ORDER BY updated_at DESC) rn ... WHERE rn = 1` is shown in r28 but the responder gave only the partition clause without the full pre-dedup CTE wrap.

### Q3 — `ORDER BY` no `LIMIT` stable-sort question — CRITICAL OVERSTATEMENT FAIL
**Scores: Accuracy 1.5 / Completeness 2 / Clarity 2.5 / Actionability 1.5 = 1.875 HARD FAIL — VERIFIED OVERSTATEMENT; iter559 PRIMARY fix.**

Responder claimed VERBATIM:
> "Without a LIMIT, ORDER BY guarantees nothing. Trino is free to return rows in any order unless you use LIMIT. ORDER BY without a LIMIT is effectively STRIPPED by the optimizer — the planner sees you're not limiting rows so the sort is pointless and SKIPS it. ORDER BY without LIMIT is IGNORED; results come back in random order every run. LIMIT makes the ORDER BY actually execute (enforces single-threaded gather + sort)."

**VERIFIED FALSE for a TOP-LEVEL `ORDER BY`.** The Trino 467 docs at trino.io/docs/467/sql/select.html ORDER BY section say verbatim:

> *"Note that, following the SQL specification, an `ORDER BY` clause only affects the order of rows for queries that immediately contain the clause. Trino follows that specification, and **drops redundant usage of the clause** to avoid negative performance impacts."*

> *"Since tables in SQL are inherently unordered, and the `ORDER BY` clause in this case does not result in any difference, but negatively impacts performance of running the overall **insert statement**, Trino skips the sort operation."*

> *"Another example where the `ORDER BY` clause is redundant, and does not affect the outcome of the overall statement, is a **nested query**"*

The docs are explicit: Trino drops `ORDER BY` only when it is **REDUNDANT** — i.e. **inside a subquery, CTE, view, or `INSERT-SELECT`** where the enclosing/consuming operation does not preserve order. A **TOP-LEVEL** `SELECT ... ORDER BY x` (no `LIMIT`) IS HONORED — it returns sorted rows. The responder conflated "nested/INSERT `ORDER BY` without `LIMIT` may be dropped" with "top-level `ORDER BY` without `LIMIT` is ignored" — the latter is FALSE.

Also FALSE: *"LIMIT makes the ORDER BY actually execute"*. The right mental model is:
- **Top-level `ORDER BY` always sorts** (with or without `LIMIT`). `LIMIT` turns it into a `TopN` operator (more efficient + fixed single output stream) but sort happens either way.
- **Nested `ORDER BY` without `LIMIT` may be dropped** (redundant; consumer reshuffles anyway).
- **Nested `ORDER BY` WITH `LIMIT` is preserved** (it changes the row set — not just the order — so it's NOT redundant). The `ORDER BY + LIMIT` combo inside a CTE / INSERT / view IS the standard way to force preservation.
- **Tie non-determinism**: even a top-level `ORDER BY x` returns rows in unstable order **AMONG TIED ROWS** if `x` has duplicates and there's no tiebreaker. The right fix is "add a unique tiebreaker for a deterministic total order" (`ORDER BY x, id`), NOT "add a LIMIT to make ORDER BY execute."

GREP of `resources/07-analytical-query-patterns.md` and `resources/23-sql-best-practices-olap.md` shows ZERO routing-clean canonical for: "ORDER BY without LIMIT determinism", "ORDER BY stripped/redundant", "ORDER BY in subquery/CTE/INSERT not preserved", "TopN operator", or "unique tiebreaker for deterministic sort". The only adjacent content is the `ROWS vs RANGE on tied ORDER BY values` block in r07 §window-functions (which covers tied-peers semantics for window frames, NOT top-level ORDER BY preservation). **iter559 PRIMARY FIX REQUIRED.**

Accuracy 1.5 (not 1) because the partial truth — `ORDER BY` inside a nested context may be dropped — is technically right; the fail is that the responder applied it to the top-level case which is the question's actual scope. Clarity 2.5 — the framing is confident and quotable but wrong, which is worse than honest uncertainty for a SaaS engineer who will now believe top-level `ORDER BY` is useless without `LIMIT`.

### Q4 — Explode MAP into rows via `CROSS JOIN UNNEST(map_entries(m))`
**Scores: Accuracy 5 / Completeness 4.5 / Clarity 5 / Actionability 4.5 = 4.75 STRONG PASS.**

Responder produced:
- `CROSS JOIN UNNEST(map_entries(map_column)) AS t(entry)` → `entry.key` / `entry.value` (entry is `ROW(key, value)`)
- `GROUP BY entry.key` use case
- CROSS JOIN drops NULL/empty maps; `LEFT JOIN UNNEST(...) ON TRUE` keeps them
- Map HOFs (`map_filter`, `transform_values`) when output stays MAP

Verified at trino.io/docs/467/functions/map.html: signature *"map_entries(map(K, V)) -> array(row(K, V))"* — matches responder's "entry is ROW(key, value)" framing exactly. The two-column form `AS t(k, v)` (auto-unrolling the ROW into two columns) also works and is more idiomatic in some Trino code — both forms are valid; responder picked one and stayed consistent.

Completeness -0.5: did not surface that you can ALSO write `CROSS JOIN UNNEST(map_column) AS t(k, v)` directly (without `map_entries`) — Trino auto-explodes MAP into `(key, value)` columns. Both forms are valid; the `map_entries` wrap is one extra hop. Actionability -0.5: a quick example with the dropped-empty-map gotcha would have helped.

---

## iter559 fix targets (PRIMARY)

**Fix 1 — HIGHEST — ORDER BY determinism canonical (Q3 fail).** Add `### LEADING CANONICAL — ORDER BY determinism / stable sort in Trino — TOP-LEVEL is honored, NESTED may be dropped` in r07 or r23 (both natural hosts; r07 is closer to existing ROWS-vs-RANGE tied-peers canonical). Content MUST include:
- **Keyword anchors**: `ORDER BY without LIMIT`, `ORDER BY stripped`, `ORDER BY ignored`, `ORDER BY not preserved`, `stable sort Trino`, `deterministic sort Trino`, `ORDER BY in subquery dropped`, `ORDER BY in CTE not preserved`, `ORDER BY in view`, `INSERT ORDER BY`, `TopN`, `tied ORDER BY non-deterministic`, `unique tiebreaker ORDER BY`.
- **THE FACT in one sentence** (with verbatim Trino docs quote at trino.io/docs/467/sql/select.html): a **TOP-LEVEL** `SELECT ... ORDER BY x` IS HONORED with or without `LIMIT` — Trino sorts the final output. Trino drops `ORDER BY` ONLY when it is **REDUNDANT** — i.e. inside a subquery / CTE / view / `INSERT-SELECT` where the consuming operation does not preserve row order.
- **Verbatim doc quote**: *"an ORDER BY clause only affects the order of rows for queries that immediately contain the clause. Trino follows that specification, and drops redundant usage of the clause to avoid negative performance impacts."*
- **Four worked examples**:
  1. `SELECT ... ORDER BY x` (top-level, no LIMIT) — **HONORED**, output is sorted.
  2. `WITH cte AS (SELECT ... ORDER BY x) SELECT * FROM cte` — `ORDER BY` inside CTE **DROPPED**; only the outer `ORDER BY` matters.
  3. `INSERT INTO t SELECT ... ORDER BY x` — **DROPPED** (tables are unordered).
  4. `SELECT * FROM (SELECT ... ORDER BY x LIMIT 100) ORDER BY y` — inner `ORDER BY+LIMIT` IS preserved (changes row set); outer `ORDER BY y` controls final order.
- **The TIE non-determinism trap** (the REAL downstream-instability cause): even a top-level `ORDER BY x` returns ties in arbitrary order. The fix is `ORDER BY x, unique_id` (unique tiebreaker), NOT "add a LIMIT".
- **5-row DO-NOT-WRITE table**:
  1. "ORDER BY without LIMIT is stripped/ignored at the top level" → **FALSE** (top-level honored).
  2. "LIMIT makes ORDER BY actually execute" → **FALSE** (top-level sorts either way; LIMIT just enables TopN).
  3. "ORDER BY in a CTE is preserved by the outer query" → **FALSE** (dropped unless paired with LIMIT).
  4. "ORDER BY x guarantees deterministic order even when x has duplicates" → **FALSE** (ties are non-deterministic; add a unique tiebreaker).
  5. "INSERT INTO t SELECT ... ORDER BY x persists the row order" → **FALSE** (tables are unordered).
- **Cross-refs**: r07 ROWS-vs-RANGE tied-peers canonical (related but different scope: window frames within a partition, NOT top-level result-set order).

**Fix 2 — LOW (polish, optional) — direct MAP unnest form.** Add a one-line note adjacent to (or as a sibling of) the map-explode canonical that `CROSS JOIN UNNEST(map_column) AS t(k, v)` works directly without `map_entries(...)` wrapping. Two forms, both valid, one less hop.

**iter559 probe targets:**
- HIGHEST — top-level ORDER BY without LIMIT re-probe: "Does `SELECT * FROM t ORDER BY name` (no LIMIT) return sorted rows in Trino, or do I need to add a LIMIT?", "I have `ORDER BY x` in a CTE and the outer query gets random order — why?", "Are top-level ORDER BY and ORDER BY in a subquery treated the same way?"
- HIGHEST — tie non-determinism re-probe: "My report shows different row order each run even though I have ORDER BY date — what's wrong?"
- HIGH — Q1 + Q2 durability re-probes (different angles to confirm iter558 canonicals hold).
- MEDIUM — direct `UNNEST(map_col) AS t(k, v)` vs `UNNEST(map_entries(m))` re-probe.
- LOW — DO NOT TOUCH federation row stays 4.49944/310 + no edits to resources/22 §13.x.

---

## Topic average updates

- **Analytical query patterns on Iceberg+Trino** (Q3 ORDER BY determinism — r07 is natural host) 4.4123/22 → (4.4123·22 + 1.875)/23 = 99.95/23 = **4.3457/23** (-0.0666 — Q3 well below topic avg drags hard).
- **Lakehouse schema design** (Q1 r09 CAST JSON→typed + Q4 map UNNEST — both routed to r09) 4.5624/15 → (4.5624·15 + 4.875)/16 = 73.31/16 = 4.5819/16 → (4.5819·16 + 4.75)/17 = 78.06/17 = **4.5917/17** (+0.0293 — both above topic avg lift).
- **Improving complex SQL performance on Trino with dbt** (Q2 composite unique_key dedup — r28 hosts the iter558 canonical) 4.6764/18 → (4.6764·18 + 4.875)/19 = 89.05/19 = **4.6868/19** (+0.0104 — Q2 above topic avg lifts).
- **Federation NOT probed — 4.49944/310 row UNCHANGED** per iter472-557 directive + iter558 task constraint.

---

## Meta-rule observation
Directive's "verify YOUR OWN corrections + PIN TRINO 467 + watch for OVERSTATEMENTS" caveat was DECISIVE on Q3. The responder's framing of "ORDER BY without LIMIT is stripped/ignored" sounds plausible enough that without WebFetching trino.io/docs/467/sql/select.html VERBATIM, the judge could have either (a) believed it and scored HIGH (false positive — responder propagates falsehood to real SaaS engineers) or (b) overcorrected with a wrong "ORDER BY is always honored everywhere" rebuttal (false negative). The TRUTH from the docs is nuanced: TOP-LEVEL is honored, NESTED (subquery/CTE/INSERT/view) is dropped when redundant. 21st consecutive iter (iter537-558) where meta-rule prevented false-positive judgment.

---

## Notes
- Did NOT bump training/state.json (teacher already set iteration=558).
- Federation rubric row 4.49944/310 unchanged.
- Did NOT touch resources/22 §13.x.

**OVERALL: 4.09375 PASS — Q1 + Q2 + Q4 strong (4.75-4.875 each); Q3 1.875 HARD FAIL on top-level ORDER BY without LIMIT (responder OVERSTATED "stripped/ignored" — Trino docs say top-level is HONORED; only redundant nested ORDER BY is dropped). iter559 PRIMARY FIX = add ORDER BY determinism canonical in r07/r23 distinguishing top-level (honored) vs nested (dropped) vs tie non-determinism (add unique tiebreaker).**

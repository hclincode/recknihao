# Iter1301 Judge Feedback

## Iteration verdict

**Overall avg: 4.328 (PASS by overall threshold; 3 STRONG / 1 FAIL).**

| Q | Score | Verdict | Topic touched |
|---|---|---|---|
| Q1 (boolean / null-safe equality) | **4.875** | STRONG PASS | SQL query best practices for OLAP |
| Q2 (plain LEFT JOIN plan shows CROSS JOIN) | **2.8125** | **FAIL** (Q-level <3.5) | Improving complex SQL performance on Trino with dbt |
| Q3 (per-developer schema via env_var) | **4.6875** | STRONG PASS | Improving complex SQL performance on Trino with dbt |
| Q4 (Oracle LAG 3-arg default → Trino) | **4.9375** | STRONG PASS | Oracle PL/SQL → dbt+Trino migration |

iter1300 4.375 → iter1301 4.328: essentially flat. Q1/Q3/Q4 clean. Q2 is the single FAIL — root-cause off-target: engineer described a PLAIN LEFT JOIN (no subquery) plan rendering as `CrossJoin`, responder attributed it to LATERAL / decorrelation-failed `CorrelatedJoin`, which is a DIFFERENT plan node and a DIFFERENT scenario. The primary cause for "plain JOIN renders as CrossJoin" — a **non-equi (inequality/range/function-wrapped) ON predicate** that prevents hash-join — was not surfaced. Content gap CONFIRMED via grep: no findable "non-equi JOIN ON → CrossJoin + Filter" canonical anchored to r28's join section. LIGHT FIX-A recommended.

---

## Per-question

### Q1 — Boolean / null-safe equality (`is_active = 1` errors; null-safe compare; null-safe "different from") → **4.875 STRONG PASS**

Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75.

Responder: `is_active = 1` is a type error in Trino 467 (no implicit boolean ↔ integer coercion); use `WHERE is_active = true`, `WHERE is_active = false`, or `WHERE NOT is_active`. Null-safe equality = `IS NOT DISTINCT FROM`; null-safe "is A different from B" = `IS DISTINCT FROM`. Correctly contrasted `NULL = NULL → NULL` (three-valued logic) vs `NULL IS NOT DISTINCT FROM NULL → TRUE`.

**VERIFIED**:
- Trino 467 boolean is a distinct type with no integer coercion — `WHERE bool_col = 1` raises "Cannot apply operator: boolean = integer" at analyze time per [trino.io/docs/current/functions/comparison.html](https://trino.io/docs/current/functions/comparison.html) + [trino.io/docs/467/language/types.html](https://trino.io/docs/467/language/types.html).
- `IS NOT DISTINCT FROM` / `IS DISTINCT FROM` documented as null-safe comparison operators per [trino.io/docs/467/functions/comparison.html](https://trino.io/docs/467/functions/comparison.html): "These operators function the same as the equality operators, but treat null values as equal to each other."
- Resource alignment: r28 L1222 lists `IS NOT DISTINCT FROM` among supported equi-join predicates; r13/r17/r22/r23 all reference the operator. No imported-prior (no assumed-absence), no over-warning, no broken-secondary.

Minor Clar/Compl shaves: didn't surface that `IS NOT DISTINCT FROM` is also a valid equi-join key (DF participates per r28 L1222) — would have closed the loop for "I want to JOIN on nullable boolean columns." Non-load-bearing.

---

### Q2 — Unexpected CROSS JOIN in plan (plain LEFT JOIN, no subquery) → **2.8125 FAIL**

Acc 2.5 / Clar 3.5 / Prac 2.5 / Compl 2.75.

Responder attributed the plan-side `CrossJoin` to **(1)** LATERAL subquery correlation (`CROSS JOIN LATERAL` / `LEFT JOIN LATERAL ... ON true`) and **(2)** correlated-subquery decorrelation failure rendering a `CorrelatedJoin` nested-loop. Diagnostic guidance: `EXPLAIN (FORMAT TEXT)`; recognize `Join[INNER][BROADCAST/PARTITIONED]`, `CorrelatedJoin`, `RemoteExchange[REPLICATE/REPARTITION]`; then `EXPLAIN ANALYZE`.

**ROOT-CAUSE OFF-TARGET — CONFIRMED**:

The engineer's scenario is a **plain `LEFT JOIN` between two tables with no subquery**. The responder's framing is wrong on TWO points:

1. **LATERAL/correlated-subquery decorrelation doesn't apply here.** No subquery → no decorrelation step → no `CorrelatedJoin`. The responder is answering a different question (correlated subquery slowness, which is the r28 §2 canonical).

2. **`CorrelatedJoin` ≠ `CrossJoin` — they are distinct plan nodes.** `CorrelatedJoin` is the marker for failed decorrelation of a correlated subquery (r28 §2 "the smoking gun"). `CrossJoin` is the cartesian-product / nested-loop operator used when a JOIN's ON clause has NO usable equality predicate. The engineer literally said the plan shows a `CrossJoin` — that's a categorically different signal from `CorrelatedJoin`.

**Primary cause for "I wrote a plain LEFT JOIN and the plan shows CrossJoin" — VERIFIED**:

A `JOIN ... ON <pred>` whose `<pred>` cannot be reduced to at least one equi-key (i.e., is purely inequality / range / `BETWEEN` / `!=` / function-wrapped / type-mismatched) **cannot be hash-joined**. Trino plans it as `CrossJoin` (cartesian product) with the predicate as a downstream `Filter`. This is the nested-loop O(N×M) fallback.

VERIFIED via:
- [trino.io/episodes/9.html](https://trino.io/episodes/9.html): "In Trino, a hash-join is the common algorithm that is used to join tables" — hash-join requires equality. Non-equi predicates fall outside this fast path.
- [trinodb/trino PR #4994](https://github.com/trinodb/trino/pull/4994) + [PR #5276](https://github.com/trinodb/trino/pull/5276): nested-loop join operator (`NestedLoopJoinPagesBuilder`) handles "pure non-equi joins" and "outer joins with non-equi conditions." The plan-side rendering for these is the `CrossJoin` node.
- Background: "Join operations are not limited to equijoin criteria, and the Hash Join algorithm is not suitable for join conditions with inequality constraints." Non-equi → nested-loop → CrossJoin in plan.

**Concrete trigger shapes the responder did not surface**:

| Engineer's ON clause | Why hash-join can't fire | Plan |
|---|---|---|
| `ON e.account_id BETWEEN a.id_low AND a.id_high` | Range, not equality | `CrossJoin` + `Filter` |
| `ON e.acct_id > a.id` | Inequality | `CrossJoin` + `Filter` |
| `ON e.account_id != a.id` | Inequality | `CrossJoin` + `Filter` |
| `ON LOWER(e.acct) = a.id` | Function-wrap on join key prevents equi-key extraction | `CrossJoin` + `Filter` (or full scan + filter) |
| `ON e.acct_id = CAST(a.id AS varchar)` | Type-mismatch on join key disables hash-key extraction | `CrossJoin` + `Filter` |
| `ON 1 = 1` / forgotten ON | No predicate at all (already covered by r23 §4 single-line "you forgot a join condition") | `CrossJoin` |

**EXPLAIN diagnostic the responder should have given**:
1. Run `EXPLAIN (FORMAT TEXT)` and grep the JOIN node.
2. If the JOIN node prints as `CrossJoin` with a sibling/downstream `Filter[<the ON predicate>]`, the ON clause has no equi-key.
3. Re-read the ON clause: look for inequality (`<`, `>`, `!=`, `<>`), range (`BETWEEN`), function-wraps (`LOWER()`, `CAST()`, `date_trunc()`), or implicit type mismatches.
4. If at least one equi-key exists alongside non-equi predicates, rewrite as `ON e.k = a.k AND <range pred>` — Trino can then hash-join on `e.k = a.k` and apply the rest as a join filter (visible in EXPLAIN as `Join[<eq_key>][filter=...]`).

**Content gap — CONFIRMED via grep of `resources/`**:

- `resources/23-sql-best-practices-olap.md` §4 L2479 has only the single line `CrossJoin — you forgot a join condition. Almost always a bug.` — covers MISSING-ON only, not non-equi-ON.
- `resources/28-complex-sql-performance-trino-dbt.md` has rich `CorrelatedJoin` coverage (§2 — correlated subqueries, L15, L783–842, L1345) but no "plain JOIN ON non-equi predicate → CrossJoin" canonical.
- r28 L1220–1222 lists the supported DF predicates (`=, <, <=, >, >=, IS NOT DISTINCT FROM`) — useful for the DF angle but does not explain that inequality predicates as the SOLE join condition force the JOIN itself to a CrossJoin.

**Recommendation — LIGHT FIX-A**: add a short canonical card at r28 §2 (or a new §2a) and a sibling expansion of r23 §4 L2479. Suggested keyword anchors: *"plain JOIN plan shows CrossJoin", "wrote LEFT JOIN but EXPLAIN shows CrossJoin", "BETWEEN/inequality/range in ON clause", "JOIN on non-equality slow", "no equi-key in ON clause", "JOIN with `!=` Trino", "JOIN on function-wrapped key"*. The card should:
- State the rule: a JOIN whose ON predicate contains NO equality on at least one key cannot hash-join → planned as `CrossJoin` + `Filter` (O(N×M)).
- Show the 6-row trigger-shapes table above.
- Distinguish `CrossJoin` from `CorrelatedJoin` in one line (different plan nodes, different root causes — see §2 for `CorrelatedJoin`).
- Give the rewrite: add at least one equi-key (`ON e.k = a.k AND <range_pred>`); if no natural equality exists, materialize a bucket key (e.g., `date_trunc('day', ts)`) and equi-join on the bucket + filter for the exact range.

**NEW HARD WATCH `iter1301-Q2 non-equi-JOIN-ON renders as CrossJoin content gap`**: after LIGHT FIX-A landing, re-probe in 2-4 iters under varied "plain JOIN but plan shows CrossJoin" / "BETWEEN in ON makes the JOIN slow" / "JOIN on type-mismatched key" framings. Reach-test the new card; close watch on first clean hit.

No imported-prior. No over-warning. No fabrication. The misdirection is a topic-mixup, not a hallucination — the responder reached for r28 §2 (the most heavily-anchored "join is slow" canonical) when the question's plan-node signal pointed elsewhere.

---

### Q3 — Per-developer schema via `env_var('USER')` → **4.6875 STRONG PASS**

Acc 4.75 / Clar 4.5 / Prac 5.0 / Compl 4.5.

Responder: `profiles.yml` with two targets — `dev` schema `"dbt_{{ env_var('USER') }}"` (each developer gets `dbt_alice`, `dbt_bob` without manual `--target`) and `prod` schema `analytics`. `dbt run` → dev, `dbt run --target prod` → prod.

**VERIFIED** via [docs.getdbt.com/reference/dbt-jinja-functions/env_var](https://docs.getdbt.com/reference/dbt-jinja-functions/env_var) + [docs.getdbt.com/docs/core/connect-data-platform/connection-profiles](https://docs.getdbt.com/docs/core/connect-data-platform/connection-profiles): `env_var()` is supported inside `profiles.yml`; `$USER` is the conventional shell variable per-developer; quoting form `"dbt_{{ env_var('USER') }}"` is the canonical pattern. dbt-trino's `profiles.yml` schema property does accept Jinja expressions per dbt-trino docs.

Minor shaves:
- Compl: did not surface the alternative `target: dev` `dev_user: "{{ env_var('USER') }}"` + custom generate_schema_name macro pattern (the dbt-Labs "best practice for shared dev warehouse" route) — useful when developers need different *schemas* AND different *credentials*. Responder's simpler form works for the asked question.
- Clar: didn't explicitly say "set `USER` in CI/cron environments otherwise the schema collapses to `dbt_` (empty)" — material on a k8s/cron stack where `$USER` may be unset and `env_var()` will raise an error unless a default is supplied via `env_var('USER', 'ci')`. Recall-ceiling, not a content gap.

No imported-prior, no over-warning, no fabrication.

---

### Q4 — Oracle `LAG(order_total, 1, 0)` 3-arg default → Trino → **4.9375 STRONG PASS**

Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 4.75.

Responder: "Trino LAG supports the 3-arg default form: `LAG(column, offset, default) OVER (...)`. Direct Oracle equivalent: `LAG(order_total, 1, 0)`. First row in the partition → 0 default; subsequent rows → 1 row back. Offset must be positive integer constant. No COALESCE wrapper needed."

**VERIFIED** via [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html) (verbatim signature `lag(x[, offset[, default_value]])`): "If the offset refers to a row that is not within the partition, the `default_value` is returned, or if it is not specified `null` is returned." Trino 467 supports the 3-arg form natively. Matches pin **reference_trino_listagg_native** family (assumed-PRESENCE counter-signal — responder correctly identified the function as present, did NOT fall into the assumed-absence trap that has bitten 9 times: starts_with / to_char / listagg / array_sum / format_number / migrate / LATERAL / MERGE-WHEN-MATCHED-AND / truncate-1arg).

**POSITIVE COUNTER-SIGNAL** for iter1297-Q4 Oracle-false-premise-pattern watch: the responder DIRECTLY confirmed the 3-arg form exists and works identically to Oracle, refusing to hedge or suggest a COALESCE workaround. Same defensive-answering pattern as iter1300-Q4 (Oracle EXTRACT → Trino kept-as-is). Matches the pin family.

Minor Compl shave: didn't mention the GitHub edge case ([trinodb/trino #19003](https://github.com/trinodb/trino/issues/19003)) where LAG/LEAD don't return the default when the offset itself is NULL (rather than out-of-range) — extremely niche, non-load-bearing for the Oracle migration question.

No imported-prior, no over-warning, no broken-secondary, no fabrication.

---

## Cross-question patterns

- **Imported-prior assumed-absence family**: clean this iter. Q4 LAG 3-arg correctly confirmed PRESENT (positive counter-signal); no assumed-absence slip.
- **Responder broken-secondary alternative**: clean — no padded "for completeness" alternative on Q1/Q3/Q4.
- **Responder over-warning folklore**: clean — Q1 boolean-equality answer was direct, not folklore-hedged.
- **False-premise endorsement family** (iter1297/iter1299 watch): clean — no false premises asked this iter; Q4 LAG 3-arg correctly asserted.
- **Topic-mixup**: NEW pattern this iter (Q2). Responder reached for the wrong canonical (`CorrelatedJoin` r28 §2 = correlated-subquery slowness) when the engineer's signal (`CrossJoin` plan node + plain JOIN, no subquery) pointed at a different root cause (non-equi ON predicate). This is NOT assumed-absence and NOT a synthesis ceiling — it's a routing miss where the keyword "CROSS JOIN" matches CorrelatedJoin lexically (both contain "Join") but the plan node names are categorically different.

---

## Watches

### NEW

- **HARD `iter1301-Q2 non-equi-JOIN-ON renders as CrossJoin content gap`**: LIGHT FIX-A recommended at r28 §2 (or new §2a) + sibling expansion of r23 §4 L2479. Re-probe in 2-4 iters under "plain JOIN plan shows CrossJoin" / "BETWEEN in ON makes the JOIN slow" / "JOIN on type-mismatched key" framings. Close watch on first clean hit (FIX-A reaches).

### CARRY (un-probed)

- iter1300-Q2 spill-causality-flip + broadcast-threshold-raise-vs-lower (re-probe 3-6)
- iter1299-Q3 dbt `{{ this }}` `is_incremental()` guard reach-test
- iter1299-Q4 Oracle MOD sign-handling false-premise hedge (L1271 LIGHT FIX-A reach-test)
- iter1298-Q2 metadata-tables
- iter1297-Q4 Oracle-false-premise-endorsement (Q4-LAG-3-arg positive counter-signal this iter)
- iter1296-Q1 / iter1296-Q3 / iter1295-Q2 / iter1294-Q4 / iter1290-Q3 / iter1289-Q2 / iter1289-Q4

### CLOSED this iter

None.

---

## Rubric topic deltas

| Topic | Before | After | Delta |
|---|---|---|---|
| SQL query best practices for OLAP | 4.5912 / 311 | 4.5921 / 312 | +0.0009 |
| Improving complex SQL performance on Trino with dbt (Q2 + Q3, 2 datapoints) | 4.4381 / 96 | 4.4241 / 98 | -0.0140 |
| Oracle PL/SQL → dbt+Trino migration | 4.4933 / 274 | 4.4949 / 275 | +0.0016 |

All required topics remain PASSED. Margins remain comfortable (smallest = Query-performance-basics at +0.6364, not touched this iter).

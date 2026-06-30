# Judge Feedback — Iteration 1286

**Overall**: 4 questions, average **4.5625 STRONG PASS** (Q1 4.875 STRONG / Q2 4.3125 PASS / Q3 4.75 STRONG / Q4 4.3125 PASS).

**Headline**: Pure breadth round delivers 3 clean passes and 1 borderline-clean pass with **ONE MANDATORY FIX-A** that surfaces a leftover from iter1240's truncate-2-arg reconcile. Q4 cites "use truncate(x) 1-arg or truncate(x,d) 2-arg" — the 2-arg form does NOT exist on Trino 467 (per pinned `reference_trino_truncate_1arg_only`). Grep of r27 §4.4C shows the worked example (L1649-1684) and DO-NOT-WRITE were correctly reconciled at iter1240, BUT the **canonical mapping table row at L1638 still teaches "Trino 467 HAS the 2-arg `truncate(x, d)` overload"** in direct contradiction with the rest of its own section + L1707/L1712 cross-dialect-spillover table. Responder faithfully lifted the L1638 row = RESOURCE DEFECT, not pure responder slip. Same missed-sibling-reconcile pattern as iter1271 (bloom CREATE 467 vs 469 split across resources).

| Q | Topic | Score | Status | Verdict |
|---|---|---|---|---|
| Q1 approx_distinct error margin for DAU dashboard | SQL query best practices for OLAP | 4.875 | STRONG PASS | 2.3% std-error default + 68/95/99.7 std-dev bands + [0.0040625, 0.26] range all verified; customer-facing decision rule + validation procedure + tuning all present |
| Q2 Iceberg concurrent write conflicts (append + compact) | Iceberg table maintenance | 4.3125 | PASS | Optimistic concurrency / atomic snapshot swap CORRECT; `write.{delete,update,merge}.isolation-level` property names + `serializable`/`snapshot` values + `serializable` default CORRECT; `$properties` metadata query VALID on 467; "80% of production failures" is r26-sourced narrative not fabrication; "extra_properties may not affect runtime" caveat is r26-stated framing (faithful citation) |
| Q3 dbt --full-refresh on incremental | Improving complex SQL perf on Trino with dbt | 4.75 | STRONG PASS | drop+recreate from scratch / is_incremental()=False / WHERE delta skipped / when-to-use list all correct, dbt docs verified |
| Q4 Oracle NUMBER → Trino BIGINT/DECIMAL mapping | Oracle PL/SQL → dbt + Trino SQL migration | 4.3125 | PASS | NUMBER per-column heuristic SOUND; CAST→integer rounds half-up CORRECT; truncate(x) 1-arg CORRECT; **truncate(x,d) 2-arg presented as available on 467 → WRONG (RESOURCE DEFECT at r27 §4.4C L1638)** |

---

## Q1 — approx_distinct error margin for customer-facing DAU dashboard (4.875 STRONG PASS)

**Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75.**

All three load-bearing dialect facts source-verified against [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html):
1. **2.3% standard error default** — verbatim "This function should produce a standard error of 2.3%, which is the standard deviation of the (approximately normal) error distribution over all possible sets."
2. **Optional 2nd-arg max_standard_error param** — verbatim "The current implementation of this function requires that `e` be in the range of `[0.0040625, 0.26000]`."
3. **68/95/99.7 std-dev bands** — statistically correct application of the 1σ/2σ/3σ confidence intervals for a normal distribution (the docs explicitly call out the "approximately normal" error distribution, so the bands are valid; the responder turned a single 2.3% number into actionable ±error ranges).

Customer-facing decision rule ("COUNT(DISTINCT) if cohort <1M or customer-facing; approx_distinct for internal huge datasets") is sound practical guidance; the validation procedure (run both, compare 5-10 partitions, >3% deviation = investigate) is directly executable. Tuning range correct.

Minor Compl shave (-0.25): didn't mention HLL state-merging via `merge(cast(approx_set(user_id) as hyperloglog))` as the cross-partition cardinality combine pattern, useful for the 90-day rolling window case (precompute daily HLL sketches, merge across days). Non-load-bearing — the responder's answer is paste-and-run for the immediate Q.

No imported-prior, no broken-secondary, no over-warning, no fabrication.

---

## Q2 — Iceberg concurrent write conflicts: append + compact same table (4.3125 PASS)

**Acc 4.0 / Clar 4.25 / Prac 4.75 / Compl 4.25.**

**Iceberg optimistic-concurrency model CORRECT**: plan against snapshot N → write data files → atomic compare-and-swap on the current-snapshot pointer → loser retries against N+1 or fails. Standard Iceberg consistency semantics.

**Isolation-level property names + values CORRECT** (verified against [raw.githubusercontent.com/apache/iceberg/apache-iceberg-1.5.2/docs/docs/configuration.md](https://raw.githubusercontent.com/apache/iceberg/apache-iceberg-1.5.2/docs/docs/configuration.md)):
- `write.delete.isolation-level` — default `serializable`, valid values `serializable`/`snapshot`
- `write.update.isolation-level` — same
- `write.merge.isolation-level` — same

**$properties metadata query VALID on Trino 467** (verified via WebFetch of [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html)): `SELECT * FROM "test_table$properties"` with whole-token double-quote pair is the documented form. Filter `WHERE key LIKE 'write.%.isolation-level'` works.

**The "80% of production failures" figure is r26-SOURCED not fabricated** — grep of `resources/26-iceberg-concurrent-write-conflicts.md` L51 shows: "This is the scenario behind 80% of 'my MERGE keeps failing with `ValidationException: Found conflicting files`' production tickets." So the responder is faithfully citing a resource claim. Whether that figure is itself sourced inside r26 is a teacher concern, not a responder accuracy ding.

**The "set via Spark not Trino" + "Trino extra_properties may not affect runtime enforcement" caveat is r26-STATED framing**, not responder invention — grep shows r26 L119-121 verbatim teaches: `write.merge.isolation-level | (no Trino-native — use extra_properties or Spark) | serializable`, and L177-179 verbatim: "use `extra_properties` map OR Spark `SET TBLPROPERTIES` (Spark recommended for runtime effect)". So the responder is faithfully reflecting r26's intentional position. **Whether r26 is technically right that Trino's `extra_properties` doesn't take runtime effect on Iceberg isolation-level keys is a separate question** — Iceberg isolation-level properties are table-metadata-level properties read by the writer, and on a SPARK-writer workload (which is what Q2 describes — "two SPARK jobs"), the **Spark-side `SET TBLPROPERTIES` is indeed the canonical write path**, so for this Q's scenario the framing is workable. For a Trino-writer workload the framing would be more questionable.

**Acc shave (-1.0)**: the "extra_properties may not affect runtime enforcement" caveat is correct for a Spark-writer scenario but the responder didn't make that scope explicit — engineer could reasonably read it as "even setting the property at all is ineffective from Trino" which isn't true (Spark writers reading the same table-metadata property still see the new value regardless of who set it). One-line "for your Spark-writer setup, set via Spark `SET TBLPROPERTIES`" would have removed the ambiguity. Per `feedback_responder_over_warning_folklore` family — slight over-cautious framing.

**The two-fix routing is exactly right for the disjoint-partition case**: (1) `snapshot` isolation if writes are genuinely on different partitions, (2) serialize in scheduler if the same rows are genuinely contested. Trade-off (no-phantom-rows vs throughput) named correctly.

Minor Compl shave (-0.5): didn't surface `commit.retry.num-retries` / `commit.retry.min-wait-ms` / `commit.retry.max-wait-ms` tuning — relevant alternative path when the conflict is real but the retry budget is too tight (r26 L89 lists these as keyword anchors). Non-load-bearing for the disjoint-partition case the responder routed to, but the "or must we serialize?" framing in Q2 could have been partially deflected with "before serializing, raise retry count to 8".

No imported-prior, no broken-secondary, no fabrication. Cites r26.

---

## Q3 — dbt --full-refresh on incremental model (4.75 STRONG PASS)

**Acc 5.0 / Clar 4.75 / Prac 4.75 / Compl 4.5.**

All mechanics correct and verified against [docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models): "To force dbt to rebuild the entire incremental model from scratch, use the `--full-refresh` flag on the command line. This flag will cause dbt to drop the existing target table in the database before rebuilding it for all-time."

Responder cleanly stated:
- `is_incremental()` evaluates to `False` → the `WHERE` delta filter inside `{% if is_incremental() %}` block is skipped
- Entire table is DROPPED + recreated from scratch with ALL source data — NOT an append
- When to use: model-logic bug fix (recompute history), broken incremental (missed delta / dup rows), schema change, initial setup
- Normal incremental = only new rows = fast

This directly addresses + corrects the engineer's ambiguity ("drop+recreate OR reprocess all and append" — answer is the former, not the latter).

**iter1201 dbt --full-refresh mechanism slip family CLEAN here** — iter1201 responder wrongly framed --full-refresh as "MERGE INTO that touches every row" + "Iceberg snapshot isolation guarantees no mid-run breaks". This iter's responder gave the right mechanism (drop+CTAS) — no recurrence of the iter1201 slip.

Minor Compl shave (-0.5): didn't surface (a) `--full-refresh --select my_model+` to also full-refresh downstream incrementals, (b) the `full_refresh: false` config to PROTECT a specific model from accidental --full-refresh (real on-prem safety pattern for the engineer's case — if production has a "do not full-refresh" model where rebuild would be too expensive or where the source CDC retention is shorter than the model history). Both nuance not load-bearing.

No imported-prior, no broken-secondary, no over-warning, no fabrication.

---

## Q4 — Oracle NUMBER → Trino BIGINT/DECIMAL mapping (4.3125 PASS, with MANDATORY FIX-A)

**Acc 3.5 / Clar 4.75 / Prac 4.75 / Compl 4.25.**

**NUMBER per-column mapping heuristic SOUND**:
- `NUMBER` for id/counter → `bigint` (correct — exact integer up to 2^63)
- `NUMBER(18,2)` for money → `decimal(18,2)` — NEVER `double` (correct — IEEE-754 binary float doesn't represent decimal fractions exactly, well-known accounting hazard)
- `NUMBER` for computed float-result → `double` (correct — when scale is implicit and not money)
- `NUMBER(10,0)` → `bigint`/`integer` (correct — explicit-scale-0 integer)

**CAST(double/decimal AS integer) ROUNDS half-up CORRECT** per pinned `reference_trino_cast_to_integer_rounds`: 47.89 → 48 (not truncation). Resource-verified canonical.

**truncate(x) 1-arg CORRECT** per pinned `reference_trino_truncate_1arg_only` (verified this iter via [trino.io/docs/467/functions/math.html](https://trino.io/docs/467/functions/math.html)): only `truncate(x) → [same as input]` listed; drops fractional part toward zero.

**`truncate(x, d)` 2-arg PRESENTED AS AVAILABLE on Trino 467 → WRONG**. Per pinned `reference_trino_truncate_1arg_only` (iter1240): 2-arg `truncate(x, d)` decimal-places overload does NOT exist on Trino 467 (added post-467, ~471+). Verified verbatim this iter via WebFetch — only 1-arg signature listed in the 467 math docs. The correct 467 form for d-place truncation is `truncate(x * power(10, d)) / power(10, d)` (toward-zero, negative-safe).

**RESOURCE DEFECT confirmed** via grep of `resources/27-oracle-plsql-to-dbt-trino.md` §4.4C: the section has CONTRADICTORY content within itself:
- **L1638 canonical-mapping table row STILL TEACHES "Trino 467 HAS the 2-arg `truncate(x, d)` overload"** — WRONG, source of responder's slip
- L1649-1666 worked example correctly says "There is NO 2-arg truncate(n, d) on 467 (truncate is 1-arg ONLY)" — CORRECT
- L1668-1684 DO-NOT-WRITE callout correctly defangs 2-arg form — CORRECT
- L1712 cross-dialect-spillover table correctly says "1-arg only" — CORRECT

iter1240's in-place reconcile fixed the worked example + DO-NOT-WRITE + spillover table but **missed the L1638 mapping-table row**. Same **missed-sibling-reconcile within same section** pattern as:
- iter1271 (bloom CREATE 467 vs 469 — split across r17 §713/§1012 vs r03 §474/§469/§563)
- iter1194 (optimize-clears-position-deletes — split across r28 vs r13 L2862)
- iter1168 (iceberg.system.migrate native — split across r21 §78/141/147 vs r17 §231/912)

Per pinned `feedback_reconcile_dont_append.md` + `feedback_trace_recurring_folklore_to_resource_root_cause.md` — when an apparent responder slip recurs on a topic with a known reconcile history, grep the SAME section for any surviving wrong sibling rows.

### MANDATORY FIX-A (teacher next iter)

**Surgical edit at `resources/27-oracle-plsql-to-dbt-trino.md` §4.4C L1638**:

CURRENT (WRONG):
```
| `TRUNC(n, d)` where `n` is numeric, `d` is decimal places | Truncates `n` to `d` decimal places (drops digits beyond position `d`, toward zero) | **`truncate(n, d)`** — lowercase, 2-arg; truncates `n` to `d` decimal places (toward zero), same semantics as Oracle. Equivalent verbose form: `truncate(n * power(10, d)) / power(10, d)`. | Trino 467 **HAS the 2-arg `truncate(x, d)` overload** (`truncate(decimal(p,s), bigint) -> decimal(p,s)`) — only the Oracle **name** `TRUNC` is missing, not the 2-arg capability. Just write `truncate`, not `TRUNC`. |
```

REPLACE WITH:
```
| `TRUNC(n, d)` where `n` is numeric, `d` is decimal places | Truncates `n` to `d` decimal places (drops digits beyond position `d`, toward zero) | **`truncate(n * power(10, d)) / power(10, d)`** — Trino 467 `truncate` is **1-arg ONLY**; the 2-arg `truncate(x, d)` overload does NOT exist on 467 (added post-467, ~471+). Scale by `power(10, d)`, truncate, scale back — toward-zero, negative-safe. | Trino 467 has ONLY `truncate(x) -> [same as input]` (1-arg). Writing `truncate(price, 2)` on 467 errors with `Unexpected parameters (decimal, integer) for function truncate. Expected: truncate(double)`. Use `truncate(price * 100) / 100` for d=2. Do NOT use `FLOOR` (rounds toward −∞, wrong for negatives). See §4.4C worked example below + DO-NOT-WRITE matrix for details. Verified [trino.io/docs/467/functions/math.html](https://trino.io/docs/467/functions/math.html) (only 1-arg signature listed). |
```

**Rationale**: brings L1638 row into consistency with L1649-1684 (worked example + DO-NOT-WRITE) and L1712 (cross-dialect-spillover table), which are already correct per the iter1240 reconcile. This row is the keyword-magnet first entry of the table — engineer landing on §4.4C reads this row first and lifts "**`truncate(n, d)`** — lowercase, 2-arg" as the canonical form. Fixing the magnet row stops the leak.

**Watch**: NEW SOFT WATCH `iter1286-Q4 truncate-2-arg-on-467 r27 §4.4C L1638 reconcile FIX-A reach test` — re-probe Oracle `TRUNC(x, n)` numeric port framings within 3-5 iters; if regression recurs after the L1638 fix, escalate to LIGHT FIX-A grep-and-reconcile for any remaining "2-arg available" sibling claims across r07/r23/r28 (per resource-defect grep-all pattern).

Minor Compl shave (-0.75): didn't flag the bare `NUMBER` (no precision/scale) overflow risk — Oracle bare `NUMBER` is effectively `NUMBER(38)` (38 decimal digits, up to ~1.7×10^38), which is **larger than `bigint`'s 2^63 ceiling (~9.2×10^18)**. The "unknown → bigint" default in the responder's heuristic silently truncates / overflows on 19+ digit Oracle NUMBER values. Safer default for bare-NUMBER: `decimal(38, 0)` (preserves Oracle's effective max) or audit the column's actual max value first with `SELECT MAX(LENGTH(TO_CHAR(col))) FROM oracle_table`. Non-load-bearing for typical id/money/counter columns but matters for surrogate-key-hash columns and any unbounded NUMBER usage.

Clar 4.75 — per-column heuristic table is clean and easy to apply to 50+ col tables.

Prac 4.75 — direct mapping rules + the "money never double" warning + the systematic per-column approach are all actionable for the engineer's migration.

No imported-prior beyond the truncate-2-arg recurrence (which is RESOURCE-SOURCED not responder), no broken-secondary, no over-warning, no fabrication. Cites r27.

---

## Patterns, watches, FIX-As

### MANDATORY FIX-A this iter

**`r27 §4.4C L1638 mapping-table row reconcile`** — reverse "Trino 467 HAS the 2-arg `truncate(x, d)` overload" to "1-arg only, use `truncate(x * power(10, d)) / power(10, d)`". Brings L1638 into consistency with L1649-1684 worked example + DO-NOT-WRITE callout + L1712 spillover table (all already correct per iter1240). Exact surgical edit above. Missed-sibling-reconcile pattern matches iter1271 + iter1194 + iter1168.

### Watches

- **NEW SOFT WATCH `iter1286-Q4 truncate-2-arg L1638 reconcile FIX-A reach test`**: re-probe Oracle `TRUNC(x, n)` numeric port + "Trino truncate to d decimal places" framings within 3-5 iters; if regression recurs after L1638 fix, escalate.
- **NEW SOFT WATCH `iter1286-Q2 Iceberg isolation-level Spark-vs-Trino runtime-effect scope`**: re-probe Iceberg concurrent-write conflict framings where the writer is TRINO (not Spark) within 4-8 iters; check whether the responder still says "extra_properties may not affect runtime enforcement" without scoping to Spark-writer case. If recurs, marginal FIX-A at r26 L177-179 to add per-writer scoping clarity.
- **CARRY iter1278-Q1** Scheduled-vs-CPU-as-I/O-wait imprecision (route to Blocked time explicitly) — periodic re-probe.
- **CARRY iter1285-Q2** mixed-TIMESTAMP-types CAST-attaches-session-zone non-federation findability gap — open SOFT watch.
- **CARRY iter1283-Q4** strpos-3-arg-banned-myth recurrence — recall-ceiling acceptance, no further defang.

### Resource defect pattern summary

This is the **4th instance** in recent iters of `missed-sibling-reconcile within same section / across resources`:
1. iter1168 — migrate-is-native (r21 §78/141/147 + r17 §231/912 sibling missed)
2. iter1194 — optimize-clears-position-deletes (r28 + r13 L2862 sibling missed)
3. iter1271 — bloom CREATE 467 vs 469 (r17 §713/§1012 + r03 §474/§469/§563 split)
4. **iter1286 — truncate-2-arg on 467** (r27 §4.4C L1638 mapping-table row missed in the iter1240 reconcile that fixed L1649-1684 + L1712)

**Process pin for teacher**: when applying an in-place reconcile to a section, grep the ENTIRE section (including any mapping/canonical tables, leading callouts, keyword-anchor blocks) — NOT just the prose paragraphs where the canonical examples live. The first row of a canonical mapping table is the keyword-magnet and gets read first by the responder; fixing the worked example without fixing the magnet row leaks the wrong claim back out.

### Overall verdict

**4.5625 STRONG PASS** with one MANDATORY FIX-A scoped to a single 1-row surgical edit in r27. No new findability gaps. Three of four answers are clean strong/clean passes; Q4 PASS-with-defect is RESOURCE-sourced not responder-fault.

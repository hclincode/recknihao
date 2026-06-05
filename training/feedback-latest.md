# Judge Feedback — Iter 496

**Date**: 2026-06-06
**Phase**: extended
**Overall**: 4.8125 STRONG PASS (+1.3125 above 3.5 floor)
**Federation**: NOT PROBED — 4.49944/310 row UNCHANGED per iter472-496+ directive.

---

## TL;DR

- **Q1 GROUPING-bitmask fix LANDED — bulletproofed.** Responder mapped `CASE GROUPING(region, country, product_category) WHEN 0 / WHEN 1 / WHEN 3 / WHEN 7` for a 3-col ROLLUP, with 7 = 'Grand Total'. ZERO recurrence of the iter495 `WHEN 2 = 'Grand Total'` fab. The leading-canonical block teacher installed at r28 §LEADING CANONICAL (line ~318) pattern-matched verbatim on the 3-col re-probe. Also correctly stated 2/4/5/6 are unreachable in a 3-col ROLLUP. This is the **5th successful instance** of the leading-canonical-example bulletproofing strategy.
- **Q3 `max_recursion_depth` is NOT a fabrication.** WebSearch-verified against trino.io/docs/current/sql/select.html — `max_recursion_depth` IS a real Trino session property, **default 10**, tunable via `SET SESSION max_recursion_depth=N`. WITH RECURSIVE IS marked experimental in current Trino docs (verbatim: "this feature is experimental only. Proceed to use it only if you understand potential query failures and the impact of the recursion processing on your workload"). Both claims hold on Trino 467. The suspected-fab probe came back clean.
- **Q4 freshness `config:` placement is CORRECT for dbt 1.9+.** Per docs.getdbt.com/reference/resource-properties/freshness, `freshness` + `loaded_at_field` under `config:` is the canonical post-1.9 form; pre-1.9 top-level placement still parses but emits `PropertyMovedToConfigDeprecation`. `dbt source freshness` is the correct CLI and is NOT auto-run by `dbt run`/`dbt build`.
- **Zero new fabrications detected this iteration.** All four answers pattern-matched the recently-installed leading canonical blocks (r27 §6.7B for freshness, r27 §7A.1 for WITH RECURSIVE, r28 §LEADING CANONICAL for GROUPING bitmask).

---

## Per-question scoring

### Q1 — 3-col ROLLUP(region, country, product_category) with GROUPING() bitmask labels — **4.9375 STRONG PASS** (re-probe of iter495 fix)

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5.0 | Bitmask values 0/1/3/7 all correct; explicit MSB=leftmost rule; explicit note that 2/4/5/6 NEVER appear in 3-col ROLLUP — both match the trino.io/docs/current/sql/select.html quote "bits are assigned to the argument columns with the rightmost column being the least significant bit". Labels Detail/Country Subtotal/Region Subtotal/Grand Total are semantically sensible: WHEN 1 = product_category rolled up only → row aggregates across products within each (region, country) → that IS a country-level subtotal; WHEN 3 = country+product_category rolled up → row aggregates within each region → region-level subtotal. |
| Clarity | 4.75 | Walked through what each bit means before showing the CASE; copy-pasteable; rule "2^N-1 = grand total" inferable. |
| Actionability | 5.0 | Drop-in SQL block; engineer can run it as-is on Trino 467 + Iceberg. |
| Completeness | 5.0 | Covered the CASE mapping, the GROUP BY ROLLUP shape, the unreachable-values note, and the bit-significance rule. |

**Fix-landed flag**: YES — `WHEN 7 = 'Grand Total'` for the 3-col ROLLUP. The iter495 value-2-mislabel fab did NOT recur. This is the LOAD-BEARING confirmation the judge was asked to verify.

### Q2 — Iceberg time-travel by timestamp + finding available snapshots — **4.8125 STRONG PASS**

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5.0 | `FOR TIMESTAMP AS OF TIMESTAMP '2026-05-16 14:30:00 UTC'` is valid Trino 467 Iceberg-connector syntax (verified at trino.io/docs/current/connector/iceberg.html); `iceberg.analytics."orders$snapshots"` with the whole `table$snapshots` token inside one quote pair is the correct metadata-table form; selecting `snapshot_id / committed_at / operation / summary` matches the documented metadata-table columns; the "resolves to latest snapshot at-or-before" semantics are correct per Iceberg spec. |
| Clarity | 4.75 | Two ways spelled out (TIMESTAMP vs VERSION); engineer knows to query snapshots first to pick a target. |
| Actionability | 4.75 | Both queries copy-pasteable; explicit guidance on the quoting rule for metadata tables (common foot-gun). |
| Completeness | 4.75 | Covered both the time-travel query AND the snapshot-discovery query; could optionally have mentioned the 7-day snapshot retention floor (downstream of expire_snapshots) but that wasn't asked. |

### Q3 — Oracle CONNECT BY PRIOR → Trino WITH RECURSIVE — **4.75 STRONG PASS** (suspected-fab probe came back clean)

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 4.75 | WITH RECURSIVE structure (anchor `manager_id IS NULL` UNION ALL recursive JOIN on org_tree) is the correct Trino 467 shape — column aliases are correctly declared, single recursive reference, UNION ALL not UNION. Experimental flag claim is **VERIFIED** at trino.io/docs/current/sql/select.html (verbatim: "this feature is experimental only. Proceed to use it only if you understand potential query failures and the impact of the recursion processing on your workload"). `max_recursion_depth` session property is **VERIFIED REAL**, default **10**, tunable via `SET SESSION max_recursion_depth=N` (and via `WITH SESSION` clause on a single SELECT). The pre-hook variant `pre_hook="SET SESSION max_recursion_depth=100"` for dbt is correct. -0.25 because the answer didn't surface that plan size grows **quadratically** with recursion depth (the trino.io docs warn this explicitly) and didn't mention the option to use `WITH SESSION max_recursion_depth=N` on a single query when the session-wide property is undesirable. |
| Clarity | 4.75 | Walked Oracle engineer through the syntactic translation; explained why a closure-table materialization is the production-grade alternative for deep trees. |
| Actionability | 4.75 | Drop-in SQL + dbt pre-hook + escape-hatch (materialized closure-table model). |
| Completeness | 4.75 | Covered translation, depth bound, dbt integration, production escape hatch. Could add the quadratic-plan-growth warning verbatim. |

**Fabrication probe outcome**: NO FAB. The judge's prior `max_recursive_iterations` hypothesis was the wrong correction — Trino's actual property IS `max_recursion_depth` (default 10). The leading-canonical block at r27 §7A.1 cited the source correctly.

### Q4 — dbt source freshness on Postgres upstream — **4.75 STRONG PASS**

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5.0 | `freshness: {warn_after, error_after}` + `loaded_at_field` UNDER a `config:` block IS the canonical dbt 1.9+ placement (verified at docs.getdbt.com/reference/resource-properties/freshness — pre-1.9 top-level form is deprecated and emits `PropertyMovedToConfigDeprecation`). `dbt source freshness` is the correct CLI. The claim that freshness does NOT auto-block downstream models in `dbt run`/`dbt build` is CORRECT (verified at docs.getdbt.com/docs/deploy/source-freshness — freshness is a separate command, NOT included in `dbt build`); the recommended gate (`dbt source freshness` as its own CI stage, exit-code-driven) is the correct operational pattern. |
| Clarity | 4.75 | Engineer can see exactly which YAML keys go where, which command runs the check, and what happens if a source is stale. |
| Actionability | 4.5 | Copy-pasteable YAML, copy-pasteable CLI, copy-pasteable CI step. Could optionally have shown the `filter:` knob for scoping `MAX(loaded_at_field)` to a recent partition (useful on large tables) but that's enhancement, not gap. |
| Completeness | 4.75 | Declaration shape + CLI + downstream behavior + CI gating all covered. |

---

## Overall

`(4.9375 + 4.8125 + 4.75 + 4.75) / 4 = 19.25 / 4 = 4.8125`

**Verdict: STRONG PASS (95th consecutive overall PASS in extended phase). Margin +1.3125 above 3.5 floor. Highest overall since iter493 (4.7813) and iter400 (4.59).**

---

## Topic-row updates (append-to-history math)

- **Improving complex SQL performance on Trino with dbt** (Q1 GROUPING re-probe maps here): 4.5964/7 → (4.5964*7 + 4.9375)/8 = (32.1748 + 4.9375)/8 = 37.1123/8 = **4.6390/8** (+0.0426 — recoups the iter495 -0.1511 drag from the GROUPING bug; the leading-canonical block did its job).
- **Iceberg table maintenance** (Q2 time-travel maps here — snapshot discovery/time-travel is the maintenance-domain subtopic): 4.4896/147 → (4.4896*147 + 4.8125)/148 = (660.1712 + 4.8125)/148 = 664.9837/148 = **4.4931/148** (+0.0035).
- **Oracle PL/SQL → dbt + Trino migration** (Q3 CONNECT BY translation maps here): 4.5175/67 → (4.5175*67 + 4.75)/68 = (302.6725 + 4.75)/68 = 307.4225/68 = **4.5209/68** (+0.0034).
- **dbt sources / source freshness** (Q4 maps here directly): 4.219/3 → (4.219*3 + 4.75)/4 = (12.657 + 4.75)/4 = 17.407/4 = **4.3518/4** (+0.1328 — meaningful bump on a low-sample-count row; topic now has 4 data points).

Federation: **4.49944/310 UNCHANGED** per iter472-496+ directive — NOT PROBED this iteration.

---

## What landed and what to keep probing

### Confirmed-landed canonical blocks (do not regress)

1. **r28 §LEADING CANONICAL — GROUPING SETS / ROLLUP / CUBE with the GROUPING() bitmask** (installed iter496, line ~318). 3-col ROLLUP confirmed today. **Next probe: 2-col ROLLUP re-probe (the original iter495 phrasing) to confirm the WHEN 3 = grand total mapping ALSO holds when the question shape matches the iter495 trigger.**
2. **r27 §7A.1 — CONNECT BY → WITH RECURSIVE with experimental + depth + quadratic-plan caveats** (installed earlier). Confirmed today on org-chart phrasing.
3. **r27 §6.7B LEADING CANONICAL — dbt source freshness** (installed earlier). Confirmed today on Postgres-source phrasing. **`config:` placement holds.**

### Open guardrails (keep untouched)

- **r22 §13.x federation guardrails** (lines 8691 + 8793): ROLLUP/CUBE/GROUPING SETS do NOT push down to PostgreSQL via JDBC. Untouched.
- **Federation rubric row 4.49944/310**: not probed; do not back-fill.
- **r07 §5 Pattern B2 YoY canonical**, **r27 §4.1A DECODE-NULL canonical**, **r28 LEADING CANONICAL dbt-trino partitioning canonical** all untouched and holding from prior iterations.

---

## Next-iter (iter497) judge probe targets

To keep accumulating data-points on the leading-canonical blocks that have only had ONE successful probe each:

1. **GROUPING bitmask — 4-col ROLLUP** (e.g., `ROLLUP(region, country, store, product_category)` with labels) — probe whether the responder generalizes the 2^N-1 grand-total value (15) without seeing it explicitly enumerated in the canonical block. If it errors, the canonical block needs an N-col table extension.
2. **GROUPING bitmask — CUBE vs ROLLUP differentiation** — probe a `CUBE(region, category)` question; the canonical block §(e) says value 2 IS valid under CUBE. Confirm responder doesn't blanket-apply the ROLLUP "value 2 never appears" rule to CUBE.
3. **WITH RECURSIVE — second angle** — bill-of-materials hierarchy or category tree (different domain, same recursion shape) to confirm the `max_recursion_depth=10` + experimental notes route from non-org-chart phrasing.
4. **dbt source freshness — third angle** — probe the `filter:` knob (scope `MAX(loaded_at_field)` to a partition) and/or the per-table override + `freshness: null` opt-out semantics. r27 §6.7B documents both but they're untested.
5. **Federation**: still NOT probed per the standing directive.

---

## Teacher actions for iter497

**No mandatory teacher work this iteration — all four answers were STRONG PASS with zero fabrications.** Optional polish:

1. **r27 §7A.1 minor enhancement (LOW priority)**: add a one-line callout that plan size grows **quadratically** with `max_recursion_depth` (current text says "do not set unboundedly high — runaway recursion will OOM a worker" which is correct but less precise than the docs' quadratic-growth warning). Verbatim Trino doc text: "the size of the query plan growth is quadratic with the recursion depth".
2. **r28 §LEADING CANONICAL §(b) bitmask table (LOW priority)**: extend the table with a 4-col ROLLUP row (values 0/1/3/7/15) so iter497 probe target #1 has a direct lookup, and inline the general rule "for N-col ROLLUP, grand total = 2^N - 1, with N+1 total emitted groupings".
3. **r27 §6.7B (LOW priority)**: nothing missing — block is complete and pattern-matched today.

**Do NOT touch**: r22 §13.x federation guardrails; federation rubric row; r07 §5 Pattern B2; r27 §4.1A DECODE-NULL canonical; r28 LEADING CANONICAL dbt-trino partitioning block.

---

## State.json directive

Per the user instruction: **DO NOT bump state.json** — teacher set it to 496; leave `iteration: 496`, `phase: "extended"`, `passed: true` as-is.

# Judge Feedback — Iter 545

**Overall: 4.0625 PASS** (≥3.5 floor) — but a CRITICAL Q1 fab-absence (1.875) dragged the avg down despite three strong PASSes. **The iter545 teacher's r09 L609 map_concat block + r23 §3.1D arbitrary/any_value/max_by/min_by canonical landed for Q2/Q3 — but did NOT land for Q1.** Q1 is a regenerative FAB-ABSENCE: the responder denied a real, built-in Trino function (`map_concat`) AND failed to reach the just-added L609 block — base-training "I don't know any merge-maps function" pattern overrode the resource.

---

## Per-question scores

### Q1 — Merge default + tenant maps in a single Trino expression — **1.875 / 5 FAIL** (FAB-ABSENCE — worst failure class)

| Dim | Score | Justification |
|---|---|---|
| Accuracy | 1.5 | Responder said *"Without a built-in `map_concat` in Trino 467, you'd likely need to..."* — **map_concat IS a real, built-in Trino function**. Trino docs verbatim ([trino.io/docs/current/functions/map.html](https://trino.io/docs/current/functions/map.html)): `map_concat(map1(K, V), map2(K, V), ..., mapN(K, V)) -> map(K, V)` — *"Returns the union of all the given maps. If a key is found in multiple given maps, that key's value in the resulting map comes from the last one of those maps."* The RIGHTMOST map wins — `map_concat(default_settings, tenant_overrides)` is the exact one-call answer. Hedged ("This is a gap in my resources") but the fab-absence claim itself is incorrect, AND the suggested workarounds (chain map HOFs / `map_from_entries`) waste engineer effort. |
| Completeness | 1.5 | No working answer — engineer cannot copy/paste anything. |
| Clarity | 3.0 | Prose is readable and the hedge is honest in tone, but it points the engineer at the wrong workarounds. |
| Actionability | 1.5 | Suggested `map_from_entries` chains / HOF combinations require non-trivial effort and produce wrong shape; the actual answer is one function call. |

**FAB-ABSENCE diagnosis.** GREP confirms `resources/09-lakehouse-schema-design.md` L609 contains the iter545 teacher's map_concat canonical block (verified verbatim): the block is labeled *"Merge two (or more) maps with `map_concat` — RIGHTMOST map's value wins on key collision"*, has keyword anchors *map_concat Trino, merge two maps, combine maps with override, default settings override map, rightmost map wins, map union, overlay tenant overrides onto defaults*, includes the verbatim signature + duplicate-key quote + a worked SaaS example `map_concat(default_settings, tenant_overrides)` — exactly the Q1 example. **The block exists and is keyword-perfect for Q1's phrasing.** Yet the responder regenerated "no built-in" from base training rather than reaching it.

Findability verdict: **mid-file burial in a long MAP subsection.** The block at L609 sits between (a) the iter532 `COALESCE(element_at(...), <default>)` blockquote at L607 and (b) the LEADING CANONICAL header for the MAP-HOF family at L611. Both neighbors are headed `### LEADING CANONICAL — ...` H3s. The map_concat block is a **`>` blockquote**, not an H3 — the responder's keyword-zone scan skipped right over it to the LEADING CANONICAL H3 below (the MAP-HOF family), which doesn't mention `map_concat`, and from there regenerated "no merge function exists". **Salience problem, not anchor problem** — the keyword anchors ARE present in the blockquote, but they sit inside body text under a non-headline element.

### Q2 — `arbitrary(user_name)` / `any_value(user_name)` for constant-per-group columns — **4.875 / 5 WIN**

| Dim | Score | Justification |
|---|---|---|
| Accuracy | 5.0 | Verbatim match to Trino docs ([trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html)): *"Returns an arbitrary non-null value of `x`, if one exists. Identical to `any_value()`."* Responder correctly stated they are aliases. Correctly flagged the "only valid when constant per group" constraint. |
| Completeness | 4.75 | Cited r23 §3.1D anchor; covered both names + the alias relationship + the constant-per-group caveat. Could mention NULL-skipping behavior explicitly. |
| Clarity | 4.75 | Clean one-call answer, plain language. |
| Actionability | 5.0 | Engineer can paste `arbitrary(user_name) AS user_name` (or `any_value(user_name)`) directly into the GROUP BY query. |

**iter544 Q3 gap CLOSED.** r23 §3.1D landed on first re-probe — durability check passed.

### Q3 — `max_by(status, event_time)` for latest-by-timestamp — **4.875 / 5 WIN**

| Dim | Score | Justification |
|---|---|---|
| Accuracy | 5.0 | Verbatim match to Trino docs ([trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html)): *"Returns the value of `x` associated with the maximum value of `y` over all input values."* Correctly noted `min_by` for earliest, and the tie-breaker idiom `max_by(status, (event_time, event_id))` mirrors r23 §3.1D L380. |
| Completeness | 4.75 | Cited r23 §3.1D; covered max_by + min_by + tie-breaker. Could mention 3-arg `max_by(x, y, n)` top-N variant but that's bonus. |
| Clarity | 4.75 | Direct one-call alternative to window+ROW_NUMBER subquery; correctly contrasted as "cleaner than window/subquery". |
| Actionability | 5.0 | Pasteable: `SELECT user_id, max_by(status, event_time) AS latest_status FROM events GROUP BY user_id`. |

**Pre-emptive coverage CONFIRMED.** r23 §3.1D's max_by/min_by subsection landed cleanly — paired aggregate-family canonical works.

### Q4 — dbt seeds (what, when vs real table, production gotchas) — **4.625 / 5 PASS**

| Dim | Score | Justification |
|---|---|---|
| Accuracy | 4.5 | CSV in `seeds/` directory: verified at [docs.getdbt.com/docs/build/seeds](https://docs.getdbt.com/docs/build/seeds) — default dir is `seeds/` (configurable via `seed-paths`). The dbt 1.0+ rename from `data/` to `seeds/` is correct. `+column_types` config: verified — used to override inferred datatypes (canonical use case: preserving leading zeros in zip codes / phone numbers). `dbt seed` vs `dbt build`: `dbt build` runs seeds + snapshots + models + tests + sources in DAG order; `dbt run` SKIPS seeds — correct distinction. `dbt seed` truncates+reinserts; column changes need `--full-refresh` for DROP CASCADE rebuild — correct. |
| Completeness | 4.5 | Covered the four asked angles (what, when vs source/ingest table, production gotchas including row-cap, sensitive-data anti-pattern, source-control discipline). Slight gap: did not explicitly call out the `quote_columns` config (which trips up CSVs with commas inside string values) — minor. |
| Clarity | 4.75 | Seed-vs-source-vs-ingest-table comparison table well-shaped for a SaaS engineer with no dbt background. |
| Actionability | 4.75 | Engineer knows: put CSV in `seeds/`, run `dbt seed` or `dbt build`, configure `+column_types` in `dbt_project.yml`, keep size small, don't use for sensitive data. |

---

## Overall

**Avg = (1.875 + 4.875 + 4.875 + 4.625) / 4 = 16.25 / 4 = 4.0625 → PASS** (≥3.5 floor, margin +0.5625 above floor — MID, dragged by Q1).

- **140th consecutive PASS in extended phase.**
- **Q2 + Q3 WINS confirm iter545 paired aggregate-family canonical (r23 §3.1D) landed** — gap closed on first re-probe.
- **Q1 FAB-ABSENCE = the iter545 map_concat block at r09 L609 did NOT land** despite keyword-perfect anchors. The block IS present and the content is exact, but it sits as a `>` blockquote sandwiched between two LEADING CANONICAL H3 headers — the responder's keyword scan skipped past it.

---

## iter546 PRIMARY FIX — escalate map_concat to LEADING CANONICAL H3 at the TOP of the MAP keyword zone

This is a **findability/salience** failure, not a content failure. The body text is correct — the position and the element type are wrong.

### Specific edit (RECONCILE-DON'T-APPEND)

**REMOVE** the current `>` blockquote at `resources/09-lakehouse-schema-design.md` L609 (the iter545 map_concat block).

**INSERT** as a new `### LEADING CANONICAL — Merge two MAPs in Trino with map_concat — RIGHTMOST map wins on key collision (overlay tenant overrides on defaults)` H3 — positioned **immediately AFTER L545 `### CRITICAL — use element_at(), NOT [], for MAP access in Trino`** (i.e., promote it from L609 → ~L546 — the FIRST MAP-function the responder hits when scanning the MAP keyword zone, ABOVE the existence-check subsection, ABOVE the COALESCE-default blockquote, ABOVE the MAP-HOF family). The element_at canonical established the responder's "I am now in the MAP function zone" state; map_concat should be the first LEADING CANONICAL it sees after that header.

### Required content (preserve all of the iter545 substance — re-shape as an H3 LEADING CANONICAL, not a blockquote)

1. **Top-line "merge maps" keyword anchor block** repeated verbatim from the iter545 blockquote (map_concat Trino, merge two maps, combine maps with override, default settings override map, rightmost map wins, map union, union of maps Trino, merge MAP columns, overlay tenant overrides onto defaults, **"merge two MAP columns"** [the exact phrase from Q1 angle 1], **"single Trino expression to merge maps"** [Q1 phrasing], **"how do I combine multiple MAPs into one"** [Q1 angle 2 phrasing]).

2. **One-line rule callout** in **bold** at the top: *"To merge two MAP columns where one map's values should override the other's on key collision, use `map_concat(base_map, override_map)` — the RIGHTMOST map's value wins per key, so put the OVERRIDE map LAST."*

3. **Signature + verbatim duplicate-key quote** (preserve verbatim from iter545):
   - Signature: `map_concat(map1(K, V), map2(K, V), ..., mapN(K, V)) -> map(K, V)`
   - Quote: *"If a key is found in multiple given maps, that key's value in the resulting map comes from the last one of those maps."* — [trino.io/docs/current/functions/map.html](https://trino.io/docs/current/functions/map.html)

4. **Worked SaaS example** (preserve verbatim from iter545):
   ```sql
   SELECT tenant_id,
          map_concat(default_settings, tenant_overrides) AS effective_settings
   FROM iceberg.analytics.tenant_config;
   -- keys present in tenant_overrides override the corresponding default_settings values;
   -- keys present ONLY in default_settings survive unchanged.
   ```

5. **DO-NOT-WRITE table** (preserve all four from iter545 + ADD two new rows):
   - `||` is NOT map_concat (string/array operator only)
   - "LEFT wins on key collision" is FALSE — RIGHTMOST wins
   - CASE WHEN ladder over keys is wrong shape
   - **NEW DO-NOT-WRITE row** addressing the exact workaround the responder regenerated on Q1: *"Use `map_from_entries(map_entries(m1) || map_entries(m2))` to merge two maps."* → **WRONG SHAPE / WRONG TOOL** — `map_concat` is the one-call documented form; the array-chain rewrite is verbose and harder to read.
   - **NEW DO-NOT-WRITE row** addressing the other MAP-HOF rewrite the responder hinted at: *"Use `transform_values(m1, (k, v) -> COALESCE(element_at(m2, k), v))` to overlay a second map."* → **WRONG SHAPE** — this only updates keys that exist in `m1`; keys ONLY in `m2` are DROPPED. `map_concat(m1, m2)` keeps the union. This is the exact silent-bug the workaround introduces.

6. **Cross-refs** (preserve verbatim from iter545) — point downward to the COALESCE-default callout, the MAP-HOF family LEADING CANONICAL, and the CAST-to-JSON LEADING CANONICAL. State **"For full-map merge with override, this is the canonical — the MAP-HOF family below is for per-entry FILTER / TRANSFORM, not full-map merge."**

7. **At the top of the existing MAP section** (around L533 `### MAP access — Parquet-native, NOT JSON parsing`), add a one-line **navigation hint**: *"To merge two MAPs with override semantics, see `map_concat` LEADING CANONICAL below."* This routes the responder there when its keyword scan opens at the section header.

### Why this fix (per iter491 base-training-habit-fab playbook)

- **Top-of-keyword-zone**: moving from L609 (mid-section, below COALESCE-default) → L~546 (immediately after the element_at intro) puts map_concat at the FIRST LEADING CANONICAL the responder encounters when "merge two maps" keywords route into r09's MAP zone.
- **H3 LEADING CANONICAL element, not `>` blockquote**: matches the salience pattern the responder demonstrably homes in on (it FOUND the MAP-HOF LEADING CANONICAL at L611 — it just kept walking past the blockquote at L609 to get there). Same element type = same gravitational pull.
- **Exact Q1-phrasing anchors in the keyword block**: "merge two MAP columns", "single Trino expression to merge maps", "how do I combine multiple MAPs into one" — these are the verbatim words the saas-engineer used. Routing requires lexical overlap.
- **DO-NOT-WRITE rows that negate the EXACT regenerated workaround**: `map_from_entries` chain + `transform_values + COALESCE + element_at` chain. These are the two patterns the responder hinted at on Q1 — closing them off directly prevents the same regeneration on the next probe.

---

## iter546 secondary — durability holds

- **r23 §3.1D arbitrary/any_value/max_by/min_by**: HOLD verbatim. Two STRONG PASSes this iteration; do NOT rewrite. RECONCILE-DON'T-APPEND only if a future failure surfaces.
- **r07 L752-767 ROWS-vs-RANGE worked table**: not probed this iter (iter544 PASS holds). Hold.
- **r13 L5446-5459 on_schema_change**: not probed this iter (iter544 PASS holds). Hold.
- **dbt seeds** (Q4): no dedicated canonical exists; responder pieced it together correctly from base training + general dbt knowledge. Consider adding a brief r26 / r27 `dbt seeds` callout (CSV in `seeds/`, `+column_types`, `dbt seed` vs `dbt build`, full truncate+reload, gotchas) ONLY IF a future probe slips — Q4 4.625 says base training is currently sufficient.

---

## iter546 probe targets

- **HIGH — map_concat 3rd angle (verifies iter546 LEADING CANONICAL escalation landed)**: *"Single Trino call to combine multiple feature-flag maps where later maps override earlier ones?"* OR *"Which Trino function gives me the union of two MAP columns with rightmost-wins on duplicate keys?"* (must answer `map_concat(map1, map2, ..., mapN)` + rightmost-wins; must NOT fab-absence; must NOT regenerate `map_from_entries` chain).
- **MEDIUM — arbitrary/any_value 3rd angle (durability on Q2 WIN)**: *"Is there a Trino aggregate that's cheaper than MAX() when I just need any non-null value per group?"* (must answer `arbitrary` / `any_value` + non-determinism caveat + functional-dependency motivation).
- **MEDIUM — max_by 2nd angle (durability on Q3 WIN, beyond the latest-status example)**: *"How do I get the highest-revenue product per category in one aggregate?"* (must answer `max_by(product_id, revenue)` + 3-arg top-N variant).
- **LOW — dbt seeds 2nd angle (durability check on Q4 PASS)**: *"If my seed CSV has 50k rows and I run `dbt seed` every CI run, what breaks first?"* (must answer: SQL-INSERT round trips become slow, this is the row-cap gotcha; large seeds should be ingest tables via Spark, not seeds).
- federation stays UNPROBED (LOW — row stays 4.49944/310).

---

## Meta-rule check

- Verified iter546 map_concat fix BEFORE asserting (WebFetch trino.io/docs/current/functions/map.html — duplicate-key quote verbatim; signature verbatim; rightmost-wins behavior confirmed).
- Verified Q2 / Q3 doc match BEFORE assigning WIN scores (WebFetch trino.io/docs/current/functions/aggregate.html — `arbitrary` / `any_value` / `max_by` / `min_by` verbatim).
- Verified Q4 dbt seeds at docs.getdbt.com/docs/build/seeds — seeds/ dir, `+column_types`, `dbt seed` vs `dbt build`, truncate+reload behavior all confirmed.
- Verified the iter545 teacher's L609 map_concat block IS present in r09 with the correct content via Grep + Read — confirmed it's a salience/placement failure (mid-file `>` blockquote sandwiched between H3 LEADING CANONICAL siblings), not a content failure.

9th consecutive iter (iter537-545) where the meta-rule prevented false-positive correction in either direction.

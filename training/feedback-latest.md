# Iter1213 Judge Feedback — PASS (4.03 avg) + LIGHT FIX-A on Q3 (dbt-trino session_properties canonical + Option C catalog-property fabrication defang); Q4 inverted (+)-mnemonic SOFT WATCH

**Overall verdict**: **PASS**, avg **4.0313** (16.125/4), **LIGHT FIX-A on Q3**. Q1/Q2 STRONG PASS pin-perfect. Q3 has a real **fabrication** (Option C `iceberg.query_max_memory_per_node=8GB` in `etc/catalog/iceberg.properties` — not a valid Trino config form) **plus a critical omission** (the canonical dbt-trino-native `session_properties:` block in `profiles.yml` is the cleanest answer to the engineer's literal "apply once before all models" ask and resources/ has ZERO hits for it). Q4 mapping-table examples correct but appended prose mnemonic "the `(+)` always appears on the table you want to keep the unmatched rows from" is **INVERTED** — Oracle `(+)` marks the OPTIONAL/null-padded side; you keep ALL rows from the side **without** `(+)`. Mnemonic not resource-sourced, classified as responder per-instance slip + SOFT WATCH (NOT a r27 reconcile — over-attractor risk per `feedback_new_card_over_attracts_adjacent`).

| Q | Topic | Score | Verdict |
|---|---|---|---|
| Q1 | Iceberg table maintenance (`$files` + `$snapshots` measurement + `expire_snapshots(retention_threshold=>'7d')` + `remove_orphan_files`) | 4.625 | STRONG PASS (minor reader-safety nuance shave) |
| Q2 | Analytical query patterns on Iceberg+Trino (per-user MIN trial_start CTE + time-windowed INNER JOINs) | 4.625 | STRONG PASS (minor `pct_step1_users`-is-actually-COUNT column-label slip) |
| Q3 | Improving complex SQL perf on Trino with dbt (on-run-start vs pre_hook connection scope + session vars) | 3.25 | PASS + LIGHT FIX-A (Option C fabrication + missed `session_properties` canonical) |
| Q4 | Oracle PL/SQL → dbt+Trino SQL migration (`(+)` outer join rewrite to LEFT/RIGHT JOIN) | 3.625 | PASS (mapping table correct, INVERTED prose mnemonic — SOFT WATCH) |

---

## Q1 — Iceberg `$snapshots`/`$files` measurement + `expire_snapshots(retention_threshold=>'7d')` + `remove_orphan_files` + reader safety — 4.625 STRONG PASS

**Verified against [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html)** (WebFetch this iter):

### Measurement metadata tables — both verified

- **`$snapshots` columns**: docs confirm verbatim `committed_at` ("The time when the snapshot became active"), `operation` ("The type of operation performed on the Iceberg table"), `summary` ("A summary of the changes made from the previous snapshot"). Responder named all three correctly.
- **`$files` content column**: docs confirm verbatim "Type of content stored in the file. The supported content types in Iceberg are: DATA(0), POSITION_DELETES(1), EQUALITY_DELETES(2)". Responder named exact mapping (0=DATA, 1=POSITION_DELETES, 2=EQUALITY_DELETES) and column `file_size_in_bytes` — both correct.

### Reclamation procedures — both verified

- **`ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold=>'7d')`**: correct 467 form per docs. Note responder pragmatically chose `7d` — happens to clear the documented `iceberg.expire-snapshots.min-retention` 7d default floor (verified at [trinodb/trino#19096](https://github.com/trinodb/trino/issues/19096) "Retention specified (1.00d) is shorter than the minimum retention configured in the system (7.00d)"). No floor-collision hazard.
- **`ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold=>'7d')`**: correct 467 form per docs.

### Reader-safety claim — mostly correct, pragmatic nuance

Responder said "files referenced by newer snapshots / currently-running queries stay safe". For long-running queries:
- Iceberg + Trino reads pin a snapshot at query-start; physical files referenced by that pinned snapshot stay on MinIO until that snapshot is unreferenced.
- If the long-running query started **within** `retention_threshold` (7d here), its pinned snapshot is **retained**, so files survive — safe.
- **Edge case** (not flagged): if a query has been running **longer than 7d** (rare in practice, but possible for batch backfills), its pinned snapshot CAN be expired and Trino may surface `Cannot find snapshot` mid-scan. For a "long-running query" that's still within hours-to-a-day, the responder's framing is fine. The pragmatic answer is correct for the engineer's stated SaaS use.

**Soft Compl shave (-0.375)**: `iceberg.expire-snapshots.min-retention` 7d floor not explicitly named as the "why-can't-I-set-1d" guard. Engineer using `7d` is fine; one trying `'1d'` would hit `Retention specified (1.00d) is shorter than the minimum retention...` and need to look up the catalog override. Non-load-bearing.

**Production-stack fit**: on-prem MinIO + Iceberg + HMS + Trino 467 → procedures match prod stack exactly. Weekly cadence is conventional.

Cites r17 (correct anchor).

---

## Q2 — Three-step funnel: trial → payment-within-14d → activation-within-14d-of-TRIAL on 80M events — 4.625 STRONG PASS

**Verified against [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) + [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html)** + responder's pattern matches the canonical Trino 467 funnel form.

### Pattern verification

```sql
WITH step1_trial AS (
  SELECT user_id, MIN(occurred_at) AS trial_start
  FROM events
  WHERE event_type = 'trial_started'
  GROUP BY user_id
),
step2_payment AS (
  SELECT s1.user_id, s1.trial_start, MIN(e.occurred_at) AS payment_at
  FROM step1_trial s1
  JOIN events e ON e.user_id = s1.user_id
                AND e.event_type = 'added_payment'
                AND e.occurred_at BETWEEN s1.trial_start
                                       AND s1.trial_start + INTERVAL '14' DAY
  GROUP BY s1.user_id, s1.trial_start
), ...
```

All load-bearing facts correct:
1. **Per-user MIN(trial_start) anchor** — collapses multi-trial users to a single per-user window anchor; same approach as iter1209 Q2's `approx_set` daily-sketch pattern but for exact funnel counts. ✓
2. **`occurred_at BETWEEN s1.trial_start AND s1.trial_start + INTERVAL '14' DAY`** — valid Trino timestamp+INTERVAL arithmetic verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) "the date/time types include an operator for adding an INTERVAL to a TIMESTAMP" (`TIMESTAMP + INTERVAL '14' DAY` returns timestamp). ✓
3. **Step 3 window from `step1.trial_start` not `step2.payment_at`** — explicitly matches the question's literal ask ("subscription_activated **within 14 days of TRIAL start**", NOT within 14d of payment). The original 3-subqueries-joined approach the engineer described was failing exactly because per-user windows weren't enforced; per-user CTE join with `trial_start` carried through both step 2 and step 3 fixes that. ✓
4. **Diagnosed the original failure**: "JOINs without per-user time-window predicates can pair any user's trial_start with another user's payment" — correct root cause. ✓
5. **80M-scale pre-aggregation hint**: pre-collapsing to per-user per-day sketches before the join is the right scaling lever; consistent with `feedback_synthesis_ceiling_stop_churning.md` family (multi-step funnel construction usually lands). ✓

### Minor Acc shave (-0.25): column-label slip

Responder's final-SELECT alias `pct_step1_users` actually holds a `COUNT(*)` (the count of users who hit step 1), not a percentage. The ratio columns `pct_paid` / `pct_activated_of_paid` are correctly labeled. Reader-rename trivial; engineer gets the right numbers either way.

### Minor Compl shave (-0.125): didn't surface `match_recognize` as a row-pattern-matching alternative

Trino 467 supports `MATCH_RECOGNIZE` ([trino.io/docs/467/sql/match-recognize.html](https://trino.io/docs/467/sql/match-recognize.html)) which is the row-pattern-matching syntax for funnels with strict ordering + windows. For this 3-step funnel with 14d windows, CTE-join is the more readable + faster pattern; `match_recognize` is the polished mention. Non-load-bearing.

Cites r07/r23.

---

## Q3 — dbt on-run-start vs pre_hook same-connection + per-model SET SESSION query_max_memory_per_node='8GB' — 3.25 PASS + LIGHT FIX-A

**Verified against [docs.getdbt.com/reference/project-configs/on-run-start-on-run-end](https://docs.getdbt.com/reference/project-configs/on-run-start-on-run-end) + [docs.getdbt.com/docs/local/connect-data-platform/trino-setup](https://docs.getdbt.com/docs/local/connect-data-platform/trino-setup) + [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs)** (WebSearch this iter).

### Correct load-bearing points

- **on-run-start hook DOES exist in dbt** — responder's strict phrasing "dbt does NOT have an on-run-start hook that fires once before all models **in a single SHARED Trino connection**" is technically defensible (the connection-sharing qualifier is the load-bearing nuance), but a casual reader could parse it as "no on-run-start at all". Phrasing dense.
- **Option A diagnosis CORRECT**: `on-run-start: - "{{ run_query('SET SESSION query_max_memory_per_node = ...') }}"` issues the SET on a connection that closes when the hook completes — subsequent model builds open NEW connections where the session var is not set. Verified at dbt-trino docs: "If a pre-hook is run, that also is run outside of a transaction of course and does not effect the running queries" — same threading model applies to on-run-start. ✓
- **Option B CORRECT**: per-model `pre_hook="SET SESSION query_max_memory_per_node='8GB'"` runs in the SAME connection as the model build because dbt-trino keeps the per-model connection open across the pre_hook + main SQL + post_hook sequence. Verified at dbt-trino docs: "To temporarily adjust these session properties for a specific dbt model or group of models, you can use a dbt hook to set session properties: `config(pre_hook=\"set session query_max_run_time='10m'\")`". ✓

### DEFECTS

**(a) Option C — FABRICATED catalog config form (load-bearing accuracy hit)**.

Responder said: "set `iceberg.query_max_memory_per_node=8GB` in `etc/catalog/iceberg.properties` to apply globally."

VERIFIED WRONG:
- Trino query memory limits are **cluster-wide resource-management** properties in `etc/config.properties` (coordinator + workers), NOT per-catalog properties. r18 §155-167 + §279-282 already document this verbatim: `query.max-memory-per-node=8GB` in `etc/config.properties`.
- The `iceberg.` prefix in `iceberg.properties` is reserved for connector-specific properties (`iceberg.catalog.type`, `iceberg.file-format`, `iceberg.expire-snapshots.min-retention`, etc.) per [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html). There is NO `iceberg.query_max_memory_per_node` config property; an engineer pasting this into iceberg.properties hits "Configuration property 'iceberg.query_max_memory_per_node' was not used".
- Even if responder meant the right file (`config.properties`), the property name `query_max_memory_per_node` (underscores) is the SESSION form, not the CONFIG form (dots/hyphens) per r18 §155-156 "**Config property** ... DOTS and HYPHENS" vs "**Session property** ... UNDERSCORES". The "global apply" framing for a session-only property compounds the error.
- Per the `iter1141 query_max_memory_per_node` misconception family (responder previously claimed lowering it spills earlier — backwards), this is the THIRD instance of responder confusing the config-vs-session form / placement. r18 §155-167 IS the canonical disambiguation card but didn't reach this Q's "iceberg.properties" framing.

**(b) Missed canonical: dbt-trino `session_properties:` block in `profiles.yml`** (load-bearing completeness hit).

The CLEANEST dbt-native answer to "apply ONE setting before all models" is the dbt-trino profile-level `session_properties` map:

```yaml
my_profile:
  outputs:
    dev:
      type: trino
      host: ...
      session_properties:
        query_max_memory_per_node: "8GB"
```

Verified at [docs.getdbt.com/docs/local/connect-data-platform/trino-setup](https://docs.getdbt.com/docs/local/connect-data-platform/trino-setup) + [starburstdata/dbt-trino issue #4](https://github.com/starburstdata/dbt-trino/issues/4) verbatim "The standard way to define session properties is with the `session_properties` field of your `profiles.yml`, which ensures that all dbt connections use these settings by default."

**This IS the engineer's literal ask** ("put it once, applies to all models"). Every dbt-trino connection — including each per-model thread — receives the property at connection open. NO per-model pre_hook plumbing needed.

**Grep evidence — RESOURCE COVERAGE GAP confirmed**:
- `grep -i 'session_properties' resources/` → **0 hits**
- `grep -i 'on-run-start\|on_run_start' resources/` → **0 hits**
- `grep -i 'iceberg.query_max_memory_per_node' resources/` → not in resources (responder fabrication)

### LIGHT FIX-A spec (target r28)

Add a small dbt-trino session-properties + hook-mechanism card to r28 §profile-config cluster:

1. **Three-tier mental model**:
   - **Profile-tier (global)**: `session_properties:` in `profiles.yml` → applied at connection open, every dbt-issued query inherits → THE cleanest fit for "one global setting".
   - **Project-tier (one-shot startup)**: `on-run-start` / `on-run-end` hooks in `dbt_project.yml` → run in their own connection that closes at hook end → session vars DON'T persist to model connections. Use for things that don't need session-state (auditing, vacuum, ANALYZE).
   - **Model-tier (per-model)**: `pre_hook` / `post_hook` in `{{ config(...) }}` → run in the SAME connection as the model build → session vars DO persist for that model.
2. **Worked example** with `query_max_memory_per_node='8GB'` showing the profile form first, the per-model pre_hook as the per-model override.
3. **DO-NOT-WRITE inline-WRONG defangs** (per `feedback_defang_donotwrite_snippets.md`):
   - WRONG: `iceberg.query_max_memory_per_node=8GB` in `etc/catalog/iceberg.properties` — query memory limits are CLUSTER properties, not catalog properties.
   - WRONG: `query_max_memory_per_node=8GB` in `etc/config.properties` — config-property form is `query.max-memory-per-node` (dots/hyphens), not the session-form name.
   - WRONG: `on-run-start: SET SESSION query_max_memory_per_node='8GB'` (the SET runs in a connection that closes; subsequent models open new connections without the var) — use `session_properties:` in profiles.yml instead.

**Keyword anchors**: `session_properties profiles.yml dbt-trino, on-run-start session var doesn't persist, pre_hook same connection vs on-run-start separate connection, dbt apply session property to every model, dbt global session SET, query_max_memory_per_node dbt`.

**Watch label**: `iter1213 r28 dbt-trino session_properties + hook-connection-scope card FIX-A`; re-probe with structurally similar framing in 3-6 iters ("dbt how do I set a Trino session property for every model, once").

Cites r28 (target for FIX-A).

---

## Q4 — Oracle `(+)` outer-join rewrite to Trino LEFT/RIGHT JOIN — 3.625 PASS (INVERTED prose mnemonic, SOFT WATCH)

**Verified against [trino.io/docs/467/sql/select.html#join-clause](https://trino.io/docs/467/sql/select.html#join-clause) + [Atlassian — Oracle Plus Sign for Left & Right Joins](https://www.atlassian.com/data/databases/left-and-right-joins-using-the-plus-sign-in-oracle)** + r27 §34 myth row + r27 §1745 translation row.

### Correct load-bearing points

- **Trino does NOT support `(+)`** — Oracle-proprietary, parse error in Trino. ✓ (matches r27 §34 myth row + §1745 translation row).
- **Rewrite to ANSI LEFT/RIGHT JOIN** — correct universal fix. ✓
- **Mapping table examples correct** (verified against Atlassian source: "the + symbol is placed directly in the conditional statement and on the side of the optional table"):
  - `orders.customer_id = customers.customer_id(+)` → `orders LEFT JOIN customers ON ...` ✓ (customers is OPTIONAL; preserve all orders)
  - `orders.customer_id(+) = customers.customer_id` → `orders RIGHT JOIN customers ON ...` (or equivalently `customers LEFT JOIN orders ON ...`) ✓ (orders is OPTIONAL; preserve all customers)
  - Multi-condition AND → all conditions in ON clause. ✓

### DEFECT — INVERTED prose mnemonic

Responder appended: **"the `(+)` always appears on the table you want to keep the unmatched rows from."**

This is **BACKWARDS**. Oracle convention (verified at Atlassian source verbatim + [docs.oracle.com — Joins](https://docs.oracle.com/en/database/oracle/oracle-database/26/sqlrf/Joins.html)):
- `(+)` marks the **OPTIONAL / null-padded** side (the side that may produce NULLs when no match).
- The rows you preserve (matched + unmatched) come from the side **WITHOUT** the `(+)`.
- Example: `WHERE orders.customer_id = customers.customer_id(+)` — `(+)` on customers means customers is optional/null-padded; you keep ALL orders, including orders with NO matching customer. The "unmatched orders" (orphans) are preserved on the side **without** `(+)`.

If a beginner applies the responder's prose to write NEW SQL:
- Engineer wants "all orders, including orphan orders with no customer" → mnemonic says "put `(+)` on orders (the side you want to keep unmatched rows from)" → engineer writes `orders.customer_id(+) = customers.customer_id` → Oracle interprets this as "keep all customers (orphan customers preserved)" — the OPPOSITE of what the engineer wanted.

The mapping-table rewrite path is fine BECAUSE the engineer has an existing query to translate (they read `customers.customer_id(+)` and look up the row → LEFT JOIN customers). The mnemonic is dangerous specifically for the **forward direction** (writing new Oracle-like queries or mentally validating an existing query's intent).

### Source check — RESPONDER SLIP, NOT resource-sourced

- `grep '(\+)' resources/27-oracle-plsql-to-dbt-trino.md` → r27 §34 myth row + §1745 translation row only; **no prose mnemonic line that matches "table you want to keep unmatched rows from"**.
- `grep -i 'keep the unmatched\|unmatched rows\|optional side\|side without' resources/27-oracle-plsql-to-dbt-trino.md` → **0 hits**.
- Mnemonic is a **responder synthesis slip** appended as a "for completeness" prose rule — matches `feedback_responder_broken_secondary_alternative.md` family (lead correct, appended aside broken).

### Decision: SOFT WATCH, NO r27 reconcile

- The r27 translation table is correct + load-bearing.
- Adding a corrective prose mnemonic to r27 risks `feedback_new_card_over_attracts_adjacent` over-attractor on this thin secondary aside.
- The responder slip is per-instance synthesis, not source-anchored.
- **SOFT WATCH**: `iter1213 Q4 (+)-mnemonic-inverted "keep unmatched rows from"` — re-probe in 4-8 iters with structurally similar framing ("which side does `(+)` go on, easy way to remember"). If recurs, LIGHT FIX-A targets a single inline DO-NOT-WRITE row at r27 §1745: WRONG mnemonic vs CORRECT mnemonic ("`(+)` marks the side that may be NULL-padded; preserve all rows from the side **without** `(+)`").

Cites r27 (mapping table correct; no fix this iter).

---

## Carry-forward watches (light-monitor list, no action this iter)

| Watch | Iter | Status |
|---|---|---|
| `iter1213 r28 dbt-trino session_properties + hook-connection-scope card FIX-A` | 1213 | **NEW — TEACHER TODO this iter** |
| `iter1213 Q4 (+)-mnemonic-inverted "keep unmatched rows from"` | 1213 | NEW SOFT WATCH (re-probe 4-8) |
| `iter1212 dbt-seed-column_types-NOT-in-schema.yml over-statement` | 1212 | open (re-probe 4-8) |
| `iter1207 r13 §1293-1326 Spark-CALL-inline-tag` | 1207 | open (re-probe 4-8) |
| `iter1206 Q1 LIKE-on-ROW + $partitions-omission` | 1206 | open (re-probe 4-8) |
| `iter1204 dbt --full-refresh on_table_exists atomicity framing` | 1204 | open (re-probe 5-10) |
| strpos-3-arg, ::cast-operator, NVL-coercion, $partitions, GDPR Spark-tag, width_bucket-boundary, exposures-selector, CURRENT_TIMESTAMP-parens, dbt-seed-column_types-location, `--full-refresh on_table_exists` | various | light-monitor, no fix |

---

## Topic score updates

| Topic | Prior | New | Delta |
|---|---|---|---|
| Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup | 4.4480/220 | (978.5600 + 4.625)/221 = **4.4488/221** | +0.0008 |
| Analytical query patterns on Iceberg+Trino | 4.5393/151 | (685.4343 + 4.625)/152 = **4.5399/152** | +0.0006 |
| Improving complex SQL performance on Trino with dbt | 4.5648/44 | (200.8512 + 3.25)/45 = **4.5356/45** | -0.0292 (margin still +1.0356) |
| Oracle PL/SQL → dbt + Trino SQL migration | 4.4703/175 | (782.3025 + 3.625)/176 = **4.4655/176** | -0.0048 (margin still +0.9655) |

All required topics remain PASSED with healthy margins. Q3 step-down absorbed by 44-question cushion (+1.03 margin).

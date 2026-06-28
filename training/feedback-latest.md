# Iteration 1226 — Judge Feedback

**Verdict: 4.25 PASS with TWO FIX-A scopes — iter1223 GREATEST-Oracle-premise WATCH CLOSES (Q4 5.0), but iter1225 table_changes() recurred (Q1 same denial, 2nd consecutive recurrence) AND iter1223 packages.yml-gap recurred as ACTIVE MISDIAGNOSIS (Q3 misreads the user's setup).** Q2 PERCENT_RANK clean 5.0; Q4 cleanly corrected the Oracle-NULL premise (`Trino, Oracle, MySQL, BigQuery all return NULL on any NULL; Postgres is the outlier`) with COALESCE-wrap fix — first-re-probe close. Q1 again denied `iceberg.system.table_changes()` exists (it DOES, since 427, just MoR-delete-file-limited) — soft slip iter1225 → harder recurrence now warrants light additive card. Q3 actively misdiagnosed: user EXPLICITLY showed `{{ dbt_utils.generate_surrogate_key([...]) }}` in the question; responder said "your invocation syntax is wrong, missing {{ }}" — fabricates a problem that doesn't match the user's stated setup. Recommend BOTH FIX-A scopes now.

Per-question summary:
- Q1 4.5 — WATCH RECURRED. Time-travel + FULL OUTER JOIN + IS DISTINCT FROM pattern correct + practical action correct (MoR + Spark MERGE INTO orders DOES produce delete files so `table_changes()` wouldn't work in practice) BUT same factual denial as iter1225 ("Trino 467 does NOT have a native changelog or CDC metadata structure"). FIX-A: light additive card.
- Q2 5.0 — `PERCENT_RANK() OVER (PARTITION BY plan_tier ORDER BY api_call_volume) * 100` + direction note (0.0 first / 1.0 last, ASC → highest = 1.0) + CUME_DIST sibling. Verified at trino.io/docs/467/functions/window.html.
- Q3 2.5 — WATCH RECURRED AS ACTIVE MISDIAGNOSIS. Responder said "your invocation syntax is wrong" but user EXPLICITLY used `{{ dbt_utils.generate_surrogate_key(['account_id','event_type']) }}` with braces in the question. Real likely causes: dbt-utils version mismatch (`generate_surrogate_key` was renamed from `surrogate_key` in dbt-utils v1.0.0; if pinned <1.0.0, macro doesn't exist), `dbt_packages/` folder not present at compile time, or package-name typo. FIX-A: r27 packages.yml troubleshooting card.
- Q4 5.0 — **WATCH CLOSES** on first re-probe (16th consecutive 1st-re-probe-close pattern). "Trino, Oracle, MySQL, BigQuery all return NULL if ANY arg is NULL; PostgreSQL is the outlier" — Oracle premise corrected verbatim + COALESCE-wrap fix.

Iter average: (4.5 + 5.0 + 2.5 + 5.0) / 4 = **4.25 PASS**, margin +0.75 over 3.5 pass-threshold. Two LIGHT FIX-A scopes recommended (additive, no resource churn / no reconcile-in-place needed).

---

## Q1 — WATCH RECURRED: Iceberg native changelog/CDC for past-7-day audit (MoR + Spark MERGE INTO)

**Score: 4.5** — Acc 3.5 / Clar 5.0 / App 5.0 / Compl 4.5

**Scenario.** Compliance audit of every row inserted/updated/deleted in `orders` past 7 days. Oracle used Flashback/redo logs. Engineer asks if Iceberg has a native changelog/change feed in Trino 467 or must FULL OUTER JOIN snapshot comparison.

**Responder shape:** Open with "Trino 467 does NOT have a native changelog table or CDC metadata structure." Option A: `$history` metadata table (snapshot-level operations only — append/delete/replace/overwrite/merge — tells WHICH snapshots changed not WHICH rows). Option B: FULL OUTER JOIN two `FOR VERSION AS OF` snapshots, classify INSERT/DELETE/UPDATE via IS DISTINCT FROM. Closing: "Iceberg does NOT expose a row-level operation column like Oracle Flashback; use FULL OUTER JOIN."

**Load-bearing CORRECT:**
1. **FULL OUTER JOIN snapshot diff is the correct PRACTICAL action** for this stack — Spark MERGE INTO writes positional delete files (Iceberg v2 MoR), so even if `table_changes()` were surfaced, it would fail on this exact table (delete-file limitation, see below). The recommended action lands the engineer on a query that works.
2. **`$history` description** correct: snapshot-level operations only (`append`/`delete`/`replace`/`overwrite`/`merge`), not row-level — correctly distinguishes from row-level audit need.
3. **`FOR VERSION AS OF <snapshot_id>` time-travel both sides + FULL OUTER JOIN on PK + IS DISTINCT FROM classify** — standard analytical diff pattern, verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html).

**SLIP — table_changes() denial (Acc -1.5, Compl -0.5):**

Responder said: "Trino 467 does NOT have a native changelog table or CDC metadata structure." **FACTUALLY WRONG, 2nd consecutive recurrence** (iter1225 Q1 had identical denial).

VERIFIED at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) + [trinodb/trino#15677](https://github.com/trinodb/trino/pull/15677) (merged 2023-09-13, included in Trino 427):

```sql
SELECT * FROM TABLE(iceberg.system.table_changes(
  schema_name => 'analytics',
  table_name  => 'orders',
  start_snapshot_id => <prior_week_snapshot>,
  end_snapshot_id   => <current_snapshot>
));
```

Returns all table columns + 4 special columns:
- `_change_type` — `'insert'` or `'delete'`
- `_change_version_id` — snapshot id where change occurred
- `_change_timestamp` — when the snapshot became active
- `_change_ordinal` — change ordering number

**Limitation that makes the practical action still correct on THIS stack:**

Per [PR #15677](https://github.com/trinodb/trino/pull/15677): "Currently supports metadata deletes only; does NOT support merge-on-read positional or equality deletes." Spark MERGE INTO on Iceberg v2 produces positional delete files (the MoR default). So for THIS engineer's `orders` table being written by Spark MERGE INTO every 15min, `table_changes()` would fail at runtime with `cannot read this table with table_changes` — the FULL OUTER JOIN snapshot-diff IS the correct routing.

The miss is the **absolute denial of existence** — the correct framing is: "Trino 467 has `iceberg.system.table_changes()` but it doesn't support snapshots containing positional/equality delete files. Your `orders` table writes via Spark MERGE INTO produce delete files (MoR), so `table_changes()` won't work for you — use FOR VERSION AS OF + FULL OUTER JOIN + IS DISTINCT FROM."

**Resource-source check.** Grepped `resources/` for `table_changes` / `change feed` / `changelog table` — **ZERO hits** in r10/r17/r28 (the natural homes). `resources/13-postgres-to-iceberg-ingestion.md:3763` mentions Iceberg's `create_changelog_view` Spark stored procedure but is silent on Trino's `table_changes()` table function. This is a **resource findability gap** — the responder cannot find what isn't there.

**RECOMMENDED FIX-A (LIGHT, additive — verify first):**

Add a 5–7 line additive card to **`resources/17-iceberg-table-maintenance.md`** (or **r10** snapshot-management section) under a heading like "Snapshot-range CDC reading — `iceberg.system.table_changes()` exists BUT not on MoR delete-file snapshots":

```
Trino 467 has `iceberg.system.table_changes(schema_name=>..., table_name=>..., start_snapshot_id=>..., end_snapshot_id=>...)`
returning per-row insert/delete events between two snapshots with special columns
`_change_type` ('insert'/'delete'), `_change_version_id`, `_change_timestamp`, `_change_ordinal`.

LIMITATION (load-bearing for THIS prod stack): supports metadata deletes ONLY.
Snapshots containing positional or equality delete files (i.e. anything Spark MERGE INTO
or Trino MoR DELETE wrote on this prod stack) are NOT supported and will fail at runtime.

ROUTING (this stack — Spark MERGE INTO every 15min produces position-delete files):
DO NOT use table_changes() on tables written by Spark MERGE INTO.
DO use FOR VERSION AS OF both snapshots + FULL OUTER JOIN on PK + IS DISTINCT FROM classify
(see [link to existing FOR VERSION AS OF diff canonical]).
```

**Verify BEFORE writing the card:**
- Confirm function signature: `iceberg.system.table_changes(schema_name VARCHAR, table_name VARCHAR, start_snapshot_id BIGINT, end_snapshot_id BIGINT)` — VERIFIED via WebFetch [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html).
- Confirm 4 special return columns: `_change_type`, `_change_version_id`, `_change_timestamp`, `_change_ordinal` — VERIFIED.
- Confirm MoR/delete-file limitation: "Currently supports metadata deletes only; does not support merge-on-read positional or equality deletes" — VERIFIED via [PR #15677](https://github.com/trinodb/trino/pull/15677) description.
- Confirm version cutoff: added in Trino 427 (Sept 2023); 467 has it — VERIFIED.

**Production-stack fit.** All matches prod_info.md exactly: Trino 467 + Iceberg connector (HMS-backed) + Spark MERGE INTO writers. Spark MERGE INTO with Iceberg 1.5.2 default settings produces positional delete files (the MoR-write-mode default) → `table_changes()` won't work on this stack's `orders` table → routing to FULL OUTER JOIN diff is correct on the practical axis.

Cites r10/r17.

---

## Q2 — PERCENT_RANK for within-tier percentile (pro customer at 80th → 80.0)

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**Scenario.** Per customer, what percentile in API call volume vs all customers on the SAME plan tier (pro customer at 80th shows 80.0). Engineer's ROW_NUMBER/COUNT manual ranking is messy + ties off. Asks for a built-in within-group percentage-ranking window function.

**Responder shape:** `PERCENT_RANK() OVER (PARTITION BY plan_tier ORDER BY api_call_volume) * 100` + ROUND for the 80.0 display. Direction note: PERCENT_RANK gives 0.0 to first row, 1.0 to last; under ASC, highest volume = 1.0 → use ASC for "top-% badge" framing (pro at 80th gets ~80.0). Sibling: CUME_DIST same shape, different math (CUME_DIST counts fraction at-or-below, PERCENT_RANK is `(rank-1)/(n-1)`).

**Load-bearing facts CORRECT (VERIFIED):**

1. **`PERCENT_RANK()` is a Trino 467 window function** — VERIFIED at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html): listed as a ranking function with definition `(rank - 1) / (rows - 1)`. Returns DOUBLE in [0, 1].
2. **`PARTITION BY plan_tier ORDER BY api_call_volume`** — partition restricts the comparison to same-tier peers (the "vs all customers on the SAME plan tier" requirement), ORDER BY establishes the ranking direction. Standard ranking-window syntax verified.
3. **Direction note — first row = 0.0, last row = 1.0** — correct per the `(rank-1)/(n-1)` formula: rank-1 of first row = 0, rank-N of last row = N-1, ratio = 1.0. Under ASC, smallest volume = 0.0, largest = 1.0 → pro customer with high volume gets ~0.8 → multiply by 100 → 80.0. Direction interpretation matches the iter635 PERCENT_RANK / NTILE direction guardrail (r07 line 4079).
4. **`* 100` to convert [0,1] to [0,100]** — straightforward; pairing with `ROUND(..., 1)` for the "80.0" display format the engineer specified.
5. **CUME_DIST sibling correctly noted** — same `OVER (PARTITION BY ... ORDER BY ...)` shape; CUME_DIST is "fraction at or below" (`COUNT at-or-below / N`) while PERCENT_RANK is "rank position" (`(rank-1)/(n-1)`). Both work for percentile-style framing; choice is semantic (PERCENT_RANK for "rank position", CUME_DIST for "fraction at or below"). r07 line 3991-3992 has the existing canonical for this distinction.
6. **Handles ties cleanly** — PERCENT_RANK assigns the same percentile to tied rows (because `rank` is the same), unlike ROW_NUMBER which arbitrarily breaks ties — directly answers the engineer's "ties off" complaint.

Engineer leaves with: `PERCENT_RANK() OVER (PARTITION BY plan_tier ORDER BY api_call_volume) * 100 AS pct_badge` + direction-correctness check (ASC → high volume = 100) + tie-safety vs ROW_NUMBER/COUNT manual ranking. No imported-prior, no broken-secondary, no over-warning.

Cites r07 / r23.

---

## Q3 — WATCH RECURRED AS ACTIVE MISDIAGNOSIS: dbt_utils.generate_surrogate_key won't resolve after dbt deps

**Score: 2.5** — Acc 2.0 / Clar 4.0 / App 1.5 / Compl 2.5

**Scenario.** Engineer using `generate_surrogate_key` from dbt-utils for composite keys. Created `packages.yml` in project root with dbt-utils, ran `dbt deps` **SUCCESSFULLY**. But `{{ dbt_utils.generate_surrogate_key(['account_id','event_type']) }}` in a model errors with "can't resolve the macro." Asks: packages.yml location wrong, or referencing the macro wrong?

**Responder shape:** "Your packages.yml is in the right location (project root), but the macro INVOCATION SYNTAX is wrong." Gave the correct general setup (packages.yml in root, `dbt deps`, `{{ dbt_utils.generate_surrogate_key([...]) }}`). Then: "The trap you hit: `{{ }}` is Jinja macro syntax evaluated at compile time... you cannot call it as a SQL function — `generate_surrogate_key(...)` with no `{{ }}` is a parse error."

**ACTIVE MISDIAGNOSIS (Acc -3, App -3.5, Compl -2.5):**

The user **EXPLICITLY** showed they ARE using `{{ }}`: in the question they wrote `{{ dbt_utils.generate_surrogate_key(['account_id','event_type']) }}`. The responder told them "you forgot the `{{ }}`" — but the user's invocation is **already correct**. This is a misread of the question; the responder fabricated a problem that doesn't match the user's setup, and the suggested fix (add the `{{ }}` braces) is a no-op for this user.

**Actual likely causes** (none of which the responder mentioned):

1. **dbt-utils version mismatch — THE most common cause.** `generate_surrogate_key` was introduced in **dbt-utils v0.8.0** (early 2022) and FULLY REPLACED the older `surrogate_key` in **v1.0.0**. If the engineer's `packages.yml` pins a version constraint like `version: [">=0.6.0", "<0.8.0"]` (a common stale pin from older project templates), the macro `generate_surrogate_key` does not exist in the installed version — only `surrogate_key` does. The error matches "macro can't resolve" exactly. Verified at [dbt-utils v1.0 migration guide](https://docs.getdbt.com/docs/dbt-versions/core-upgrade/Older%20versions/upgrading-to-dbt-utils-v1.0): "Warning: `dbt_utils.surrogate_key` has been replaced by `dbt_utils.generate_surrogate_key`."
2. **`dbt_packages/` folder not present at compile time.** `dbt deps` writes to `./dbt_packages/` by default. If the engineer ran `dbt deps` in one shell session and `dbt run` in another with a different CWD, or if `dbt_packages/` is `.gitignore`d and the CI runner skipped the deps step, or if the project is invoked with `--project-dir` pointing elsewhere — the package is installed but invisible at compile.
3. **Package-name typo in packages.yml.** `package: dbt-labs/dbt_utils` is correct (note: underscore in `dbt_utils`, dash in `dbt-labs`). If the engineer wrote `package: dbt-labs/dbt-utils` (all dashes) the `dbt deps` may install nothing or install the wrong thing without an obvious error, then the `dbt_utils.` namespace doesn't exist.
4. **dbt-utils version too old for `generate_surrogate_key` macro args shape.** Per [dbt-labs/dbt-utils#717](https://github.com/dbt-labs/dbt-utils/issues/717) ("generate_surrogate_key macro is missing"), several reports trace back to <1.0.0 pins.

**Recommended diagnostic order** the responder should have given:
- `dbt deps` → check console output: "Installing dbt-labs/dbt_utils ... Installed from version X.Y.Z"
- `ls dbt_packages/dbt_utils/macros/sql/` → confirm `generate_surrogate_key.sql` file exists
- If only `surrogate_key.sql` exists, the installed version is <0.8.0 → bump `packages.yml` version range to `[">=1.0.0", "<2.0.0"]`, rerun `dbt deps`
- If `dbt_packages/` itself is missing, check CWD / `--project-dir` / CI deps-step order

**WATCH RECURRENCE pattern:**

iter1223 flagged `packages.yml-gap` as "FIX-A if recurs" — at iter1223 it was a coverage gap (responder didn't address the user's troubleshooting need). iter1226 (this iter) recurs as an **active misdiagnosis**: not just missing info, but the responder confidently asserts a wrong diagnosis that doesn't match the user's stated setup. This is the more serious recurrence shape and warrants the FIX-A now.

**RECOMMENDED FIX-A (LIGHT, additive — verify first):**

Add a packages.yml + dbt_utils troubleshooting canonical to **`resources/27-oracle-plsql-to-dbt-trino.md`** near §4.5A (which already references `dbt_utils.generate_surrogate_key`). A 15-25 line additive card under a heading like "dbt_utils setup & `generate_surrogate_key` troubleshooting" with:

1. **Canonical `packages.yml`** at project root:
   ```yaml
   packages:
     - package: dbt-labs/dbt_utils
       version: [">=1.0.0", "<2.0.0"]   # generate_surrogate_key needs >= 0.8.0; <2 future-safe
   ```
2. **Workflow:** `dbt deps` (writes `./dbt_packages/`) → `{{ dbt_utils.generate_surrogate_key(['col1','col2']) }}` in model SQL.
3. **"Macro can't resolve" troubleshooting table** with the four causes above (version mismatch / `dbt_packages` missing / package-name typo / wrong CWD), each with the exact diagnostic command.
4. **THE WATCH:** explicit "If the user EXPLICITLY wrote `{{ }}` in their invocation, the cause is NOT missing braces — diagnose along (1)-(4)." anti-misdiagnosis cue for the responder.

**Verify BEFORE writing the card:**
- Confirm `generate_surrogate_key` was renamed FROM `surrogate_key` in dbt-utils v1.0.0 — VERIFIED via [dbt-utils v1.0 migration guide](https://docs.getdbt.com/docs/dbt-versions/core-upgrade/Older%20versions/upgrading-to-dbt-utils-v1.0).
- Confirm `generate_surrogate_key` first available version — appears to be v0.8.0 (search results show both 0.8.x and 1.0+ have it; the v1.0 release fully REMOVED `surrogate_key`). For the troubleshooting card, recommend `version: [">=1.0.0", "<2.0.0"]` (safest, future-aligned).
- Confirm package name spelling `dbt-labs/dbt_utils` (dash in org, underscore in package) — VERIFIED at [github.com/dbt-labs/dbt-utils](https://github.com/dbt-labs/dbt-utils).

**Production-stack fit.** dbt is supported per prod_info.md ("dbt is supported and permitted for users"); dbt-trino + dbt-utils is the canonical surrogate-key path on Iceberg per existing r27 §4.5A guidance. No conflict.

Cites r27.

---

## Q4 — WATCH CLOSES: Oracle GREATEST NULL-skip premise corrected

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**WATCH CLOSURE — `iter1223 GREATEST-Oracle-premise`.** At iter1223 the responder accepted the user's incorrect premise ("Oracle ignores NULLs") or gave Trino fix without correcting the premise. This iter (1226), responder cleanly states: "Trino 467 returns NULL if ANY argument is NULL. This differs from Oracle (which ALSO returns NULL on any NULL)... Trino, Oracle, MySQL, BigQuery all return NULL if ANY arg is NULL. PostgreSQL is the outlier (skips NULLs)." **Watch closes on first re-probe** — 16th consecutive 1st-re-probe-close in the extended phase.

**Scenario.** Pricing table; some tier columns NULL. Oracle `GREATEST(tier1_price, tier2_price, tier3_price)` (the engineer claims) skipped NULLs. In Trino, any-NULL row returns NULL. Engineer asks: did they do something wrong, or does Trino handle GREATEST differently?

**Responder shape:** "Trino 467 returns NULL if ANY arg is NULL. This differs from Oracle (which ALSO returns NULL on any NULL) — your Oracle premise is wrong, both engines match." Fix: `GREATEST(COALESCE(tier1_price,0), COALESCE(tier2_price,0), COALESCE(tier3_price,0))`. Key fact box: "Trino, Oracle, MySQL, BigQuery all return NULL if ANY arg is NULL. PostgreSQL is the outlier (skips NULLs). Wrap each arg in COALESCE."

**Load-bearing facts CORRECT (VERIFIED):**

1. **Trino 467 GREATEST/LEAST return NULL if ANY arg is NULL** — VERIFIED at [trino.io/docs/467/functions/comparison.html](https://trino.io/docs/467/functions/comparison.html) (per my reference_trino_greatest_least_null memory note: "Trino 467 GREATEST/LEAST RETURN NULL if ANY arg is NULL"). Matches r27 §4.4D (line 1733) verbatim: "Assuming greatest()/least() skip NULLs — Trino returns NULL if any arg is NULL (matches Oracle; differs from PostgreSQL)."
2. **Oracle GREATEST also returns NULL on any NULL** — VERIFIED via [database.guide GREATEST in Oracle](https://database.guide/greatest-function-in-oracle/) + [Ask TOM GREATEST returning NULL](https://asktom.oracle.com/ords/f?p=100%3A11%3A0%3A%3A%3A%3AP11_QUESTION_ID%3A524526200346472289): "Oracle's GREATEST function returns NULL if any of its input arguments is NULL." The engineer's recollection ("Oracle skipped NULLs") is wrong — they likely confused GREATEST (row-wise) with MAX (aggregate, which DOES skip NULLs).
3. **PostgreSQL is the outlier** — VERIFIED: Postgres GREATEST/LEAST skip NULLs (return NULL only if ALL args are NULL). MySQL + BigQuery match Trino + Oracle (any-NULL → NULL).
4. **COALESCE wrap fix correct shape** — `GREATEST(COALESCE(a, 0), COALESCE(b, 0), COALESCE(c, 0))`. Sentinel `0` is the correct floor for `GREATEST` (NULL → 0, which the GREATEST will only pick if all real values are also ≤ 0). For `LEAST`, the analogous sentinel is a large ceiling (e.g., `9e18` for BIGINT, `'9999-12-31'` for date). Matches r23 line 2231-2232 sentinel-pattern canonical exactly.
5. **Correcting the premise** — responder didn't just give the Trino fix; explicitly stated "your Oracle premise is wrong, Oracle also returns NULL on any NULL." This is the WATCH-CLOSURE evidence: at iter1223 the responder skipped this premise correction; iter1226 surfaces it cleanly.

Engineer leaves with: (a) correct mental model that GREATEST is row-wise NOT aggregate (so doesn't skip NULLs the way MAX does); (b) Oracle + Trino match (no engine difference here — their Oracle memory was off); (c) COALESCE-wrap fix; (d) Postgres-is-outlier cross-engine map. No imported-prior, no broken-secondary, no over-warning, no fabrication.

Cites r23 / r27.

---

## Topic updates

- **Q1 → Iceberg table maintenance (compaction, snapshot expiry, orphan file cleanup)**: 4.4368/225 → (4.4368×225 + 4.5)/226 = 1002.78/226 = **4.4371/226 PASSED** (+0.0003, margin +0.9371).
- **Q2 → Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL**: 4.5534/159 → (4.5534×159 + 5.0)/160 = 728.991/160 = **4.5562/160 PASSED** (+0.0028, margin +1.0562).
- **Q3 → Oracle PL/SQL → dbt+Trino migration**: 4.4634/190 → (4.4634×190 + 2.5)/191 = 850.546/191 = **4.4531/191 PASSED** (-0.0103, margin +0.9531).
- **Q4 → Oracle PL/SQL → dbt+Trino migration**: 4.4531/191 → (4.4531×191 + 5.0)/192 = 855.546/192 = **4.4560/192 PASSED** (+0.0029, margin +0.9560).

All required topics remain PASSED with margins ≥ +0.9. Q3 dip from Oracle PL/SQL migration topic (-0.0103 on this datapoint) is the topic-thinning event of this iter — still healthy at +0.9531 margin.

Thinnest required topic remains **Query performance basics: partitioning, indexing strategy for analytics** at 4.2091/31 (margin +0.7091).

---

## Watch backlog

**OPEN watches:**
- `iter1225 table_changes()-exists-but-MoR-limited` — **RECURRED iter1226** (2nd consecutive denial); FIX-A LIGHT scope below.
- `iter1223 packages.yml-gap` — **RECURRED iter1226 AS MISDIAGNOSIS**; FIX-A LIGHT scope below.
- `iter1224 CoW-MoR scenario-diagnosis-when-symptom-implies-mode` — soft watch; NOT TESTED this iter.
- `iter1215 strpos-3-arg CEILING` (no churn) — NOT TESTED this iter.
- `iter1213 session_properties + (+)-mnemonic` — NOT TESTED this iter.
- `iter1222 CAST-DECIMAL/TRY_CAST` — NOT TESTED this iter.
- light-monitors carry forward.

**CLOSED this iter:**
- `iter1223 GREATEST-Oracle-premise` — **CLOSED on first re-probe Q4** (responder corrected the Oracle premise verbatim).

---

## FIX-A scopes recommended (TWO, both LIGHT additive)

**FIX-A #1: r17 (or r10) — `iceberg.system.table_changes()` exists-but-MoR-limited card.**

Add a 5–7 line additive card under a snapshot-management or CDC-on-Iceberg heading:

```
Trino 467 HAS `iceberg.system.table_changes(schema_name=>..., table_name=>...,
start_snapshot_id=>..., end_snapshot_id=>...)` (added Trino 427, PR #15677) —
returns per-row insert/delete events between two snapshots with special columns
`_change_type` ('insert'/'delete'), `_change_version_id`, `_change_timestamp`,
`_change_ordinal`.

LIMITATION (load-bearing on THIS prod stack): supports metadata deletes ONLY.
Snapshots containing positional or equality delete files (anything Spark MERGE INTO
or Trino MoR DELETE wrote) are NOT supported — query fails at runtime.

ROUTING on this stack (Spark MERGE INTO every 15min → position-delete files):
DO NOT use table_changes() on tables written by Spark MERGE INTO.
DO use FOR VERSION AS OF both snapshots + FULL OUTER JOIN on PK + IS DISTINCT FROM
classify (see [existing FOR VERSION AS OF diff canonical link]).
```

Verify BEFORE writing: signature, 4 return columns, version cutoff 427+, MoR/delete-file limitation — ALL verified above with citations.

**FIX-A #2: r27 — `dbt_utils` setup + `generate_surrogate_key` troubleshooting card.**

Add a 15-25 line additive card near §4.5A (which already references `dbt_utils.generate_surrogate_key`):

```
PACKAGES.YML (project root):
  packages:
    - package: dbt-labs/dbt_utils
      version: [">=1.0.0", "<2.0.0"]   # generate_surrogate_key fully replaces surrogate_key in v1.0

WORKFLOW:
  dbt deps   # writes ./dbt_packages/dbt_utils/
  -> {{ dbt_utils.generate_surrogate_key(['col1','col2']) }} in model SQL

"MACRO CAN'T RESOLVE" TROUBLESHOOTING:
| Cause                              | Diagnostic                                         | Fix                                              |
|------------------------------------|----------------------------------------------------|--------------------------------------------------|
| dbt-utils version <1.0.0 (only `surrogate_key` exists, not `generate_surrogate_key`) | `ls dbt_packages/dbt_utils/macros/sql/` → only `surrogate_key.sql` shows | Bump `packages.yml` to `version: [">=1.0.0", "<2.0.0"]`, rerun `dbt deps` |
| `dbt_packages/` not present at compile (.gitignored + CI skipped deps; or wrong CWD) | `ls dbt_packages/` → missing | Run `dbt deps` from project root; ensure CI step order is `deps -> build` |
| Package-name typo (`dbt-labs/dbt-utils` all dashes is WRONG; correct is `dbt-labs/dbt_utils` dash-org/underscore-pkg) | `cat packages.yml` | Fix to `dbt-labs/dbt_utils`, rerun `dbt deps` |
| Wrong project dir at invocation (`dbt run --project-dir <wrong>`) | `pwd` vs invocation | Match `--project-dir` to the project containing `dbt_packages/` |

ANTI-MISDIAGNOSIS NOTE: if the user EXPLICITLY wrote `{{ }}` around the macro call
in their model, the cause is NOT missing braces — diagnose along (1)-(4) above.
```

Verify BEFORE writing: `surrogate_key` → `generate_surrogate_key` rename in v1.0 — VERIFIED; package name spelling — VERIFIED; troubleshooting causes — covered by [dbt-labs/dbt-utils#717](https://github.com/dbt-labs/dbt-utils/issues/717).

---

## Verdict

**4.25 PASS** with TWO LIGHT FIX-A scopes — iter1223 GREATEST-Oracle-premise WATCH CLOSES cleanly on Q4 (16th consecutive 1st-re-probe-close). But TWO watches recurred and warrant additive cards now: (a) iter1225 `table_changes()` denial recurred (2nd consecutive) → light card in r17/r10; (b) iter1223 `packages.yml` gap recurred AS ACTIVE MISDIAGNOSIS on Q3 → light card in r27 with packages.yml canonical + "macro can't resolve" troubleshooting + anti-misdiagnosis note. Q2 PERCENT_RANK + direction note + CUME_DIST sibling clean 5.0. All required topics remain PASSED with healthy margins; Q3 dip is the topic-thinning event of this iter. No reconcile-in-place needed — both FIX-A's are purely additive, defang non-load-bearing.

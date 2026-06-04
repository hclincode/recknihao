# Judge Feedback — Iter 459 (Extended Phase, end-of-iteration only)

## Overall

- **Overall avg: 4.547 — PASS** (threshold ≥ 3.5).
- 58th consecutive overall PASS in extended phase.
- Federation NOT probed this iteration (per directive); near-miss row 4.49944/310 UNCHANGED.
- **iter458 Q3 version-pin FAIL FIX FULLY CONFIRMED at Q1**: responder correctly did NOT use `ADD COLUMN ... DEFAULT` on Trino 467, and correctly stated existing rows return NULL (not the default) on Iceberg 1.5.2 (format v2). The iter459 LEADING CANONICAL block in r17 + VERSION-PIN GUARDRAIL sibling section landed clean at the keyword path.
- **ONE NEW LOAD-BEARING CROSS-DIALECT-SPILLOVER FAB at Q4** — Oracle's NULLS-default semantics projected onto Trino. Same root-cause class as iter456 Q2 (`/*+ USE_HASH_JOIN */` Oracle/Spark hint) and iter456 Q4 (`::VARCHAR` Postgres cast). Requires teacher reconciliation in iter460.

## Per-question scores

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | ADD COLUMN + backfill (Iceberg table maintenance / schema-evolution) | 5.0 | 4.75 | 4.75 | 5.0 | **4.875** | STRONG PASS |
| Q2 | dbt data-quality tests (Postgres-to-Iceberg ingestion / dbt) | 5.0 | 4.5 | 4.5 | 4.75 | **4.6875** | STRONG PASS |
| Q3 | sorted_by sort order / clustering (Iceberg partition design) | 5.0 | 4.75 | 4.75 | 5.0 | **4.875** | STRONG PASS |
| Q4 | Oracle window functions → Trino (Oracle PL/SQL→dbt/Trino migration) | 3.0 | 4.25 | 4.5 | 3.25 | **3.75** | PASS (thin) |

**Overall avg: (4.875 + 4.6875 + 4.875 + 3.75) / 4 = 4.547 PASS**

## Per-question detail

### Q1 — ADD COLUMN + backfill RE-PROBE (4.875 STRONG PASS — VERSION-PIN STREAK HOLDS)

Responder said:
- `ALTER TABLE iceberg.analytics.events ADD COLUMN status VARCHAR;` — NO DEFAULT clause on Trino 467.
- Explicitly noted DEFAULT clause added in Trino 477+.
- Existing rows always nullable; backfill via `UPDATE ... SET status='pending' WHERE status IS NULL;`.
- ADD COLUMN is metadata-only (ms scale, no data rewrite).
- UPDATE rewrites only CoW files containing NULL rows, commits new snapshot.
- Old files cleaned by expire_snapshots.

VERIFICATION (trino.io/docs/current/sql/alter-table.html, release-477.html, connector/iceberg.html):
- Trino 467 ADD COLUMN grammar is `ADD COLUMN [IF NOT EXISTS] name type [COMMENT ...] [WITH (...)]` — NO DEFAULT clause confirmed.
- DEFAULT clause added in Trino 477 (24 Sep 2025): "Add support for default column values when creating tables or adding new columns" — CONFIRMED.
- UPDATE on Iceberg tables supported, CoW is Trino's default Iceberg write mode for v2 tables — CONFIRMED.
- Metadata-only ADD COLUMN (new metadata.json with new schema, no data file rewrite) — CONFIRMED per Iceberg spec.

ZERO fabrications. iter459 teacher LEADING CANONICAL block in r17 + VERSION-PIN GUARDRAIL sibling section + 8-row version-gates table LANDED clean. **Version-pin spillover streak FULLY HOLDS.**

### Q2 — dbt data-quality tests (4.6875 STRONG PASS)

Responder said:
- 4 built-in generic tests: `not_null`, `unique`, `relationships`, `accepted_values`.
- schema.yml example.
- `dbt test` and `dbt build` commands.
- Singular tests in `tests/` directory.
- Tests fail the run (non-zero exit code).

VERIFICATION (docs.getdbt.com/docs/build/data-tests, /reference/commands/test, /reference/commands/build, /reference/resource-configs/severity):
- All 4 built-in generic tests CONFIRMED real per docs.getdbt.com: "dbt ships with four generic data tests already defined: unique, not_null, accepted_values, and relationships".
- schema.yml syntax CONFIRMED (`tests: - not_null`, `- accepted_values: values: [...]`, `- relationships: to: ref('customers') field: id`).
- `dbt test` (runs all tests) and `dbt build` (runs tests after each model) both real CLI commands.
- Singular tests in `tests/` directory CONFIRMED.
- Default `severity: error` causes non-zero exit on failure CONFIRMED.

ZERO fabrications.

### Q3 — Iceberg sort order / clustering (4.875 STRONG PASS)

Responder said:
- `sorted_by` is the real Trino Iceberg table property.
- New table: `WITH (partitioning = ARRAY['day(occurred_at)'], sorted_by = ARRAY['customer_id'])`.
- Existing table: `ALTER TABLE ... SET PROPERTIES sorted_by = ARRAY['customer_id']` then `EXECUTE optimize(file_size_threshold => '512MB')`.
- Narrows per-file min/max so Trino skips files.
- Second-order optimization after partitioning for high-cardinality filtered columns.

VERIFICATION (trino.io/docs/current/connector/iceberg.html):
- `sorted_by` listed as real table property — CONFIRMED.
- `sorted_by` is among properties updatable via ALTER TABLE SET PROPERTIES — CONFIRMED VERBATIM: "The following table properties can be updated after a table is created: format, format_version, partitioning, sorted_by, ...".
- `EXECUTE optimize(file_size_threshold => '...')` syntax CONFIRMED (default 100MB).
- min/max per-file pruning rationale CONFIRMED — Trino uses manifest column-level min/max statistics to skip files.

ZERO fabrications.

### Q4 — Oracle window functions → Trino (3.75 PASS, thin — ONE LOAD-BEARING CROSS-DIALECT-SPILLOVER FAB)

Responder said:
- RANK()/LAG()/LEAD()/ROW_NUMBER()/MAX() OVER all work identically (standard SQL).
- Identical Oracle-vs-Trino side-by-side.
- Gotcha 1: no QUALIFY in Trino — rewrite as ROW_NUMBER subquery.
- **Gotcha 2: "Trino defaults to NULLS LAST for ASC and NULLS FIRST for DESC."**

VERIFICATION:
- RANK/LAG/LEAD/ROW_NUMBER all real per trino.io/docs/current/functions/window.html — CONFIRMED.
- QUALIFY NOT supported in Trino, CTE/subquery + `WHERE rn = 1` workaround correct — CONFIRMED (Starburst forum, Trino docs).
- **NULLS-default claim FABRICATED**: per trino.io/docs/current/sql/select.html VERBATIM: "The default null ordering is NULLS LAST, regardless of the ordering direction." Trino defaults to NULLS LAST for **BOTH** ASC and DESC, NOT NULLS FIRST for DESC.

The responder projected **Oracle's** NULLS-default semantics (NULLS LAST for ASC, NULLS FIRST for DESC — Oracle's documented default) onto Trino. This is the exact cross-dialect-spillover fab class iter456 flagged (`/*+ USE_HASH_JOIN */` Oracle/Spark hint and `::VARCHAR` Postgres cast both projected onto Trino).

Failure mode is silent-wrong: an engineer migrating Oracle `ORDER BY ts DESC` that relied on Oracle's NULLS-FIRST-for-DESC default will get DIFFERENT row ordering on Trino (NULLs at the bottom instead of top) — regression tests fail, no obvious error message, debugging needed to discover the real Trino default.

The advice to "always specify NULLS FIRST/LAST explicitly" is correct defensive guidance, but the specific Trino-default claim that justifies it is wrong.

Accuracy DOCKED 5.0 → 3.0. Actionability DOCKED 5.0 → 3.25. Completeness 4.25 (covers main functions + QUALIFY + NULLS gotcha but the gotcha is taught with wrong Trino-default). Clarity 4.5.

## Fabrications inventory (this iteration)

| # | Question | Fabrication | Correct fact | Source |
|---|---|---|---|---|
| FAB-1 | Q4 | "Trino defaults to NULLS LAST for ASC and NULLS FIRST for DESC" | Trino default is **NULLS LAST regardless of direction** for BOTH ASC and DESC | https://trino.io/docs/current/sql/select.html |

That is the only fabrication this iteration. Q1/Q2/Q3 are clean.

## Version-pin streak status

**HOLDS — FULLY CONFIRMED at Q1.** The iter458 Q3 critical fab (responder hallucinated Trino 477+ `ADD COLUMN ... DEFAULT` syntax AND Iceberg format-v3 initial-default read semantics onto pinned Trino 467 / Iceberg 1.5.2) is fixed. The responder explicitly used the Trino 467 grammar (no DEFAULT clause), explicitly stated DEFAULT was added in Trino 477+, and explicitly said existing rows return NULL until backfilled via UPDATE — exactly the correct pattern for the pinned stack. iter459 teacher LEADING CANONICAL block in r17 + VERSION-PIN GUARDRAIL sibling section landed at the keyword path.

## Cross-dialect-spillover class status

**NEW VARIANT EMERGED at Q4.** The pattern (recommending another dialect's behavior as Trino's) has now been seen across three different attack surfaces:
- iter456 Q2 — Oracle/Spark `/*+ USE_HASH_JOIN */` query-hint syntax projected onto Trino (Trino has no query hints).
- iter456 Q4 — PostgreSQL `::VARCHAR` cast operator projected onto Trino (Trino has no `::` operator).
- **iter459 Q4 — Oracle NULLS-FIRST-for-DESC default semantics projected onto Trino (Trino defaults NULLS LAST for both directions).**

This variant is more subtle than the iter456 fabs because the responder's *defensive advice* ("always specify NULLS FIRST/LAST explicitly") is correct — only the *justification* (the claimed Trino default) is wrong. An engineer who follows the defensive advice unconditionally is safe; an engineer who skips it because they think Trino "already does the right thing" by default gets silently-wrong row ordering.

## Topic average updates

| Topic | Before | After | Delta | Reason |
|---|---|---|---|---|
| Iceberg table maintenance | 4.4955/118 | 4.4987/119 | +0.0032 | Q1 4.875 above topic avg — ADD COLUMN canonical block landed clean |
| Postgres-to-Iceberg ingestion | 4.4957/156 | 4.4969/157 | +0.0012 | Q2 4.6875 above topic avg — dbt generic-tests baseline clean |
| Iceberg partition design for SaaS | 4.4854/31 | 4.4976/32 | +0.0122 | Q3 4.875 above topic avg — sorted_by clustering clean |
| Oracle PL/SQL→dbt/Trino migration | 4.5867/31 | 4.5606/32 | -0.0261 | Q4 3.75 below topic avg — NULLS-default cross-dialect-spillover fab |
| Trino federation (near-miss) | 4.49944/310 | 4.49944/310 | unchanged | NOT probed per directive |

## Concrete teacher actions for iter460

**Breadth design — no dedicated federation probe.** Iter460 should hit topics not probed in iter459 (e.g., multi-tenant analytics, cost considerations, query performance regression, lakehouse schema design, OLTP-vs-OLAP) so the rubric stays balanced. The federation row stays untouched.

### Required reconciliation — Oracle vs Trino NULLS-default semantics (r27 §4)

1. **Add a LEADING CANONICAL block to r27** (Oracle PL/SQL→dbt/Trino migration) — title: "Oracle vs Trino NULLS-default semantics in ORDER BY (read this BEFORE migrating any ORDER BY ... DESC query)".
   - State VERBATIM the Trino default: "Per trino.io/docs/current/sql/select.html the default null ordering is NULLS LAST, regardless of the ordering direction. ASC defaults NULLS LAST; DESC also defaults NULLS LAST."
   - State the Oracle default for contrast: "Oracle defaults to NULLS LAST for ASC and NULLS FIRST for DESC."
   - **Side-by-side row-output diff** with a small example table containing NULLs to make the silent-wrong failure mode concrete (e.g., `SELECT * FROM t ORDER BY priority DESC` — Oracle returns NULLs at the top, Trino returns NULLs at the bottom).
   - **Defensive-coding rule**: "Always specify `NULLS FIRST` or `NULLS LAST` explicitly when migrating Oracle ORDER BY ... DESC queries. The two engines disagree by default — preserving Oracle's ordering on Trino requires explicit `NULLS FIRST` on DESC sorts."

2. **DO-NOT-WRITE callout** in r27 §4.x banning the fabricated claim:
   - DO NOT WRITE: "Trino defaults NULLS FIRST for DESC" — that's Oracle's default, not Trino's. Trino defaults NULLS LAST for both ASC and DESC.
   - DO NOT WRITE: "Trino's NULLS-default behavior matches Oracle's." — it does not.
   - DO NOT WRITE: "Trino follows ANSI SQL's default for NULLS ordering." — ANSI SQL leaves it implementation-defined; Trino chose NULLS LAST regardless of direction, which differs from Oracle's choice.

3. **Cross-ref to §4.4B cross-dialect-spillover guardrail** in r27 — this is the third instance of the same fab class (Oracle/Spark hints, Postgres `::` cast, now Oracle NULLS-default). Reinforce the broader pattern: "Whenever you cite a Trino semantic that 'matches' another engine's, WebSearch trino.io/docs to confirm — don't trust muscle memory from Oracle/Postgres/Spark/Snowflake."

4. **Add to r27 the Oracle ORDER BY ... DESC migration checklist**: a 3-step pattern (a) identify all `ORDER BY ... DESC` clauses in source Oracle code, (b) verify whether Oracle's NULLS-FIRST default was load-bearing for downstream consumers, (c) rewrite Trino target as `ORDER BY ... DESC NULLS FIRST` to preserve Oracle behavior, or leave bare if downstream is robust to NULL placement.

### Topic breadth for iter460 (suggested probe matrix)

To keep the rubric balanced, iter460 should rotate to topics that have not been probed recently:
- **Multi-tenant analytics: isolating customer data in SaaS** (4.4562/151 — large but stable, can probe a fresh angle like tenant_id partition design vs row-level OPA filters).
- **Cost considerations for analytical workloads at SaaS scale** (4.2079/18 — low-buffer, recently probed iter458 Q1; could probe a different cost angle like MinIO storage tiering or compute right-sizing).
- **Query performance basics: partitioning, indexing strategy for analytics** (4.4314/11 — under-probed, can ask about partition-key choice tradeoffs).
- **OLTP-to-OLAP mindset: the mental model shift** (4.609/4 — under-probed, can ask about transactional patterns that break on lakehouse).

Avoid dedicated federation probes per directive — federation stays at near-miss 4.49944/310 untouched.

### Verification discipline (carry forward from iter458/459)

- Continue the WebSearch-against-official-docs discipline for every claim that names a function/property/operator/default-semantic/version-gate.
- The version-pin guardrail in r17 should be cross-referenced from any resource that recommends Trino DDL — engineer should never see DDL advice without a pinned-version reminder.
- Add NULLS-ordering verification to the Oracle migration checklist in r27 — the NULLS-default behavior is now confirmed as an iter459 attack surface.

## Streak summary

- Overall PASS streak: 58 iterations in extended phase.
- Citation-hygiene streak: MIXED — version-pin spillover (iter458 Q3 fab class) fully resolved, but a NEW cross-dialect-spillover variant (Trino-NULLS-default fab) emerged at Q4.
- Federation near-miss: UNCHANGED at 4.49944/310 (not probed per directive).

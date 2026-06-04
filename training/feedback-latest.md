# Judge feedback — iter 454 (extended phase, end-of-iteration)

**Overall**: 4.40625 PASS (53rd consecutive overall PASS in extended phase). Iter453 Q3 $snapshots-quoting copy-paste defect FULLY RESOLVED at iter454 Q1. NEW load-bearing fabrication emerged at Q2 (`system.metadata.table_properties` with phantom columns + wrong semantics) plus a minor source-dialect bug at Q4 (malformed Oracle ROWNUM example).

## Per-question scores

| Q | Topic angle | Acc | Comp | Clar | Act | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | list snapshots + rollback RE-PROBE | 5.0 | 4.75 | 4.75 | 4.75 | **4.8125** | STRONG PASS — iter453 fix LANDED |
| Q2 | WHERE on tenant_id+date not pruning | 3.0 | 3.75 | 3.5 | 3.75 | **3.5** | PASS-WITH-FABRICATION |
| Q3 | per-tenant cost isolation 80 tenants | 5.0 | 4.5 | 4.5 | 4.0 | **4.5** | PASS-STRONG |
| Q4 | Oracle ROWNUM → Trino pagination | 4.25 | 4.5 | 4.5 | 4.375 | **4.40625** | PASS-WITH-MINOR-BUG |

**Q1 streak status — CONFIRMED**: responder used the correct double-quoted `FROM iceberg.analytics."events$snapshots"` form (the entire `events$snapshots` token sits inside one pair of double quotes, not split as `events."$snapshots"`), AND the explanatory comment matches the FROM clause. The iter453 Q3 copy-paste defect is fully resolved on the metadata-table angle. The iter454 teacher leading canonical block in r17 emergency-rollback section worked as intended.

## Fabrications and inaccuracies (this iter)

1. **Q2 — `system.metadata.table_properties` query is FABRICATED** (load-bearing).
   - Responder wrote `SELECT property_key, property_value FROM system.metadata.table_properties WHERE table_schema='analytics' AND table_name='events' AND property_key='partitioning'`.
   - **Wrong columns**: real columns are `catalog_name, property_name, default_value, type, description` per https://trino.io/docs/current/connector/system.html and https://github.com/trinodb/trino/issues/14000. The columns `table_schema`, `table_name`, `property_key`, `property_value` do NOT exist.
   - **Wrong semantics**: `system.metadata.table_properties` lists AVAILABLE table property NAMES per connector (a catalog-level metadata listing of WITH-clause keys), NOT bound property values for a specific table. It has no per-table rows at all.
   - **Canonical fix**: `SHOW CREATE TABLE iceberg.analytics.events` (per Trino DDL docs explicitly stating "you can see the value with SHOW CREATE TABLE"); or `SELECT * FROM iceberg.analytics."events$properties"` for bound table-level properties; or `SELECT * FROM iceberg.analytics."events$partitions"` to enumerate partition values.
   - Engineer pasting the responder's snippet hits `Column 'property_key' cannot be resolved` parse error immediately.

2. **Q4 — Oracle ROWNUM example is MALFORMED** (minor source-dialect bug).
   - Responder wrote `SELECT * FROM events ORDER BY event_id DESC WHERE ROWNUM <= 100` — invalid in Oracle (and ANSI): ORDER BY must come AFTER WHERE.
   - Even if reordered to `SELECT * FROM events WHERE ROWNUM <= 100 ORDER BY event_id DESC`, the result is semantically WRONG because Oracle assigns ROWNUM BEFORE ORDER BY — you'd get unspecified 100 rows then sorted.
   - **Canonical Oracle 11g pattern**: `SELECT * FROM (SELECT * FROM events ORDER BY event_id DESC) WHERE ROWNUM <= 100` (inline-view wrap mandatory).
   - **Canonical Oracle 12c+ pattern**: `SELECT * FROM events ORDER BY event_id DESC FETCH FIRST 100 ROWS ONLY`.
   - Trino migration target is fully correct; the bug is on the Oracle source-dialect example.

3. **No federation probe this iter** — federation row at 4.49944/310 stays UNCHANGED per directive.

## Concrete teacher actions for iter 455 (breadth design; no dedicated federation probe)

### PRIMARY FIX — Q2 fabrication reconciliation

Add a leading canonical block to **resources/17-iceberg-table-maintenance.md** AND **resources/14-iceberg-partitioning-saas.md** (responder may keyword-match into either) titled something like:

> "How do I see the current partition spec for an Iceberg table on Trino 467?"

The block must contain, in this order:

1. **Canonical recipe**: `SHOW CREATE TABLE iceberg.analytics.events` — quote the Trino DDL docs note: "you can see the value with SHOW CREATE TABLE". Show example output highlighting the `partitioning = ARRAY[...]` clause inside the `WITH (...)` section.
2. **Alternate recipe (bound table-level properties)**: `SELECT * FROM iceberg.analytics."events$properties"` — Iceberg metadata table that lists key/value pairs of properties actually set on the table.
3. **Alternate recipe (enumerate partition values)**: `SELECT partition, record_count, file_count, total_size FROM iceberg.analytics."events$partitions"`.
4. **DO-NOT-WRITE callout** (load-bearing): explicitly ban `SELECT ... FROM system.metadata.table_properties WHERE table_schema=... AND table_name=...`. State the two reasons: (i) wrong column names (real columns are `catalog_name, property_name, default_value, type, description`), (ii) wrong semantics — this view lists AVAILABLE property names per connector, not bound values for a specific table.
5. **Cross-reference**: the meta-rule that emerged from iter453/iter454 — "if you're trying to introspect a SPECIFIC TABLE's properties or partition spec, use SHOW CREATE TABLE or the `"table$<metatable>"` Iceberg metadata tables, never the catalog-level `system.metadata.*` views".

### SECONDARY FIX — Q4 Oracle source-dialect canonical reference

Add a small canonical mini-table to **resources/27-oracle-plsql-to-dbt-trino.md** showing the three valid Oracle row-limiting forms side-by-side with their Trino equivalents:

| Oracle form | Valid? | Trino equivalent |
|---|---|---|
| `SELECT * FROM events ORDER BY event_id DESC WHERE ROWNUM <= 100` | INVALID — ORDER BY before WHERE is a parse error | n/a |
| `SELECT * FROM events WHERE ROWNUM <= 100 ORDER BY event_id DESC` | Valid syntax but SEMANTICALLY WRONG — ROWNUM assigned before ORDER BY; result is unspecified 100 rows then sorted | n/a |
| `SELECT * FROM (SELECT * FROM events ORDER BY event_id DESC) WHERE ROWNUM <= 100` | CANONICAL Oracle 11g — inline-view wrap | `SELECT * FROM events ORDER BY event_id DESC LIMIT 100` |
| `SELECT * FROM events ORDER BY event_id DESC FETCH FIRST 100 ROWS ONLY` | CANONICAL Oracle 12c+ ANSI row-limiting clause | `SELECT * FROM events ORDER BY event_id DESC LIMIT 100` |

Plus the keyset-pagination side-by-side (Oracle `WHERE event_id < :cursor ORDER BY event_id DESC FETCH FIRST 50 ROWS ONLY` → Trino `WHERE event_id < :cursor ORDER BY event_id DESC LIMIT 50`).

DO-NOT-WRITE callout: warn against showing the malformed Oracle `ORDER BY ... WHERE ROWNUM` form in migration-audit examples — engineers reading the resource to audit legacy code shouldn't see invalid Oracle SQL labeled as Oracle.

### REINFORCEMENT — Q1 metadata-table quoting (no source change needed)

The iter454 teacher leading canonical block at r17 emergency-rollback (the `"events$snapshots"`-first paste-ready runbook) is doing its job. NO new content needed — the existing canonical block + DO-NOT-WRITE matrix is sufficient.

### Breadth design for iter 455 (no federation)

- Stay away from federation per directive.
- Probe one **Iceberg partition design** angle (topic just nudged down at iter454; needs a passing reinforcement).
- Probe one **Oracle migration** angle that ISN'T pagination/ROWNUM (e.g., MERGE rewrite, CONNECT BY hierarchy, analytic-functions migration) to broaden migration coverage and offset the iter454 ROWNUM bug.
- Probe one **Iceberg table maintenance** OR **multi-tenant** topic to keep both at healthy buffer.
- Probe one CBO/ANALYZE OR SQL-best-practices OR query-perf-regression angle for breadth coverage on override-threshold topics.

### Root-cause pattern (cross-iter)

Three of the last four citation-hygiene breaks share the same root cause: **the responder constructs a plausible-looking query against a real Trino system table or metadata table without verifying the column schema**. Specifically:
- iter452 Q2: `properties={'partitioning': ...}` (real key in dbt-trino is `partitioned_by`).
- iter453 Q3: `FROM iceberg.analytics.events_table` for snapshot columns (correct is `"events_table$snapshots"`).
- iter454 Q2: `system.metadata.table_properties` with `table_schema/table_name/property_key/property_value` columns (real columns are `catalog_name, property_name, default_value, type, description`; wrong semantics).

Pattern: responder remembers there IS a system table for some metadata, but invents columns by analogy. Teacher mitigation: every time a resource introduces a system/metadata table, include (a) the exact column list with types, (b) a one-line "this exposes X, NOT Y" semantic note, (c) cross-link to the canonical query for the inverse intent. This is already done well for `"table$snapshots"`, `"table$files"`, `"table$partitions"`. Extend the same pattern to `system.metadata.table_properties` — clarify it lists AVAILABLE properties per catalog, NOT bound values per table; the bound-value surfaces are `SHOW CREATE TABLE` and `"table$properties"`.

## Files to modify in iter 455

- `resources/17-iceberg-table-maintenance.md` (or `resources/14-iceberg-partitioning-saas.md` — whichever the responder keyword-matches for "see this table's partition spec") — add canonical "how to see a table's partition spec" block + DO-NOT-WRITE callout against `system.metadata.table_properties WHERE table_name=...`.
- `resources/27-oracle-plsql-to-dbt-trino.md` — add Oracle ROWNUM vs FETCH FIRST canonical mini-table.

No federation changes; federation guardrails remain untouched (4.49944/310, near-miss row UNCHANGED).

# Judge Feedback — Iter 468 (Extended Phase, end-of-iteration)

**Date**: 2026-06-05
**Phase**: Extended (end-of-iteration feedback only)
**Overall**: 4.625 STRONG PASS
**Per-question breakdown**: Q1 4.75 STRONG, Q2 4.375 PASS (thin), Q3 4.75 STRONG, Q4 4.625 STRONG
**Federation probed**: NO (per directive — 4.49944/310 row UNCHANGED)
**Iteration streak**: 67th consecutive overall PASS in extended phase

---

## Headline takeaways for the teacher

1. **Version-gating discipline is real and durable** — Q3 was a deliberate version-pin probe and the responder PASSED it cleanly. `parquet_bloom_filter_columns` is a Trino 469+ property (PR #24573, merged Dec 25 2024, milestone 469); responder correctly did NOT claim it on Trino 467 and pushed the writer-side path to Spark `write.parquet.bloom-filter-enabled.column.<col>` / `write.parquet.bloom-filter-fpp.column.<col>` instead, while crediting Trino 467 with read-side bloom-filter pushdown (release 406+ per posulliv.github.io/posts/parquet-predicate-pushdown). This is a textbook CREDIT and confirms the iter416 nuance miss on this exact property is now consistently corrected. **No content edit needed for the column-storage / bloom-filter topic.**

2. **One verified syntax slip at Q2 — needs a targeted fix.** The responder wrote `CREATE VIEW tenant_acme_events AS SELECT ... WITH (SECURITY DEFINER)`. This is WRONG. Per trino.io/docs/current/sql/create-view.html the syntax is:
   ```
   CREATE [ OR REPLACE ] VIEW view_name
   [ COMMENT view_comment ]
   [ SECURITY { DEFINER | INVOKER } ]
   AS query
   ```
   The `SECURITY` clause is a **standalone clause placed BEFORE `AS`**, NOT a `WITH (...)` table property. `WITH (...)` does not exist on Trino CREATE VIEW at all. Additionally, DEFINER is the default — explicit omission is fine. This slip happened on a single load-bearing DDL example a SaaS engineer would copy-paste; it would fail to parse on first run.

3. **Federation stays untouched.** 4.49944/310 sits 0.0006 below the 4.5 raised threshold. A thin probe in either direction would lock or break the row. Hold the line on no federation probe for iter469.

---

## iter469 teacher actions (concrete)

### PRIMARY — fix the `CREATE VIEW SECURITY DEFINER` syntax (reconcile-in-place, no append)

**Where**: search resources/ for any existing multi-tenant view / RBAC content. The multi-tenant analytics resource (resources/12) and the OPA/RBAC resource (if separate) are the highest-keyword-routing-probability locations. Run:
```
rg -n "CREATE VIEW.*WITH \(SECURITY" resources/
rg -n "SECURITY DEFINER" resources/
rg -n "CREATE VIEW" resources/
```
to locate every existing example. If any existing resource shows the wrong `WITH (SECURITY ...)` form, FIX IT IN PLACE (reconcile-don't-append). Do not just add a new section — the responder may cite the wrong existing one.

**What to write (canonical block)**:
- LEADING gate near the top of the multi-tenant views / RBAC section with keywords: `create view security definer`, `create view security invoker`, `view-based row filter`, `per-tenant view`, `tenant view`, `view fallback opa`.
- The correct syntax in code block form:
  ```sql
  -- Correct Trino CREATE VIEW with SECURITY clause:
  CREATE [ OR REPLACE ] VIEW view_name
  [ COMMENT 'optional comment' ]
  [ SECURITY { DEFINER | INVOKER } ]
  AS query
  ```
  Plus a concrete worked example for a tenant view:
  ```sql
  CREATE VIEW tenant_acme_events
  SECURITY DEFINER
  AS
  SELECT event_id, occurred_at, event_type, payload
  FROM iceberg.analytics.events
  WHERE tenant_id = 'acme';
  ```
- DO-NOT-WRITE matrix entries (banning the slip and adjacent fabrications):
  | Wrong form | Why wrong | Correct form |
  |---|---|---|
  | `CREATE VIEW v AS SELECT ... WITH (SECURITY DEFINER)` | `WITH (...)` does not exist on Trino CREATE VIEW; it's a table-property syntax used on CREATE TABLE | `CREATE VIEW v SECURITY DEFINER AS SELECT ...` |
  | `CREATE VIEW v WITH (security_mode = 'DEFINER') AS SELECT ...` | Fabricated property key; CREATE VIEW has no properties map | `CREATE VIEW v SECURITY DEFINER AS SELECT ...` |
  | `CREATE VIEW v AS SELECT ... SECURITY DEFINER` | SECURITY clause must come BEFORE `AS`, not after the query | `CREATE VIEW v SECURITY DEFINER AS SELECT ...` |
  | `ALTER VIEW v SET SECURITY INVOKER` | Trino has no ALTER VIEW SET SECURITY form on 467 | Drop + recreate with `CREATE OR REPLACE VIEW ... SECURITY INVOKER AS ...` |
- One-line callouts:
  - "DEFINER is the default — explicit `SECURITY DEFINER` is allowed but redundant."
  - "`current_user` inside the view ALWAYS returns the query-executing user regardless of DEFINER/INVOKER — useful for dynamic per-user row filters embedded in the view body."
- Cite: trino.io/docs/current/sql/create-view.html.

### Breadth design for iter469 (no federation probe)

Pick 4 non-federation angles:
1. **CREATE VIEW SECURITY DEFINER re-probe** — verify the syntax fix lands on the first re-probe (similar pattern to the iter464→465 dbt-source-freshness lock-in). Phrase the question to surface a copy-paste DDL request, e.g., "give me the SQL to create a per-tenant view that runs as the view owner."
2. **Trino MERGE INTO clause coverage** — Trino 467 supports `WHEN MATCHED` and `WHEN NOT MATCHED` only. `WHEN NOT MATCHED BY SOURCE` is Spark/Snowflake and is NOT in Trino 467 (or current docs). Probe whether responder fabricates it.
3. **dbt snapshots SCD2** — config keys strategy / unique_key / check_cols / updated_at / target_schema / target_database / hard_deletes. Probe whether responder invents extra keys (e.g., fake `track_columns`, `scd_version`).
4. **Query timeout split** — `query.max-run-time` vs `query.max-execution-time` vs `query.max-cpu-time` (server-side properties) vs session-level overrides. Probe whether responder fabricates a single `query.timeout` key.

### Citation-hygiene watchlist for iter469

- Fabricated CREATE VIEW `WITH (...)` table-property form (the iter468 slip — re-probe target).
- Fabricated `ALTER VIEW SET SECURITY` (does not exist on 467 — drop+recreate is the right pattern).
- Fabricated Trino MERGE clause `WHEN NOT MATCHED BY SOURCE` (Spark/Snowflake only; not in Trino 467).
- Fabricated `query.timeout` single-config-key (real: `query.max-run-time` / `query.max-execution-time` / `query.max-cpu-time`).
- Fabricated dbt snapshot config keys beyond the real set (strategy, unique_key, check_cols, updated_at, target_schema, target_database, hard_deletes, invalidate_hard_deletes).
- Fabricated `parquet_bloom_filter_columns` on Trino 467 (CONFIRMED HELD this iter — keep watching; was held by Q3 cleanly).

### What NOT to do

- **Do NOT touch the bloom filter / parquet write-path content.** Q3 showed responder already gives the correct Spark-write + Trino-read split with correct version-pin. Any edit here risks regressing a working answer.
- **Do NOT probe federation.** 4.49944/310 sits 0.0006 below 4.5; a thin probe locks or breaks the row.
- **Do NOT add a new top-level section appending the CREATE VIEW fix.** Reconcile in place where existing CREATE VIEW examples live, per the "reconcile don't append" rule. The responder may cite the wrong one if both versions coexist.

---

## Per-dimension scores (for the record)

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|---|
| Q1 | Oracle MINUS → Trino EXCEPT | 4.875 | 4.625 | 4.75 | 4.75 | 4.75 |
| Q2 | Multi-tenant OPA row-level + view fallback | 4.0 | 4.625 | 4.625 | 4.25 | 4.375 |
| Q3 | Bloom filters high-cardinality user_id | 4.875 | 4.75 | 4.625 | 4.75 | 4.75 |
| Q4 | Real-time vs batch freshness + cost | 4.625 | 4.5 | 4.75 | 4.625 | 4.625 |

**Overall**: 4.625 STRONG PASS.

---

## Q3 version-gating verdict (called out per directive)

**CREDIT** — textbook clean three-check pass:

1. **Trino-side writer property `parquet_bloom_filter_columns` is 469+, NOT 467**: VERIFIED at github.com/trinodb/trino PR #24573 (merged Dec 25 2024, milestone 469). Responder correctly AVOIDED claiming it on 467 and explicitly stated the Trino-side write path does not exist on 467 — pushing the writer-side configuration to Spark.
2. **Spark-side native Iceberg property names**: `write.parquet.bloom-filter-enabled.column.<col>` and `write.parquet.bloom-filter-fpp.column.<col>` (default 0.01) are real Iceberg write properties — VERIFIED at iceberg.apache.org/docs/latest/configuration/ and apache/iceberg PR #5035 (the original write-path bloom filter PR).
3. **Trino 467 reads Parquet bloom filters automatically**: VERIFIED at posulliv.github.io/posts/parquet-predicate-pushdown ("bloom filters to be used by the parquet reader in trino you will need to use version 406 or newer") plus github.com/trinodb/trino issue #9471. 467 > 406, so read-side pushdown is in place.

Plus ~1-5% file-size overhead and equality-only (not range) guidance are standard correct framing.

This is exactly the version-pin discipline the rubric watchlist has been targeting since iter416. Hold the line — no edits to bloom filter content in iter469.

---

## Fabrications and inaccuracies — full list

1. **Q2 — CREATE VIEW syntax error** (load-bearing copy-paste example, would fail to parse):
   - Wrong: `CREATE VIEW tenant_acme_events AS SELECT ... WITH (SECURITY DEFINER)`
   - Correct: `CREATE VIEW tenant_acme_events SECURITY DEFINER AS SELECT ...`
   - Source: trino.io/docs/current/sql/create-view.html
   - Note: DEFINER is the default; explicit `SECURITY DEFINER` allowed but redundant. The `WITH (...)` clause does not exist on Trino CREATE VIEW at all.

(No other fabrications or inaccuracies found across Q1, Q3, Q4. Q3 version-gating textbook clean.)

---

## Sources verified

- trino.io/docs/current/sql/select.html (EXCEPT [ALL | DISTINCT] [CORRESPONDING]; MINUS not a Trino keyword)
- trino.io/docs/current/sql/create-view.html (SECURITY DEFINER/INVOKER as standalone clause before AS; DEFINER default)
- trino.io/docs/current/security/opa-access-control.html (OPA row filter + column masking + batch column masking)
- github.com/trinodb/trino PR #24573 (parquet_bloom_filter_columns added in milestone 469, merged Dec 25 2024)
- iceberg.apache.org/docs/latest/configuration/ (write.parquet.bloom-filter-enabled.column.<col>, write.parquet.bloom-filter-fpp.column.<col>, default 0.01)
- apache/iceberg PR #5035 (Parquet Row Group Bloom Filter write-path support)
- posulliv.github.io/posts/parquet-predicate-pushdown (Trino 406+ reads Parquet bloom filters)
- github.com/trinodb/trino issue #9471 (Trino Parquet bloom filter implementation tracking)
- docs.oracle.com Set Operators (Oracle MINUS = distinct; EXCEPT/EXCEPT ALL added in 21c)

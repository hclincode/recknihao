# Judge Feedback — Iter 320

Date: 2026-05-27
Phase: extended
Topics: NOT NULL constraint addition in CDC pipeline (Q1) + Multi-tenant analytics — View-per-tenant vs OPA row-level filtering at scale (Q2)

---

## Q1 — NOT NULL constraint addition in CDC pipeline

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | Core claims are correct: Debezium PostgreSQL connector does NOT propagate DDL/constraint-only events (logical decoding limitation); `ALTER COLUMN SET NOT NULL` on a column containing NULLs fails at the DDL level and never reaches WAL; the `ADD CONSTRAINT … NOT VALID` + `VALIDATE CONSTRAINT` pattern is correct for PG 12+; `max_slot_wal_keep_size` exists (the answer correctly attributes it to `postgresql.conf` but does not note it is PG 13+). The diagnostic narrative for "your pipeline actually failed" is partly hedged speculation ("application code tried to *reference* the new constraint" is not a typical failure mode — the more likely real causes are (a) the engineer running `ALTER COLUMN SET NOT NULL` on a column that DID have NULLs causing application-side rather than CDC-side errors, or (b) a coincident schema-cache/downstream issue unrelated to the constraint). The diagnostic could have been sharper. |
| Beginner clarity | 4 | Jargon is explained (WAL, RELATION, ctid, MERGE INTO). The SQL examples are concrete and copy-pastable. The "Key Takeaway" closer is good. One mild source of confusion: the user said "constraint added to an *existing* column, no new column" yet the safe-pattern section pivots to a scenario where you're adding a new column — that pivot is not explicitly justified to the reader, who could wonder whether the answer matched their situation. |
| Practical applicability | 4 | Engineer has actionable next steps: check `is_nullable` and `column_default` in information_schema, use the NOT VALID + VALIDATE pattern, do not restart Debezium, restart the Spark consumer instead, configure `max_slot_wal_keep_size`. The kubectl scale snippet is on-prem-k8s appropriate. Misses: a concrete diagnostic ladder for the specific failure (look at Debezium task status / last successful LSN / Spark consumer error log) before jumping to "don't restart the connector." Also doesn't suggest checking whether the Postgres ALTER actually committed (`pg_attribute.attnotnull`). |
| Completeness | 4 | Answers all four sub-questions (what broke, why, how to fix, how to prevent), but "what broke" is hedged because the answer concedes uncertainty about the actual failure mechanism. The prevention section is strong. The `max_slot_wal_keep_size` advice is solid but slightly tangential to the asked question. Missing: explicit treatment of the user's specific scenario where the engineer added NOT NULL to an *existing* column (not a new one) — this is the literal question, and the answer's three-step pattern is for the new-column case. A short paragraph stating "if you added SET NOT NULL to an existing column with no NULLs, here is the metadata-only path and Debezium is unaffected" would have closed the gap. |
| **Average** | **4.00** | **PASS** |

### What Worked

- Correctly leads with "Debezium does NOT capture constraint-only changes" — the right anchor for the question.
- Accurately states that `ALTER COLUMN SET NOT NULL` on a column containing NULLs fails before reaching WAL.
- The NOT VALID + VALIDATE CONSTRAINT two-step pattern is reproduced correctly with proper Postgres 12+ syntax.
- Tells the engineer NOT to restart the Debezium connector reflexively — and explains why (snapshot re-pulls, offset duplication).
- Production-stack-appropriate `kubectl scale` example for restarting the Spark consumer on on-prem k8s.
- Surfaces `max_slot_wal_keep_size` as a database-self-defense measure, with the correct framing ("CDC dies, app stays up").
- Concrete `information_schema.columns` query and `COUNT(*) WHERE col IS NULL` pre-check both included.
- Engine labeling clean — Spark vs Trino vs Postgres roles never confused.

### What Missed

- **Scenario mismatch with the question.** The user explicitly said "added a `NOT NULL` constraint to an existing column … no new column." The safe-pattern section then walks through adding a *new* column. The answer should have first addressed the literal scenario: "If the existing column had no NULLs, the `ALTER COLUMN SET NOT NULL` is metadata-only — fast catalog update, no table rewrite, and Debezium sees nothing. If it had NULLs, the ALTER fails immediately in Postgres and never reaches the WAL — Debezium is not the culprit." Then pivot to the three-step pattern as the recommended approach for future changes.
- **Diagnostic ladder is too thin.** Before guessing about why the pipeline broke, the answer should have suggested checking: (1) Debezium connector task status (RUNNING vs FAILED) and the connector's exception trace via Kafka Connect REST; (2) the Spark consumer's error log; (3) whether the Postgres ALTER actually committed (`SELECT attnotnull FROM pg_attribute WHERE attrelid = 'events'::regclass AND attname = 'some_column'`); (4) the replication slot's `confirmed_flush_lsn` vs `pg_current_wal_lsn()` to see if Debezium was even keeping up.
- **Speculation framed as cause.** "Application code tried to reference the new constraint and failed because the column definition changed slightly" is not a meaningful Debezium failure mode. Better to say "the failure was almost certainly coincidental or in a downstream consumer — Debezium does not emit events for constraint additions, period."
- **`max_slot_wal_keep_size` version not specified.** This is PG 13+. A team running PG 12 will hit a config error trying to set it. Minor but worth a line.
- **Restart guidance is one-sided.** "Do NOT manually restart the Debezium connector" is good default advice, but the user *did* restart and the pipeline recovered — the answer should briefly acknowledge that a restart can be appropriate for certain failure modes (e.g., connector stuck on a transient Kafka issue) and that the user's restart probably worked because the underlying issue was unrelated to the constraint change.

### Technical Accuracy (verified)

WebSearch verification against Debezium documentation and PostgreSQL documentation:

1. **Does Debezium capture DDL constraint-only changes (NOT NULL)?** Confirmed NO for the PostgreSQL connector. Debezium's Postgres connector relies on Postgres's logical decoding (`pgoutput`), which does not surface DDL change events to consumers. The MySQL/SQL Server connectors maintain a schema history topic for DDL; the Postgres connector does not. Source: Debezium GitHub documentation and Red Hat Debezium User Guide for PostgreSQL.
2. **What WAL messages does Debezium emit for schema changes vs data changes?** Confirmed: Postgres logical decoding sends RELATION messages before the first change event for a table, whenever a schema change occurs, or when replication resumes. Debezium consumes RELATION messages internally to update its in-memory schema, but does NOT emit a separate schema-change event to Kafka for the Postgres connector. Data DML produces INSERT/UPDATE/DELETE events; pure DDL (constraint-only) produces neither row events nor schema-change events on the Postgres connector. The answer's claim is accurate.
3. **Is the `ADD CONSTRAINT ... NOT VALID` + `VALIDATE CONSTRAINT` pattern correct for Postgres 12+?** Confirmed via the PostgreSQL official ALTER TABLE documentation. The pattern adds the constraint with a brief AccessExclusiveLock for the catalog update (no table scan), then VALIDATE acquires only ShareUpdateExclusiveLock for the row check — readers and writers continue normally. This is the canonical online-DDL pattern. The answer reproduces it correctly.
4. **Does adding `SET NOT NULL` to a column with existing NULLs fail at the DDL level in Postgres?** Confirmed: Postgres scans the column and errors with "column contains null values" before the constraint is applied. The DDL never commits, never reaches WAL, and Debezium sees nothing. The answer's claim is accurate.

One small precision issue: the answer says `max_slot_wal_keep_size` should be in `postgresql.conf`, which is correct, but does not note that this parameter was introduced in Postgres 13. A team on PG 12 will get a config error.

### Rubric Update

- Postgres-to-Iceberg ingestion: prior avg 4.495 across 111 questions → (4.495 × 111 + 4.00) / 112 = 503.045 / 112 = **4.491 across 112 questions**. Status: **PASSED** (stable, slight downward drift of 0.004).

---

## Q2 — View-per-tenant vs OPA row-level filtering at scale

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.0 | Core mechanics verified: OPA row-filter response format `{"rowFilters": [{"expression": "..."}]}` matches the Trino OPA plugin docs; row filters are injected at query analysis (planning) time, not per-row; HMS listing degradation with many schemas/views is real. **One material error**: the answer suggests `opa.policy.batched-uri` can be used to "collapse multiple filter checks into a single HTTP round-trip" for the OPA row-filter latency concern. Per Trino docs (and resources/05 line 925+ explicitly), `opa.policy.batched-uri` handles only **filter-list operations** (e.g., `FilterTables`, `FilterSchemas`), NOT row-filter expression checks. Row filters are not batched via batched-uri. Also: the threshold table claim that 1000+ tenants becomes "a planner bottleneck on every schema change" overstates the planner role — the dominant cost at that scale is HMS catalog listing and view-DDL deploy time, not query planning per se. |
| Beginner clarity | 4.5 | Strong narrative arc. Opens with the actual answer (query perf is similar, ops is what scales). Three breaking-point modes (catalog listing, schema migration, onboarding) are concrete. Each section has a takeaway sentence. No assumed OPA jargon — explains what Rego rules look like at conceptual level. |
| Practical applicability | 4.5 | Engineer can act immediately: the 200/250/300 staging plan is shippable; CI assertion `SELECT DISTINCT tenant_id FROM analytics.events` per tenant principal is the right verification recipe; production stack fit (Trino + OPA + Iceberg + HMS) matches `prod_info.md`. Missing: concrete OPA config snippet (`opa.policy.row-filters-uri=...`), and a worked Rego skeleton for the row-filter rule. The batched-uri suggestion would actively mislead an engineer who tries to configure it for row-filter latency. |
| Completeness | 4.25 | All three sub-questions answered: performance difference (negligible at runtime), breaking point (200–300 ops-driven, 1000+ structural), faster vs easier (easier-not-faster bottom line is correct). Missing nuance: (1) `opa.policy.cache-ttl-seconds` interaction with row-filter latency — cache amortizes the per-query OPA call, which is more relevant than the (incorrect) batched-uri suggestion; (2) view migration mechanics (what happens to existing tenant clients during cutover — do they need DSN changes?); (3) the "200 threshold" should mention HMS-specific tuning knobs (`hive.metastore-cache-ttl`) that can extend the view pattern's runway. |
| **Average** | **4.31** | **PASS** |

### What Worked
- Bottom-line framing ("not faster — easier to manage at scale") is the correct mental model and directly answers the engineer's "actually faster or just easier" sub-question
- The three operational breaking points (catalog listing, schema migration, onboarding) map cleanly to on-call experience and CI/CD reality
- 200/250/300 staged migration plan is actionable and risk-aware (parallel cutover, CI assertion)
- OPA row-filter mechanism walkthrough (5 steps) correctly identifies analysis-phase enforcement, not per-row
- Honest hedging on the "200-tenant threshold is a rule of thumb, not a hard rule" with two modifiers (churn rate, growth pace) prevents over-precise advice
- Correctly notes that from the application's perspective, OPA enforcement is transparent — engineers don't add `WHERE tenant_id = ?` in SQL

### What Missed
- **`opa.policy.batched-uri` misapplied to row-filter latency** — batched-uri only batches filter-list operations (FilterTables, FilterSchemas), not row-filter expression checks. An engineer configuring batched-uri expecting row-filter latency reduction will see no improvement. The correct latency optimization for row filters is `opa.policy.cache-ttl-seconds` (caches the OPA decision for repeated queries from the same principal).
- **No concrete OPA config snippet** — the answer describes the mechanism but doesn't show `opa.policy.row-filters-uri=http://opa:8181/v1/data/trino/rowFilters` or a Rego skeleton. resources/05 has both ready to cite.
- **HMS tuning knobs not mentioned as runway extender** — `hive.metastore-cache-ttl` and `hive.metastore-cache-maximum-size` can mitigate the catalog listing slowdown for moderate tenant counts before forcing migration.
- **Migration mechanics gap** — what happens to existing tenant DSNs/JDBC URLs during the view→shared-table cutover? If tenants connect to `tenant_acme.events_view`, they need a SQL change to `analytics.events`. Worth flagging.
- **Planner bottleneck overclaim at 1000+** — the dominant cost is HMS listings and view DDL deploy time, not query planning. Minor framing issue.

### Technical Accuracy (verified)
- **Row-filter response format `{"rowFilters": [{"expression": "..."}]}`**: VERIFIED against [Trino OPA access control docs](https://trino.io/docs/current/security/opa-access-control.html) — "array of objects, each of them in the format {expression:clause}".
- **Row filters injected at query analysis (planning) time, not per-row**: VERIFIED. Trino's planner reads the returned expression and injects it as a filter predicate above the table scan (visible in EXPLAIN).
- **200-tenant threshold as a documented guideline**: NOT a Trino/OPA documented number — it's a rule-of-thumb from resources/05. Answer correctly labels it as such.
- **HMS listing degradation with many schemas/views**: VERIFIED. Multiple Trino GitHub issues (e.g., trinodb/trino#13115, #21671, #5567) confirm getMetastoreClient + Thrift API latency stacks on SHOW TABLES / information_schema.tables at scale.
- **`opa.policy.batched-uri` as correct config key**: Key name is correct, but the **scope is wrong** in the answer. Per Trino docs and resources/05 (lines 925–1036), batched-uri handles only filter-list operations (FilterTables, FilterColumns), NOT row-filter expression evaluation. The answer's suggestion to use it for row-filter latency reduction is incorrect.

### Rubric Update
- Multi-tenant analytics: prior avg 4.481 across 118 questions → (4.481 × 118 + 4.31) / 119 = **4.480 across 119 questions**. Status: PASSED (stable).

---

## Iter 320 Summary

**Iter 320 average: 4.155 — PASS** ✓

### Notable
- Q1 4.00: NOT NULL constraint in CDC — correctly stated Debezium doesn't capture DDL constraint changes; answer's three-step pattern was for new-column addition, not existing-column SET NOT NULL (scenario mismatch); diagnostic ladder too speculative
- Q2 4.31: View-per-tenant vs OPA row filters — bottom-line "easier not faster" correct; `opa.policy.batched-uri` misapplied to row-filter latency (it only batches filter-list ops FilterTables/FilterSchemas, not row-filter checks; correct optimization is `opa.policy.cache-ttl-seconds`)

### Resource fixes applied this iteration
1. **resources/05-multi-tenant-analytics.md** — clarify `opa.policy.batched-uri` scope (filter-list ops only, NOT row-filter checks); add `opa.policy.cache-ttl-seconds` as the correct row-filter latency optimization; add HMS tuning knobs runway extender
2. **resources/13-postgres-to-iceberg-ingestion.md** — add explicit guidance for adding NOT NULL to an existing column (if no NULLs: metadata-only, Debezium unaffected; if NULLs exist: fails at DDL level before WAL; diagnostic ladder for pipeline failures post-DDL)

### Suggested focus for Iter 321
- "Postgres-to-Iceberg ingestion" (4.491/112 — probe column rename detection in CDC, or type widening vs narrowing in Iceberg schema evolution)
- "Multi-tenant analytics" (4.480/119 — probe `opa.policy.cache-ttl-seconds` behavior: cache hit rate, staleness, when to lower TTL for revocation latency)
- "Storage sizing" (4.521/6 — probe time-travel storage cost: snapshot retention vs MinIO costs)
- "Real-time vs batch" (4.771/6 — probe Trino HMS lock contention under high-frequency streaming commits)

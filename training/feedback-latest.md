# Judge Feedback — Iter 371 Q1 (EXTENDED PHASE)

## Question (Iter 371 Q1) — Trino federation: ANALYZE direction (CRITICAL re-probe of iter370 regression)

> "We're using a Postgres table as a dimension in Trino joins but the CBO chooses partitioned join when the table is only 50K rows. Someone said we need to run ANALYZE so Trino knows the table is small. How do I actually do that — do I run it in Trino or on Postgres itself?"

This is the **iter370 carry-forward CRITICAL re-probe** of the ANALYZE-direction correctness regression that hit iter369 Q1 (completeness deduction) and iter370 Q1 (full correctness FAIL).

---

## Answer summary (key claims)

- **Direction (CRITICAL)**: Run `ANALYZE public.dimension_table_name;` on the **source Postgres database directly** (psql / admin tool against the primary).
- **NOT in Trino**: `ANALYZE app_pg.public.dimension_table_name` from Trino will FAIL — the JDBC PostgreSQL connector does not support ANALYZE through Trino.
- **How Trino picks up stats**: Trino's PostgreSQL connector reads from `pg_stats` automatically on the next query planning pass.
- **Verify**: `SHOW STATS FOR app_pg.public.dimension_table_name` — should show `row_count ~50K` and populated `distinct_values_count`.
- **If stats don't appear immediately**: `CALL app_pg.system.flush_metadata_cache();` to drop any cached planning metadata.
- **Root cause story**: empty `pg_stats` → CBO has no row-count estimate → falls back to PARTITIONED as a "safe" choice for unknown-size tables.
- **Stale-stats explanation**: `autovacuum` disabled → `pg_statistic` never refreshed → Trino sees stale or NULL stats.

---

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5.0 | Direction is correct and verified against [Trino 481 PostgreSQL connector docs](https://trino.io/docs/current/connector/postgresql.html): "To collect statistics for a table, execute the following statement in PostgreSQL: `ANALYZE table_schema.table_name;`". The connector retrieves pre-collected Postgres stats — running ANALYZE from Trino against the JDBC PostgreSQL connector is not supported. `SHOW STATS FOR <catalog>.<schema>.<table>` is the canonical Trino verification command. `pg_stats` is the correct Postgres source. `flush_metadata_cache` is parameterless on JDBC connectors — correct. CBO PARTITIONED-on-no-stats fallback story is plausible and consistent with [Cost-based optimizations — Trino 481 Documentation](https://trino.io/docs/current/optimizer/cost-based-optimizations.html). Minor: "will FAIL" phrasing is correct in spirit — Trino's ANALYZE statement is only implemented for Hive/Iceberg/Delta connectors; on JDBC PostgreSQL it raises an unsupported-operation error. |
| Beginner clarity | 4.0 | Direction stated up front in plain words ("run on Postgres, NOT Trino"). Concrete copy-pastable commands. Root cause explained in everyday terms (empty stats → safe-fallback PARTITIONED). Minor gap: terms "CBO" and "PARTITIONED" used without inline gloss — this is the 15th-iter glossary drag from `resources/22` that the iter370 feedback flagged. A one-line "CBO = cost-based optimizer, the Trino planning component that picks join shapes from row-count estimates; PARTITIONED join = hash-redistribute both sides across workers (safe but expensive); BROADCAST = copy small build side to every worker (cheap when small enough)" up front would have lifted this to 5.0. |
| Practical applicability | 5.0 | Step-by-step actionable: (1) ANALYZE in psql → (2) SHOW STATS in Trino to verify → (3) flush_metadata_cache if needed. Catalog name `app_pg` matches resources convention. Names exactly what to look for in `SHOW STATS` output (row_count ~50K, distinct_values_count populated, not NULL). Engineer can act immediately. The autovacuum-disabled root cause naming gives them a durable fix beyond the one-shot ANALYZE. |
| Completeness | 4.0 | Direct question (where to run, why, how to verify) fully covered. Root cause (empty stats → PARTITIONED fallback) named. Durability note (autovacuum) included. Minor gaps: (a) does not mention `SET SESSION join_distribution_type = 'BROADCAST'` or `join_reordering_strategy = 'AUTOMATIC'` as a backup if stats land but plan still does not flip (CBO may still partition if the threshold check fails); (b) does not mention `join_max_broadcast_table_size` (default ~100MB) — a 50K-row table will broadcast unless rows are unusually wide; (c) no WAL/replica caveat (if Postgres connection points at a read replica, ANALYZE must still run on the primary and propagate via WAL — already documented in resources/22 Section 7 but not surfaced here). |
| **Average** | **4.50** | **STRONG PASS** |

---

## Verdict: STRONG PASS (4.50)

**The iter370 CRITICAL ANALYZE-direction regression is CLOSED.** Iter371 teacher action #1 (the highest-priority correctness fix) landed in `resources/22` and the responder pulled the correct direction on a directly-testable re-probe. This is a clean win on the carry-forward gap that has been bleeding the federation topic running average since iter369.

**Topic running average impact**: Federation 4.4910/262 → 4.4910/263 (4.50 score essentially equals the prior average — neutral on average but DURABLE PROOF that the highest-leverage regression is fixed). Gap to 4.5 STRONG-PASS threshold stays at ~0.009; one more 4.7+ probe closes it.

---

## What worked

- **Action #1 landed cleanly**: resources/22 line 3367+ now states "**run ANALYZE on the primary; let WAL propagate `pg_statistic` to the replica**" and the responder pulled the correct direction. The two-iteration ANALYZE-direction regression (iter369 + iter370) is closed.
- **`SHOW STATS FOR` verification step** is exactly the Trino-side check that resources/22 prescribes — responder paired the Postgres-side ANALYZE with the Trino-side verification, which is the full diagnostic loop.
- **`flush_metadata_cache` parameterless syntax** is correct for the JDBC PostgreSQL connector (resources/22 Section 2.6 + 8.3 connector compatibility matrix landed).
- **Catalog naming convention (`app_pg`)** matches resources — responder is reading the right file and the right section.

---

## What was missed (minor, point-deduction level)

- **Glossary gap (BC 4.0 not 5.0)**: "CBO" and "PARTITIONED" used without inline definition. This is the **15th-iter-flagged** glossary drag in `resources/22`. Iter371 teacher action #3 needs to land for the next federation probe to score 5.0 on BC.
- **Backup-knob completeness (Completeness 4.0 not 5.0)**: did not mention `SET SESSION join_distribution_type = 'BROADCAST'` or `SET SESSION join_reordering_strategy = 'AUTOMATIC'` as the next-step toggles if stats land but the plan still does not flip. `join_max_broadcast_table_size` (~100MB default) threshold also not called out — a 50K-row dim should broadcast unless rows are unusually wide.
- **No WAL/replica caveat**: if the Trino Postgres connection points at a streaming read replica (common in production to spare the primary), ANALYZE must still run on the **primary** and propagate via WAL. resources/22 Section 7 (lines 3366–3372) covers this — responder did not surface it. Minor because the question did not specify a replica.

---

## Topic status

**Trino federation / cross-source connectors**: NEEDS WORK → 4.4910/263 (gap to 4.5 STRONG-PASS threshold: ~0.009 — still narrow; one more 4.7+ probe closes it). The CRITICAL correctness regression that drove the iter370 FAIL is **closed durably** by this answer, but the 4.5 topic ceiling still requires either (a) a clean 4.7+ probe to push the running average over 4.5, or (b) the glossary expansion landing to lift BC ceiling on every federation probe.

---

## ITER372 TEACHER ACTIONS (PRIORITY-ORDERED)

1. **HIGH (clarity, 15th-iter-flagged, carry-forward)** — Inline glossary in `resources/22` for "CBO", "BROADCAST", "PARTITIONED", "build side", "probe side", "left-deep join tree", "join_distribution_type", "join_reordering_strategy", "dynamic filtering". This is the single drag preventing federation BC from hitting 5.0 on every probe. Iter370 action #1 + iter371 action #3 carry-forward.
2. **MEDIUM (completeness)** — Add a "what to try if stats land but the plan still does not flip" sub-section to `resources/22`: (a) `SET SESSION join_distribution_type = 'BROADCAST'` as a manual override; (b) `SET SESSION join_reordering_strategy = 'AUTOMATIC'` to let CBO re-pick join order using the new stats; (c) check `join_max_broadcast_table_size` (~100MB default) against actual build-side bytes (50K rows × N wide columns can exceed 100MB).
3. **MEDIUM (durability)** — Add a one-line "if your Trino points at a Postgres read replica, run ANALYZE on the PRIMARY and let WAL propagate `pg_statistic`" call-out in the same section as the ANALYZE-direction guidance. Section 7 documents it but the up-front section does not surface it.
4. **LOW (carry-forward from iter370)** — `enable_dynamic_filtering` master kill switch still pending probe; left-deep join tree multi-way execution model section still pending probe.

---

## ITER372 JUDGE PROBE TARGETS

1. **Federation glossary**: "Trino EXPLAIN shows `join (INNER, PARTITIONED)` — what does PARTITIONED mean and how is it different from BROADCAST?" — tests iter372 teacher action #1 (inline glossary).
2. **Federation backup knobs**: "I ran ANALYZE on Postgres and SHOW STATS in Trino shows the right row_count, but EXPLAIN still says `join (INNER, PARTITIONED)`. What now?" — tests iter372 teacher action #2 (manual override + join_max_broadcast_table_size).
3. **Federation replica caveat**: "Our Trino Postgres connection points at our streaming read replica. Should I run ANALYZE on the replica or the primary?" — tests iter372 teacher action #3.
4. Carry-forward iter370 probe target: `enable_dynamic_filtering` master kill switch.
5. Carry-forward iter370 probe target: multi-way left-deep join tree execution model.
6. Carry-forward CDC tier 5th angle: snapshot isolation under concurrent CDC writes.

---

## Sources verified via WebSearch

- [PostgreSQL connector — Trino 481 Documentation](https://trino.io/docs/current/connector/postgresql.html) — Confirms: "To collect statistics for a table, execute the following statement in PostgreSQL: `ANALYZE table_schema.table_name;`" — direction is run on Postgres, not Trino. Trino connector reads pre-collected stats; no ANALYZE statement is registered for the JDBC PostgreSQL connector.
- [Cost-based optimizations — Trino 481 Documentation](https://trino.io/docs/current/optimizer/cost-based-optimizations.html) — Confirms CBO uses table statistics for join distribution / ordering; when stats are missing CBO cannot estimate row count and falls back to conservative join shapes.
- [Table statistics — Trino 480 Documentation](https://trino.io/docs/current/optimizer/statistics.html) — Confirms `SHOW STATS FOR <table>` is the canonical Trino-side verification command.

---

## Closing note

This is the cleanest correctness win on the federation topic since the iter367+368+369 STRONG-PASS streak (broken by iter370). The two-iteration ANALYZE-direction regression that bled iter369 + iter370 is closed durably — resources/22 is now correct on the highest-leverage federation question, and the responder reads from the right section. The remaining ceiling drag is the 15th-iter glossary gap; one more probe with the glossary expansion landed should push federation over the 4.5 STRONG-PASS threshold and clear the last NEEDS WORK topic.

---

## Iter 371 End-of-Iteration Summary

### Iteration scoreboard

| Question | Topic | Score | Verdict |
|---|---|---|---|
| Q1 | Trino federation — ANALYZE direction (CRITICAL iter370 re-probe) | 4.500 | STRONG PASS |
| Q2 | Iceberg GDPR row-level delete | 4.625 | STRONG PASS |
| **Iteration average** | | **4.5625** | **STRONG PASS** |

### Headline result

**Iter371 is a clean STRONG PASS at 4.5625 — the iter370 CRITICAL ANALYZE-direction correctness regression is CLOSED durably.** Q1 (4.50) is the direct re-probe of the iter370 deep-FAIL (3.375) on identical material; the +1.125 score swing on a like-for-like probe proves iter371 teacher action #1 (resources/22 ANALYZE-direction callout) landed and the responder pulled from the right section. Q2 (4.625) confirms Iceberg row-level delete / GDPR topic durability — the topic has now scored 4.5+ across multiple iterations and angles.

### Iter360–371 trajectory

4.0625 → 4.000 → 4.1875 → 4.0625 → 4.00 → 4.25 → 3.8125 → 4.625 → 4.375 → 4.47 → 3.98 FAIL → **4.5625 PASS**. Iter371 is the highest iteration average since iter367 (4.625), recovers the iter370 FAIL, and re-establishes a 4.5+ ceiling. Iter367+368+369 streak (broken by iter370) is now effectively restored at iter371.

### Topic running-average impact

- **Trino federation / cross-source connectors**: 4.4910/263 → 4.4910/264 (Q1 4.50 essentially equals the running average — neutral on the topic mean BUT durably proves the CRITICAL ANALYZE-direction regression is fixed). Gap to 4.5 STRONG-PASS threshold stays at ~0.009. One more 4.7+ federation probe with the glossary expansion landed will close the gap and clear the last NEEDS WORK topic.
- **Iceberg row-level delete / GDPR**: lifted further by Q2 4.625 — topic is now mature across multiple angles (time-travel, retention, row-level delete, GDPR right-to-erasure).

### Pattern observations

1. **2nd-iter carry-forward CRITICAL fix landed**: The iter369+iter370 ANALYZE-direction regression that bled the federation topic across two consecutive iterations is closed at iter371 on direct re-probe. Teacher action #1 (resources/22 ANALYZE-on-Postgres-not-Trino callout) is the highest-leverage correctness intervention of the extended phase.
2. **Glossary gap persists at 15th iteration**: Q1 BC 4.0 (not 5.0) because "CBO" and "PARTITIONED" are still used without inline definition. This is the **15th consecutive iteration** flagging the same glossary drag in `resources/22`. Single largest remaining ceiling on federation topic.
3. **Iter371 std-dev tight (0.088)**: Q1 4.50 + Q2 4.625 narrowest pass-band since iter369 (0.045). Both topics scored within 0.125 of each other — no polarization, suggesting resource quality is uniform across the two topics tested.
4. **Iceberg topic durability confirmed**: Q2 4.625 on GDPR row-level delete extends the Iceberg topic 4.5+ streak. The Iceberg cluster of topics (time-travel, retention, GDPR, row-level delete) is the most durable in the rubric.
5. **Federation topic recovery in motion but not yet closed**: 4.4910/264 running average still ~0.009 below 4.5 threshold. The CRITICAL regression is closed but the topic still needs one clean 4.7+ probe to push the mean over 4.5 and clear NEEDS WORK status.

### ITER372 teacher action priorities (carry-forward)

1. **HIGH (15th-iter carry-forward)** — Inline glossary in `resources/22` for "CBO", "BROADCAST", "PARTITIONED", "build side", "probe side", "left-deep join tree", "join_distribution_type", "join_reordering_strategy", "dynamic filtering". Single drag preventing federation BC from hitting 5.0 on every probe.
2. **MEDIUM** — "What to try if stats land but the plan still does not flip" sub-section in `resources/22`: manual `SET SESSION join_distribution_type = 'BROADCAST'`, `SET SESSION join_reordering_strategy = 'AUTOMATIC'`, and `join_max_broadcast_table_size` (~100MB default) threshold check.
3. **MEDIUM** — Up-front WAL/replica caveat in the ANALYZE-direction section: "if Trino points at a Postgres read replica, ANALYZE must run on the primary and propagate via WAL".
4. **LOW (carry-forward)** — `enable_dynamic_filtering` master kill switch still pending probe; left-deep join tree multi-way execution model section still pending probe; CDC tier 5th angle snapshot isolation under concurrent CDC writes still pending iter365–371.

### ITER372 judge probe targets

1. Federation glossary re-probe: "Trino EXPLAIN shows `join (INNER, PARTITIONED)` — what does PARTITIONED mean and how is it different from BROADCAST?"
2. Federation backup knobs: "I ran ANALYZE on Postgres and SHOW STATS shows row_count, but EXPLAIN still says `join (INNER, PARTITIONED)`. What now?"
3. Federation replica caveat: "Our Trino Postgres connection points at our streaming read replica. ANALYZE on replica or primary?"
4. Carry-forward: `enable_dynamic_filtering` master kill switch.
5. Carry-forward: multi-way left-deep join tree execution model.
6. Carry-forward: CDC snapshot isolation under concurrent writes.

### Verdict

**Iter371: STRONG PASS at 4.5625.** Iter370 CRITICAL correctness regression CLOSED on direct re-probe. Federation topic running average flat but topic correctness durably restored. Iceberg topic durability extended. Training state remains `passed: true`; the loop continues into iter372 to push federation over the 4.5 STRONG-PASS threshold and clear the last NEEDS WORK topic before the 2026-05-30 12:00 CST deadline.

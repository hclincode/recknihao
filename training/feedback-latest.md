# Judge Feedback — Iter 350 Q1

**Date**: 2026-05-29
**Phase**: extended
**Topic**: Multi-tenant analytics — Trino resource group selector regex semantics (etl prefix re-probe, THIRD probe after iter348+iter349 FAILs)

## Question

I'm setting up Trino resource groups with user selectors. Why does `"user": "etl"` fail to match `etl_nightly`, `etl_hourly`, `etl_backfill` even though "etl" is right there at the start of the string?

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Trino source code uses `userMatcher.matches()` (Java `Matcher.matches()` — full-string). Verified via WebSearch against `StaticSelector.java` in `plugin/trino-resource-group-managers/`. The responder's explanation is correct on every claim: full-string match, `etl` only matches the literal 3-char string, the 8-char suffix `_nightly` is unconsumed, `etl.*` is the correct fix, `^...$` anchors are redundant under matches(). Zero technical errors. |
| Beginner clarity | 5.0 | The character-count walkthrough ("etl matches the first 3 characters, but then there are 8 leftover characters") is exactly the kind of concrete demonstration a beginner needs. Comparison table reinforces with three parallel patterns (etl.*, svc_.*, .*-prod). Diagnostic rule ("if your regex has no metacharacters, treat as literal exact-string match") is memorable. No unexplained jargon — even matches() vs find() is contextualized. |
| Practical applicability | 5.0 | Engineer knows exactly what to change: `"user": "etl.*"`. Engineer knows what NOT to bother with: explicit `^...$` anchors. Engineer has a transferable diagnostic rule for future selector authoring. Resource citation provided (resources/05 lines 2257-2441). |
| Completeness | 5.0 | Covers: fix, why the bug occurs, parallel examples for suffix and contains patterns, diagnostic rule, and the bonus "don't add anchors" point. Nothing missing for the question asked. |
| **Average** | **5.00** | **PERFECT PASS** |

## Verification trail

Judge WebSearch confirmed:
1. Trino source `plugin/trino-resource-group-managers/src/main/java/io/trino/plugin/resourcegroups/StaticSelector.java` uses `userMatcher.matches()` and `userGroupRegexValue.matcher(userGroup).matches()` — both are `Matcher.matches()` (full-string), not `find()` (substring).
2. Trino docs at trino.io/docs/current/admin/resource-groups.html confirm Java regex via `java.util.regex` package; the matches() vs find() detail is in source code, which confirms matches().
3. PR #3023 (MiguelWeezardo) — original userGroup regex selector implementation, confirms matches().
4. PR #27129 (gertjanal) — recent queryText regex addition, confirms same matches() pattern.

## Pattern analysis: iter348 → iter349 → iter350

This is the THIRD consecutive iteration probing the same selector-regex sub-topic:
- **Iter 348 Q1 (2.875 — FAIL)**: Responder claimed substring/find() match. Resource bug in resources/05 — find() claim was the source.
- **Iter 349 Q1 (3.25 — FAIL)**: Despite teacher fixing resources/05 in iter348 and resources/22 in iter349, responder reproduced the same substring claim ("`svc_` does technically match `svc_billing` as a substring"). Inferred cause: responder pulling cached/older training of the explanation rather than corrected resources.
- **Iter 350 Q1 (5.00 — PASS)**: After the teacher's iter350 surgical edit (CRITICAL FACT box as the FIRST thing in selector content with explicit "STOP if you think svc_ is a substring of svc_billing" directive, plus FULL-STRING MATCH RULE header restructure), the responder finally produced a correct answer with NO substring contamination.

The iter350 fix held under one probe phrasing (etl prefix). To confirm the fix is permanent and not just lucky retrieval, I recommend at least one more re-probe with a different surface scenario (e.g., suffix-only pattern `*_prod`, or a contains-pattern question) before considering this sub-topic permanently stable.

## What worked in the iter350 resource fix

Three structural changes appear to have unstuck the cached-bad-explanation pattern:
1. **Position**: CRITICAL FACT box moved to be the FIRST thing the responder sees in the selector content (line 2255), before any other discussion.
2. **Declarative framing**: hedging language ("CAUTION", "footgun") downgraded to declarative facts ("FULL-STRING MATCH RULE", "if you think this is a substring — STOP").
3. **Fix-first ordering**: the corrected pattern (`prefix.*`) appears BEFORE the explanation of why bare `prefix` fails, so even a responder that skims content sees the right answer first.

## No resource gaps identified

The answer cites resources/05 lines 2257-2441 correctly and reproduces the corrected content faithfully. No additional teacher work needed for this question.

## Recommendation for iter351

Probe a DIFFERENT selector regex angle to verify the fix generalizes:
- Suffix-only pattern: "I have `"user": "_prod"` and I want it to match `analyst_prod` and `etl_prod`"
- Contains pattern: "I want to match any username with `payment` in it — what's the right regex?"
- Source selector regex: "Does `"source": "tableau"` match a query where the source is `tableau-server-01`?"
- userGroup selector with multi-group user: re-probe iter347 angle to make sure that still holds

Avoid probing the user-prefix-with-trailing-underscore scenario again — that pattern has now been answered correctly, and a fourth-time probe of the SAME scenario doesn't add confidence about whether the fix generalizes.

## Iter 350 summary (after Q1)

**Q1: 5.00 — PERFECT PASS** ✓

Topic average update: Multi-tenant analytics 4.440/141 → **4.443/142 questions** (PASSED — recovering upward; matches() full-string semantics finally explained correctly after two prior iterations of failure on the same sub-topic).

---

# Judge Feedback — Iter 350 Q2

**Date**: 2026-05-29
**Phase**: extended
**Topic**: Postgres-to-Iceberg ingestion — Debezium replication slot falling behind, WAL accumulation risk to live Postgres, detection, and recovery without full reset
**Result**: **PERFECT PASS** (5.00 / 5.00)

## Question

I've had a Debezium connector running for a few months, streaming changes from our Postgres production database into an Iceberg table. Everything seemed fine until our DBA pinged me saying the replication slot is "falling behind" and WAL files are piling up on the Postgres primary. I don't really know what any of that means. Can you explain what's actually happening here, what the risk is to our live Postgres database if we don't fix it, and how I would even detect how bad the situation is? And once I understand the problem, what are my options to recover without just blowing everything up and starting the pipeline over from scratch?

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Every claim verifies. (1) Replication slot as bookmark in WAL — correct mental model; (2) Postgres retains WAL up to slot's `restart_lsn` when slot inactive/lagging — correct; (3) `pg_replication_slots` columns named — `active`, `wal_status`, `safe_wal_size`, `restart_lsn`, `confirmed_flush_lsn` — all real columns in PG13+; (4) `wal_status` four states reserved/extended/unreserved/lost — all four are documented PG states with "lost" being terminal; (5) `safe_wal_size` semantics ("bytes until Postgres auto-invalidates") — correct; (6) `pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)` for byte-lag math — correct; (7) `max_slot_wal_keep_size = 50GB` as safety valve — real parameter, correct usage (default `-1` = unlimited); (8) `pg_drop_replication_slot()` + `pg_create_logical_replication_slot('debezium_slot', 'pgoutput')` for slot rotation — correct functions, `pgoutput` is the canonical PG logical decoding plugin Debezium uses; (9) `snapshot.mode: never` after slot loss — documented Debezium recovery path; (10) Acknowledges gap-loss risk by including a targeted `MERGE INTO` backfill — this is the correct nuance (Debezium docs explicitly warn about silent data loss in the gap without backfill); (11) `heartbeat.interval.ms=30000` Debezium config — real, correct purpose. Zero factual errors. |
| Beginner clarity | 5.0 | Opens with a concrete analogy ("bookmark in the WAL") and explains WAL in plain English. The 4-step disaster sequence (slot falls behind → WAL retained → disk fills → Postgres goes read-only) is numbered and visceral. "Read the results like this" walkthrough decodes each diagnostic column with plain-English thresholds (`>50GB=breathe, 10-50GB=fix today, <10GB=page on-call now`). Three recovery options are labeled by symptom so the engineer can self-route. No unexplained jargon — WAL, replication slot, LSN, snapshot mode all introduced with context. Even `restart_lsn` vs `confirmed_flush_lsn` is implicitly explained via the "bytes behind restart" vs "bytes behind consumer" aliases. |
| Practical applicability | 5.0 | Engineer can execute end-to-end: (a) diagnostic SQL is copy-paste ready, (b) thresholds are quantitative (50/10 GB), (c) `max_slot_wal_keep_size = 50GB` config line is ready for `postgresql.conf`, (d) slot recovery SQL is two precise commands with correct decoding plugin (`pgoutput`), (e) Debezium restart with `snapshot.mode: never` + MERGE INTO backfill for the gap-loss case, (f) permanent fix specifies alerting frequency (every 30s) and exact paging thresholds, (g) heartbeat setup includes both the heartbeat table creation and `heartbeat.interval.ms=30000` config. Production-stack-fit: Debezium → Kafka → Spark → Iceberg fits prod_info.md ingestion stack. The 500MB/min WAL estimate is an honest rough-order-of-magnitude figure with no overclaiming. |
| Completeness | 5.0 | The 4-part question is fully answered in order: (1) what's happening — slot-as-bookmark + WAL retention mechanics; (2) the risk — disk-fill → DB read-only/crash sequence with explicit "#1 way CDC takes prod DB offline" framing; (3) detection — diagnostic SQL with column-by-column reading guide; (4) recovery options without reset — three discrete scenarios matched to symptoms with runbook each; plus the permanent fix (monitoring + heartbeats). The gap-backfill nuance for the slot-loss path is included — answer doesn't pretend `snapshot.mode: never` is lossless. Nothing important is missing for this question. |
| **Average** | **5.00** | **PERFECT PASS** |

## Verification trail (WebSearch)

1. **`safe_wal_size` is a real column**: Confirmed via [EDB blog "PostgreSQL 13: Don't let slots kill your primary"](https://www.enterprisedb.com/blog/postgresql-13-dont-let-slots-kill-your-primary), [Gunnar Morling's mastering-postgres-replication-slots blog](https://www.morling.dev/blog/mastering-postgres-replication-slots/), and [PostgreSQL official docs](https://www.postgresql.org/docs/current/runtime-config-replication.html). Introduced in PG13 beta3, represents bytes-until-auto-invalidation.

2. **`max_slot_wal_keep_size` is a real parameter**: Confirmed via [postgresqlco.nf](https://postgresqlco.nf/doc/en/param/max_slot_wal_keep_size/) and [pgPedia](https://pgpedia.info/m/max_slot_wal_keep_size.html). Added in PG13. Default `-1` = unlimited (the dangerous default). Setting it to a finite value lets Postgres invalidate the slot before disk fills — the responder's safety-valve framing is exactly right.

3. **`wal_status` four states (reserved/extended/unreserved/lost)**: Confirmed via [pgDash WAL article](https://pgdash.io/blog/taming-postgresql-wal-file-growth.html) and [PostgreSQL docs](https://www.postgresql.org/docs/current/runtime-config-replication.html). "lost" is terminal — no recovery, slot must be dropped and recreated. The responder's state ladder matches exactly.

4. **`snapshot.mode: never` after slot loss**: Confirmed via [Debezium PostgreSQL connector docs](https://debezium.io/documentation/reference/stable/connectors/postgresql.html) and [Aiven node-replacement guide](https://aiven.io/docs/products/kafka/kafka-connect/howto/debezium-source-connector-pg-node-replacement). Importantly, Debezium docs explicitly warn that with `snapshot.mode=never` after slot loss, **events between the old slot position and current WAL position are silently skipped** — leading to silent data loss. The responder correctly acknowledged this by appending "run a targeted `MERGE INTO` from Postgres to Iceberg to backfill the gap period" — this is the right mitigation. If the answer had said `snapshot.mode: never` without the backfill, it would have been a partial-truth that exposes the engineer to silent loss.

5. **`heartbeat.interval.ms` is a real Debezium config**: Confirmed via Debezium docs. Correctly used here for idle-table scenarios where the slot would otherwise not advance and false-alert.

## What worked exceptionally well

- **Empathy in framing**: "I don't really know what any of that means" was the engineer's lead, and the answer opens with a concrete bookmark-in-WAL analogy rather than jumping straight to SQL. Beginner respect.
- **Risk-first urgency calibration**: The "this is the #1 way a CDC pipeline can take your production Postgres database offline" framing correctly conveys urgency without alarmism.
- **Three recovery options matched to symptoms**: The engineer doesn't have to read all three — they match their `wal_status` value to Option 2 vs Option 3. This is exactly how a runbook should be structured.
- **Safety-valve framing of `max_slot_wal_keep_size`**: The line "keeps the app alive even if the pipeline dies" captures the production tradeoff perfectly — better to lose the pipeline (recoverable) than the source database (catastrophic).
- **Gap-loss nuance handled**: Many answers would stop at `snapshot.mode: never`. This answer goes further and adds the MERGE INTO backfill, which is the correct mitigation for the silent-data-loss risk Debezium docs warn about.
- **Heartbeat configuration with the WHY**: Heartbeats are introduced not as a cargo-cult config but with the rationale "keeps the slot advancing even on quiet tables so you don't get false alerts" — engineer learns the mechanism, not just the magic config.

## Minor nits (not blocking, did not affect score)

1. The diagnostic SQL hardcodes `slot_name = 'debezium_slot'` — could mention that the engineer should substitute their actual slot name (Debezium config `slot.name`). Most engineers will infer this, but a beginner-empathy answer could call it out.
2. The fresh-slot creation uses `pg_create_logical_replication_slot` — could also mention that Debezium 2.x can create the slot automatically on first start if it doesn't exist, so manual creation is optional in some setups. Not a deduction since manual creation is also a valid recovery path.
3. No mention of the `pg_stat_replication` view (active streaming connections) as a complementary monitoring target — `pg_replication_slots` answers "what's the slot state" while `pg_stat_replication` answers "is anything actually consuming". Out of scope for this question's framing.

## No resource gaps identified

The answer's mental model (slot-as-bookmark, four-step disaster sequence, three recovery branches, monitoring + heartbeats permanent fix) appears to come from `resources/13-postgres-to-iceberg-ingestion.md`. Cite is accurate. Resources/13 continues its 7-iteration strong-PASS streak on Postgres-to-Iceberg ingestion sub-topics. No teacher action needed.

## Recommendation for iter351 onward

- Postgres-to-Iceberg ingestion topic is durably strong (avg 4.524 / 131 questions, 7 consecutive strong PASSes covering MERGE_CARDINALITY_VIOLATION, lag-buffer P99, schema evolution ADD/RENAME/TYPE/DROP, JSONB, and now replication-slot WAL accumulation). Recommend rotating away from this topic for the next 2-3 iterations and probing under-tested sub-topics:
  - Iceberg maintenance: 36 questions only — probe `rewrite_position_delete_files` for V2 tables with high delete-row count, or the `expire_snapshots` window for time-travel customers.
  - SQL query best practices: probe the `EXPLAIN ANALYZE` distinct-from-`EXPLAIN` distinction for runtime vs plan-time stats.
  - Multi-tenant analytics: per iter350 Q1 recommendation, probe a DIFFERENT selector regex angle (suffix `*_prod`, source selector, contains pattern) to confirm the iter350 fix generalizes beyond the prefix scenario.

## Iter 350 final summary

| Question | Topic | Score | Result |
|---|---|---|---|
| Q1 | Multi-tenant analytics — Trino selector regex (etl prefix, 3rd probe) | 5.00 | **PERFECT PASS** |
| Q2 | Postgres-to-Iceberg ingestion — Debezium replication slot WAL accumulation, detection, recovery | 5.00 | **PERFECT PASS** |
| **Iteration avg** | | **5.00** | **PERFECT PASS** |

Topic average updates:
- Multi-tenant analytics: 4.440/141 → **4.443/142 questions** (PASSED — recovering upward after iter348+iter349 FAILs)
- Postgres-to-Iceberg ingestion: 4.520/130 → **4.524/131 questions** (PASSED — 7th consecutive strong PASS)

This is the strongest iteration result in the recent window. Both topics tested produced perfect 5.00 scores, and the iter350 surgical resource fix in resources/05 (matches() full-string CRITICAL FACT box) appears to have broken the iter348→iter349 substring/find() bug pattern on the selector regex sub-topic. No teacher action needed for iter351 unless a re-probe of a DIFFERENT selector-regex angle reveals the fix doesn't generalize.

---

## Iter 350 End-of-Iteration Summary

**Date**: 2026-05-29
**Phase**: extended
**Iteration result**: **5.00 / 5.00 — PERFECT PASS**

### Scores table

| Question | Topic | Technical | Beginner clarity | Practical | Completeness | Avg | Result |
|---|---|---|---|---|---|---|---|
| Q1 | Multi-tenant analytics — Trino selector regex (etl prefix, 3rd probe after iter348+iter349 FAILs) | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** | PERFECT PASS |
| Q2 | Postgres-to-Iceberg ingestion — Debezium replication slot WAL accumulation, detection, recovery | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** | PERFECT PASS |
| **Iteration** | | **5.0** | **5.0** | **5.0** | **5.0** | **5.00** | **PERFECT PASS** |

### What broke the iter348/iter349 substring-bug pattern

For two consecutive iterations (348 → 2.875, 349 → 3.25), the responder kept producing the same wrong substring/find() explanation for Trino selector regex behavior, even after the teacher patched both resources/05 (iter348) and resources/22 (iter349). The corrected matches() text was present in the resources but BURIED — labeled with hedging headers like "CAUTION" and "Two production footguns", and the actual fix (`prefix.*`) appeared mid-paragraph after long explanations. The responder kept reproducing the older, cached substring framing instead of the buried correct one.

The iter350 surgical fix applied four structural changes that finally broke the pattern (all to resources/05 lines 2253-2445):

1. **CRITICAL FACT box at the TOP of selector content (line 2255)** — the FIRST thing the responder sees when it enters the selector section. Includes a Right-vs-Wrong table with `.*` fixes for `svc_`/`data_`/etc., a character-count walkthrough of `svc_billing`, and an explicit imperative: "if you ever think svc_ is a substring of svc_billing — STOP".
2. **Declarative framing replacing hedged framing** — "CAUTION" and "footgun" downgraded to "FULL-STRING MATCH RULE" and "if you think this is a substring — STOP". Declarative facts override cached partial-truths better than warnings do.
3. **Fix-first ordering** — the corrected pattern (`prefix.*`) now appears BEFORE the explanation of why bare `prefix` fails. Even a responder that skims content sees the right answer first.
4. **Reinforcement at the field-name-warning paragraph** — added an inline matches() reminder next to the "is a regex too" phrasing, so the rule is repeated at a second touchpoint.

The result: Q1 produced a textbook-correct answer with zero substring contamination, citing resources/05 lines 2257-2441 and reproducing the corrected content faithfully. The 3-iteration regression on this sub-topic appears resolved — but on only ONE probe phrasing (etl prefix), so the fix needs cross-angle verification before being considered durably stable.

### Suggested focus for iter 351

**Primary: re-probe selector regex from a DIFFERENT angle** to confirm the fix generalizes beyond the prefix scenario. Avoid the user-prefix-with-trailing-underscore phrasing (already covered 4 times). Candidate angles:
- **Suffix pattern**: "I have `"user": "_prod"` and I want it to match `analyst_prod` and `etl_prod`. Why doesn't it work?"
- **Contains pattern**: "I want to match any username with `payment` in it — what's the right regex?"
- **Source selector**: "Does `"source": "tableau"` match a query where the source is `tableau-server-01`?"
- **userGroup selector with multi-group user**: re-probe the iter347 angle to ensure that still holds.

A passing answer at a different angle = the fix is structural, not just memorized for one phrasing. A failing answer at a different angle = the CRITICAL FACT box approach works only when the question surface matches the box's worked example, and the teacher needs to generalize the fix across more sub-patterns.

**Secondary: probe under-tested topics** to broaden coverage and avoid over-rotating on the recently-failed topic.
- **Iceberg maintenance** (only 36 questions): `rewrite_position_delete_files` for V2 tables with high delete-row count, OR the `expire_snapshots` window for time-travel customers.
- **SQL query best practices**: probe `EXPLAIN ANALYZE` vs `EXPLAIN` distinction (runtime vs plan-time stats), OR probe a join-reordering / broadcast-vs-partitioned join scenario.
- **Cost optimization**: probe storage-class tiering for Iceberg snapshots, OR S3 request cost reduction via metadata caching.

Rotating away from Postgres-to-Iceberg ingestion is recommended — that topic is on a 7-iteration strong-PASS streak (4.524 / 131 questions) and additional probes there won't expose weaknesses. The marginal information gain is higher from probing the not-yet-verified selector-regex generalization AND from probing topics with thinner coverage.

# Judge Feedback — Iter 322

Date: 2026-05-27
Phase: extended
Topics: Storage growth estimation with daily updates (Q1) + OPA cache-ttl-seconds revocation latency (Q2)

---

## Q1 — Storage growth estimation with daily updates

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | Formula `snapshot_overhead = daily_rewritten_volume × retention_days` matches the resource and the verified CoW physics. `$files` columns (`file_size_in_bytes`, `record_count`) and `$snapshots` summary fields (`added-files-size`, `operation`) are real and queryable from Trino (verified via Trino 481 docs and Iceberg metadata-tables references). CoW is the verified default for `write.update.mode` in Iceberg 1.5.x. The "files containing those rows" framing (i.e., rewrite > byte-size of touched rows) is correct. The "350 MB" figure for rewriting files containing 10M rows isn't algebraically derived from the prior 200 B/row × 10M = ~285 MB — it's slightly hand-wavy (would be ~285 MB at the same compression) but the order of magnitude is right and the engineer is told to MEASURE actual values via the queries provided. Small nit: the `summary['operation'] IN ('overwrite','delete')` filter for CoW UPDATEs is correct — Iceberg tags CoW UPDATEs as `overwrite` — but excludes `'replace'` (compaction), which can materially understate rewrite volume on tables with regular compaction. |
| Beginner clarity | 5 | Manager-ready table, named columns (Parameter / Example / Formula), explicit GB rollup, headroom row, "round up to next tier" actionable. Two worked numerical paths (30-day vs 7-day retention) crystallize the retention lever. Plain-language "Right mental model" and "Why 10% daily updates doesn't mean 10% daily storage growth" sections nail the conceptual trap. No jargon left unexplained — "snapshot" is contextualized as "in case you want to time-travel back". |
| Practical applicability | 5 | Engineer can literally lift the table into a spreadsheet today. The two diagnostic SQL queries return the two unknowns they need (bytes_per_row, daily_rewritten_volume) directly from Trino against their production Iceberg tables — no estimation guesswork. The "drop retention to 7 days to cut overhead by ~75%" closing note gives them an immediate manager-conversation lever. Fits the prod stack exactly (Trino 467 + Iceberg + MinIO). |
| Completeness | 5 | All four sub-questions addressed: (a) linear vs compound — explicitly "linear for live data + bounded by retention window for snapshots, NOT calendar-time compounding"; (b) formula — provided with worked example; (c) how to measure — two diagnostic queries against `$files` and `$snapshots`; (d) 6-month plan — rolled into the spreadsheet table with headroom and tier rounding. Minor gap: doesn't explicitly mention the 7-day Trino floor on `expire_snapshots` (so "drop to 7 days" is exactly at the floor), and doesn't note metadata overhead (~1-3%) — neither is critical for the spreadsheet ask. |
| **Average** | **5.00** | **PASS** |

### What Worked
- Decomposing total storage into **live_data + snapshot_overhead** is the correct mental model and matches resources/11 exactly.
- Distinguishing **calendar-day growth (linear)** from **snapshot overhead (bounded by retention window)** directly answers the "does it compound" question with a precise, defensible "no, but it's not 10% either."
- The two-query diagnostic playbook (`$files` -> bytes_per_row, `$snapshots` -> daily rewrite volume) gives the engineer their two unknowns from production data rather than estimates.
- The spreadsheet table with Parameter / Example / Formula columns is exactly manager-ready format.
- The retention-lever framing ("snapshot cost depends on how long you keep history, not how long the data exists") is the single most useful insight for the capacity-planning conversation.
- "10% of rows can live in 35% of files" correctly captures that Iceberg's file-row distribution is rarely uniform after compaction, and the answer steers the engineer to measure rather than assume.
- Stays inside the production stack (Trino 467 + Iceberg + MinIO on-prem) — no cloud-cost references or unavailable tooling.

### What Missed
- The 350 MB rewrite figure isn't algebraically derived from the prior bytes-per-row × rows-updated (would be ~285 MB at 200 B/row, 7x compression, 10M rows). It's plausible but breaks the explicit derivation chain. Adding "≈ 285 MB if uniformly distributed, often higher because files contain more rows than just the updated ones" would tighten the chain.
- The `$snapshots` filter should include `'replace'` operation (used by `rewrite_data_files` compaction) — otherwise compaction-driven rewrites are excluded from the daily rewrite volume estimate, which can substantially understate overhead on tables with regular compaction.
- The "drop retention to 7 days" suggestion lands exactly at Trino's `iceberg.expire-snapshots.min-retention` floor — worth a one-line callout that anything below 7 days requires raising the connector config.
- No mention of metadata overhead (~1-3%) — it's negligible but the engineer asked for "actual bytes on disk" so a one-sentence confirmation that metadata is dominated by data files would close the loop.

### Technical Accuracy (verified)
1. **`snapshot_overhead = daily_rewritten_volume × retention_days`** — Verified correct for Iceberg CoW. Matches resources/11 and Dremio/AWS Iceberg documentation on CoW behavior (whole-file rewrites on UPDATE/DELETE pinned by snapshot references until expiry).
2. **`$files` query with `SUM(file_size_in_bytes) / SUM(record_count)`** — Verified valid. Trino 481 docs confirm `file_size_in_bytes` and `record_count` are columns on the `$files` metadata table. Double-quoted `"events$files"` syntax is the correct Trino form.
3. **`$snapshots` table with `summary['added-files-size']` and `summary['operation']`** — Verified real. The Iceberg snapshot summary map contains `added-files-size`, `added-data-files`, `added-records`, `changed-partition-count`, etc. `operation` is exposed both as a top-level column and inside `summary`. Filtering on `summary['operation'] IN ('overwrite','delete')` captures CoW UPDATE/DELETE commits correctly. (Caveat: this filter excludes `'replace'` from compaction; noted above.)
4. **Iceberg default mode is Copy-on-Write for UPDATE/DELETE** — Verified. `write.update.mode` and `write.delete.mode` default to `copy-on-write` in Iceberg (including 1.5.x). The answer's claim that "Iceberg rewrites the files containing those rows" is exactly correct for the default configuration.

All four key claims hold up. No fabrication or hallucination detected.

### Rubric Update
- Storage sizing: prior avg 4.447 across 7 questions -> (4.447 × 7 + 5.00) / 8 = **4.516 across 8 questions**. Status: PASSED.

Sources:
- [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html)
- [Apache Iceberg Metadata Tables: Querying the Internals](https://datalakehousehub.com/blog/2026-04-29-apache-iceberg-masterclass-11-metadata-tables/)
- [Row-Level Changes on the Lakehouse: Copy-On-Write vs. Merge-On-Read in Apache Iceberg (Dremio)](https://www.dremio.com/blog/row-level-changes-on-the-lakehouse-copy-on-write-vs-merge-on-read-in-apache-iceberg/)
- [Iceberg write modes — RisingWave](https://docs.risingwave.com/iceberg/write-modes)
- [Trino on ice IV: Deep dive into Iceberg internals](https://trino.io/blog/2021/08/12/deep-dive-into-iceberg-internals)

---

## Q2 — OPA cache-ttl-seconds revocation latency

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 1.5 | **CRITICAL FACTUAL ERROR**: `opa.policy.cache-ttl-seconds` is NOT a real Trino OPA plugin configuration property. WebFetch against the official Trino OPA docs (trino.io/docs/current/security/opa-access-control.html) AND the actual `OpaConfig.java` source on github.com/trinodb/trino confirms the plugin has ONLY these properties: `opa.policy.uri`, `opa.policy.row-filters-uri`, `opa.policy.column-masking-uri`, `opa.policy.batch-column-masking-uri`, `opa.policy.batched-uri`, `opa.log-requests`, `opa.log-responses`, `opa.allow-permission-management-operations`, `opa.http-client.*`, and `opa.context-file`. There is NO decision-caching mechanism in the Trino OPA plugin — every authorization check (allow/deny, row filter, column mask) is a live HTTP call to OPA. The answer therefore invents the entire premise (Trino-side decision caching), invents the tuning lever (`cache-ttl-seconds=0/5/10/30/60`), and invents the configured behavior ("Trino caches the OPA row-filter decision for a given `(user, table)` pair for the TTL window"). The cumulative-latency model (JWT revocation + bundle update + OPA poll + Trino cache expiry) is wrong on stage 4 — Trino's contribution to revocation latency from caching is zero. The actual revocation latency model on this stack is JWT revocation/expiry + bundle propagation only, plus in-flight queries that already passed authz. What IS accurate: `kill_query(query_id => '...', message => '...')` syntax verified against trino.io/docs/current/connector/system.html; the OPA bundle polling story (min_delay_seconds/max_delay_seconds, 30s–60s typical) is correct; the JWT-at-IdP framing is correct; the `io.trino.plugin.opa.OpaHttpClient` logger name is correct. But because the entire central question — "how do we tune the Trino cache TTL?" — is answered by recommending a property that does not exist, the technical accuracy floor is hit. This is a hallucinated-config failure mode that will mislead the engineer into editing `etc/access-control.properties` with a line that Trino will reject (or silently ignore, depending on the plugin's strictness). Note: the fabricated property also appears in `resources/05-multi-tenant-analytics.md` (lines 632, ~639, ~780) — the resource itself is the source of the hallucination, so the responder is propagating a known-bad source. |
| Beginner clarity | 4.5 | Genuinely well-written prose. Opens with a direct "yes, the concern is real"; walks through cache scope (per-user, per-table) with a concrete `alice`/`events`/`users` example; the four-stage cumulative-latency framing is pedagogically excellent IF the model were real; the high-churn vs low-churn tuning matrix is concrete and beginner-friendly; the "right question" reframe (focus on IdP revocation speed, not just cache TTL) is genuinely insightful; the kill_query escape-hatch section is digestible. No unexplained jargon. The clarity does the engineer a *disservice* by being so confident about a fabricated config — a more hedged answer would be less harmful. |
| Practical applicability | 1.0 | The headline recommendation — edit `etc/access-control.properties` to set `opa.policy.cache-ttl-seconds=30` — will **fail** because the Trino OPA plugin does not recognize this property. The engineer will paste this into prod, the coordinator will either refuse to start (config validation) or log an "unused configuration property" warning at startup, and they will lose confidence in the answer entirely. The `kill_query` snippet is correctly applicable and immediately useful. The `system.runtime.queries` lookup is correct. The advice "focus on OPA bundle polling interval" is correct and applicable. But the central tuning lever the engineer asked about — "how do I tune the cache TTL?" — is unanswerable as written because the cache does not exist. A correct answer would have said: "Trino's OPA plugin does NOT cache decisions — every query makes a fresh HTTP call to OPA. Your revocation latency is therefore IdP+bundle propagation only, plus any in-flight queries that already passed authz (use kill_query for those)." That is a fundamentally different, and much shorter, answer. |
| Completeness | 2.5 | Addresses all three sub-questions structurally (is the concern real → "yes"; how to tune → cache-ttl-seconds knob; tradeoff → matrix). But the first sub-question is answered WRONG (the concern, as stated — Trino-cached "allow" decisions — does not exist with the stock OPA plugin), the second sub-question is unanswerable (the lever does not exist), and the tradeoff matrix is fabricated. The kill_query escape hatch and IdP-revocation framing are real coverage of nuance the user did not explicitly ask about. Missing entirely: that the actual decision flow with the stock plugin is "every query → fresh HTTP call to OPA" so cache concerns are mooted at the Trino layer; that the only relevant tunables are OPA-side (bundle polling, partial evaluation cache inside OPA itself if used); that for high-throughput SaaS, the engineer may want to use `opa.policy.batched-uri` for filter-list calls (which IS a real property and is in resources/05 line 629) to reduce OPA call volume without caching decisions. |
| **Average** | **2.38** | **FAIL** |

### What Worked
- `kill_query(query_id => '...', message => '...')` syntax verified correct against trino.io system connector docs — the escape-hatch section is the strongest part of the answer.
- `system.runtime.queries` lookup with `state = 'RUNNING'` filter is correct and immediately runnable.
- OPA bundle polling stage (`min_delay_seconds`/`max_delay_seconds`, 30s–60s typical) is accurately described.
- The JWT-revocation-at-IdP framing is correct and stack-fit (prod uses custom JWT auth per prod_info.md).
- "Focus on IdP revocation + bundle polling first; Trino-side is a smaller lever" is the right architectural framing if the Trino-side cache existed.
- Prose is clear, well-structured, and assumes no OPA expertise.

### What Missed
- **HALLUCINATED CONFIG PROPERTY.** `opa.policy.cache-ttl-seconds` does not exist in the Trino OPA plugin. The official docs at trino.io/docs/current/security/opa-access-control.html and the `OpaConfig.java` source on github.com/trinodb/trino confirm only 10 properties exist, none of which involve caching or TTL. The Trino OPA plugin makes a fresh HTTP call to OPA for every authorization decision (allow/deny, row filter, column mask). The answer's entire central premise — that Trino caches "allow" decisions per (user, table) for a configurable TTL — is fabricated.
- **PROPAGATED FROM RESOURCE.** The fabricated property is also present in `resources/05-multi-tenant-analytics.md` at lines 632, ~639, ~780 (the answer faithfully copied it). The resource is the upstream source of the hallucination and must be fixed before the responder can produce a correct answer to this question family.
- **MISFRAMED REVOCATION LATENCY MODEL.** The "sum of four stages" with Trino cache as stage 4 is wrong because stage 4 does not exist. The correct model on this stack is: (a) IdP marks JWT invalid / waits for short JWT TTL, (b) bundle propagation (push + OPA poll, ~30s–5min). Trino contributes zero from caching. The only Trino contribution is in-flight queries that already passed authz, which keep running until they complete or are killed.
- **MISSED THE REAL ANSWER.** The accurate response to "how do we cut a tenant off immediately" on the production stack is: (1) revoke/short-TTL the JWT at the IdP so they cannot re-authenticate, (2) push updated bundle to OPA so subsequent NEW queries are denied at admission, (3) `kill_query` any in-flight queries from that user. There is no Trino-side cache to flush because none exists.
- **MISSED `opa.policy.batched-uri` as the real OPA-call-volume tunable.** If the underlying concern is "OPA call volume is too high," `batched-uri` (a real property, mentioned in resources/05 line 629) is the lever — not a fictional decision cache.
- **NO HEDGING.** A more cautious answer would have said "verify against your Trino version's OPA docs before relying on this config key." The answer states the cache scope ("Per-user, per-table") with full confidence, which makes the failure mode worse.

### Technical Accuracy (verified)

WebSearch + WebFetch verification against trino.io docs and the trinodb/trino GitHub repo:

1. **`opa.policy.cache-ttl-seconds` as a Trino OPA config key**: **NOT VERIFIED — DOES NOT EXIST**. WebFetch of https://trino.io/docs/current/security/opa-access-control.html lists only: `opa.policy.uri`, `opa.policy.row-filters-uri`, `opa.policy.column-masking-uri`, `opa.policy.batch-column-masking-uri`, `opa.policy.batched-uri`, `opa.log-requests`, `opa.log-responses`, `opa.allow-permission-management-operations`, `opa.http-client.*`, `opa.context-file`. Confirmed against the OpaConfig.java source in trinodb/trino — no `@Config("opa.policy.cache-ttl-seconds")` annotation exists. There is no decision-caching layer in the Trino OPA plugin.
2. **Cache applies to row-filter decisions specifically?**: **MOOT** — no cache exists for any decision type (allow/deny, row filter, column mask, batched, filter list). Every authorization check is a live HTTP call.
3. **`CALL system.runtime.kill_query(query_id => '...', message => '...')` syntax**: **VERIFIED** against trino.io/docs/current/connector/system.html. Both parameters are required. Standard form. The answer's example is correct.
4. **Four-stage revocation latency model (JWT + bundle update + OPA poll + Trino cache expiry)**: **PARTIALLY WRONG**. Stages 1–3 (JWT revocation, bundle update, OPA poll) are accurate and well-described. Stage 4 (Trino cache expiry) does not exist in the stock OPA plugin — Trino does not cache OPA decisions. The cumulative-latency math therefore overstates the revocation window by including a stage that contributes zero.
5. **OPA bundle polling defaults / `min_delay_seconds`/`max_delay_seconds`**: **VERIFIED** against openpolicyagent.org docs — bundle plugin polls within the configured interval window.
6. **`io.trino.plugin.opa.OpaHttpClient` logger name**: **VERIFIED** — matches the package path in the trinodb/trino source.

Sources:
- [Open Policy Agent access control — Trino 481 Documentation](https://trino.io/docs/current/security/opa-access-control.html)
- [System connector — Trino 480 Documentation](https://trino.io/docs/current/connector/system.html)
- [trino-opa OpaConfig.java source](https://github.com/trinodb/trino/tree/master/plugin/trino-opa/src/main/java/io/trino/plugin/opa)
- [Trino | Open Policy Agent for Trino arrived](https://trino.io/blog/2024/02/06/opa-arrived.html)

### Rubric Update
- Multi-tenant analytics: prior avg 4.480 across 119 questions → (4.480 × 119 + 2.38) / 120 = (533.12 + 2.38) / 120 = 535.50 / 120 = **4.463 across 120 questions**. Status: **PASSED** (above 3.5 threshold), but with a sharp single-question drop of −2.10 from the topic average that must NOT be ignored. The fabricated-config failure mode in resources/05 must be fixed before the next iteration probes this topic, or the same failure will recur.

---

## Iter 322 Summary

**Iter 322 average: (5.00 + 2.38) / 2 = 3.69 — PASS (barely)** ✓ (Q1 PASS / Q2 FAIL — passes only on Q1's perfect score absorbing Q2's catastrophic miss)

### Notable
- Q1 5.00: Storage growth estimation with daily updates — perfect score; resources/11 fixes from Iter 321 paid off; spreadsheet-ready table with two diagnostic queries; only minor nits (350 MB derivation, `'replace'` operation in filter, 7-day floor mention)
- Q2 2.38: OPA cache-ttl-seconds revocation latency — **FAIL**. Answer's entire central tuning recommendation (`opa.policy.cache-ttl-seconds=30`) is built on a Trino OPA plugin config property that does not exist. Verified via WebFetch of trino.io OPA docs and OpaConfig.java in trinodb/trino. The Trino OPA plugin makes a fresh HTTP call for every authorization decision — there is no decision cache. The fabrication propagated from `resources/05-multi-tenant-analytics.md` lines 632/~639/~780, which itself contains the bad config name. The `kill_query` escape-hatch syntax and JWT/bundle propagation framing are accurate; everything tied to the fictional cache TTL is misleading.

### Resource fixes needed this iteration (URGENT)
1. **resources/05-multi-tenant-analytics.md** — Remove ALL references to `opa.policy.cache-ttl-seconds` (lines 632, ~639, ~780). The Trino OPA plugin does not cache decisions. Replace with: (a) accurate statement that every authorization check is a live HTTP call to OPA, (b) the real revocation latency model (IdP JWT revocation/short-TTL + OPA bundle propagation only, plus in-flight queries via `kill_query`), (c) `opa.policy.batched-uri` as the real OPA-call-volume tunable for filter-list operations, (d) the verified list of 10 actual OPA plugin config properties for reference. Cite sources: trino.io/docs/current/security/opa-access-control.html and OpaConfig.java in trinodb/trino.

### Suggested focus for Iter 323
- **Multi-tenant analytics** (4.463/120 after Q2 — single-question −2.10 drop): re-probe the same revocation-latency angle from a different phrasing AFTER resources/05 is fixed. Verify the responder no longer recommends the fabricated `opa.policy.cache-ttl-seconds` and instead correctly identifies IdP+bundle propagation as the only stages, plus `kill_query` for in-flight queries.
- **Multi-tenant analytics** (cross-check): probe `opa.policy.batched-uri` as the real OPA-call-volume tunable — confirm the responder can correctly distinguish "batched filter-list call" (a real optimization) from "cached decision" (which does not exist on this plugin).
- **OPA-config audit** more generally: any topic that touches OPA plugin configuration should be cross-verified against OpaConfig.java in trinodb/trino to catch other hallucinated properties that may exist in resources/05.
- **Iceberg table maintenance** (4.655/20): still under-probed for Trino 467-specific gaps from Iter 321 — `dry_run` Trino-vs-Spark asymmetry, 7-day floor on both procedures, `clean_expired_metadata` parameter.

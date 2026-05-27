# Judge Feedback — Iter 323

Date: 2026-05-27
Phase: extended
Topics: OPA policy revocation latency (Q1) + First-run snapshot expiry + clean_expired_metadata (Q2)

---

## Q1 — OPA policy revocation latency

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All major claims verified against trino.io OPA docs and OpaConfig.java source: (1) Trino OPA plugin has no decision cache — every authorization is a fresh HTTP call, confirmed by full property enumeration in OpaConfig.java (no cache property exists); (2) `CALL system.runtime.kill_query(query_id => '...', message => '...')` syntax is the exact documented form; (3) `system.runtime.queries` with `state = 'RUNNING'` filter is valid — `state` and `user` are real columns; (4) authorization happens at query analysis/planning on the coordinator, not during distributed execution — correct. The "30s–60s typical bundle poll" cites real OPA bundle config keys (`min_delay_seconds`/`max_delay_seconds`). The log property `io.trino.plugin.opa.OpaHttpClient=DEBUG` aligns with package naming conventions. No fabricated config properties (notable improvement after iter322's `opa.policy.cache-ttl-seconds` fix). |
| Beginner clarity | 4 | The "Quick Answer" up front directly addresses the panicked incident framing. The two-stage breakdown (authorization at startup, not during execution) is well-explained without jargon. The timeline table is concrete and easy to scan. Jargon like "Rego," "bundle," "principal," and "split" appears without gloss — a true beginner would not know what these mean. "Bundle polling cycle" is name-dropped without explaining that OPA pulls policies from a bundle server. Otherwise the prose is incident-shaped and actionable. |
| Practical applicability | 5 | Perfect fit for the hostile-churn incident scenario. The "Complete Incident Playbook" gives an executable 5-step runbook. The kill_query SQL is copy-pasteable. The debug commands (DEBUG log level, error_code filter) give concrete observability hooks. Matches production environment exactly: Trino 467 + OPA + JWT principal, MinIO bundle server hosting (consistent with on-prem MinIO stack). Engineer can act on this within minutes. |
| Completeness | 5 | Covers all four sub-questions: (1) how long before denial kicks in (bundle poll + zero in-Trino caching = sub-second after bundle live); (2) the chain of events (policy push → bundle build → OPA poll → next-query check on coordinator); (3) how to make sure they can't run even one more query (kill_query for in-flight + bundle propagation for new); (4) the authorization-at-submission semantic (queries already running are not re-checked). Bonus: debugging section, error code to grep, and explicit "the only scenario where a query goes through after revocation" framing directly answers the hostile-incident worry. |
| **Average** | **4.75** | **PASS** |

### What Worked
- Lead with the answer the panicked engineer needs: policy takes effect on the NEXT query; in-flight queries finish unless killed.
- Correctly states the "no decision cache" property of the Trino OPA plugin — verified against OpaConfig.java source (notable recovery after iter322's fabricated `opa.policy.cache-ttl-seconds` issue).
- Concrete incident playbook with 5 numbered steps.
- Correct `kill_query` syntax with both `query_id` and `message` named parameters.
- Authorization-at-submission semantic explained clearly: a 4-hour in-flight job is not retroactively blocked.
- Debug hooks (log level + error code) match real Trino package naming.
- Timeline table is operationally useful — shows what an SRE would see at each stage.

### What Missed
- "Rego" and "bundle" mentioned without one-line explanation for a beginner — could add a brief gloss like "Rego = OPA's policy language; bundle = packaged policy file that OPA downloads from a server like MinIO."
- "Principal" used in the SQL example (`user = 'churned-tenant-principal'`) but the production stack uses JWT — could clarify that the value matches the Trino session user, mapped from a JWT claim like `sub`.
- Could explicitly note that triggering an out-of-band bundle push (HTTP POST to OPA's bundle endpoint, or OPA delta bundles with long polling) bypasses the polling delay entirely — currently only mentions "if your CI/CD supports it" without showing how.
- No mention of verifying after the kill that the OPA policy push was actually picked up by OPA itself (e.g., OPA's `/v1/data` endpoint or bundle status endpoint) before relying on the deny — a paranoid incident playbook would include this verification step.

### Technical Accuracy (verified)
1. **Trino OPA plugin decision cache**: VERIFIED — no cache exists. OpaConfig.java enumerates 9 config properties (uri, batched-uri, log-requests, log-responses, allow-permission-management-operations, row-filters-uri, column-masking-uri, batch-column-masking-uri, context-file). No cache-related property. Documentation confirms OPA contacts OPA for each query. Answer's claim "every query's authorization is a fresh live HTTP call to OPA" is correct.
2. **kill_query syntax**: VERIFIED — `CALL system.runtime.kill_query(query_id => '...', message => '...')` is the exact documented Trino syntax with `query_id` required and `message` optional.
3. **OPA bundle polling as only delay**: VERIFIED — once a bundle is activated in OPA, the Trino plugin sees the new policy on the next HTTP call (no in-Trino cache). `min_delay_seconds`/`max_delay_seconds` in OPA bundle config control poll cadence. Answer's "typically 30s to 60s, configurable faster" is reasonable default range. Bonus alternative (not mentioned): delta bundles + HTTP long polling can reduce activation latency further.
4. **system.runtime.queries with state filter**: VERIFIED — columns include `query_id`, `state`, `user`, `query`, plus error_code, error_type, timestamps. `WHERE state = 'RUNNING'` is valid Trino SQL.

### Rubric Update
- Multi-tenant analytics: prior avg 4.463 across 120 questions → (4.463 × 120 + 4.75) / 121 = **4.465 across 121 questions**. Status: PASSED.

---

## Q2 — First-run snapshot expiry + clean_expired_metadata

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 1.5 | **CRITICAL FACTUAL ERROR — version mismatch.** The answer is explicitly addressed to "Trino 467" (the user's stated version, confirmed by prod_info.md) and recommends a first-run command containing two parameters that do NOT exist in Trino 467: `retain_last => 10` and `clean_expired_metadata => true`. Verified against trino.io release notes: **`retain_last` and `clean_expired_metadata` were added to `expire_snapshots` in Trino release 479 (14 Dec 2025)** — a full year after Trino 467's release (6 Dec 2024). Trino 467 supports ONLY the `retention_threshold` parameter on `ALTER TABLE ... EXECUTE expire_snapshots(...)`. The fabricated arguments are corroborated by GitHub issue [trinodb/trino#27357](https://github.com/trinodb/trino/issues/27357), which is the November 2025 feature request asking for exactly these parameters because they didn't exist yet — the linked PR #27362 became part of the 479 release. On Trino 467, the headline recommended SQL will fail with "Invalid procedure argument" or similar, leaving the engineer stuck with the same problem they came in with. The description of `clean_expired_metadata` itself is correct in principle (it cleans expired schemas/partition specs/sort orders not referenced by any live snapshot — verified against Trino 481 docs and the 479 release notes), but the answer recommends it without warning that it requires a version upgrade. What IS accurate: the 7-day `iceberg.expire-snapshots.min-retention` floor (default 7d, verified); the description of what `expire_snapshots` does at a high level; the claim that Trino's `remove_orphan_files` has NO `dry_run` parameter while Spark does (verified — Trino exposes only `retention_threshold`); the safety guarantee that the procedure won't block other queries. The "won't blow up" reassurance is right that there's no OOM or coordinator lock, but the answer misses that `expire_snapshots` runs single-node on Trino (issue [trinodb/trino#19096](https://github.com/trinodb/trino/issues/19096)) — wall-clock can stretch well beyond "1–10 minutes" on a six-month backlog. |
| Beginner clarity | 4.5 | Well-organized: "What expire_snapshots Does on First Run" with numbered steps, "What to Expect on First Run" with timing estimates, "Will Six Months Slow Down the First Run? No." direct framing, and a "safe ordering for first run" recipe. The 7-day floor is positioned as "your safety net" — pedagogically nice. No unexplained jargon. The clarity does the engineer a *disservice* here, however: the confident presentation of a fabricated multi-parameter call (`retain_last => 10, clean_expired_metadata => true`) makes the engineer trust it and paste it into prod. A more hedged tone ("verify your Trino version supports these parameters") would have softened the failure. |
| Practical applicability | 1.0 | The headline first-run command will **FAIL** on Trino 467. The engineer will paste:<br>`ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '30d', retain_last => 10, clean_expired_metadata => true);`<br>and Trino 467 will reject it with a procedure-argument error because neither `retain_last` nor `clean_expired_metadata` are recognized. They asked specifically about Trino 467, the prod environment is on 467, and the answer ignored the version constraint. The correct Trino 467 form is `EXECUTE expire_snapshots(retention_threshold => '30d')` — single argument only. For the `clean_expired_metadata` semantic question ("what does it do?"), the correct answer is: "It's a real Iceberg-level concept, exposed in Spark's `CALL iceberg.system.expire_snapshots(..., clean_expired_metadata => true)` and in Trino 479+ as a procedure argument. On your Trino 467, run the metadata cleanup from Spark, or upgrade to Trino 479+." The answer makes the `dry_run` Trino-vs-Spark asymmetry call correctly, which is valuable, but that good moment is buried beneath the broken main recommendation. The schedule block at the end repeats the same broken SQL — so even the "post-first-run" maintenance template is unusable. |
| Completeness | 3 | Addresses both sub-questions structurally: (1) "will the first run blow up?" → "no, here's why" with timing and concurrency notes (mostly correct in spirit, but misses the single-node, non-parallel behavior from issue [#19096](https://github.com/trinodb/trino/issues/19096) that does meaningfully affect a six-month backlog), and (2) "what is clean_expired_metadata and do I need it?" → describes the semantic correctly but recommends a non-existent Trino 467 parameter. Missing: (a) explicit version-availability check for the parameter the user asked about — this is the #1 expected element given the user explicitly named "Trino 467"; (b) the alternative for Trino 467 users who DO want metadata cleanup (run from Spark); (c) the practical first-run advisory to **start with a generous `retention_threshold` like `'90d'` and ratchet down over successive runs** rather than going straight to 30d on a six-month-old table; (d) acknowledgment that the procedure runs on a single node which DOES affect wall-clock on a backlog; (e) the table-level `history.expire.*` properties as belt-and-suspenders, which resource 17 covers in depth and would have given a Trino 467 equivalent for the missing `retain_last`. |
| **Average** | **2.50** | **FAIL** |

### What Worked
- The 7-day `iceberg.expire-snapshots.min-retention` floor is correctly described and correctly framed as a safety net for first-run users (verified against Trino docs).
- The `dry_run` Trino-vs-Spark asymmetry is correctly called out — only Spark's `CALL iceberg.system.remove_orphan_files(..., dry_run => true)` supports preview; Trino's `EXECUTE remove_orphan_files(...)` does not. This matches resource 17 and the verified Trino 481 docs.
- "Won't blow up" reassurance is correct in spirit — the procedure does not OOM or lock the coordinator; it scans metadata, marks snapshots, issues deletes. The basic mechanics description is right.
- Reads/writes to the table continue normally during expiry (snapshot isolation) — correctly stated.
- The conceptual description of `clean_expired_metadata` ("cleans up expired schema versions, partition specs, and sort orders no longer referenced") matches the Trino 479 docs and Iceberg semantics. The PROBLEM is just that it's recommended for a Trino version that doesn't have it.
- Recommending follow-up `remove_orphan_files` after `expire_snapshots` and noting the maintenance schedule is operationally correct.

### What Missed
- **VERSION-FABRICATED PARAMETERS.** The recommended SQL `expire_snapshots(retention_threshold => '30d', retain_last => 10, clean_expired_metadata => true)` is NOT valid on Trino 467. Verified against trino.io release notes: `retain_last` and `clean_expired_metadata` were added in **Trino 479 (14 Dec 2025)** — a full year after Trino 467's release (6 Dec 2024). The user explicitly stated Trino 467 and prod_info.md confirms it. The engineer will paste this into prod and Trino will reject it.
- **NO VERSION CHECK.** The answer never cross-checks the parameter list against the user's stated Trino version. For a Trino 467 user asking specifically about `clean_expired_metadata`, the right lead is: "That parameter was added in Trino 479 (Dec 2025). On your Trino 467, it's not available from Trino — you'd need to either upgrade to 479+ or run the metadata cleanup from Spark."
- **MISFRAMED FIRST-RUN BACKLOG STORY.** The procedure does NOT auto-bound work to a "safe chunk"; it processes everything older than the operator-specified `retention_threshold`. On a six-month backlog with `retention_threshold => '30d'`, ~5 months of snapshots ARE all candidates. The "won't blow up" framing is right that it won't OOM, but the recommended first-run strategy should have been: start with `retention_threshold => '90d'`, let it complete, then ratchet to 60d, then 30d. That gives a recoverable runway.
- **MISSED ISSUE #19096 / SINGLE-NODE EXECUTION.** Per the open GitHub issue, `expire_snapshots` in Trino runs on a single coordinator node, not distributed. For a six-month backlog with hundreds of thousands of files to delete, this DOES matter — wall-clock can stretch from "a few minutes" to tens of minutes or longer. The "1–10 minutes" estimate is plausible but understates the variability.
- **MISSED `history.expire.*` TABLE PROPERTIES.** Resource 17 covers `history.expire.min-snapshots-to-keep` and `history.expire.max-snapshot-age-ms` in depth as the table-level retention floor. These are the actually-portable Trino 467 way to achieve the safety of `retain_last` — set the property once and every subsequent `expire_snapshots` call enforces the floor. The answer skips them entirely.
- **NO HEDGING.** The first-run command is presented with full confidence. A more cautious answer would have said "Trino 467 supports `retention_threshold` only — `retain_last` and `clean_expired_metadata` require Trino 479+."

### Technical Accuracy (verified)

WebSearch + WebFetch verification against trino.io release notes and GitHub:

1. **`clean_expired_metadata => true` as a Trino 467 parameter**: **NOT VERIFIED — DOES NOT EXIST ON 467**. Trino release 479 notes (14 Dec 2025) explicitly add this: "Add `retain_last` and `clean_expired_metadata` options to `expire_snapshots` command." GitHub issue [trinodb/trino#27357](https://github.com/trinodb/trino/issues/27357) (Nov 18, 2025) is the feature request that resulted in PR #27362, which became part of release 479. On Trino 467, the only supported parameter is `retention_threshold`. The answer's recommended command will fail.
2. **`retain_last => 10` as a Trino 467 parameter**: **NOT VERIFIED — DOES NOT EXIST ON 467**. Same release-479 source as above. The current Trino 481 docs DO list `retain_last` as valid because the docs are version-current, but it was added in 479. Trino 467 rejects it.
3. **What `clean_expired_metadata` actually cleans (when on a supported version)**: **VERIFIED**. Trino 481 docs and the Iceberg `RemoveExpiredMetadata` action confirm it cleans expired partition specs, schemas, and sort orders no longer referenced by any live snapshot. The answer's semantic description is accurate.
4. **`remove_orphan_files` missing `dry_run` in Trino, present in Spark**: **VERIFIED**. Trino's `ALTER TABLE ... EXECUTE remove_orphan_files(...)` exposes only `retention_threshold`. Spark's `CALL iceberg.system.remove_orphan_files(..., dry_run => true)` supports preview. The answer's claim is correct and matches resource 17.
5. **7-day floor via `iceberg.expire-snapshots.min-retention` (default 7d)**: **VERIFIED**. Trino docs confirm the default and the rejection error message format. Resource 17 documents it.
6. **First run processes the full backlog vs being bounded**: **PARTIALLY CORRECT**. The procedure is bounded by `retention_threshold` — if the operator passes `'30d'`, only snapshots older than 30 days are candidates. So on six months of history with `retention_threshold => '30d'`, ~5 months of snapshots are all processed in one shot. The answer's "won't blow up" is right that there's no OOM, but it skips that the work runs on a single node ([trinodb/trino#19096](https://github.com/trinodb/trino/issues/19096) reports non-parallel execution) and can take much longer than the "1–10 minutes" estimate on a heavy table.

Sources:
- [Release 479 (14 Dec 2025) — Trino 480 Documentation](https://trino.io/docs/current/release/release-479.html) — confirms `retain_last` and `clean_expired_metadata` added in 479, NOT in 467
- [Release 467 (6 Dec 2024) — Trino 479 Documentation](https://trino.io/docs/current/release/release-467.html) — confirms no expire_snapshots parameter additions in 467
- [Iceberg expire_snapshot parameters support — trinodb/trino#27357](https://github.com/trinodb/trino/issues/27357) — Nov 2025 feature request for the missing parameters
- [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html) — current-version docs that list `retain_last` and `clean_expired_metadata` (only on 479+)
- [Iceberg Expire Snapshots not working — trinodb/trino#19096](https://github.com/trinodb/trino/issues/19096) — single-node, non-parallel execution behavior

### Rubric Update
- Iceberg table maintenance: prior avg 4.655 across 20 questions → (4.655 × 20 + 2.50) / 21 = (93.10 + 2.50) / 21 = 95.60 / 21 = **4.552 across 21 questions**. Status: **PASSED** (above 3.5 threshold), but with a sharp single-question drop of −2.15 from the topic average that mirrors the Iter 322 OPA failure pattern: fabricated parameters in a confidently-stated SQL recommendation. The version-skew failure mode in resources/17 must be fixed before the next iteration probes this topic.

---

## Iter 323 Summary

**Iter 323 average: (4.75 + 2.50) / 2 = 3.625 — PASS (barely)** ✓ (Q1 PASS / Q2 FAIL — passes only on Q1's strong score absorbing Q2's version-skew miss)

### Notable
- Q1 4.75: OPA policy revocation latency — strong recovery from Iter 322's fabricated `opa.policy.cache-ttl-seconds`. Responder now correctly states the Trino OPA plugin has NO decision cache, every authorization is a fresh HTTP call, in-flight queries need `kill_query`. The resources/05 fix from Iter 322 paid off.
- Q2 2.50: First-run snapshot expiry + clean_expired_metadata — **FAIL**. The recommended Trino 467 SQL contains two parameters (`retain_last`, `clean_expired_metadata`) that were added in Trino 479 (Dec 14, 2025), a year AFTER Trino 467's release. The user explicitly stated Trino 467; prod_info.md confirms it; the answer ignored the version constraint. The `dry_run` Trino-vs-Spark asymmetry call and 7-day floor description are accurate. Pattern matches Iter 322's failure mode: confident-tone fabricated parameter in a copy-pasteable SQL block.

### Resource fixes needed this iteration (URGENT)
1. **resources/17-iceberg-table-maintenance.md** — Add an explicit version-availability table for `expire_snapshots` parameters in Trino:
   - Trino 467 (current production): `retention_threshold` ONLY.
   - Trino 479+ (Dec 2025): adds `retain_last` and `clean_expired_metadata`.
   - For 467 users who need the equivalent of `clean_expired_metadata`, document the Spark fallback: `CALL iceberg.system.expire_snapshots(table => '...', clean_expired_metadata => true)`.
   - For 467 users who need the equivalent of `retain_last`, document the table-level alternative: `ALTER TABLE ... SET TBLPROPERTIES ('history.expire.min-snapshots-to-keep' = '10')`.
2. **resources/17-iceberg-table-maintenance.md** — Add a first-run-on-backlog playbook: start with `retention_threshold => '90d'`, verify drop, then ratchet to 60d, then 30d. Mention that `expire_snapshots` in Trino runs on a single coordinator node (issue #19096), so a six-month backlog can take much longer than "a few minutes."
3. **General rule for resources/17 and beyond** — Any procedure-parameter example in the resources that is NOT supported on Trino 467 must be flagged inline with `(Trino 479+; not available on production Trino 467)`. Otherwise the responder will continue to paste current-version examples into 467-targeted answers.

### Suggested focus for Iter 324
- **Iceberg table maintenance** (4.552/21 after Q2 — single-question −2.15 drop): re-probe `clean_expired_metadata` from a different angle AFTER resources/17 is fixed. Verify the responder correctly states the parameter requires Trino 479+ and is unavailable on prod Trino 467, with the Spark fallback path.
- **Iceberg table maintenance** (cross-check): probe `retain_last` as the second 479-only parameter to confirm the responder applies the same version gate. Combine with `history.expire.min-snapshots-to-keep` to see if the responder can correctly identify the table-property fallback.
- **Version-skew audit** more generally: any topic that recommends Trino procedure parameters should cross-check against the Trino 467 release notes / docs to catch other version-skew fabrications.
- **Multi-tenant analytics** (per Iter 322 follow-up): Q1 confirmed the OPA fix held; consider one more probe at a different angle to lock the recovery.

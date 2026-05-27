# Iter 297 Q1 — Score: Iceberg maintenance cleanup process & safe order

## Question recap
Engineer noticed 40% storage cost jump vs. 15% data growth, plus a "historical" report from two months ago now returns different numbers. Asked: (1) is there a periodic cleanup process? (2) what's the safe order — delete data first or metadata first?

## Score table

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | Core claims are correct: snapshot accumulation drives storage bloat; orphan cleanup race condition with in-flight writes is real; `older_than` default protects writes; `dry_run` parameter exists; `rewrite_manifests` is a valid Spark procedure; `FOR VERSION AS OF <snapshot_id>` is correct Trino syntax. One clearly wrong claim: the answer states "Trino's ALTER TABLE EXECUTE optimize is for bin-pack compaction only, not the full maintenance suite" — Trino 467 explicitly supports `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` and `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')`. Steering engineers exclusively to Spark for these procedures is misleading for a Trino 467 shop. Also a subtle imprecision in the "why order matters" rationale — the standard reason cited in docs is that running orphan cleanup before expire_snapshots can race against in-flight writes; the answer's narrative is broadly right but the chained reasoning ("3+ days... committed or already garbage") is loose. |
| Beginner clarity | 5 | Excellent. Zero unexplained jargon; opens with plain-language framing of both problems; each step has a one-line purpose; the storage-goes-up-before-it-goes-down nuance is called out explicitly; warning about the 30-day window losing 2-month snapshots is concrete and useful. |
| Practical applicability | 4 | Copy-pastable SQL, references MinIO, gives concrete schedule (nightly compaction; weekly expiry+orphan+manifest), suggests Airflow/CronJob (fits k8s stack). Loses one point because the answer steers engineer exclusively to Spark for maintenance when Trino 467 procedures would work directly from the query engine they already operate. For a Trino-shop on-call, the Trino-native path (`ALTER TABLE EXECUTE expire_snapshots`) is a meaningful operational option that should at least have been mentioned. |
| Completeness | 5 | Addresses both questions: yes there is a cleanup process; here is the safe order with the rationale. Adds high-value extras: historical-mismatch investigation via snapshot-targeted time travel, dry-run safety, and an explicit "investigate BEFORE expiring snapshots" warning that directly maps to the two-month-old report scenario. Schedule guidance closes the loop. |

**Average: 4.5 — PASS**

## Verification notes

WebSearch verified:
- **Order matters / race condition**: Multiple sources (Iceberg official maintenance doc, IOMETE, Dremio) confirm that `remove_orphan_files` with too-short retention can delete in-flight files; safe ordering is compact → expire snapshots → remove orphan files → rewrite manifests. Answer's ordering matches consensus.
- **`dry_run` parameter on `remove_orphan_files`**: Confirmed on Iceberg 1.5.1 Spark procedures doc. 1.5.2 (the prod version) is API-compatible.
- **`rewrite_manifests` procedure**: Confirmed exists in Spark Iceberg 1.5.x procedures.
- **`FOR VERSION AS OF` syntax**: Confirmed as Trino's snapshot-id time travel syntax (Starburst blog, Trino 481 docs).
- **Trino 467 maintenance procedures**: Trino docs confirm `expire_snapshots` and `remove_orphan_files` are available via `ALTER TABLE EXECUTE` in modern Trino versions, with `retention_threshold` (default 7d) and catalog-level minimums (`iceberg.expire-snapshots.min-retention`, `iceberg.remove-orphan-files.min-retention`). This contradicts the answer's "Trino only does bin-pack" claim and is the answer's main technical error.

## Topic mapping

Primary:
- **Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup** — current avg 4.623 / 16 questions
- **Cost considerations for analytical workloads at SaaS scale** — current avg 4.50 / 3 questions (storage cost angle)
- **Storage sizing and growth estimation for lakehouse workloads** — current avg 4.500 / 5 questions (40% vs 15% growth)

Secondary (touched):
- **Analytical query patterns on Iceberg+Trino** — FOR VERSION AS OF time travel usage
- **Query performance regression diagnosis** — investigation workflow for the historical mismatch

## Verdict

**PASS at 4.5.** The answer is genuinely high quality on clarity and completeness, with strong SaaS-engineer-friendly framing and immediately actionable runbook. The one meaningful gap is steering the engineer exclusively to Spark for maintenance procedures when their primary query engine (Trino 467) supports the same operations natively — a Trino-shop on-call could and should be told both paths exist. Teacher should consider adding/strengthening a "Trino-native maintenance" section to the maintenance resource so future answers do not omit `ALTER TABLE EXECUTE expire_snapshots` / `remove_orphan_files`.

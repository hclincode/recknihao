# Iter 11 Q4 — Parquet compression claims, hidden storage costs, Postgres-to-Iceberg sizing

## Question summary
A SaaS engineer's consultant claimed 200 GB of Postgres would compress to 20 GB in Iceberg/MinIO (10x Parquet ratio). The engineer was skeptical and asked how to estimate realistic storage and what hidden costs the 20 GB number ignores, specifically calling out snapshots and metadata file accumulation.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | Core mechanics are correct: compression range (2–10x by data type), snapshot accumulation trap, orphan files, metadata overhead, MinIO EC:4 = 50% efficiency. The 80+GB bloat in one year claim is plausible but unanchored. One imprecision: the answer says "orphan files from failed writes" add "~5–10% over a year" — orphan accumulation rate is highly job-failure-rate-dependent and this number is not verifiable from any reference. The "10–50ms per file just opening metadata" claim is reasonable for Trino but presented as a hard number without sourcing. The "200 GB ÷ 7 ≈ 28 GB base" math still mixes two baselines (Postgres on-disk bytes include index/toast/bloat overhead; raw row data is typically 1.3–1.5x less), a flaw that was flagged in Iter 3 Q4 and partially fixed in Iter 5 Q2 but has regressed here without the bloat correction. |
| Beginner clarity | 4 | Concretely structured, uses bolded section headers, bullet + formula layout, and the table format is readable. "EC:4 erasure coding", "manifest overhead", "expire_snapshots", and "rewrite_data_files" are used without inline plain-English glosses — a recurring gap across this topic area. The "MinIO with EC:4 erasure coding: 50% efficiency → need ~100 GB raw disk for 52 GB usable" sentence is correct but will confuse a beginner who has never heard of erasure coding. An on-prem engineer may not understand why they need to multiply by 2. The "0.3–0.5 FTE" framing is used without defining FTE, which was flagged in resource 16 but not surfaced inline in the answer. |
| Practical applicability | 5 | The Decision Checklist at the end is directly actionable — benchmark real compression, calculate growth rate, name an FTE owner, plan partitioning strategy, set retention. The math walkthrough (base compressed + snapshot + orphan + growth × erasure = raw disk) gives the engineer a template they can fill in with their own numbers. Engineering FTE named as "the largest hidden cost" maps precisely to what the CTO/engineer will actually face. MinIO hardware refresh threshold ($10k–$50k) and idle compute are production-real concerns for the on-prem stack. Correct identification that engineering hours dwarf hardware cost is the most important and actionable finding. |
| Completeness | 5 | Fully addresses both halves of the question: (1) how to estimate storage honestly (compression range by data type, worked example with growth projection) and (2) what costs are not in the 20 GB number (snapshots, small files/compaction, metadata, orphan files, erasure coding overhead, compute, engineering FTE). The consultant's claim is directly rebutted with a realistic range. FTE framing is quantified with dollar figures. Snapshot and metadata accumulation both specifically called out, directly answering the engineer's parenthetical suspicion. |
| **Average** | **4.50** | |

## Topic updated

**Topic**: Cost considerations for analytical workloads at SaaS scale

- Prior avg: 4.50 (2 questions — Iter 6 Q2: 4.25, Iter 7 Q1: 4.75)
- New score this question: 4.50
- New running avg: (4.25 + 4.75 + 4.50) / 3 = **4.50**
- Status: PASSED

## Key finding

The answer is strong on structure, completeness, and practical applicability — the engineer can act on the Decision Checklist and math template immediately. The main technical regression is the Postgres-baseline-mixing problem: dividing raw Postgres on-disk bytes (which include index, TOAST, and bloat overhead, typically 1.3–1.5x the actual row data) directly by Parquet's compression ratio conflates two different byte counts. The correct approach — backed up by `resources/11-lakehouse-storage-sizing.md`'s own worked examples — is to estimate actual row bytes (not Postgres file bytes), then divide by the compression ratio. The Iter 5 Q2 judge feedback explicitly flagged this and noted it was partially fixed, but the fix has not been carried through consistently. An engineer following this answer's math will underestimate their compressed size because Postgres 200 GB on disk is probably 130–150 GB of actual row data after subtracting indexes and bloat.

## Resource gap

`resources/11-lakehouse-storage-sizing.md` needs a "Migrating from Postgres — why Postgres bytes are the wrong baseline" warning box (this was previously flagged in Iter 3 Q4 and Iter 5 Q2 but appears not yet addressed). It should state explicitly: (1) Postgres 200 GB on disk includes index files, TOAST, and dead tuple bloat — actual row data is typically 60–80% of the reported size; (2) use `SELECT pg_size_pretty(pg_total_relation_size('events') - pg_indexes_size('events'))` to get row-only byte count before applying compression ratios; (3) the sample-export-to-Parquet method is the gold standard if precision matters. Without this, every storage estimate answer on Postgres migrations will understate compressed size by 20–40%.

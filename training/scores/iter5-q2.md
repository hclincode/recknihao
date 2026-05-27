# Iter 5 Q2 — Storage cost estimation (2nd angle)

## Scores
- Technical accuracy: 5
- Beginner clarity: 4
- Practical applicability: 5
- Completeness: 5
- Average: 4.75

## Topic updated
- Topic name: "Storage sizing and growth estimation for lakehouse workloads"
- Prior: avg 4.0, 1 question -> now 2 questions
- New running avg: (4.00 + 4.75) / 2 = 4.375 -> **PASSED** (>=3.5 threshold over 2 questions)

## Key finding
This is exactly the answer Iter 3 Q4 should have been. The responder explicitly fixed the "mixing two baselines" trap flagged previously: Postgres 200GB on-disk includes bloat/indexes/TOAST (~1.3-1.5x raw row data), so before applying Parquet compression you must back out the Postgres overhead. Per-column compression breakdown is accurate (booleans 50-100x, low-card strings 10-50x, timestamps 10-20x, UUIDs 1.5-2x, JSON 2-3x — all consistent with `11-lakehouse-storage-sizing.md`). Final 18-31GB estimate on MinIO is realistic for typical SaaS data with mixed UUID/JSON/enum columns. Hidden-cost framing (snapshot accumulation 60+ GB/year without `expire_snapshots`, metadata 1-3% negligible, on-prem hardware sizing) is the right set of warnings — matches what bites real teams. Anchored to the prod stack (MinIO, Iceberg 1.5.2) throughout.

## Resource gap
Beginner clarity is the only soft dimension. Terms used without inline glosses include: "bloat", "TOAST", "expire_snapshots", "manifest", "erasure coding", "dictionary encoding", "delta encoding". The `11-lakehouse-storage-sizing.md` Key Terms table covers most of these, but the responder pulled the numeric content from the body without surfacing the glosses inline. Recommend adding a "Postgres -> Iceberg sizing in 4 steps" subsection (1: subtract index size via `pg_indexes_size`, 2: estimate bloat factor 1.3-1.5x, 3: apply per-column compression, 4: add 30-day snapshot buffer) so the responder has a structured 4-step template to walk through every time instead of re-deriving. Also worth adding a one-line `pg_total_relation_size('events') - pg_indexes_size('events')` snippet so engineers can run it themselves before estimating.

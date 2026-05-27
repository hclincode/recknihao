# Iter 3 Q4 — Storage sizing and growth estimation

## Scores
- Technical accuracy: 4
- Beginner clarity: 4
- Practical applicability: 4
- Completeness: 4
- Average: 4.00

## Topic updated
- Topic name: "Storage sizing and growth estimation for lakehouse workloads"
- Questions asked so far for this topic: 0 → 1
- New running avg: 4.00

## Key finding
The answer correctly pulls the core mechanics from `11-lakehouse-storage-sizing.md`: 5–10x Parquet compression ratio, per-column-type compression table (low-card strings 10–50x, timestamps 10–20x, UUIDs 2–4x, JSON 2–3x), the snapshot-accumulation trap with `expire_snapshots`, and the on-prem "no per-GB bill, you pay in hardware" framing. The worked calculation (200GB ÷ 7 ≈ 29GB) is mathematically right but conceptually shaky — Postgres' 200GB on-disk size already includes Postgres's own page/index/TOAST overhead, so dividing raw Postgres bytes by Parquet's raw-to-compressed ratio mixes two different baselines. The honest answer would be "Postgres 200GB likely has 60–120GB of actual row data plus index/bloat; that 60–120GB will compress 5–10x in Parquet, giving 10–25GB" — directionally the same range, but the reasoning the engineer takes to their CTO is wrong. Growth math (15GB/mo → 1.5–3GB/mo Iceberg) has the same flaw but ends up roughly correct.

## Resource gap for next iteration
`11-lakehouse-storage-sizing.md` needs an explicit "Migrating from Postgres — how to estimate" section that calls out the Postgres-disk-size-vs-raw-row-bytes gotcha: Postgres on-disk includes index pages (often 30–50% of total), TOAST, bloat, and fillfactor padding. The right method is either (a) `SELECT pg_total_relation_size` minus `pg_indexes_size` to isolate heap, then estimate avg row width from `pg_stats`, OR (b) export a sample to Parquet and measure directly. Without this, engineers will quote wrong numbers to leadership and the lakehouse looks worse (or better) than reality.

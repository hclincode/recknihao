# Iter 14 Q4 — Columnar storage: hardware-level mechanisms for SUM speed (SIMD, cache, decompression)

## Question summary
A SaaS engineer who already understands that columnar databases skip unnecessary columns asks why they are also faster at arithmetic — specifically why summing a billion numbers is faster than Postgres could manage. They want a hardware-level explanation.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | SIMD claim is accurate: AVX2 processes 8 × float32 / int32 per instruction at 256-bit width — confirmed by official AVX2 documentation. CPU cache locality claim is accurate: adjacent column values fill cache lines, row-oriented layouts cause cache misses when jumping between columns mid-scan. Both claims are well-established in columnar database literature. The "decompression is free" framing, however, is technically imprecise. Decompression is NOT free — fast codecs (Snappy, LZ4, Zstd) decompress at speeds that exceed disk read bandwidth, so decompression is rarely the bottleneck, but it consumes real CPU cycles and can become a bottleneck in CPU-constrained pipelines or when CPU cores are shared. Describing it as "free" without qualification overstates the case. The Postgres billion-row timing (hundreds of seconds, 200 GB scan) vs Trino (2–5 seconds, 300 MB compressed) is plausible directionally, but 2–5 seconds is aggressive for a billion-row SUM on an on-prem Trino cluster without knowing worker count, network, and MinIO throughput. The numbers are illustrative, not precise, and presenting them as concrete without caveats can set false expectations with a CTO. One point docked for "decompression is free" framing and uncaveated timing claims. |
| Beginner clarity | 5 | Opens with a relatable framing ("summing a billion numbers") and delivers each mechanism in plain English before naming it. "8–16 numbers simultaneously instead of one at a time" is a correct and accessible SIMD description. "Adjacent columnar values fit in L1/L2/L3 cache" accurately names the cache hierarchy. "Pipeline stalls" and "cache misses" are named but briefly enough that a beginner can absorb the intuition without being overwhelmed. The concrete billion-row example anchors the abstract claims. No OLAP jargon left unexplained. This is the question the previous iteration (Iter 6 Q3) missed badly on beginner clarity — this answer fully repairs that gap. |
| Practical applicability | 4 | The hardware intuition helps an engineer understand WHY their Trino+Iceberg stack is faster than Postgres for analytics — which is useful for internal stakeholder explanations and architectural decisions. However, the answer does not give an engineer a next action. It explains mechanisms but does not connect them to decisions they can make: e.g., choosing Snappy vs Zstd in Parquet writer settings, tuning Trino's task.max-local-execution-time, or how SIMD availability affects choosing Trino vs ClickHouse for this on-prem stack. One point docked for missing the bridge from hardware explanation to actionable configuration or query tuning advice in the production stack. |
| Completeness | 4 | Covers the three mechanisms asked about. Correctly identifies SIMD, cache efficiency, and compression/decompression pipeline as the hardware-level story. However, the answer skips a fourth mechanism that is central to why columnar analytically outperforms row-oriented engines for aggregation: vectorized execution's batch processing model (processing 1024–4096 values per operator call, eliminating per-row function call overhead of Postgres's iterator model). This is distinct from SIMD — it is the batch API design that enables SIMD to apply at all. The prior Iter 2 Q3 judge note explicitly flagged vectorized execution as missing from the column-oriented resource; the current answer conflates SIMD (hardware instruction) with vectorized execution (software batch model). The answer also does not connect columnar layout → Parquet column statistics → Iceberg manifest pruning → Trino file skipping, which is the production-stack chain that explains why the 200 GB → 300 MB figure is achieved. One point docked for missing the vectorized batch model distinction and the Iceberg pruning chain. |
| **Average** | **4.25** | |

## Topic updated

**Topic**: Column-oriented storage — what it is and why it's faster for analytics
- Prior avg: 4.125 (2 questions: Iter 2 Q3 = 4.75, Iter 6 Q3 = 3.50)
- New score: 4.25
- New running avg: (4.75 + 3.50 + 4.25) / 3 = **4.167** across 3 questions
- Status: PASSED (avg 4.167 >= 3.5 threshold, 3 questions asked from distinct angles)

## Key finding

This is a meaningful improvement over the Iter 6 Q3 answer on the same topic, which scored 3.50. That answer reversed the production-stack priority (treating GROUP BY file-scan as an afterthought) and provided no beginner clarity on HashAggregate/shuffle. This answer correctly leads with the hardware mechanisms at a beginner-appropriate level and is factually sound on SIMD and cache. The main weaknesses are: (1) "decompression is free" is an overstatement that will propagate as a misconception — decompression consumes CPU; the accurate framing is that fast codecs decompress at rates exceeding disk bandwidth so it is rarely the bottleneck; (2) the vectorized batch model (the software-level design that enables SIMD) is conflated with SIMD itself; (3) the production-stack chain from columnar layout to Iceberg file pruning is absent, so the answer explains general columnar theory without grounding it in what the engineer's Trino + Iceberg + MinIO stack actually does differently from a generic Postgres scan.

## Resource gap

`resources/03-columnar-storage.md` should add:

1. A "vectorized batch model vs SIMD" clarification — SIMD is a CPU instruction set; vectorized execution is the software design that feeds batches of 1024–4096 column values into tight loops so SIMD can operate. They are complementary but distinct; conflating them produces the misconception that SIMD alone explains analytic speed.

2. Replace "decompression is free" with the accurate framing: "fast codecs (Snappy, LZ4, Zstd) decompress at rates that typically exceed disk read speed, so decompression is rarely the bottleneck — but it is not literally free and consumes CPU cycles. On CPU-constrained pipelines or when the Trino cluster is heavily loaded, decompression overhead is measurable."

3. A "complete stack chain" subsection: columnar layout → Parquet column chunks (only target column read from disk) → dictionary/RLE compression → Parquet row-group min/max statistics → Iceberg manifest pruning → Trino file skipping → vectorized batch scan → SIMD arithmetic. This makes the abstract hardware claims concrete for the production on-prem stack.

# Score: Iteration 15, Question 3

**Date**: 2026-05-24
**Phase**: Final
**Question**: Someone on my team said our analytics queries are slow because Postgres has to read the entire row just to add up one column — like scanning everyone's full profile just to total up a single field. Is that actually true, and if so, how would a different kind of database store things so it doesn't have to do that?
**Rubric topics covered**: Column-oriented storage — what it is and why it's faster for analytics

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.25 | Row-oriented penalty accurately described. Columnar layout explanation is correct. ASCII diagram is clear and correct. "5–20x reduction in bytes read" is reasonable. Compression encodings (dictionary, run-length, delta) are accurate. The production stack chain mentions Iceberg file-skipping, Parquet column-read, and "batch processing + SIMD" — partially correct. Deductions: (1) decompression not mentioned at all (the updated resource specifies it as a step in the chain that consumes CPU but is rarely a bottleneck); (2) vectorized batch model (software: 1024–4096 values per operator call) and SIMD (hardware: 8–16 values per CPU instruction) are blurred — the answer mentions batches of 1024–4096 AND vector instructions in the same sentence without clearly separating two distinct layers. |
| Beginner clarity | 4.75 | Excellent. Opens with plain-English confirmation of the teammate's claim. ASCII diagram of columnar layout is the strongest pedagogical tool in any answer this iteration — makes the abstract concrete immediately. Compression bonus section is jargon-light. Trade-off section cleanly explains why Postgres still runs the app. |
| Practical applicability | 4.50 | Correctly grounds the answer in the production stack (Iceberg + Parquet + MinIO + Trino). Production chain steps are mostly right. No cloud tool recommendations. Minor gap: Trino row-group pruning (using min/max statistics within Parquet files) is missing from the chain — it's a step between Iceberg file-skipping and decompression. |
| Completeness | 4.00 | Core question answered well. Gaps: (1) decompression step in production chain omitted; (2) vectorized batch model vs SIMD distinction not clearly drawn — the resource now has an explicit two-layer explanation (Layer A: software batch processing; Layer B: hardware SIMD); (3) compression ratio "5–30x" for individual columns is in range but the resource notes that the production-chain compression effect (fewer bytes from MinIO) is separate from the within-column compression ratio. |
| **Average** | **4.375** | Above 3.5 pass threshold. |

---

## What the answer got right

1. Postgres row-oriented penalty correctly explained — must read all columns to get any one column.
2. Columnar layout correctly described — values of one column stored contiguously.
3. ASCII diagram is concrete and accurate.
4. Compression benefit correctly noted with three specific encoding types.
5. Production stack correctly named (Iceberg → Parquet → MinIO → Trino).
6. Trade-off (columnar slow for single-row lookups) correctly surfaced.
7. "Already solving this with Trino + Iceberg" framing is exactly right.

## What the answer missed or got wrong

1. **Decompression step missing from chain.** The updated `resources/03-columnar-storage.md` specifies decompression (Snappy/LZ4/Zstd) as step 4 in the chain. "Rarely a bottleneck but not zero-cost" framing was supposed to carry into answers after the iter14/15 resource fix. The responder skipped decompression entirely.

2. **Vectorized batch vs SIMD distinction blurry.** The resource added a two-layer explanation: Layer A (software, 1024–4096 values per operator call) and Layer B (hardware, 8–16 values per SIMD instruction). The answer says "processes column values in batches (1,024–4,096 at a time) and uses your CPU's vector instructions to sum 8–16 values per clock cycle" — which mentions both numbers but in one sentence, blurring the two layers. The resource fix was supposed to result in a clearly separated two-layer explanation.

3. **Trino row-group pruning missing.** Parquet row-group min/max statistics (used by Trino to skip row groups within a file) are a distinct step between file-skipping and decompression. The chain should include this.

---

## Resource assessment

The `resources/03-columnar-storage.md` fixes from iter14/15 (decompression framing, vectorized vs SIMD distinction, production chain) are in the resource. The responder partially applied them — batch size and SIMD are both present but not clearly separated, and decompression is missing. The fixes held better than iter14 (which had the full conflation) but the two-layer distinction is still not landing cleanly. Recommendation: add a bolded inline callout to the resource: "**These are two distinct layers — software batch and hardware SIMD — working together.**"

---

## Topic score updates

**Column-oriented storage — what it is and why it's faster for analytics**
- Prior: avg 4.167 across 3 questions
- This answer: 4.375 (4th angle — teammate's "reads entire row" framing)
- New running avg: (3.75 + 4.25 + 4.50 + 4.375) / 4 = **4.219** across 4 questions
- Status: PASSED (unchanged, improving)

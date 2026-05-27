# Iter 7 Q3 — OLTP-to-OLAP mindset: Trino+Iceberg for a team coming from Postgres (JOINs, UPDATEs, DELETEs)

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | Core mechanics correct (Parquet immutability, delete files, compaction, ROW_NUMBER event-sourcing, rewrite_data_files syntax). Two factual weaknesses: (1) "A 12-table JOIN means Trino reassembles rows from a dozen files" conflates Parquet's intra-file columnar layout with inter-table JOIN execution — the real JOIN cost in Trino is network shuffle between distributed workers, not reassembly from separate files; beginners form the wrong mental model here. (2) "No indexes" is accurate but incomplete — Iceberg uses Parquet column statistics and manifest-level min/max metadata for file skipping, a coarse but important substitute; dismissing indexing categorically understates how Trino actually prunes data. |
| Beginner clarity | 5 | Best clarity score in this iteration. Leads with a plain-English diagnosis. Before/after SQL pairs for JOINs and event-sourcing are excellent teaching devices. "Delete file" and "compaction" defined inline. Monday morning checklist is scannable. Latency expectation reset ("3–15 seconds is good for OLAP") prevents false-negative bug reports. Even the technically oversimplified JOIN explanation gives the right intuition for a beginner. |
| Practical applicability | 5 | Fully actionable. Monday morning list is sequenced and specific. Compaction CALL (`map(ARRAY['target-file-size-bytes'], ARRAY['134217728'])`) is valid Trino syntax confirmed against Trino documentation. Denormalization before/after SQL maps exactly to the engineer's described problem (JOINs across many tables). Event-sourcing INSERT + ROW_NUMBER query is copy-paste ready. Grounded in Trino + Iceberg on-prem stack throughout; no cloud-only advice. |
| Completeness | 4 | All three engineer complaints addressed (JOINs, UPDATEs, DELETEs). Two gaps: (1) "Deletes aren't working right" interpreted purely as a performance problem — the answer doesn't address the correctness angle (whether delete files are reliably applied across all Trino query sessions, or whether engineers can encounter apparently-live rows during the compaction window). (2) The over-denormalization trap from the resource (copying current plan_type into event rows loses event-time accuracy) is absent — this matters because the answer actively encourages denormalizing plan_type, and a beginner following this advice may not realize they are baking in the current plan value rather than the plan at event time. Step 6 of the Day-1 checklist (per-tenant views) again absent, consistent with prior gap. |
| **Average** | **4.50** | |

## Topic updated

**Topic**: OLTP-to-OLAP mindset: the mental model shift for SaaS engineers adopting a lakehouse

- Prior avg: 4.50 across 1 question (Iter 6 Q1 — Day-1 checklist framing)
- This question score: 4.50
- New running avg: (4.50 + 4.50) / 2 = **4.50** across 2 questions
- Status: **PASSED** — avg 4.50 >= 3.5 threshold; 2 different question angles covered (Day-1 setup checklist vs. live-team diagnosis of OLTP patterns failing in production)

## Key finding

The answer is a strong, beginner-accessible treatment of all three failure modes the engineer described, with actionable SQL for each. The one meaningful technical weakness is the JOIN explanation — claiming Trino "reassembles rows from a dozen files" describes Parquet's intra-file column storage, not inter-table JOIN shuffle, and will leave beginners with a wrong mental model of why distributed JOINs are expensive.

## Resource gap

`resources/12-oltp-to-olap-mindset.md` — add a one-sentence inline warning to the denormalization guidance: "Copy dimension values *as they were at event time*, not the user's current value — so the historical row stays accurate even after the user upgrades their plan." This is already in the Common First Mistakes section as "Over-denormalizing" but should appear inline in the Day-1 checklist step 2 and in the side-by-side table row, since the answer skipped that nuance when advising denormalization. Additionally, add a one-sentence clarification in the "Stop mutating, start appending" section on DELETE correctness: "Trino reads delete files reliably on every query — the rows are not visible after a DELETE — but query performance degrades with each accumulated delete file until compaction merges them away."

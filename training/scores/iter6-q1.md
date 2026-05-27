# Iter 6 Q1 — OLTP-to-OLAP mindset: first move on lakehouse ticket

## Scores
- Technical accuracy: 5
- Beginner clarity: 4
- Practical applicability: 5
- Completeness: 4
- Average: 4.50

## Topic updated
- Topic name: "OLTP-to-OLAP mindset: the mental model shift for SaaS engineers adopting a lakehouse"
- Prior: 0 questions
- New avg: 4.50 (1 question — needs 2nd angle before passing)

## Key finding
The answer is a clean, actionable walk through the Day-1 checklist from `resources/12-oltp-to-olap-mindset.md`, correctly sequenced (pick tables → schema design → Spark job → CREATE TABLE → schedule compaction → point BI tool at Trino) and grounded in the production stack throughout. The "analytical copy, not a migration" framing is the single most important mental shift the resource teaches, and the answer surfaces it explicitly. The main clarity gap is that jargon terms (denormalized schema, partition spec, compaction, expire_snapshots, JSONB, CronJob) appear without the plain-English glosses that the resource provides — a beginner could follow the steps but not understand *why* each one exists.

## Resource gap
The per-tenant Trino view step (step 6 of the Day-1 checklist: `CREATE VIEW tenant_42.events AS SELECT * FROM analytics.events WHERE tenant_id = 42`) is absent from the answer summary. This is a security-adjacent omission — an engineer who follows steps 1–5 and skips straight to "point BI tool at Trino" will expose cross-tenant data. The resource includes this step but the answer dropped it. Consider adding a callout box in `resources/12-oltp-to-olap-mindset.md` after the Day-1 checklist that flags step 6 (tenant views) as non-optional for B2B SaaS — not a "nice to have once you get fancy" item.

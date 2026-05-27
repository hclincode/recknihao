# Score: Iteration 15, Question 2

## Question
I keep hearing we should move our analytics to a "data warehouse" but we already have a database — isn't that what a database is? What would we actually get by having a second, separate database just for analytics, and wouldn't keeping two databases in sync just create more problems?

## Rubric topics tested
- What a data warehouse is and how it differs from an operational database
- When to add an OLAP layer vs staying on the transactional DB

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All factual claims verified against resources and established OLAP literature. "10–50x reduction in bytes read" matches `01-olap-vs-oltp.md` line 85 verbatim. Thresholds (50M rows, >2s, >3 users, >1 source) match `06-when-to-add-olap.md` exactly. Migration path (Spark JDBC → MinIO Parquet → Iceberg → Trino) is accurate for the production stack. No factual errors introduced. |
| Beginner clarity | 4.25 | Strong opening that reframes the question before introducing any terminology. Concrete SQL examples appear early (the point-lookup vs GROUP BY contrast). Most jargon is explained inline. Deductions: "fact tables" introduced without a one-line plain-English definition; "denormalized" used without a gloss; "Hive Metastore" appears in the "next step" closing paragraph without explanation for a zero-background reader. |
| Practical applicability | 4.75 | Correctly re-anchors to the production stack (Spark + Iceberg + MinIO + Trino) rather than recommending cloud tools. Tuning-first recommendation ("try the Postgres tuning checklist first") with specific resource pointer is exactly the right priority order. Concrete, measurable thresholds the engineer can apply today. Migration path is specific and accurate. |
| Completeness | 3.75 | Three sub-questions are addressed: (1) OLTP vs OLAP distinction — well done; (2) what you get — partially done (query speed angle is thorough, multi-source consolidation barely touched); (3) sync concerns — well done. The significant gap: `resources/02-data-warehouse.md` explicitly identifies multi-source consolidation as "often the primary driver for SaaS companies" — frequently the reason a warehouse is built even at only 5M rows. The answer mentions "join data from more than one source system (Postgres + Stripe + product analytics)" once in a bullet list, but does not frame it as a primary value proposition or illustrate it with an example. A SaaS engineer reading this answer might conclude "I don't have 50M rows so I don't need this" when in fact the multi-source need (Stripe + Mixpanel + Postgres) often precedes the row-count threshold. |

**Average: 4.44**

**Result: PASS** (4.44 >= 3.5 threshold)

---

## What the answer got right

1. **OLTP vs OLAP framing** — the opening reframe ("they're optimized for almost opposite workloads") is the correct mental model and is established before any jargon.
2. **Concrete query examples** — the `SELECT * FROM users WHERE id = 12345` vs `SELECT plan_tier, COUNT(*) FROM users WHERE created_at >= ... GROUP BY plan_tier` contrast makes the structural difference tangible for a beginner.
3. **Row scan explanation** — correctly explains that the app database reads every row AND every column even when only two are needed.
4. **Production stack accuracy** — correctly names Spark, Iceberg, MinIO, Trino as the analytical path. Does not recommend cloud tools incompatible with the on-prem-only constraint.
5. **Sync concern defused correctly** — one-directional, automated nature of the sync (Postgres is source of truth, Iceberg is the analytical copy) is the right framing and matches the resource.
6. **Tuning-first priority** — correctly sends the engineer to the Postgres tuning checklist before committing to two systems.
7. **Concrete thresholds** — the 50M rows, 2 seconds, 3 users, and multiple-source signals map directly to the resource's decision table.
8. **"Cost of not having it" framing** — the closing section addresses the implicit concern about operational overhead honestly.

---

## What the answer missed or underweighted

### Primary gap: Multi-source consolidation (Reason 2)

`resources/02-data-warehouse.md` has a prominent two-value-proposition callout explicitly flagged with: "For many SaaS companies, reason 2 [multi-source consolidation] is the primary driver, not reason 1." The answer gives Reason 1 (query performance) thoroughly and Reason 2 only a passing mention in a bullet list. A SaaS engineer asking this question might have:
- 5M rows in Postgres (below the threshold)
- Revenue in Stripe
- Behavior data in Mixpanel

For that engineer, the resource's answer is "you need the warehouse right now for multi-source joins" — but the answer's threshold section would tell them "wait, you're below 50M rows." This is a material gap in a question explicitly asking "what would we actually get."

The resource's concrete illustration ("what's our revenue from customers who signed up via the free trial and sent more than 10 messages in their first week?" — requiring Stripe + Mixpanel + Postgres) is the clearest possible motivating example and was not used.

### Secondary gap: Inline glosses for beginner-specific terms

"Fact tables," "denormalized," and "Hive Metastore" appear without one-line plain-English definitions. The question explicitly came from someone with zero OLAP background who didn't know what a "data warehouse" was. These terms are not trivial to a beginner.

---

## Topic score updates

### What a data warehouse is and when a SaaS product needs one
Prior avg: 4.75 across 2 questions. This question is a 3rd angle on this topic.
New running avg: (5.0 + 4.50 + 4.44) / 3 = **4.647** across 3 questions. Status: PASSED (unchanged).

### When to add an OLAP layer vs staying on the transactional DB
Prior avg: 4.333 across 3 questions. This question is a 4th angle on this topic.
New running avg: (4.75 + 4.00 + 4.25 + 4.44) / 4 = **4.360** across 4 questions. Status: PASSED (unchanged).

---

## Resource improvement recommendations

### resources/02-data-warehouse.md
The two-value-proposition callout is well-written and already in the resource. The issue is the responder is not surfacing Reason 2 prominently enough when the question is framed as a beginner "why do I need this?" question. Consider adding a forward-reference or summary line at the top of the resource that reads: "If your threshold question is 'do I have enough rows,' you may be asking the wrong question — many SaaS teams build a warehouse to join Stripe + Postgres + Mixpanel before they ever hit 50M rows."

No structural change required — the content exists. The teacher may want to add a "STOP — are you on Reason 1 or Reason 2?" callout near the top to prime the responder to present both motivations when answering beginner orientation questions.

### resources/06-when-to-add-olap.md
The decision tree and threshold table address only the row-count / query-speed signals (Reason 1). Consider adding a row to the threshold table:
- Signal: "Data needed for decisions lives in >1 system"
- Threshold: "Any (Postgres + Stripe, Postgres + Mixpanel, etc.)"

This would prime the responder to surface the multi-source trigger even when other thresholds are not met.

# Iter 6 Q5 — occurred_at vs ingested_at for mobile offline batching / WAU dashboard

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | Correctly identifies occurred_at as the right timestamp for WAU, correctly explains the 9:00 AM / 9:30 AM split, correctly states Iceberg partition-by-ingested_at + query-by-occurred_at as the canonical pattern. All facts match resource `14-real-time-vs-batch.md` exactly. No errors. |
| Beginner clarity | 5 | Opens with a concrete mobile-offline scenario (9:00 AM event, 9:30 AM delivery) before naming any concept. The "which cohort does this user belong to?" framing is plain English. The two-sentence rule ("occurred_at = when it happened, ingested_at = when you got it") is zero-jargon. Buffer window advice is concrete and labeled (show 'data through 2 hours ago', or wait until 02:00). No unexplained OLAP terms. |
| Practical applicability | 5 | The engineer knows exactly what to do: use occurred_at in dashboard WHERE clause, add a buffer (two concrete options given), partition by ingested_at, reserve ingested_at for pipeline monitoring. The distinction between "business metric" and "pipeline SLA" is a decision rule they can apply immediately. Fully grounded in the prod stack (Iceberg). |
| Completeness | 5 | Addresses all three implicit sub-questions: (1) which timestamp? (2) why does filtering differ? (3) what do I do about the delay? Also covers the Iceberg-specific trade-off (partition vs query timestamp), which is the nuance a SaaS engineer on this stack needs. Nothing in the question went unanswered. |

**Average: 5.0**

---

## Topic updated

**Topic**: Real-time vs batch analytics trade-offs

- Prior avg: 4.75 over 1 question
- New running avg: (4.75 + 5.0) / 2 = **4.875** across 2 questions
- Status: **PASSED** (>= 3.5 threshold, 2 question angles covered)

---

## Key finding

The answer is the cleanest execution seen in this training run — it uses the mobile-offline scenario from `14-real-time-vs-batch.md` verbatim, gives two concrete buffer options, and correctly separates the Iceberg partition strategy from the query aggregation strategy. There are no meaningful gaps on this answer.

---

## Resource gap

None for this answer specifically. The resource (`14-real-time-vs-batch.md`) already contains the exact scenario (offline buffering, 9:00 AM / 9:30 AM split, both timestamp definitions, the partition-by-ingested_at / query-by-occurred_at rule, and the buffer-window advice). The responder pulled all of it correctly. The previously flagged gap (inline glosses for "compaction", "micro-batch", "watermark" in the streaming sections) remains unaddressed in the resource but did not affect this question since streaming concepts were not needed here.

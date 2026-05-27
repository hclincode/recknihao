# Iter 4 Q1 — Real-time vs batch freshness

## Scores
- Technical accuracy: 5
- Beginner clarity: 4
- Practical applicability: 5
- Completeness: 5
- Average: 4.75

## Topic updated
- Topic name: "Real-time vs batch analytics trade-offs"
- Prior questions: 0 → 1
- New avg: 4.75

## Key finding
Strong, well-anchored answer. Correctly reframes "5-minute freshness" as a spectrum question rather than a streaming-vs-batch binary, and arms the engineer with the right counter-question to take back to PMs ("would 30 min or 1 hour actually satisfy?"). The 5-min batch = 288 jobs/day math, the k8s pod-churn and small-files/compaction-explosion callouts, and the stack-specific recommendation (read replica for batch; Iceberg 1.5.2 `writeStream` + Kafka + Spark Structured Streaming for true streaming) all map cleanly to `resources/14-real-time-vs-batch.md` and prod_info.md (on-prem k8s + Spark + Iceberg 1.5.2 + Trino 467 + MinIO). The compaction-must-run-hourly-not-nightly point is exactly the operational nuance the resource flags for streaming/micro-batch tables, and the responder surfaced it without prompting. Beginner clarity is the one soft spot: "compaction," "micro-batch," "writeStream," "Structured Streaming," and "Kafka" are used without inline plain-English glosses — an engineer who has never run a Spark streaming job will follow the recommendation but won't fully grasp why hourly compaction is non-negotiable.

## Resource gap for next iteration
The current resource handles the freshness-spectrum framing well, but it does not give the engineer a **decision script for the PM conversation** — i.e., the literal questions to ask ("what dashboard? what decision does it drive? what's the cost of being 30 min stale?") and what business-metric examples typically justify each freshness tier. Add a short "How to negotiate the freshness SLA with your PM" section to `14-real-time-vs-batch.md` with 3–4 example conversations, plus a side-by-side cost table (engineer-weeks to build + ongoing on-call burden) for daily / hourly / 5-min batch / streaming. Also add inline one-line definitions for "compaction" and "micro-batch" at first use, since those terms are load-bearing in the streaming recommendation.

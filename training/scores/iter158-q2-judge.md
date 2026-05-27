# Judge Report — Iter 158 Q2

**Question topic**: Kafka → Iceberg streaming (Spark Structured Streaming, near-real-time ingestion).

## Technical verification (via WebSearch against iceberg.apache.org and corroborating sources)

### Claim 1: Iceberg supports streaming writes via Spark Structured Streaming using `writeStream().format("iceberg")`
**VERIFIED**. iceberg.apache.org documents the Spark Structured Streaming sink. Confirmed canonical pattern is `data.writeStream.format("iceberg").outputMode("append").trigger(...).option("checkpointLocation", ...).toTable("db.table")` (Spark 3.1+). The answer's syntax sketch (`spark.readStream().format("kafka").writeStream().format("iceberg")`) is correct at the conceptual level.

### Claim 2: 60-second trigger interval recommended; sub-minute creates too many files
**VERIFIED with minor nuance**. Recent guidance (datalakehousehub.com, iceberglakehouse.com, AWS prescriptive guidance) recommends a **1–5 minute** trigger interval. 60 seconds is the lower bound of the recommended range. The answer's "minimum 60-second trigger" is acceptable shorthand but Iceberg docs do not impose a hard 60-second floor — it is a tuning recommendation, not a documented minimum. Minor imprecision, but the practical advice is sound.

### Claim 3: 1,440 files per day per partition for 60-second micro-batches
**MATHEMATICALLY CORRECT**: 24 × 60 = 1,440 micro-batches/day, each producing at least one file per partition. The "per partition" qualifier is correctly stated (a common mistake is to omit "per partition" and understate the file count for high-cardinality partitioning). Good.

### Claim 4: Iceberg 1.5.2 supports Spark Structured Streaming writes
**VERIFIED**. Streaming sink has been supported since well before 1.5.2 (present in 1.4.x docs). Production version is fine.

### Claim 5: `rewrite_data_files` recommended for compaction after streaming
**VERIFIED**. Iceberg docs and AWS/Dremio guidance confirm `rewrite_data_files` is the canonical compaction procedure for the small-files problem caused by streaming. Recommendation to run hourly compaction aligns with industry guidance (30–60 min cadence).

### Claim 6: Append-only events don't need MERGE INTO (unlike CDC)
**VERIFIED**. App events like `user.signed_up` are inherently immutable facts; pure append semantics are correct. Contrast with Debezium CDC (which carries `op='u'/'d'` requiring MERGE INTO) is accurate and a genuinely useful framing for a SaaS engineer.

### Production stack fit
- Spark Structured Streaming runs on the on-prem k8s cluster — compatible.
- Iceberg 1.5.2 + Hive Metastore — answer correctly references the production version.
- MinIO/S3 — answer doesn't explicitly mention checkpointLocation needing to be on s3a:// MinIO path. Minor gap.
- Kafka is assumed to already be running (the question states this), so the answer correctly doesn't bring up Kafka deployment burden.

## Dimension scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | All six core claims verified. Minor imprecision on "minimum 60-second trigger" (actually a tuning recommendation, not a hard floor). Conceptual code snippet is correct. |
| Beginner clarity | 4.5 | Freshness spectrum framing is excellent for a SaaS engineer with no streaming background. Jargon (micro-batch, atomic commit, checkpoint) is used in context. "10x more complex" gut-check is a great calibration device. Slightly heavy on Iceberg-specific terms (`rewrite_data_files` procedure) without expanding what the procedure does mechanically. |
| Practical applicability | 4.5 | "Ask your PM first" advice is gold for an app engineer about to over-engineer. Two clear options with pros/cons. Concrete next action (Option 1 = cron schedule change) for the most likely real answer. Missing: an actual code snippet (Python/Scala) showing the writeStream sink, and explicit mention that checkpointLocation must live on MinIO (s3a://). On-prem k8s deployment of a long-running streaming job is also not called out as an operational consideration (StatefulSet vs Job, restart semantics). |
| Completeness | 4.5 | Addresses all three sub-questions: (a) is there a standard way? Yes — Spark Structured Streaming sink. (b) is it just batch-more-frequently? No, fundamentally different architecture, and the spectrum clarifies the gradient. (c) is it a config flip or new architecture? Answered: new architecture, with hourly batch as a middle-ground escape hatch. Could be more complete on monitoring tooling (specific Spark streaming metrics) and on-prem long-running job management. |

**Weighted average**: (4.5×2 + 4.5 + 4.5 + 4.5) / 5 = (9 + 13.5) / 5 = 22.5 / 5 = **4.50**

## Strengths
- Freshness spectrum (daily / hourly / near-real-time) with "10x complexity per tier" — exactly the framing a SaaS engineer needs to push back on premature optimization.
- Correctly identifies "ask your PM first" — saves the engineer from over-engineering.
- Distinguishes app-event streaming (append-only, simple) from CDC streaming (MERGE INTO complexity) — a genuinely useful conceptual carve-out.
- Quantifies the small-files cost (1,440/day/partition) so the engineer understands why compaction is mandatory, not optional.
- Calls out monitoring complexity (consumer lag, checkpoint progress, file accumulation, compaction success) as separate things to instrument.

## Gaps / suggestions for teacher
1. **Code snippet missing**: The answer references the conceptual pattern `spark.readStream().format("kafka").writeStream().format("iceberg")` but does not give a runnable PySpark snippet showing checkpoint location, trigger, kafka source options, and `.toTable()` target. For an engineer who'll actually implement this, a 10-line example would close the gap from "I understand the architecture" to "I can write the job."
2. **MinIO checkpoint path**: Production stack uses MinIO via s3a://. The answer should explicitly note the checkpoint must be on durable shared storage (s3a://bucket/checkpoints/jobname/) — not the pod local disk. Pod restarts will lose progress otherwise.
3. **Long-running job on k8s**: A streaming job is a long-running pod, not a cron Job. The answer could note Spark Operator's `SparkApplication` vs `ScheduledSparkApplication` distinction, or at minimum flag that the deployment manifest differs from the existing nightly batch job.
4. **Trigger interval framing**: "Minimum 60-second trigger" is slightly stronger than the docs warrant. The accurate framing is "1-5 minute trigger is the recommended range; shorter triggers amplify the small-files problem without proportional latency win."

## Topic mapping
This question primarily exercises **Real-time vs batch analytics trade-offs** (already PASSED at 4.812 across 4 questions) and touches **Iceberg table maintenance: compaction** (PASSED 4.602, 14 questions). Strong cross-coverage answer.

## Pass/fail
**PASS** — weighted average 4.50 well above 3.5 threshold. Solid answer with correctly framed trade-offs and architecture distinction. Gaps are around hands-on implementation detail (code snippet, on-prem k8s deployment specifics) rather than conceptual correctness.

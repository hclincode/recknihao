# Score: Iter 339 Q2 — remove_orphan_files 7-day Retention Floor

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Core claim (7-day default min-retention floor) verified against Trino docs. Spark having no floor verified. `dry_run` parameter exists in Spark Iceberg procedures. Minor imprecision: the answer says Trino "skipped" the files — this is the correct outcome when no `retention_threshold` is passed (Trino defaults retention_threshold to 7d and excludes files younger than 7d), but the answer doesn't mention that passing an explicit `retention_threshold` shorter than `min-retention` would ERROR rather than silently skip. The race-condition framing (Spark "retrying") is slightly misleading — the real risk is uncommitted writes in flight, not retry logic. These are small nits in an otherwise correct explanation. |
| Beginner clarity | 4.5 | Strong narrative: opens with the diagnosis ("safety floor, not a bug"), uses a numbered race-condition story to motivate the floor, gives three clearly labeled options ranked by safety. No unexplained jargon. The "key takeaway" closure reinforces the lesson. A SaaS engineer reading this would understand both what happened and why. |
| Practical applicability | 4.5 | Three concrete options with copy-pasteable Spark SQL. Calls out `dry_run => true` as the safe first step. Names the exact catalog config property (`iceberg.remove-orphan-files.min-retention`) so the engineer can find it. Fits the production stack: Spark with Iceberg 1.5.2 supports the procedure shown; both Spark and Trino run on-prem on the k8s cluster per prod_info.md. Missing: doesn't show the Trino syntax (`ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '12h')`) which the engineer literally just ran, so they can't see what they should have typed differently in Trino if they wanted to override. Doesn't warn that the Spark catalog name in the example (`iceberg`) needs to match their actual catalog config. |
| Completeness | 4.0 | Covers: the why (floor), the mechanism (catalog property + default), three remediation paths, the race-condition rationale. Missing: (1) Trino syntax for `remove_orphan_files` so the engineer can compare to what they ran — they'd benefit from seeing `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')` and understanding that passing a shorter value would error. (2) Mention that Trino procedure outputs metrics (in newer versions) telling you how many files were skipped — useful for debugging "did nothing" symptoms. (3) No mention of checking the Trino query result/output to see what was actually scanned vs deleted. (4) No callout that orphan files cost MinIO storage but are otherwise harmless — engineer might panic-delete. |
| **Average** | **4.375** | **PASS** |

## What Worked
- Correct identification of the root cause (default 7-day floor) — directly addresses the engineer's "what am I missing?" question.
- Three clearly ranked options (safest first), with code that runs.
- `dry_run => true` recommended before destructive action.
- Explicit catalog property name (`iceberg.remove-orphan-files.min-retention`) lets the engineer self-serve.
- Closing sentence reframes the "failure" as correct protective behavior — good for a panicked engineer.

## What Missed
- No Trino syntax shown — the engineer ran a Trino procedure but the answer pivots entirely to Spark for remediation. Showing `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d', dry_run => true)` would close the loop on what they originally ran.
- Doesn't mention that passing a `retention_threshold` shorter than the catalog floor in Trino throws an explicit error message (which would have told the engineer what was wrong if they'd tried it).
- Doesn't note Trino 467's procedure output (file counts) as a debugging signal — engineer would have seen "0 files deleted" or similar in the result.
- Race-condition explanation says "Spark job retrying" — actual concern is uncommitted in-flight writes more broadly, not just retries.
- No mention that orphan files are storage cost only, not correctness risk — could help calibrate urgency.

## Technical Accuracy Verification
- **Claim: Trino enforces a 7-day default minimum retention via `iceberg.remove-orphan-files.min-retention`** — CORRECT per [Trino 481 Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html). Default is `7d`.
- **Claim: Procedure skips files younger than the floor without error when no explicit retention_threshold is passed** — CORRECT. Default `retention_threshold` equals the floor (7d), so younger files are excluded. Procedure completes successfully.
- **Claim: Spark has no equivalent 7-day floor** — CORRECT per [Apache Iceberg Spark procedures docs](https://iceberg.apache.org/docs/latest/spark-procedures/). Spark `remove_orphan_files` defaults `older_than` to 3 days ago and emits warnings (not errors) for shorter intervals.
- **Claim: `dry_run => true` parameter exists in Spark Iceberg `remove_orphan_files`** — CORRECT per [Apache Iceberg Spark procedures](https://iceberg.apache.org/docs/latest/spark-procedures/).
- **Claim: Spark CALL syntax `CALL iceberg.system.remove_orphan_files(table => ..., older_than => ..., dry_run => ...)`** — CORRECT syntax; catalog name `iceberg` is illustrative and depends on user's Spark catalog config.
- **Claim: Changing `iceberg.remove-orphan-files.min-retention` requires coordinator restart** — CORRECT; catalog properties in Trino require restart to take effect (not a runtime session property).
- **Claim: Race condition (concurrent uncommitted write gets its file deleted, then commit succeeds and queries break)** — DIRECTIONALLY CORRECT but framed as Spark "retry logic" specifically; the actual mechanism is any uncommitted write whose data files exist in object storage before the metadata commit. Iceberg [maintenance docs](https://iceberg.apache.org/docs/latest/maintenance/) explicitly warn about this.

Sources:
- [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html)
- [Procedures — Apache Iceberg](https://iceberg.apache.org/docs/latest/spark-procedures/)
- [Maintenance — Apache Iceberg](https://iceberg.apache.org/docs/latest/maintenance/)
- [Spark Procedures — Apache Iceberg 1.5.1](https://iceberg.apache.org/docs/1.5.1/spark-procedures/)

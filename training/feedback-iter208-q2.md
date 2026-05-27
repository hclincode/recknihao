# Iter 208 Q2 — Judge Feedback

## Question recap

Cross-catalog consistency: Iceberg snapshot isolation vs Postgres MVCC. If a long-running federated query joins an Iceberg events table with a live Postgres dimension table, can mid-query Postgres writes (plan tier updates, inserts, deletes) cause inconsistent customer-facing analytics?

## Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All key claims verified against trino.io and iceberg.apache.org docs. Cross-catalog isolation is correctly described as "not provided." Iceberg snapshot isolation per-query is correct. Postgres READ COMMITTED default is correct. Three risk scenarios (mid-query update visible, phantom inserts, vanished deletes) all align with how JDBC-based federation actually behaves. |
| Beginner clarity | 5 | Concrete time-of-day examples (2:00 PM scan, 2:03 PM update) make the consistency window tangible. Defines READ COMMITTED in two bullets a non-DBA can follow. Side-by-side SQL contrast (cross-catalog vs intra-Iceberg) is exactly the visual a SaaS engineer needs. Final summary table is a strong takeaway artifact. |
| Practical applicability | 5 | Engineer leaves with a concrete prescription: materialize the Postgres dimension into Iceberg on a 5–15 min cadence and re-write the join as Iceberg-to-Iceberg. The "canned reporting" pattern is a real production fix for customer-facing analytics. The "What NOT to do" list closes off common foot-guns. |
| Completeness | 4.75 | Covers all three risks the engineer named, plus the silent-deletion case the engineer didn't name explicitly. Minor gap: does not mention `FOR SYSTEM_TIME AS OF <timestamp>` (Iceberg time-travel) as an alternative way to align the Iceberg side to a chosen wall-clock instant if the Postgres side has its own audit/AS OF SYSTEM TIME mechanism. Also does not explicitly call out that Trino captures the Iceberg snapshot at *plan* time (effectively query start, but worth naming for engineers debugging long-tail queries). |
| **Average** | **4.9375 → 4.94** | |

**PASS / FAIL**: **PASS** (≥ 4.5 raised threshold for Trino federation topic; well above general 3.5 threshold).

---

## What was correct and verified

1. **"Trino does not provide cross-catalog transaction isolation."** — Verified against trino.io docs. The PostgreSQL connector documentation explicitly limits its transactional guarantees and provides no mechanism for cross-catalog snapshot coordination. Each catalog is read independently using that catalog's native isolation model.

2. **Iceberg snapshot isolation at query start.** — Verified against iceberg.apache.org docs and Iceberg architecture references. "Each snapshot represents an immutable, consistent view of the table at a specific point in time. Readers load a specific snapshot and operate on it for the duration of their query." The answer's phrasing ("captures a snapshot ID at start time, and every row it reads comes from that immutable snapshot") is technically precise.

3. **Postgres READ COMMITTED default.** — Verified against postgresql.org docs ("Read Committed is the default isolation level in PostgreSQL"). The Trino JDBC PostgreSQL connector does not override this, so reads against the read replica inherit READ COMMITTED semantics.

4. **The three concrete risks all align with reality**:
   - Mid-query updates *are* visible to the Postgres-side scan because READ COMMITTED reads each statement against the latest committed snapshot at statement start.
   - Phantom inserts *can* appear because the Postgres scan executes at JDBC fetch time, not at the Iceberg snapshot time.
   - Deleted rows *can* disappear for the same reason.

5. **Mitigation strategies are sound engineering advice**:
   - **Materialize Postgres dimensions into Iceberg** is the canonical fix for this class of problem at on-prem lakehouse shops; it converts a federated join into a consistent intra-Iceberg join. Fully appropriate for the production stack (Spark + Iceberg + Hive Metastore + Trino 467 on k8s).
   - **Lag buffer in watermark** (2–3× P99 replica lag) is standard incremental-ingestion practice and matches what production Spark+Iceberg ingestion jobs typically configure.
   - **Canned reporting / nightly materialized join** is the textbook pattern for customer-facing analytics where consistency must be auditable.

6. **"Why Trino can't fix this"** paragraph is technically accurate — there is no protocol Trino could speak to Postgres to coordinate snapshot IDs across the two storage engines.

---

## What was missing or wrong

### Minor technical imprecisions
- The phrasing "PostgreSQL connector uses READ COMMITTED isolation by default" attributes the isolation level to the connector. More precisely, Postgres itself defaults to READ COMMITTED, and the Trino connector does not override it — so the *effect* is correct but the *mechanism* is server-side, not connector-set. Not score-blocking; an engineer who wanted to change it via JDBC would not find a Trino-side knob.
- The answer says the Iceberg snapshot is captured "at query start." This is shorthand for "at query planning time." For very long-tail queries with heavy planning (e.g., metadata-heavy `SHOW STATS` warm-up), planning and execution can differ by seconds — usually irrelevant, but worth a note for debugging mysterious skew.

### Missing nuances
- **No mention of `FOR SYSTEM_TIME AS OF <timestamp>` on the Iceberg side.** An advanced pattern: pin the Iceberg snapshot to a specific timestamp matching a known-good Postgres state (e.g., an end-of-day backup time). Trino supports this. Worth listing as a fifth mitigation strategy.
- **No mention of consistent-time read replicas.** Some Postgres replica setups support `pg_export_snapshot()` + `SET TRANSACTION SNAPSHOT` to pin a JDBC connection to a known snapshot. Custom session properties on the Trino Postgres catalog could in theory inject this — niche but worth mentioning as a "what about" answer.
- **No mention of Trino's `iceberg.dynamic-filtering.wait-timeout`** behavior, which affects whether the Iceberg scan waits for the Postgres-side dynamic filter to arrive. This interacts with timing/visibility in ways an engineer chasing consistency anomalies should know about. Borderline relevant; could be deferred to a separate dynamic-filtering question.

### Production-fit notes
- The answer correctly recommends ingesting Postgres dims into Iceberg via Spark on a 5–15 min cadence — this is exactly the stack described in `prod_info.md` (Spark + Iceberg 1.5.2 + Hive Metastore for ingestion). Good fit.
- The "canned reporting" suggestion is appropriate for a SaaS team serving customer-facing analytics.

---

## Specific resource fixes needed

1. **`resources/22-trino-federation-postgresql.md`** — add a "Cross-catalog consistency semantics" section covering:
   - Iceberg snapshot isolation captured at plan time; immutable for the query duration.
   - Postgres JDBC scan executes at fetch time under READ COMMITTED; no connector-side override.
   - No coordination protocol between catalogs.
   - Worked example with timestamps showing the inconsistency window.

2. **Add `FOR SYSTEM_TIME AS OF` recipe** in the same resource: how to pin an Iceberg query to a known timestamp, and when this helps align with a Postgres backup/snapshot time.

3. **Cross-link to the Iceberg dimension-materialization pattern** already covered in resources on Postgres-to-Iceberg ingestion. Reinforce that this is the *primary* recommended fix for customer-facing analytics; federated joins are for exploratory work.

4. **Optional**: short note on `pg_export_snapshot()` + `SET TRANSACTION SNAPSHOT` as an advanced pattern for pinning a Postgres read to a snapshot, with the caveat that Trino's Postgres connector does not natively support injecting this per-session.

---

## Bottom line

This is one of the strongest federation answers seen in recent iterations. It correctly identifies a subtle but production-critical consistency gap that most engineers do not realize exists, gives a concrete and stack-appropriate fix (materialize to Iceberg dimension table), and provides an honest trade-off table at the end. The only reason it does not score a perfect 5.0 is the missing `FOR SYSTEM_TIME AS OF` alternative and a small mechanism-vs-effect imprecision on where READ COMMITTED comes from.

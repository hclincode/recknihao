# Iter 161 Q2 — Judge Report

## Question
"We had a dashboard query that joined our Iceberg events table (in MinIO) against a small reference table that was still sitting in PostgreSQL, and it was taking 20 minutes. Someone suggested we just copy that Postgres table into Iceberg and re-run the query — we did, and now it runs in 30 seconds. That's great, but now I'm wondering if the lesson here is just 'always move everything into Iceberg' whenever you need to join it with your main data. Is that actually the right rule, or are there cases where you'd deliberately leave a table in Postgres and query it from there? We have a few tables in Postgres that change constantly — like a settings table that applications write to every few seconds — and I'm not sure copying those makes sense."

## Topic touched
- Trino federation / cross-source connectors (PostgreSQL connector, predicate pushdown, cross-catalog join limits, when to federate vs ingest) — pass threshold 4.5

---

## Verification of key technical claims (via WebSearch + docs)

1. **"Cross-catalog joins run on Trino workers (not pushed to Postgres)"** — CORRECT. Trino's PostgreSQL connector supports join pushdown only for joins between two tables in the same PostgreSQL catalog (and only when cost-based join pushdown finds it beneficial). Cross-catalog joins (Postgres ↔ Iceberg) cannot be pushed to either source; they are executed on Trino workers after reading from each connector. Confirmed in trino.io PostgreSQL connector docs.

2. **"Dynamic filtering is exactly what small dimension × large fact joins are optimized for"** — CORRECT and well-stated. Trino dynamic filtering builds runtime filter from the small build side (here the Postgres dimension) and pushes it into the Iceberg probe-side scan, enabling file/partition pruning. This is the canonical broadcast-join + DF pattern documented at trino.io/docs/current/admin/dynamic-filtering.html. Note: the answer correctly says "Trino derives the join keys from the small Postgres side and pushes that filter into the Iceberg scan" — accurate.

3. **Hybrid UNION ALL pattern (Iceberg history + Postgres live tail)** — CORRECT and a recognized practice. This is the standard "lambda-style" or "live + batch union view" pattern used with Trino federation. Trino docs note that multiple catalogs can be queried in one statement; UNION ALL across connectors is a legitimate pattern for combining historical lakehouse data with live OLTP tail.

4. **Freshness-latency argument for keeping settings in Postgres** — CORRECT. Any ingestion path (Spark batch, CDC into Iceberg) introduces minutes-to-hours of lag. The claim "even the fastest batch ingestion is minutes at best, usually hours" is slightly pessimistic — CDC into Iceberg can achieve sub-minute lag with streaming writes — but the directional point (Postgres has zero ingestion lag and is the source of truth) is correct and important.

5. **"When to ingest" criteria (frequent queries, historical aggregation, load isolation)** — CORRECT. These three are the canonical decision factors. The load-isolation point (analytical queries can exhaust Postgres connection pool / replica CPU) is exactly right for an on-prem setup.

### Minor accuracy nits
- The phrasing "the federation connector wasn't optimized for that case" is loose. More precise: cross-catalog joins materialize both sides on Trino workers, and without dynamic filtering or good selectivity the large Iceberg side scans many rows redundantly. The 20-min → 30-sec speedup from ingesting the dim table to Iceberg is more accurately explained by: (a) both sides now live in the same catalog so file-level pruning and broadcast join work optimally, and (b) Iceberg's columnar scan is much faster than JDBC row fetch over the network.
- "even the fastest batch ingestion is minutes at best, usually hours" understates streaming/CDC capabilities; could mislead the engineer into thinking real-time ingestion is impossible.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Core mechanics (DF, cross-catalog execution, hybrid UNION ALL, ingestion lag) all correct. Minor imprecision on "federation connector wasn't optimized" and ingestion-latency overstatement. |
| Beginner clarity | 5 | Excellent structure: opens with a direct answer, frames a clear decision tree (federate vs ingest vs hybrid), uses the engineer's own example (settings table) throughout. No unexplained jargon. |
| Practical applicability | 5 | The engineer can act on this immediately: keep settings in Postgres, federate via Trino, consider hybrid for fast-changing high-query tables. Tied to the production stack (Iceberg+MinIO+Trino) accurately. |
| Completeness | 5 | Addresses all three sub-questions: (a) is "always Iceberg" the rule (no, with reason); (b) when to leave in Postgres (freshness, low query frequency); (c) the settings table specifically (leave it in Postgres, optionally hybrid). Adds the bonus "real lesson" framing. |

**Weighted average** = (4.5×2 + 5 + 5 + 5) / 5 = (9.0 + 15) / 5 = **4.80**

## Pass/Fail
**PASS** (4.80 ≥ 4.5 elevated threshold for this topic).

## Verdict on topic status
- Before iter161-q2: Trino federation topic had avg 4.100 across 2 questions, status NEEDS WORK.
- Updated: avg = (4.100 × 2 + 4.80) / 3 = 13.0 / 3 = **4.333**, questions=3.
- Still NEEDS WORK (4.333 < 4.5 elevated threshold). Strong improvement but one more passing answer needed to clear the bar.

## Recommendations for teacher
1. Tighten resource language around cross-catalog join execution: state explicitly that join pushdown is only intra-catalog (Postgres↔Postgres), not cross-catalog, and that DF is the main optimization across catalogs.
2. Add nuance on ingestion latency tiers (CDC streaming = seconds-to-minutes; batch = minutes-to-hours) so future answers don't overstate the latency floor.
3. The hybrid UNION ALL view pattern is now well-articulated — keep this example in resources.

# Iter 330 — Q2 Score (Multi-tenant: HMS startup-latency tuning)

**Question**: "We're running analytics for about 80 different customer tenants through Trino and I've noticed that some queries take 5-10 seconds before any actual data gets read… Someone said it might be 'HMS' and that we need to tune it. What is HMS and what settings/configuration knobs should I be looking at when queries are slow to even start?"

**Topic**: Multi-tenant analytics: isolating customer data in SaaS (HMS startup-latency angle)
**Current rubric avg before this score**: 4.478 across 125 questions

## Score table

| Dimension | Score | Reasoning |
|---|---:|---|
| Technical accuracy | 4.5 | Core facts verified correct (per-query HMS contact, no Iceberg connector caching, port 9083, stateless HMS, system.runtime.queries columns). One minor caveat: HMS HA is technically not strictly "active-active" in some vendor docs (HPE), but the Apache/Starburst pattern of N stateless pods behind a k8s service is the de facto on-prem HA model, which is exactly what the answer recommends. No fabricated config props this round. |
| Beginner clarity | 4.5 | "Directory listing" mental model and the 4-step query sequence are excellent. Jargon (Thrift, RPC, GC, SPOF) is introduced but mostly defined in context. SPOF expansion ("single point of failure") is missing — minor gap for true beginners. |
| Practical applicability | 4.5 | Priority-ordered fix list, kubectl commands, pg_stat_activity query, and the system.runtime.queries triage SQL all give the engineer immediate next actions. Fits the on-prem k8s + MinIO + HMS stack exactly. |
| Completeness | 4.5 | Covers: (1) what HMS is, (2) why it's on the critical path, (3) how to diagnose with kubectl + Trino system tables, (4) Postgres backend tuning, (5) HA pattern, (6) REST catalog as long-term escape. Could have mentioned JVM heap tuning specifics (e.g., concrete -Xmx number) and `hive.metastore.uri` comma-separated config as a concrete failover knob, but those are minor. |
| **Average** | **4.5** | **PASS** |

## What worked

- **Mental model is sharp**: "HMS is the directory; MinIO is the building" maps onto the rest of the answer cleanly. The 4-step query sequence (HMS → metadata.json in MinIO → manifests → data files) gives the engineer a way to reason about *why* the delay shows up at startup specifically.
- **Critical-path framing is correct**: "every single new query you run must contact HMS first" matches the Trino Iceberg connector's actual no-caching behavior (verified against trinodb/trino#13115 and Trino 481 docs).
- **Diagnosis is actionable**: the `system.runtime.queries` SQL with the four phase-time columns lets the engineer confirm HMS is the culprit (high `analysis_time_ms` / `planning_time_ms`) vs. queueing (`queued_time_ms`) vs. data scan time (`execution_time_ms`).
- **Postgres-as-real-bottleneck callout** is correct and important — most HMS slowness in practice is the backing RDBMS, not HMS itself.
- **HA recipe is correct for on-prem k8s**: 3 stateless HMS pods + HA Postgres backend. Matches resource 21 and matches the Starburst/Apache reference patterns.
- **No fabricated config props**: prior iterations have been burned by invented properties; this answer stays close to verified facts and defers detail (e.g., "consider a REST catalog") rather than inventing knobs.

## What missed (gaps / minor issues)

- **SPOF acronym not expanded** on first use ("HMS is a SPOF — Is it HA?"). A true beginner without OLAP/k8s background may not know "SPOF" = single point of failure. Minor clarity ding.
- **No mention of `hive.metastore.uri` comma-separated form** as a Trino-side failover knob. The resource (21-hive-metastore-iceberg.md, line 196) covers this and it's a concrete config the engineer could apply today; the answer skips it.
- **No concrete JVM heap size suggested** ("Default is often too small for 80 tenants worth of tables" — but a number like "start at -Xmx4g for 80 tenants and tune up" would be more actionable).
- **Iceberg-vs-Hive caching nuance is implicit, not explicit**. The answer says "The Iceberg connector does NOT cache this result" but doesn't explain that this is intentionally different from the Hive connector (which DOES cache via `hive.metastore-cache-ttl`). Without this contrast, a reader who has seen `hive.metastore-cache-ttl` documented somewhere might try to apply it to their Iceberg catalog and be confused when it doesn't help. Resource 21 covers this explicitly (line 79); the answer could have lifted one sentence.
- **No mention of HMS schema/table-count scaling**: with 80 tenants and possibly hundreds of tables per tenant, the HMS `TBLS` and `SDS` tables can grow large enough that the Postgres lookup itself slows down without proper indexes. Resource 05 (line 36) notes "Hive Metastore performance can degrade with thousands of tables" — worth a one-liner.

## Technical accuracy verification

I verified each load-bearing technical claim:

1. **"Every new query hits HMS — no Iceberg connector caching"** — CONFIRMED. Trino issue [#13115](https://github.com/trinodb/trino/issues/13115) explicitly tracks the lack of HMS caching in the Iceberg connector. The Hive connector has `hive.metastore-cache-ttl`; the Iceberg connector deliberately does not, to preserve snapshot correctness across concurrent writers.
2. **Port 9083 is the default Thrift port** — CONFIRMED. Apache Hive docs and Starburst HMS-on-k8s docs both list 9083 as the default Thrift port.
3. **`system.runtime.queries` columns** — CONFIRMED. `queued_time_ms`, `analysis_time_ms`, `planning_time_ms`, `execution_time_ms` are all valid bigint columns on `system.runtime.queries` (Trino 467 / current). Note: `analysis_time_ms` historically was a misnomer that actually showed planning time; `planning_time_ms` was added separately. The answer uses both correctly as proxy timing signals.
4. **HMS is stateless; multiple instances for HA** — CONFIRMED. Apache Hive docs: "The Hive metastore is stateless and thus there can be multiple instances to achieve High Availability." Caveat: HPE's docs call this "active-standby" rather than "active-active" because each Trino connection talks to one HMS at a time, but the k8s Service load-balances Thrift connections across all healthy pods, which is the operational shape the answer describes. The answer's "3 HMS pods behind a Kubernetes Service" recommendation is correct for the on-prem k8s + Apache HMS pattern.
5. **HMS does Postgres lookups; stateless service** — CONFIRMED. Resource 21 and the Apache Hive admin guide both describe HMS as a stateless service whose state lives entirely in the backing RDBMS.

No technical errors found that warrant a deduction below 4.5 on accuracy.

## Production environment fit

The answer fits the prod_info.md stack exactly:
- On-prem k8s — kubectl commands and k8s Service pattern apply directly.
- Trino 467 + Iceberg 1.5.2 + HMS + MinIO — all named.
- Postgres backing HMS — assumed correctly (this is the standard).
- REST catalog mentioned as long-term option, correctly flagged as a migration project rather than a quick fix.
- No public cloud assumptions leaked in (no AWS Glue, no managed RDS suggestion).

## Rubric topic update

Multi-tenant analytics: 4.478 / 125 → **(4.478×125 + 4.5) / 126 = 4.4783 / 126** (PASSED — stable; minor upward tick).

## Verdict

**PASS** at 4.5 average. The answer is correct, fits the on-prem stack, and gives the engineer a clear diagnostic path. No fabricated config properties this round. Minor improvements available: expand "SPOF" on first use, mention `hive.metastore.uri` comma-separated failover form, contrast Iceberg-vs-Hive connector caching explicitly, and add concrete JVM heap/HMS table-count scaling notes.

## Sources consulted

- [Iceberg connector — Trino 481 Documentation](https://trino.io/docs/current/connector/iceberg.html)
- [Metastores — Trino 481 Documentation](https://trino.io/docs/current/object-storage/metastores.html)
- [Hive connector — Trino 481 Documentation](https://trino.io/docs/current/connector/hive.html)
- [Apache Hive: AdminManual Metastore Administration](https://hive.apache.org/docs/latest/admin/adminmanual-metastore-administration/)
- [Configuring the Hive Metastore Service in Kubernetes — Starburst Enterprise](https://docs.starburst.io/latest/k8s/hms-configuration.html)
- [trinodb/trino#13115 — Hive Metastore Cache for Iceberg metadata](https://github.com/trinodb/trino/issues/13115)
- [Query management properties — Trino 481 Documentation](https://trino.io/docs/current/admin/properties-query-management.html)
- [System connector — Trino 480 Documentation](https://trino.io/docs/current/connector/system.html)

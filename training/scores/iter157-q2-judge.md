# Iter 157 Q2 — Judge Report: Hive Metastore Role and SPOF

## Question recap
The SaaS engineer asked three concrete things:
1. What does Hive Metastore actually do for a Trino+Iceberg+MinIO stack on-prem?
2. Does Trino read the Metastore on every query? If it goes down, do all queries stop?
3. How much of a SPOF is it, and what HA options exist on Kubernetes?

---

## Scores

| Dimension | Score | Rationale |
|---|---|---|
| Technical accuracy | 3 | The accurate parts (Metastore as catalog/pointer, HA via replicas+HA DB+load balancer) are correct. The major problem is the answer's repeated admission that "the resources don't document this." Those are answerable facts — see verified findings below — and the answer should have stated them. Saying "I don't know" when a definite answer exists costs accuracy. |
| Beginner clarity | 4 | Well-structured, uses plain language ("where the tables live"), explains the metadata-vs-data distinction. No unexplained jargon. |
| Practical applicability | 4 | The "test it directly" advice is genuinely useful and exactly what a good on-prem SRE would do. The HA recommendations (replicas + LB + HA database) are correct. But missing the actual answer to "yes, every query hits HMS" means the engineer can't plan capacity or set realistic timeout expectations. |
| Completeness | 2 | Two out of three sub-questions were essentially deflected ("resources don't document this"). The SPOF question got partial coverage. The per-query lookup question got no answer. |

**Weighted average = (3×2 + 4 + 4 + 2) / 5 = 16/5 = 3.20**

**Verdict: FAIL** (threshold 4.5)

---

## What was verified correct (via WebSearch)

1. **Metastore as "catalog service that tracks where tables live"** — CORRECT. Per multiple Trino docs and Starburst architecture posts, for Iceberg tables HMS stores the *pointer* to the current root metadata file. ([Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html), [Starburst Iceberg in Trino](https://www.starburst.io/blog/introduction-to-apache-iceberg-in-trino/))

2. **HA strategy: multiple replicas + load balancer + HA-backed RDBMS** — CORRECT in principle. Confirmed by Cloudera HMS HA docs and Stackable operator notes that true HA requires an external HA database plus client-side failover via `hive.metastore.uris` (active/active). ([Cloudera HMS HA](https://docs.cloudera.com/cdp-private-cloud-upgrade/latest/upgrade-cdh/topics/hive-hms-ha-configuration.html), [Stackable Hive operator](https://github.com/stackabletech/hive-operator/issues/154))

3. **"Test the failure directly" advice** — operationally sound and is exactly what a Kubernetes platform team should do.

---

## What the answer SHOULD have said (and didn't)

### A. Per-query HMS access — definitive answer
For Iceberg tables on Trino, **yes, Trino contacts the Hive Metastore on essentially every query** that touches an Iceberg table. The sequence is:

1. Trino asks HMS: "Where is the current metadata pointer for table X?" (one small RPC)
2. HMS returns the path to the current `metadata.json` file in MinIO
3. Trino reads that `metadata.json` from MinIO (not from HMS)
4. Trino walks manifest lists and manifests in MinIO to plan the scan
5. Trino reads only the needed Parquet data files from MinIO

Critically: **Hive Metastore caching is DISABLED in the Trino Iceberg connector** (see [trinodb/trino#13115](https://github.com/trinodb/trino/issues/13115)). So unlike the Hive connector — which caches partition listings — the Iceberg connector hits HMS for every query. The good news: each call is a tiny "give me the pointer" lookup, not the heavy partition-enumeration call the legacy Hive connector makes. The bad news: HMS availability is on the critical path for every new query.

### B. SPOF reality — definitive answer
- **New queries**: If HMS is down, new queries against Iceberg tables fail fast with "Failed connecting to Hive metastore" / connection refused. This is documented in user reports ([trinodb/trino#16789](https://github.com/trinodb/trino/discussions/16789)).
- **In-flight queries**: Once a query has resolved the metadata pointer and started scanning data files from MinIO, it generally completes without further HMS calls — the scan is driven by Iceberg metadata files in MinIO, not HMS. So a brief HMS blip during execution is usually survivable.
- **Net SPOF risk**: HMS being down = no new queries can start. Iceberg reduces HMS load compared to legacy Hive (one pointer lookup vs partition enumeration), but does **not** eliminate the dependency.

### C. Iceberg REST catalog as a structural mitigation
Trino also supports `iceberg.catalog.type=rest`, `nessie`, `jdbc`, or `glue` — alternatives that don't require HMS at all. For an on-prem k8s deployment that wants to reduce HMS dependence long-term, an Iceberg REST catalog (e.g., Polaris, Lakekeeper, Gravitino, or Nessie) is the architectural answer. The answer didn't mention this, which is a real omission given the engineer asked "is there anything we can do about it."

### D. HA on Kubernetes — sharpening the answer
The answer says "replicas + load balancer + HA database." Correct directionally, but needs caveats:
- Stateless HMS pods + `replicas: N` only gives true HA if the *backing database* (Postgres/MySQL) is itself HA — otherwise the database becomes the SPOF.
- Clients can list multiple HMS URIs via `hive.metastore.uri` (comma-separated) and Trino will failover; a k8s `Service` already load-balances, so an explicit external LB is often unnecessary.
- The Stackable operator docs warn that `replicas > 1` alone may not give true HA if service discovery and DB failover aren't set up.

---

## Errors and gaps

| Severity | Issue |
|---|---|
| HIGH | Answer admits ignorance on the central technical question (per-query HMS access) when a definitive answer exists in Trino docs and GitHub issues. |
| HIGH | No mention of the Iceberg REST catalog / Nessie / JDBC catalog alternatives — the most relevant structural fix to the SPOF concern. |
| MEDIUM | No mention that HMS caching is explicitly disabled in the Iceberg connector (a key operational fact). |
| MEDIUM | Doesn't distinguish in-flight vs new-query behavior during an HMS outage — engineer specifically asked this. |
| LOW | HA advice doesn't flag that the backing RDBMS is the real SPOF, not the HMS pods. |

---

## Resource fix recommendations

- **HIGH**: Add a resource (or extend an existing Iceberg/Trino architecture resource) on "Hive Metastore role in the Iceberg+Trino stack" covering:
  - HMS stores only the current metadata pointer for Iceberg (not partitions, not file lists)
  - HMS is contacted per query; Iceberg connector does NOT cache HMS results
  - New-query vs in-flight-query failure modes when HMS is down
  - HA pattern: stateless HMS pods + HA Postgres + multi-URI client config
  - Alternative catalogs (REST/Nessie/JDBC) as a SPOF mitigation
- **MEDIUM**: Document the `hive.metastore.uri` multi-URI failover pattern and what Trino does on connection failure (timeout, retry counts).
- **LOW**: Add a one-paragraph "what's in HMS vs what's in MinIO for an Iceberg table" diagram-style explanation — this is exactly the mental model gap the engineer described.

---

## Sources
- [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html)
- [Trino Metastores docs](https://trino.io/docs/current/object-storage/metastores.html)
- [trinodb/trino issue #13115 — HMS cache for Iceberg metadata](https://github.com/trinodb/trino/issues/13115)
- [Starburst — Introduction to Apache Iceberg in Trino](https://www.starburst.io/blog/introduction-to-apache-iceberg-in-trino/)
- [trinodb/trino discussion #16789 — Failed connecting to Hive metastore](https://github.com/trinodb/trino/discussions/16789)
- [Cloudera — Configuring HMS for high availability](https://docs.cloudera.com/cdp-private-cloud-upgrade/latest/upgrade-cdh/topics/hive-hms-ha-configuration.html)
- [Stackable Hive operator HA discussion (issue #154)](https://github.com/stackabletech/hive-operator/issues/154)
- [Starburst — Configuring HMS in Kubernetes](https://docs.starburst.io/latest/k8s/hms-configuration.html)

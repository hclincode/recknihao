# Judge Report — Iter 158, Q1

## Question summary
SaaS engineer asks (1) is the Trino PostgreSQL connector real, (2) can you write a single SQL JOIN across Postgres + Iceberg, (3) what is the catch — does Trino pull all Postgres data over the network, and (4) how slow is this on a few-million-row table?

## Answer being judged
`/Users/hclin/github/recknihao/training/answers/iter158-q1.md`

## Verification against trino.io docs

WebSearch confirmed against `trino.io/docs/current/connector/postgresql.html` and `trino.io/docs/current/optimizer/pushdown.html`:

1. **PostgreSQL connector exists** — YES. Configured via a catalog file, e.g. `etc/catalog/postgresql.properties` with `connector.name=postgresql` and a JDBC URL. The answer's "yes, it's real" is correct.
2. **Single SQL JOIN across catalogs** — YES. `SELECT ... FROM iceberg.analytics.events e JOIN postgresql.public.users u ON ...` is supported in one statement.
3. **Predicate pushdown** — Trino's PostgreSQL connector **does** push down predicates by default for most types (numeric, UUID, temporal, DATE; with some exceptions like range predicates on character strings unless `postgresql.experimental.enable-string-pushdown-with-collate` is enabled). This matters because a `WHERE tenant_id = 7 AND created_at > '2026-05-01'` will be executed inside Postgres — Trino does NOT blindly pull the whole table.
4. **Join pushdown** — Trino supports join pushdown, BUT one of the generic conditions is **"the tables in the join must be from the same catalog."** A `postgresql.* JOIN iceberg.*` cross-catalog join therefore CANNOT be pushed to Postgres. Trino must read data from each catalog into its workers and perform the join in-cluster. This is the actual "catch" the engineer is asking about.
5. **Cross-catalog data movement** — confirmed (trinodb/trino issue #10855 — "How to avoid unnecessary cross-catalog join"). When join-pushdown is not possible, Trino performs the join inside its own workers; how much data crosses the network depends on (a) what predicates from the query *can* be pushed to each side and (b) how selective those predicates are.

## Scoring

### Technical accuracy: 2 / 5
The answer is directionally correct on the high-level "yes it's real" but commits two significant technical errors and omits a critical concept:

- **Wrong** — claim that "Trino needs to ... get the full result set back over the network." This is misleading. The Trino PostgreSQL connector DOES push down predicates by default. A query like `... JOIN postgresql.public.users u ON u.id = e.user_id WHERE u.tenant_id = 7 AND u.created_at > '2026-05-01'` will translate `tenant_id = 7 AND created_at > '2026-05-01'` into a Postgres SQL query that Postgres executes server-side and returns only the matching rows. The "few million rows" question hinges entirely on this distinction, and the answer gets it wrong.
- **Missing** — the actual real catch: **join pushdown does NOT work across catalogs** (trino.io confirms: "the tables in the join must be from the same catalog"). The JOIN itself happens inside Trino workers, not inside Postgres. This is the most important technical fact for the question and it is absent.
- **Missing** — no mention of **dynamic filtering**, which is the Trino optimization most relevant to making cross-catalog joins survivable: at runtime Trino derives a filter from the Iceberg side's key set and pushes that filter to the Postgres scan. This is the actual answer to "how slow on a few-million-row table" — with dynamic filtering plus selective predicates, the Postgres scan often returns thousands of rows, not millions.
- **Imprecise** — "join it in Trino's memory" — joins in Trino are distributed across workers and can spill to disk; they are not just an in-memory hash join in the coordinator. Minor but indicates the answer is reasoning by analogy, not from the docs.

### Beginner clarity: 4 / 5
Plain English, no unexplained jargon, numbered the three steps, sensible bottom-line framing. The engineer can follow the argument. Docked one point because "OLTP source," "OLAP system," and "CDC" appear without inline glosses, and a beginner asking "is this real?" benefits from at least the words "predicate pushdown" with a one-line definition — instead the answer hides that whole concept.

### Practical applicability: 2 / 5
The recommendation ("don't query Postgres directly via Trino; ingest to Iceberg") is *a* defensible default, but the answer presents it as the only answer when the engineer's actual question — "we want one SQL query that combines real-time Postgres with historical Iceberg" — is a textbook valid use case for the PostgreSQL connector when (a) the Postgres-side query is selective (filtered by indexed columns) and (b) freshness requirements exceed what hourly ingestion can give. The engineer leaves not knowing:

- How to actually configure the PostgreSQL connector catalog file in their Trino 467 k8s deployment (`etc/catalog/postgresql.properties` with `connector.name=postgresql`, JDBC URL, credentials — ideally via k8s secret).
- Which connection pool settings matter at scale.
- How to read `EXPLAIN (TYPE DISTRIBUTED)` to verify predicate pushdown.
- That cross-catalog JOINs work but cross-catalog JOIN pushdown does not, so the JOIN side that returns fewer rows should drive the query.
- That hitting the production Postgres primary from Trino under analytical load is the real operational risk — point Trino at a read replica or a dedicated reporting replica, not the OLTP primary.
- That the "ingest to Iceberg" recommendation is the right long-term answer for the historical bulk — but federation is the right answer for the live join, and a **hybrid pattern** (cached historical in Iceberg + live federated Postgres lookups for the most recent partition) is what production SaaS teams actually run.

The answer also leans on "the resources I have don't deeply cover Trino's Postgres connector performance characteristics" — that hedging is itself a signal of a resource gap, not a substitute for the answer.

### Completeness: 2 / 5
The question has four explicit parts. Scoring each:
- "Is it actually a real thing?" — addressed (yes).
- "What's the catch?" — partially addressed; identifies network movement but gives the wrong mechanism and misses the real catch (no cross-catalog join pushdown; OLTP impact on the source DB; per-query connection overhead; type-mapping quirks).
- "Does Trino pull all the Postgres data over the network every time?" — answered incorrectly as "yes, the full result set." Correct answer: it pulls the rows that survive predicate pushdown (which is on by default for most predicates), and for cross-catalog joins specifically the JOIN itself runs in Trino because join pushdown doesn't cross catalogs.
- "How slow on a table with a few million rows?" — not quantified at all. The honest range — "if your WHERE clause pushes down and hits indexed columns in Postgres, sub-second to a few seconds for thousands of returned rows; if the query forces a full scan because predicates can't push down, tens of seconds to minutes" — is missing.

## Weighted average

(Technical 2 × 2 + Clarity 4 + Practical 2 + Completeness 2) / 5 = (4 + 4 + 2 + 2) / 5 = **2.4 / 5**

Below the 3.5 pass threshold.

## What needs to happen for this topic to pass

This question exposes a **missing required topic** in `training/rubric.md`. There is no row for "Trino federation / cross-source connectors (PostgreSQL, MySQL, etc.) — when to use, pushdown behavior, cross-catalog join limits." This topic should be added to the rubric, and a dedicated resource should be authored, ideally `resources/22-trino-federation-postgresql.md`, covering:

1. The PostgreSQL connector — what it is, the `etc/catalog/postgresql.properties` shape, k8s secret pattern for credentials, pointing at a read replica not the OLTP primary.
2. Predicate pushdown — what pushes down by default (numeric, UUID, temporal, DATE), what doesn't (range on strings unless `postgresql.experimental.enable-string-pushdown-with-collate`), how to verify with `EXPLAIN (TYPE DISTRIBUTED)` and look for `Layout` / `dynamicFilters` / which predicates appear in the Postgres-side `RemoteSource`.
3. Join pushdown — only within the same catalog; cross-catalog joins always materialize on Trino workers. Practical implication: the smaller / more-selectable side should drive the join.
4. Dynamic filtering — the Trino optimization that makes cross-catalog joins survivable; how it works and when it kicks in (build-side hash joins, broadcast joins).
5. When to federate vs when to ingest — the decision matrix. Federation wins for: small dimension joins, live-data sanity checks, ad-hoc one-off queries, freshness > ingestion-latency requirements. Ingest-to-Iceberg wins for: repeated dashboard queries, large historical aggregations, isolation from OLTP load, full columnar speedup.
6. The hybrid pattern — cached historical in Iceberg + live federated Postgres for the most recent partition, UNION ALL in a view. The pattern the answer skipped entirely.
7. Operational guardrails — connection pool sizing on the Trino side, Postgres `statement_timeout` enforcement, monitoring Trino-driven query load on the OLTP DB.

## Recommendation

Mark this topic as **failing** (avg 2.4). Add the topic to the required checklist. Teacher should author `resources/22-trino-federation-postgresql.md` before this question is retried. Re-test from at least two angles (e.g., the original "is it real / what's the catch" angle, plus "I'm getting timeouts when joining Postgres + Iceberg — how do I debug what's pushing down").

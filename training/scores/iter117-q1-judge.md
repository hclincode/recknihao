# Iter 117 Q1 — Judge Report

**Topic**: Postgres-to-Iceberg ingestion (Debezium + Postgres declarative partitioning)

**Question summary**: Does Debezium pointed at parent `events` automatically pick up inserts to child partitions, or do you need a connector per child?

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 2 | Central claims about default topic-per-parent and `source.table = 'events'` are **inverted** vs Debezium/Postgres defaults. The PG-publication-includes-children claim is roughly right (PG 13+) but lacks the version caveat. The critical `publish.via.partition.root` setting is never mentioned. |
| Beginner clarity | 4 | Writing is clear, well-structured, and uses concrete SQL/YAML examples. No unexplained OLAP jargon. Clarity is genuinely good — which makes the technical errors more dangerous. |
| Practical applicability | 2 | Answer tells the engineer their setup is correct and offers a diagnostic ("you should see only `source.table = 'events'`") that, if followed, will lead them to incorrectly conclude a working setup is broken and then break it by re-creating the publication. |
| Completeness | 2 | Misses the actual answer to the question: the `publish.via.partition.root` option (Debezium connector property + `publish_via_partition_root` publication option). Also misses the default per-leaf-topic behavior and the `topic.routing` SMT (`ByLogicalTableRouter`) as the standard remedy. |
| **Average** | **2.5** | **FAIL** (below 3.5 pass threshold) |

---

## Verdict

**FAIL.** The answer is confidently wrong on the two specific behaviors the engineer asked about (where the events appear and which topic they go to). Following this answer in production would lead the engineer to "fix" a correctly-configured publication into a broken one, or to conclude that their CDC pipeline is healthy when it is actually publishing under unexpected topic names and unexpected `source.table` values, breaking downstream Iceberg MERGE logic.

---

## What was verified correct (via WebSearch against official docs)

1. **Publication mechanism includes child partitions automatically when the parent is added (PostgreSQL 13+).**
   Per PostgreSQL CREATE PUBLICATION docs: "When a partitioned table is added to a publication, all of its existing and future partitions are implicitly considered to be part of the publication. So, even operations that are performed directly on a partition are also published via publications that its ancestors are part of." This part of the answer is correct.

2. **One Debezium connector is sufficient** (you don't need a connector per child). Correct.

3. **The infrastructure preflight items** (`wal_level = logical`, `rolreplication = true`, `pg_replication_slots.active` check) are all standard and correct.

4. **`snapshot.mode` discussion** — the connector property name and the recommendation to use `no_data` for steady-state CDC is correct (Debezium 2.x renamed the old `never` value to `no_data`, so this is current).

---

## Errors found

### ERROR 1 (HIGH — root of the problem): Default topic routing is per-leaf, not per-parent

**Answer claims** (line 13, line 67):
> "The Kafka topic (`app-db.public.events`) receives all writes regardless of which child partition they landed in."

> The Spark diagnostic subscribes to `"app-db.public.events"` and expects to see events.

**Reality** (Debezium PostgreSQL connector docs, verified via WebSearch):
> "When the Debezium PostgreSQL connector captures changes in a partitioned table, the default behavior is that change event records are routed to a different topic for each partition. To emit records from all partitions to one topic, configure the topic routing SMT."

So by default the engineer will see topics named `app-db.public.events_2025_01`, `app-db.public.events_2025_02`, etc., NOT a single `app-db.public.events` topic. The engineer's confusion in the question ("I can't tell if it's coming from the parent table or the child partitions") is directly explained by this default — but the answer denies the default exists.

### ERROR 2 (HIGH): Default `source.table` is the child, not the parent

**Answer claims** (line 59, line 79):
> "Debezium always reports `source.table = 'events'` (the parent), even for inserts that physically land in `events_2025_05`. This is correct behavior."

> "You should see only `source.table = 'events'` (the parent). If you see child table names like `events_2025_05`, the publication was misconfigured — it was created against the children directly."

**Reality** (PostgreSQL CREATE PUBLICATION docs, verified via WebSearch):
> "When set to `true`, changes are published using the identity and schema of the root partitioned table. When set to `false` (the default), changes are published using the identity and schema of the individual partitions where the changes actually occurred."

`publish_via_partition_root` defaults to **`false`**. With the default publication, `source.table` will be `'events_2025_05'`, not `'events'`. The answer has this exactly inverted.

This is the most damaging error: the answer's diagnostic explicitly tells the engineer that seeing child table names in `source.table` means "the publication was misconfigured" and instructs them to recreate the publication. A user following this advice would tear down their working publication.

### ERROR 3 (HIGH — the actual answer): `publish.via.partition.root` is never mentioned

The Debezium PostgreSQL connector exposes a `publish.via.partition.root` configuration property (boolean, default `false`). When set to `true` AND when Debezium auto-creates the publication, the publication is created with `WITH (publish_via_partition_root = true)`, which:
- Causes all leaf-partition changes to be emitted under the root table's identity
- Means `source.table = 'events'` for all inserts
- Means events flow to a single `app-db.public.events` Kafka topic
- Allows `table.include.list: "public.events"` (parent only) to actually work as the answer claims

Without this option, the answer's recommended configuration (`table.include.list: "public.events"`) will likely fail to capture leaf-level changes that arrive with child-table identity, OR (more commonly with Debezium 2.x default `publication.autocreate.mode = all_tables`) events will arrive under per-child topics that the downstream consumer is not subscribed to.

This is the single most important configuration option for the engineer's question and it is entirely absent.

### ERROR 4 (MEDIUM): `table.include.list` recommendation is incomplete

**Answer claims** (line 117):
> `table.include.list: "public.events"  # CORRECT — Debezium captures all children via the parent`

**Reality**: Without `publish.via.partition.root=true`, change events arrive with leaf-table identity, so a `table.include.list` containing only the parent will either filter out the leaf events (Debezium community discussion: "specifying just the parent table name in the whitelist filtered out change logs from partitioned tables") or require a regex like `public.events(_.*)?` to match parent + all children.

The correct recommendation has two flavors:
- **Flavor A (recommended for this engineer's use case)**: set `publish.via.partition.root=true` on the connector AND `table.include.list: "public.events"`. One topic, one `source.table`, MERGE INTO logic stays simple.
- **Flavor B**: leave default behavior, use `table.include.list: "public.events,public.events_.*"` (regex), and apply the `ByLogicalTableRouter` SMT to consolidate per-child topics into one topic, mapping `source.table` back to the parent name.

### ERROR 5 (MEDIUM): PostgreSQL version caveat missing

The "publication on parent auto-includes all children" behavior is only available **from PostgreSQL 13 onward**. For PostgreSQL 11–12, partitioned tables could not be added to publications and each child had to be added individually. prod_info.md doesn't pin a Postgres version, so noting this requirement is appropriate.

### ERROR 6 (LOW): `wal_level = 'minimal'` cannot be combined with `replica`

The "Problem 1" section says wal_level might "return 'replica' or 'minimal'." Technically correct, but the framing implies these are equivalent — `minimal` actively disables WAL archiving and replication slots in a way `replica` does not. Minor.

### ERROR 7 (LOW): Iceberg MERGE example has a subtle issue

The MERGE statement uses `WHEN MATCHED AND s.op = 'd' THEN DELETE` and `WHEN MATCHED AND s.op IN ('u', 'c', 'r') THEN UPDATE SET *`. With `*` semantics, the schemas of `t` and `s` must align including the Debezium-injected columns. In practice CDC pipelines extract `after` before MERGE — this is a pattern issue that does not directly answer the question but is worth flagging.

---

## Gaps (things a complete answer should have included)

1. **The `publish.via.partition.root` connector property** — the single most important config for this use case.
2. **Default per-leaf topic behavior** — directly explains the engineer's observation.
3. **`ByLogicalTableRouter` SMT** — the standard alternative for consolidating per-child topics into one.
4. **Postgres version requirement** (PG 13+) for parent-table publications.
5. **The interaction with `publication.autocreate.mode`** — Debezium will auto-create a publication if one doesn't exist; the `publish_via_partition_root` option must be set at creation time and is ignored if the publication already exists. This is a real-world gotcha (mentioned in Confluent docs: "The connector applies this configuration only during the initial creation of the publication. The connector ignores the changes made to this setting after the publication has been created.").
6. **Snapshot of partitioned tables**: Debezium snapshots each leaf partition individually unless `publish.via.partition.root=true` is set; this matters for snapshot lock cost on the engineer's table.

---

## Resource fix recommendations

### Priority HIGH — `resources/13-postgres-to-iceberg-ingestion.md`

Add a new subsection within the CDC / Debezium portion of the guide titled something like **"Debezium with Postgres declarative partitioned tables (`PARTITION BY RANGE`)"**. It must cover:

1. **Default behavior** (which is the source of user confusion):
   - One publication on parent includes all children (PG 13+).
   - But by default `source.table` reports the leaf partition name (`events_2025_05`).
   - By default each leaf gets its own Kafka topic (`app-db.public.events_2025_05`).

2. **The `publish.via.partition.root=true` recommendation**:
   - Set this on the Debezium connector config.
   - Causes Debezium to create the publication with `WITH (publish_via_partition_root = true)`.
   - All leaf changes flow to a single topic under the parent's identity.
   - Note the "only applied at publication creation" gotcha — must DROP PUBLICATION first if the publication already exists with the wrong setting.

3. **`table.include.list` rules**:
   - With `publish.via.partition.root=true`: list parent only (`public.events`).
   - Without it: use a regex (`public.events.*`) or list both parent and child partition pattern.

4. **Snapshot behavior with partitioned tables** — note that `snapshot.mode: no_data` is preferred for steady-state, especially when many leaf partitions exist.

5. **PG version requirement**: PG 13+ for parent-in-publication; PG 12 requires per-child entries.

6. **Verification SQL**:
   - `SELECT * FROM pg_publication_tables WHERE pubname = 'debezium_pub';` returns the **parent** row only when `publish_via_partition_root = true`; returns the parent row but with leaf-level event identity in WAL stream when false. Note: `pg_publication_tables` does NOT show whether `publish_via_partition_root` is set — for that check `pg_publication.pubviaroot`:
     ```sql
     SELECT pubname, pubviaroot FROM pg_publication WHERE pubname = 'debezium_pub';
     ```

### Priority HIGH — fix the existing answer's two inverted claims

If `resources/13` already has any text that says "Debezium reports `source.table = 'events'` (parent) by default for partitioned tables" or "events flow to one parent-named topic by default" — that text must be corrected. The defaults are opposite.

### Priority MEDIUM — `resources/13`

Add a decision table:

| Goal | Connector setting | Result |
|---|---|---|
| One topic, parent-named, simple MERGE | `publish.via.partition.root=true` + `table.include.list=public.events` | All leaf inserts emit to `app-db.public.events` with `source.table='events'`. |
| Per-leaf topics (e.g., for parallel consumers per month) | leave default | Topics like `app-db.public.events_2025_05`; `source.table='events_2025_05'`. |
| Per-leaf at WAL but consolidate at Kafka | default + ByLogicalTableRouter SMT | Topics consolidated; `source.table` remapped to parent. |

### Priority LOW — `resources/13`

Add a note explaining the engineer's diagnostic question: when seeing partial data and unsure of source, run `SHOW PUBLICATION debezium_pub;` and check the actual topics via `kafka-topics.sh --list | grep events` — comparing to expected names with/without `publish.via.partition.root` immediately diagnoses which mode is active.

---

## Rubric update

**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

- Prior: 4.468 across 96 questions
- This iteration: 2.5
- New running avg: (4.468 × 96 + 2.5) / 97 = (428.928 + 2.5) / 97 = 431.428 / 97 ≈ **4.448 across 97 questions**
- Status: still PASSED at the topic-level average, but this single-answer score (2.5) is the lowest in many iterations and reflects a real regression on a specific Debezium nuance.

---

## Sources (verified via WebSearch)

- [PostgreSQL CREATE PUBLICATION (current)](https://www.postgresql.org/docs/current/sql-createpublication.html) — confirms `publish_via_partition_root` default is `false`; confirms child partitions implicitly included when parent is added.
- [Debezium PostgreSQL Connector documentation (stable)](https://debezium.io/documentation/reference/stable/connectors/postgresql.html) — connector property reference.
- [Confluent Debezium PostgreSQL Source Connector config reference](https://docs.confluent.io/kafka-connectors/debezium-postgres-source/current/postgres_source_connector_config.html) — default per-leaf topic behavior, `publish.via.partition.root` semantics, "applied only at publication creation" gotcha.
- [Debezium community thread: "Configuration for partitioned tables in table whitelist"](https://groups.google.com/g/debezium/c/I4v8_6mNxps) — confirms that listing parent only filters out leaf events; regex required without `publish.via.partition.root`.
- [Debezium community thread: "Debezium not read PostgreSQL multi-level partitions"](https://groups.google.com/g/debezium/c/NroAVr2saxU) — multi-level partition gotchas.
- [Amit Langote: Partition logical replication](https://amitlan.com/2020/05/14/partition-logical-replication.html) — PG 13 first introduced parent-table publication support.

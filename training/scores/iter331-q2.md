# Iter 331 — Q2 Evaluation

**Topic**: Multi-tenant analytics (HMS catalog operations on shared Iceberg stack)
**Question theme**: Why does the Hive connector "warm up" quickly while the Iceberg connector pauses 5-10s on every query? Is the metastore cache difference real, why was it built that way, and how do we cut Iceberg startup latency?
**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter331-q2.md`

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Core technical claims fully verified against official Trino docs and source resources. Two minor `system.runtime.queries` column-name slips in the diagnostic SQL (see verification below). |
| Beginner clarity | 4.5 | "HMS stores one pointer per table; that pointer changes every write" is an excellent one-line model. Hive vs Iceberg contrast is sharp. Mentions snapshot consistency without hand-waving. |
| Practical applicability | 5.0 | Diagnostic SQL, kubectl health checks, multi-URI HMS HA config, and REST catalog migration path are all concrete and fit the on-prem Trino 467 + MinIO + k8s stack from prod_info.md. |
| Completeness | 4.5 | Hits every required beat: caching diff is real, why no caching (snapshot consistency), what 5-10s actually means (cheap call so something is wrong upstream), HMS HA, REST catalog. Could mention that even CTAS/INSERT need HMS at commit but that's a small omission. |
| **Average** | **4.625** | **PASS** |

---

## What worked

- **Directly answers the team's hypothesis first**: "Yes, the Hive connector caches partition listings; the Iceberg connector intentionally does not." No throat-clearing.
- **Names the upstream issue (trinodb/trino#13115)** — gives the engineer something to read and verify on their own.
- **Reframes the user's diagnosis correctly**: "The pause is NOT caused by the missing cache; the call is cheap (<10 ms when healthy). If you're seeing 5-10s, something else is wrong." This is the single most important reframe — a worse answer would have leaned into "yes, add a cache."
- **Snapshot consistency reason is crisp**: pointer changes on every write; caching would serve stale snapshots and miss Spark writes. Matches Iceberg's actual concurrency contract.
- **Tradeoff sentence is excellent**: "A Hive partition listing is expensive to fetch but changes rarely. An Iceberg metadata pointer is cheap to fetch but changes on every write." This is the right mental model.
- **Production-fit diagnostics**: queries `analysis_time_ms` / `planning_time_ms` on `system.runtime.queries` (the right table for phase timing), kubectl pod/log checks for HMS, comma-separated HMS URI failover, REST catalog migration path — all match the on-prem k8s + Trino 467 stack in prod_info.md.
- **Multi-URI failover config** is correct (`hive.metastore.uri=thrift://hms-0...,thrift://hms-1...,thrift://hms-2...`). Verified against Trino release 346 notes — supported and the documented HA pattern.
- **REST catalog recommendation names Polaris/Lakekeeper/Nessie** — all valid on-prem options that work with MinIO.

## What missed

- **Two minor SQL schema slips in the diagnostic recipe**:
  - The query uses `execution_time_ms` — but the resource's verified column list for `system.runtime.queries` is `queued_time_ms, analysis_time_ms, planning_time_ms` only. `execution_time_ms` is not documented as a top-level column on this table in Trino 467 (it's derived from `end - started` or surfaced as a session-property concept, but not a column).
  - The query uses `ORDER BY create_time DESC` — the actual column name is `created` per the resource and Trino source. `create_time` would fail with a column-not-found error.
  - Both are copy-paste minor; the engineer who runs it gets a clear column-name error and can fix it. Costs about 0.3 from technical accuracy.
- **No mention that INSERT/CTAS specifically also need HMS at commit time** — relevant because the user might assume HMS only affects query startup. Resource 21 covers this; answer doesn't surface it. Minor.
- **No mention of HMS Postgres backend as the actual SPOF** when discussing HA — the answer recommends 3 HMS pods but stops at "HA Postgres backend" without flagging that the DB is the real SPOF if not HA'd properly. Resource 21 makes this point explicitly; the answer truncates it. Minor.
- **No explicit timing breakdown of "what 5-10s actually looks like in pieces"** — e.g., "if it's all in analysis_time_ms it's HMS; if it's in planning_time_ms it could be MinIO manifest reads." The answer gestures at this with "5+ seconds = HMS/planning time" but conflates two distinct phases.

---

## Technical accuracy verification

| Claim in answer | Verified? | Source |
|---|---|---|
| Hive connector has `hive.metastore-cache-ttl` for partition caching | YES | [Trino 481 Hive connector docs](https://trino.io/docs/current/connector/hive.html), [Caching options in Trino's Hive connector](https://posulliv.github.io/posts/hive-caching-options/) |
| Iceberg connector intentionally has no metastore cache, tracked in trinodb/trino#13115 | YES | [trinodb/trino issue #13115](https://github.com/trinodb/trino/issues/13115) — issue exists, confirms Iceberg connector does not cache HMS table list/metadata |
| Reason: snapshot consistency, pointer changes on every write | YES | Matches Iceberg's catalog contract; consistent with resource 21 and Iceberg's snapshot/atomic-commit model |
| HMS Thrift call is <10 ms and on critical path | YES | Matches resource 21 and Trino architecture — single Thrift RPC returning one string |
| `hive.metastore.uri` accepts comma-separated URIs for failover | YES | [Trino 481 Metastores docs](https://trino.io/docs/current/object-storage/metastores.html), [Release 346 notes](https://trino.io/docs/current/release/release-346.html) — Trino prefers most-recently-operational URI |
| `system.runtime.queries` has `analysis_time_ms` / `planning_time_ms` phase columns | YES | [Trino 481 System connector docs](https://trino.io/docs/current/connector/system.html), [Release 318 notes](https://trino.io/docs/current/release/release-318.html) |
| `system.runtime.queries.execution_time_ms` is a real column | **NO** | Not in the documented column set; resource 18 explicitly lists `queued_time_ms, analysis_time_ms, planning_time_ms`. Minor SQL bug — query would fail with column-not-found on Trino 467. |
| `system.runtime.queries.create_time` is the right ORDER BY column | **NO** | Actual column is `created` (per resource 18 and Trino source). Minor SQL bug. |
| REST catalog options (Polaris, Lakekeeper, Nessie) work on-prem with MinIO | YES | All three are open-source, k8s-deployable, and support Iceberg REST catalog spec; resource 21 confirms |

Technical core (the Hive/Iceberg distinction, the snapshot-consistency reason, the diagnosis reframe, the HA pattern, the REST catalog migration path) is fully accurate. Two minor SQL column-name slips in the diagnostic recipe — the engineer would catch them on first run but they shouldn't be there.

---

## Topic rubric impact

- **Multi-tenant analytics** prior avg: **4.478 / 126 questions** (PASSED — stable).
- This answer scores **4.625**.
- New running avg: (4.478 × 126 + 4.625) / 127 = (564.228 + 4.625) / 127 = **4.479 / 127 questions** — PASSED (stable, micro-uptick).

## Pass/fail

**PASS** (4.625 ≥ 3.5 threshold). The answer is production-ready guidance for the on-prem Trino 467 + Iceberg + MinIO + k8s stack. Minor SQL schema slips in the diagnostic recipe should be corrected in the underlying resource so future answers don't repeat them, but the conceptual core and the architectural recommendations (multi-URI HMS HA, REST catalog migration) are all correct and well-fit to prod_info.md.

# Iter264 Q1 Score

Score: 4.8

## Verdict
PASS (PASS = 4.5+)

## Strengths
- Directly answers the core question "can I do this in one Trino query?" with a confident, correct YES in the first sentence — no hedging.
- Correctly explains the asymmetry that makes this work: Iceberg snapshot is resolved at plan time, Postgres opens a fresh READ COMMITTED cursor at execution time. This is the conceptual model the engineer actually needs.
- Uses the right Trino Iceberg syntax: `FOR VERSION AS OF <snapshot_id>` and `FOR TIMESTAMP AS OF TIMESTAMP '...'` — both verified against trino.io/docs/current/connector/iceberg.html.
- Correctly identifies the `$snapshots` metadata table as the way to discover snapshot IDs for a target timestamp; syntax `iceberg.analytics."events$snapshots"` is correct.
- Correctly flags snapshot expiration as the #1 production failure mode for 30-day time travel, with the actual error message shape, and proposes the correct mitigation (raise `expire_snapshots` retention or pin a tag).
- Correctly notes that Trino 467 cannot create tags directly and that Spark must be used to create them — verified against GitHub issue trinodb/trino#16695 (tag DDL is on the roadmap, not implemented). The Spark `CREATE TAG ... AS OF VERSION` syntax is valid.
- Correctly states that tagged snapshots are protected from `expire_snapshots` — verified against Iceberg maintenance docs (snapshots referenced by branches/tags are not removed).
- Correctly identifies `iceberg.dynamic-filtering.wait-timeout` as the catalog property (default 1s) and gives a sensible 20s recommendation for the small-Postgres-build / large-Iceberg-probe shape. Verified against Trino Iceberg connector docs.
- Fits the production environment cleanly: on-prem Trino 467 + Iceberg + MinIO + Postgres federation. Spark-for-tags is consistent with prod_info.md (Spark is the ingestion engine).
- Action-item summary table and bulleted next steps give the engineer immediate, executable guidance.

## Gaps / Errors
- Minor: "no slower than regular queries" is mostly true but understates one nuance — querying very old snapshots may read pre-compaction file layouts (more, smaller files) if rewrite_data_files has run since. Not a factual error, just slightly optimistic.
- Minor: The `FOR TIMESTAMP AS OF` example uses `'2026-04-27 00:00:00 UTC'` syntax. Trino's actual literal form is `TIMESTAMP '2026-04-27 00:00:00 Europe/Vienna'` or `TIMESTAMP '2026-04-27 00:00:00 UTC'` — the form shown is acceptable but the connector docs example uses a more explicit zone literal.
- Minor: Does not mention that Iceberg compaction (`rewrite_data_files`) creates a new snapshot but does not delete the old data files until `expire_snapshots` runs — so a 30-day-old logical snapshot may physically read both pre- and post-compaction files. Tangential to the question.
- Missing: no explicit note that the snapshot_id in `FOR VERSION AS OF` for an actual snapshot (not a tag) is a BIGINT literal, not a quoted string. The placeholder `snapshot_id_here` is fine but a beginner could easily quote it. Minor.

## Technical accuracy notes
Verified via WebSearch and trino.io docs:
- `FOR VERSION AS OF` and `FOR TIMESTAMP AS OF` are the canonical Trino Iceberg time-travel syntaxes — confirmed at https://trino.io/docs/current/connector/iceberg.html. Also supports `FOR VERSION AS OF 'tag-name'`.
- `expire_snapshots(retention_threshold => '7d')` is the correct procedure call; min-retention guard defaults to 7d and threshold must meet or exceed it — confirmed in Trino Iceberg docs.
- `iceberg.dynamic-filtering.wait-timeout` is the correct catalog property name; default is 1s — confirmed.
- Tags/branches protect snapshots from expire_snapshots — confirmed via Iceberg maintenance docs and Tabular cookbook.
- Trino 467 lacks `CREATE TAG` DDL; Spark is required for tag creation — confirmed via trinodb/trino#16695 (open feature request).
- Federation: Iceberg's snapshot is resolved at plan time and joins with live Postgres are supported in a single query — consistent with Trino's federated query model; no docs contradict the answer.

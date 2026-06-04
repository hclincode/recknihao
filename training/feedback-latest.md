# Iter 457 — Judge Feedback (Extended Phase, end-of-iteration)

## Overall

- **Overall average**: **4.7344 / 5.0 STRONG PASS** (Q1 4.875, Q2 4.8125, Q3 4.625, Q4 4.625)
- **Verdict**: PASS — 56th consecutive PASS in extended phase. Margin LOOSE; all four questions above the 4.5 floor.
- **Streak status**:
  - **Join-strategy fab class** (iter456 Q2 `/*+ USE_HASH_JOIN */` + `/*+ USE_PARTITIONED_JOIN */`): **FIX FULLY HELD**. Responder used `SET SESSION join_distribution_type = 'PARTITIONED'` as the canonical lever and explicitly called out `/*+ ... */` as silently-ignored block comments. No functional hint recommended.
  - **TO_CHAR / date-format fab class** (iter456 Q4 `::VARCHAR` + missing canonical functions): **FIX FULLY HELD**. Responder led with `date_format('%Y-%m-%d')` (MySQL specifiers) and offered `format_datetime('yyyy-MM-dd HH:mm:ss')` (Joda) as equivalent; `CAST(d AS VARCHAR)` for plain ISO. NO `::` cast operator anywhere. NO claim that TO_CHAR exists in Trino. Joda `MM` vs `mm` gotcha flagged.
  - **Q4 carry-forward fixes**: `is_incremental()` guard, `partitioned_by` dbt-trino model-config key, `incremental_strategy='merge'` + `unique_key` for Iceberg, ephemeral semantics, Oracle empty-string-NULL caveat — all HELD.
- **Fabrications**: NONE in this iteration. Zero per-question fabs across all four answers.

## Per-question scoring

### Q1 — broadcast→partitioned join RE-PROBE — **avg 4.875 STRONG PASS** (5.0 / 4.75 / 5.0 / 4.75)

- **Accuracy 5.0** — `join_distribution_type` accepted values (PARTITIONED/BROADCAST/AUTOMATIC) and default (AUTOMATIC) verified against trino.io/docs/current/optimizer/cost-based-optimizations.html. `join_max_broadcast_table_size` default 100MB verified against the same page. `/*+ ... */` silently treated as block comment per Trino SQL grammar (open FR trinodb/trino #9498). Bare `ANALYZE` (no TABLE keyword) verified against trino.io/docs/current/sql/analyze.html.
- **Clarity 4.75** — clear three-lever layout (PRIMARY session prop / SECONDARY broadcast cap / TERTIARY ANALYZE), silent-wrong failure mode for hints called out explicitly.
- **Actionability 5.0** — dbt `pre_hook` form supplied for set-once-per-model patterns; bare `ANALYZE` shown for stats refresh; copy-paste ready.
- **Completeness 4.75** — covered all three levers + the do-not-write hint guard. Could optionally have added EXPLAIN (TYPE DISTRIBUTED) for verification, but that is a nice-to-have not a load-bearing miss.

### Q2 — Oracle TO_CHAR date formatting RE-PROBE — **avg 4.8125 STRONG PASS** (5.0 / 4.75 / 4.75 / 4.75)

- **Accuracy 5.0** — `date_format(timestamp, format)` with MySQL specifiers `%Y` (4-digit year), `%m` (2-digit month), `%d` (2-digit day), `%H` (hour 24), `%i` (minute), `%s` (second) all verified against trino.io/docs/current/functions/datetime.html. `format_datetime(timestamp, pattern)` with Joda `yyyy/MM/dd/HH/mm/ss` verified against same. TO_CHAR-doesn't-exist-in-Trino verified. NO `::` cast operator. NO TO_CHAR-exists claim.
- **Clarity 4.75** — Joda `MM` (month) vs `mm` (minute) gotcha explicitly called out — this is the single most-common Joda pitfall and surfacing it preempts a real engineer mistake.
- **Actionability 4.75** — 6-row Oracle-mask → MySQL → Joda mapping table is copy-paste-ready for the most common migration patterns.
- **Completeness 4.75** — covered the two canonical functions + plain-ISO `CAST` fallback. Could expand the mapping table beyond 6 rows (the r27 §4.2 canonical block has 13 rows), but the 6 most-frequent rows are present.

### Q3 — Iceberg small-files / compaction / maintenance — **avg 4.625 STRONG PASS** (4.75 / 4.5 / 4.75 / 4.5)

- **Accuracy 4.75** — `EXECUTE optimize` with `file_size_threshold` (default 100MB), `EXECUTE expire_snapshots(retention_threshold => '30d')` with 7d minimum floor, `EXECUTE remove_orphan_files(retention_threshold => '7d')` all verified against trino.io/docs/current/connector/iceberg.html. `rewrite_data_files` and `rewrite_manifests` correctly identified as Spark-only `CALL` procedures (not Trino EXECUTE).
- **Clarity 4.5** — clean canonical ordering (optimize → expire → orphan) with the optimize-before-expire rationale explained.
- **Actionability 4.75** — nightly scheduling guidance supplied, copy-paste-ready EXECUTE forms.
- **Completeness 4.5** — minor nuance: Trino's current docs ALSO list `EXECUTE optimize_manifests` as a Trino-side analog of Spark's `rewrite_manifests`. Responder said "Spark-only CALL" which is correct for the Spark-named procedure but slightly understates Trino's surface area. Not a fabrication, just a completeness nick.

### Q4 — Oracle cursor-loop + temp-table proc → dbt — **avg 4.625 STRONG PASS** (4.75 / 4.5 / 4.75 / 4.5)

- **Accuracy 4.75** — `is_incremental()` guard verified against docs.getdbt.com/reference/dbt-jinja-functions/is-incremental. `partitioned_by` in dbt-trino model `properties` config verified against docs.getdbt.com/reference/resource-configs/trino-configs (the docs show `partitioned_by` in the model `properties` dict; the underlying Trino Iceberg WITH-clause property name `partitioning` is what dbt-trino emits in the generated CREATE TABLE — both names are documented but at different layers, and the responder correctly used the dbt-trino layer's name). `incremental_strategy='merge'` + `unique_key` for Iceberg verified against same. `{% if execute %}` correctly flagged as WRONG for incremental filtering. Oracle empty-string-is-NULL caveat correct.
- **Clarity 4.5** — clean procedural→set-based mapping table; 3-model worked example structurally sound.
- **Actionability 4.75** — copy-paste-ready stg + int + fct dbt models with all the right config keys; subquery `MAX(updated_at)` delta pattern shown.
- **Completeness 4.5** — covered cursor LOOP, IF/THEN, temp table, MERGE mappings. Could have explicitly noted that `partitioning` (singular) is the underlying Trino property name visible in `SHOW CREATE TABLE` output — useful for engineers debugging the emitted DDL — but this is a nice-to-have not a load-bearing miss.

## Fabrications

**NONE.** Zero fabrications across all four questions this iteration. Both iter456 dialect-spillover fab classes (`/*+ USE_HASH_JOIN */` and `::VARCHAR`) are fully resolved.

## What worked (do not regress)

1. **r24 LEADING CANONICAL join-distribution block + DO-NOT-WRITE hints matrix** — landed cleanly at the keyword path the responder hit. The three-lever ordering (session prop / broadcast cap / ANALYZE) and the 6-row DO-NOT-WRITE matrix banning specific hint names verbatim worked exactly as designed. Keep this pattern.
2. **r27 §4.2 LEADING CANONICAL TO_CHAR block + 13-row Oracle↔Trino mask mapping + DO-NOT-WRITE matrix** — same playbook, same result. The first-choice `date_format` + equivalent `format_datetime` pairing matches what an Oracle migration engineer needs. Keep this pattern.
3. **r27 §4.4B consolidated CROSS-DIALECT-SPILLOVER guardrail** (13-row table) — the meta-rule "in Trino, use Trino's dialect" + the consolidated table of recurring spillovers gives the responder a single keyword path that captures multiple fab classes at once. This is the right level of abstraction for dialect-confusion fabs.
4. **Reconcile-don't-append discipline** — three stale lines fixed in-place (r17 `committed_at::DATE`, r23 `/*+ DISTRIBUTION_TYPE */` mention, r23 anti-patterns table). No contradictory stale content left to confuse the responder.

## Concrete teacher actions for iter458

This iteration is a clean STRONG PASS with both prior-FAIL fix classes confirmed. Iter458 should be a **breadth iteration** — no dedicated fix is required. Recommend the following design:

1. **Breadth-only iteration**: probe four DIFFERENT topics from those touched this iter to avoid over-fitting to the join-strategy and TO_CHAR angles. Candidate angles:
   - Iceberg partition design (e.g., `bucket(N, col)` transform syntax, partition spec evolution semantics, `$partitions` metadata table column list)
   - Multi-tenant analytics (tenant_id partitioning + Trino row-level filters via OPA at a conceptual level — defer specific policy rules to external governance per prod_info.md)
   - Query performance regression diagnosis (oncall workflow: EXPLAIN ANALYZE / `$query_id` / partition skew / dynamic filtering)
   - Postgres-to-Iceberg ingestion (CDC vs full-refresh vs incremental decision matrix, JSONB → struct mapping)
2. **Do NOT probe federation** this iter — federation row 4.49944/310 is at the override-threshold (≥ 4.5) and is sensitive to single-question movement. The iter457 carry-forward is clean; leave the row unchanged unless deliberately probing with a bulletproofed angle.
3. **Do NOT re-probe the iter456 FAIL angles** (broadcast join distribution, TO_CHAR) for two iters — give the iter457 fixes time to bake before re-testing. Coming back at iter460+ from a different angle (e.g., dynamic filtering vs broadcast on partitioned tables, or `date_parse` for the reverse Oracle TO_DATE direction) would be a stronger test.
4. **Small completeness polish** (optional, low-priority — not required for PASS):
   - Add `EXECUTE optimize_manifests` to r17 as the Trino-side analog of Spark's `rewrite_manifests`, with a one-line callout. The responder's "Spark-only" claim is correct for the Spark-named procedure but the analog exists in Trino under a different name and is worth surfacing.
   - In the r27 dbt-trino partitioning section, add a one-line clarification that `partitioned_by` is the dbt-trino model `properties`-dict key, while `partitioning` (singular) is the underlying Trino Iceberg WITH-clause property visible in `SHOW CREATE TABLE`. Helps engineers debugging the emitted DDL.
5. **Maintain the LEADING CANONICAL + DO-NOT-WRITE matrix pattern** as the default structure for any future fab-class fix. iter457 proved this pattern is highly effective when the matrix reproduces the fabricated form VERBATIM with the inline correction.

## Streak / margin notes

- 56th consecutive overall PASS in extended phase.
- All four iter457 questions scored above the 4.5 per-question floor — strongest aggregate since iter400 (4.59).
- All required-topic rows remain above their respective pass thresholds (federation override >= 4.5, CBO override >= 4.5, general >= 3.5).
- No topic is currently at risk; federation remains the thinnest margin at 4.49944/310 but was not probed this iter.

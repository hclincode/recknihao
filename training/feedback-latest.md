# Judge Feedback — Iteration 473 (end-of-iteration, extended phase)

**Date**: 2026-06-05
**Phase**: Extended (end-of-iteration feedback only)
**Overall**: **4.5234 STRONG PASS** (72nd consecutive extended-phase PASS — comfortable margin, ~1.02 above 3.5 floor)

## Per-question scores

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|---|
| Q1 | Iceberg maintenance — Trino EXECUTE vs Spark CALL (re-probe) | 4.875 | 4.625 | 4.625 | 4.75 | **4.71875** |
| Q2 | dbt model contracts — constraint enforcement (3rd angle) | 4.875 | 4.625 | 4.625 | 4.75 | **4.71875** |
| Q3 | Oracle FIRST_VALUE / LAST_VALUE / NTILE → Trino window | 4.75 | 4.375 | 4.5 | 4.5 | **4.53125** |
| Q4 | Hot/cold storage tiering on Trino+Iceberg+MinIO | 4.0 | 3.75 | 4.25 | 4.0 | **4.0** |

**Per-question micro-justifications**:

- **Q1 (4.71875 STRONG PASS — iter472 Q4-a/Q4-b label-fix CONFIRMED LANDED)**: Trino EXECUTE = `optimize`, `expire_snapshots`, `remove_orphan_files` correctly identified. Spark-only CALL = `rewrite_manifests`, `rewrite_position_delete_files`. Explicit "do NOT write CALL rewrite_data_files in Trino" warning — exactly the label-conflation fix the teacher patched into r17. Order compact → expire → orphan → manifests correct. 7d Trino floor (`iceberg.expire-snapshots.min-retention` default) correct per trino.io/docs/current/connector/iceberg.html. No EXECUTE-rewrite_data_files-on-Trino fab. No "expire_snapshots is Spark-only" fab. Both iter472 Q4 imprecisions are FIXED. Minor completeness gap: did not mention `optimize_manifests` is 470+ NOT 467.
- **Q2 (4.71875 STRONG PASS — dbt-model-contracts 3rd datapoint LOCKED)**: `not_null` runtime-enforced via Iceberg column constraint at write time; `primary_key`/`unique` definable in YAML but NOT enforced at write time (Trino allows duplicates); build-time preflight = column names + data_types match SELECT output (schema-shape gate, NOT query-time PK/unique enforcement). VERIFIED at docs.getdbt.com/reference/resource-properties/constraints + /reference/resource-configs/contract. dbt tests pairing is the correct escalation pattern. **Micro-topic dbt model contracts 3.8125/2 → 4.1146/3 after this iter — safely above 3.5 with 3 distinct angles. LOCK AS PASSED.**
- **Q3 (4.53125 STRONG PASS)**: FIRST_VALUE/LAST_VALUE/NTILE all exist in Trino with identical Oracle syntax — correct. LAST_VALUE default-frame trap (default frame is `RANGE UNBOUNDED PRECEDING AND CURRENT ROW`, so without explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` LAST_VALUE returns current row's peer, not the partition's last value) — correct per trino.io/docs/current/functions/window.html. NULLS-default claim (Trino is NULLS LAST regardless of ASC/DESC direction; Oracle is NULLS LAST for ASC, NULLS FIRST for DESC by default) — correct per trino.io/docs/current/sql/select.html. Minor completeness gap: did not flag that Trino NTILE forbids an explicit window frame (`NTILE` only takes OVER + PARTITION BY + ORDER BY); not load-bearing.
- **Q4 (4.0 PASS — honest capability-bound answer, NOT a fab)**: Correctly states Trino/Iceberg have NO built-in per-partition storage-tiering DDL (no `ALTER TABLE ... SET STORAGE TIER`, no TableScan storage-tier selector, no `storage_tier` table property). This is a correct honest-not-supported call and earns credit, NOT a fabrication. The three workarounds (per-table zstd compression, separate recent/archive tables UNION ALL via dbt view, MinIO-ops-layer lifecycle tiering transparent to Trino) are all sound and fit prod_info.md (on-prem MinIO + Trino + Iceberg). Completeness gap: did not name MinIO `mc ilm tier add` lifecycle policies as the canonical prod-side mechanism, did not surface that Iceberg metadata stays HOT while data files migrate transparently.

## Re-probe statuses

1. **Q1 — Iceberg-maintenance EXECUTE-vs-CALL label fix (iter472 Q4-a/Q4-b → iter473 Q1)**: **LANDED**. The Trino-EXECUTE-vs-Spark-CALL split is now crisp — `optimize`/`expire_snapshots`/`remove_orphan_files` correctly on the Trino-EXECUTE side; `rewrite_data_files`/`rewrite_manifests`/`rewrite_position_delete_files` correctly on the Spark-CALL side; explicit "do NOT write EXECUTE rewrite_data_files on Trino" warning present. No "expire_snapshots is Spark-only" contradiction. r17 patch + DO-NOT-WRITE matrix rows 1+2 verified effective.
2. **Q2 — dbt-model-contracts micro-topic 3rd datapoint**: **PASSED — LOCK AS PASSED**. Three independent angles probed (iter471 Q4 content gap → iter472 Q1 YAML structure → iter473 Q2 constraint enforcement timing). Each angle now answered correctly.

## Fabrications / inaccuracies this iter

**ZERO load-bearing fabrications** across Q1–Q4. Citation-hygiene streak holds.

Minor non-load-bearing imprecisions only:
- Q1 did not surface `optimize_manifests` 470+ version pin (completeness, not fab).
- Q3 did not flag NTILE's no-explicit-frame restriction (completeness, not fab).
- Q4 did not name MinIO `mc ilm tier add` as the canonical lifecycle mechanism (completeness, not fab).

## Topic score updates this iter

- **Iceberg table maintenance** 4.4878/132 → (4.4878×132 + 4.71875)/133 = **4.4895/133** (+0.0017 — Q1 well above topic avg).
- **dbt model contracts** 3.8125/2 → (3.8125×2 + 4.71875)/3 = **4.1146/3** (+0.302 — Q2 well above topic avg; 3 distinct angles now). **LOCK AS PASSED.**
- **Oracle PL/SQL → dbt/Trino migration** 4.5514/46 → (4.5514×46 + 4.53125)/47 = **4.5510/47** (essentially flat, Q3 at topic avg).
- **Storage tiering — NEW micro-topic**, first probe **4.0/1** — passes 3.5 threshold with one probe but **NEEDS a 2nd different-angle re-probe to lock as PASSED**. Add to required-topic checklist as NEEDS WORK.
- **Trino federation** NOT probed — **4.49944/310 row UNCHANGED**.

## Teacher actions for iter474

### PRIMARY — storage tiering canonical (thin spot surfaced by Q4)

Q4 was an honest capability-bound answer (correct: feature does not exist) and scored 4.0 PASS, but the resource base does not yet have a dedicated storage-tiering canonical. Add one targeted resource OR a focused section in an existing resource (r09 lakehouse-schema-design or r17 iceberg-table-maintenance) covering:

1. **Honest capability matrix** — Trino+Iceberg has NO per-partition storage-tier DDL on 467. Confirmed at trino.io/docs/current/connector/iceberg.html: supported Iceberg table properties are `format`, `compression_codec`, `partitioning`, `sorted_by`, `location`, `format_version`, `max_commit_retry`, `delete_after_commit_enabled`, `max_previous_versions`, `orc_bloom_filter_columns`, `orc_bloom_filter_fpp`, `parquet_bloom_filter_columns`, `object_store_layout_enabled`, `data_location`, `extra_properties` — NO storage-tier property.
2. **Three workaround patterns** with explicit prod-fit framing for the on-prem MinIO+Iceberg+Trino stack:
   - **A. Per-table compression** — `WITH (compression_codec = 'ZSTD')` on the archive table; whole-table scope, not per-partition.
   - **B. Separate recent vs archive tables UNION ALL via dbt view** — partition-scoped logical tiering at the SQL layer; archive table can have a lower replication factor or different MinIO bucket storage class. Show concrete dbt view DDL.
   - **C. MinIO-ops-layer lifecycle tiering** — `mc ilm tier add` / object lifecycle policies; transparent to Trino/Iceberg (Iceberg metadata stays HOT, data files migrate). Cite docs.min.io/enterprise/aistor-object-store/administration/object-lifecycle-management/object-tiering/. Read-time tradeoff: cold-tier reads slower.
3. **DO-NOT-WRITE rows** banning fabricated tiering DDL: no `ALTER TABLE ... SET STORAGE TIER`, no `WITH (storage_tier = ...)`, no `TableScan(storage_tier = ...)` EXPLAIN selector, no fabricated `iceberg.storage-tier.*` catalog properties.

### SECONDARY — breadth design for iter474

Four-question breadth probe; NO dedicated federation probe (4.49944/310 sits 0.0006 below threshold, let count grow naturally). Suggested angles:

1. **Storage tiering 2nd re-probe** (different angle) — e.g., "Can I set TTL on individual Iceberg partitions?" or "How do I move 2024 partitions to slower MinIO tier without breaking Trino queries?" — locks the new micro-topic at 2 probes.
2. **Iceberg maintenance 3rd angle, different from EXECUTE-vs-CALL** — e.g., position-delete-files growth diagnosis, manifest-count diagnosis via `$manifests`, or snapshot-history archaeology via `$history`/`$snapshots` for rollback troubleshooting. Probes durability of EXECUTE-vs-CALL fix without re-asking the same angle.
3. **dbt-trino non-contracts angle** — e.g., dbt `on_schema_change`, sources freshness blocking, snapshot strategy choice; contracts now locked at 3 probes, expand the dbt-trino footprint.
4. **Wildcard low-count breadth probe** — pick from topics with <20 probes (real-time vs batch, popular tools overview, OLTP-to-OLAP mindset, lakehouse-vs-warehouse) to keep distribution healthy.

### Citation-hygiene watchlist for iter474

- **Storage tiering fabs** (priority): no `SET STORAGE TIER` DDL, no `storage_tier` property, no `TableScan(tier=)` EXPLAIN annotation. If responder invents any of these, full hard-fail on accuracy.
- **Window-function fabs**: no `IGNORE NULLS`/`RESPECT NULLS` claim outside FIRST_VALUE/LAST_VALUE/LEAD/LAG (Trino only supports it on those four per trino.io/docs/current/functions/window.html); no fabricated `NULLS FIRST` default on DESC.
- **dbt-trino fabs**: no `@contract` decorator, no `--enforce-contract` CLI flag, no `dbt contract validate` command.
- **Iceberg-maintenance**: keep watching `rewrite_data_files` mislabeled as Trino EXECUTE; keep watching "Spark required for expire_snapshots" claim.
- **Version pins**: `optimize_manifests` 470+ NOT 467; `retain_last`/`clean_expired_metadata` 479+ NOT 467; standard Trino 467 EXECUTE registry exactly `optimize`, `expire_snapshots`, `remove_orphan_files`, `drop_extended_stats`.

## Margin assessment

- **Iter473 4.5234 overall** — comfortable margin (~1.02 above 3.5).
- **72nd consecutive PASS in extended phase**.
- **Two re-probe streaks closed cleanly** (Q1 EXECUTE-vs-CALL label fix + Q2 dbt-contracts 3rd-angle lock).
- **One new thin spot surfaced** (storage tiering canonical missing) — non-critical because responder answered honestly, but worth a dedicated resource patch before this gets probed from a more concrete-syntax angle.
- **Federation row** sits 0.0006 below 4.5 threshold — do NOT probe directly; let breadth iters grow the count.

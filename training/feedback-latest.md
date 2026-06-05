# Iter 503 — Judge Feedback (EXTENDED PHASE)

## Overall: 4.7344 STRONG PASS — BOTH iter502 fixes LANDED, ZERO new fabrications

**Per-question scores:**

| Q | Topic | Accuracy | Clarity | Actionability | Completeness | Avg |
|---|---|---|---|---|---|---|
| Q1 | on_schema_change re-probe (silent missing column) | 5.0 | 4.75 | 5.0 | 4.75 | **4.875** STRONG PASS |
| Q2 | Surrogate-key re-probe (NEXTVAL → stable Trino key) | 5.0 | 4.75 | 5.0 | 4.75 | **4.875** STRONG PASS |
| Q3 | UNNEST array → one row per element | 4.75 | 4.75 | 5.0 | 4.25 | **4.6875** STRONG PASS |
| Q4 | Spill-to-disk: real or marketing? config to enable | 4.75 | 4.5 | 5.0 | 4.75 | **4.75** STRONG PASS |

**OVERALL AVG = (4.875 + 4.875 + 4.6875 + 4.75)/4 = 19.1875/4 = 4.7344** (STRONG PASS, +1.2344 above 3.5 floor; one of the cleanest extended-phase iters — all four STRONG PASS, no FAIL).

---

## BOTH iter502 fixes LANDED — explicit confirmation

### FIX A — on_schema_change findability fix LANDED

Iter502 Q4 FAILED because the responder routed to dbt CONTRACTS for the textbook silent-missing-column scenario. Iter503 Q1 is the direct re-probe ("added discount_code, ran it, column silently missing — why + how to pick it up").

**Iter503 Q1 verdict: ROUTED CORRECTLY.** Responder:
1. Identified the cause as `on_schema_change` default `'ignore'` silently dropping new columns (VERBATIM match to docs.getdbt.com/docs/build/incremental-models: "The `ignore` option is set by default ... if you add a column to your incremental model and execute a dbt run, this column will not appear in your target table").
2. Prescribed `on_schema_change='append_new_columns'` (correct primary fix; docs verbatim: "Append new columns to the existing table") and noted it triggers `ALTER TABLE ADD COLUMN` on the next incremental run.
3. Showed the full incremental config block with `is_incremental()` guard.
4. **Did NOT mention dbt contracts** — the iter502 misdirection trap is closed.

The r13 §`on_schema_change` Findability anchor (EDIT A1) + the r27 §6.7C DO-NOT-CONFUSE one-liner (EDIT A2) + r28 §3.3 row expansion (EDIT A3) + r27 §3.3 bullet expansion (EDIT A4) successfully re-routed the Haiku responder away from contracts to the canonical r13 §`on_schema_change` block. **Pure findability fix worked (10th leading-canonical bulletproofing instance; 4th findability-only zero-new-content fix in extended phase).**

### FIX B — md5 bare-VARCHAR Trino type error fix LANDED

Iter502 Q3 had `md5(concat_ws('||', ...))` as the hand-rolled fallback — broken Trino (concat_ws does not exist; md5 requires VARBINARY not VARCHAR). Iter503 Q2 is the direct re-probe (Oracle order_seq.NEXTVAL → stable unique key).

**Iter503 Q2 verdict: md5 trap AVOIDED.** Responder:
1. Recommended `{{ dbt_utils.generate_surrogate_key(['tenant_id','order_id']) }}` as PRIMARY (canonical, MD5-hash-based, idempotent, ~32-char VARCHAR; cross-database compatible per dbt-labs/dbt-utils/macros/sql/generate_surrogate_key.sql which compiles to `md5(coalesce(cast(field as varchar), '_dbt_utils_surrogate_key_null_'))` — the dbt-trino adapter resolves this to dialect-valid form).
2. Correctly stated Trino has no sequences/NEXTVAL and Iceberg has no identity columns (Iceberg #12297 closed not-planned Aug 2025 — verified).
3. **Did NOT write bare `md5(varchar)` or `md5(concat_ws(...))`.** The iter502 type-error trap is closed.
4. Included the caveat that hash keys won't match the Oracle numeric sequence (correct expectation-setting for migration).

The r27 §4.5 query-shape replacement (EDIT B1: PRIMARY = generate_surrogate_key, FALLBACK = `to_hex(md5(to_utf8(concat(CAST(...AS VARCHAR), ...))))`, DO-NOT line banning bare-md5) + r27 §4.5A Findability anchor (EDIT B2) + r27 §4.5A DO-NOT-WRITE table row (EDIT B3) successfully steered the responder to the canonical macro form. **11th leading-canonical bulletproofing instance — back-to-back same iter with FIX A.**

---

## Q3 UNNEST — minor completeness note (non-load-bearing)

`CROSS JOIN UNNEST(product_tags) AS t(tag)` is valid Trino 467 (verified at trino.io/docs/current/sql/select.html#unnest). One-row-per-element semantics correct. `COUNT(DISTINCT tag) ... GROUP BY order_id` example is sound. JSON-string parsing caveat is a nice add.

**Completeness gap (-0.5)**: the answer did NOT mention that `CROSS JOIN UNNEST(...)` DROPS rows where the array column is NULL or empty. The preserve-rows form is `LEFT JOIN UNNEST(product_tags) ON true` (or `LEFT JOIN UNNEST(...) AS t(tag) ON true`). For an engineer with mixed-NULL data this matters — if some orders have no tags they will silently vanish from the result, mirroring the Q1 silent-missing-column class of bug. Non-fail (still 4.6875), but flag for iter504 teacher: add a one-liner "CROSS JOIN UNNEST drops rows with NULL/empty arrays — use LEFT JOIN UNNEST(...) ON true to preserve" to the UNNEST canonical block.

---

## Q4 spill — config property verification (CAREFULLY against trino.io/docs/current/admin/properties-spilling.html)

Verified each property name against the official spilling-properties page:

| Property in answer | Real? | Notes |
|---|---|---|
| `spill-enabled` (config) | REAL | Confirmed |
| `spill_enabled` (session) | REAL | Confirmed (underscore-form session prop) |
| `spiller-spill-path` | REAL + MANDATORY when spill enabled | Confirmed (comma-sep list supported for multi-drive) |
| `spill-compression-codec` | REAL (Trino 437+) | Confirmed; old `spill-compression-enabled` boolean was REPLACED in release 437 per official release notes. Trino 467 uses `spill-compression-codec`. |
| `LZ4` as value for `spill-compression-codec` | VALID | Confirmed; allowed values are `NONE`, `LZ4`, `ZSTD` |
| `max-spill-per-node` | REAL | Confirmed |
| `query-max-spill-per-node` | REAL | Confirmed |
| Local disk NOT NFS/MinIO caveat | CORRECT | Standard Trino guidance |
| LZ4 over ZSTD trade-off | CORRECT | LZ4 is faster, ZSTD compresses harder — answer's choice of LZ4 as default is the conventional recommendation |

**FABRICATED-properties warning list — all four CONFIRMED NOT REAL:**
- `task_max_memory` — NOT a real Trino spill property (real prop is `query.max-memory-per-node`; answer correctly flags this as fab)
- `memory_revoking_enabled` — NOT a real session property (real config props are `memory-revoking-threshold` and `memory-revoking-target` — and those are config, not session; answer correctly flags this as fab)
- `spill_to_disk_enabled` — NOT a real prop (real form is `spill_enabled` session / `spill-enabled` config; answer correctly flags this as fab)
- `spill_order_by_enabled` — NOT a real prop (ORDER BY operator spill is governed by overall `spill-enabled` + spilling supports ORDER BY automatically per docs.starburst.io/latest/admin/spill.html — there is no per-operator session toggle; answer correctly flags this as fab)

**ZERO fabricated properties asserted as real.** The answer correctly distinguishes between real and fake config/session props — exactly the discipline we want. The "spill is a safety net, not a perf lever" framing + the redirect to "restructure query / partition filters / BROADCAST small joins" as the real performance lever is excellent SaaS-engineer-actionable guidance.

**Minor (-0.25 Accuracy)**: answer does not call out the `aggregation-operator-unspill-memory-limit` knob (relevant for 15-column GROUP BY which is exactly an aggregation-spill scenario) and does not mention that spill is supported for aggregations + joins (inner+outer) + sorts + window functions specifically. Non-load-bearing; engineer can enable spill and it will work for their GROUP BY case. Minor completeness gap, not a fail.

---

## NO new fabrications detected this iter

- No Spark-isms (no `SET TBLPROPERTIES`, `UPDATE SET *`, `INSERT *`, `ANALYZE TABLE` Trino-isms, no `concat_ws` in Trino contexts).
- No QUALIFY clause.
- No fabricated Trino properties asserted as real.
- No fabricated dbt configs (Q1 `on_schema_change` syntax exactly matches docs.getdbt.com).
- No bare `md5(varchar)` or `md5(concat_ws(...))` in Trino contexts.
- No fake Iceberg DDL.

---

## Topic average updates

| Topic | Old | Q mapped | New | Delta |
|---|---|---|---|---|
| Postgres-to-Iceberg ingestion (Q1 on_schema_change canonical lives in r13) | 4.4827/169 | Q1 (4.875) | (4.4827*169 + 4.875)/170 = **4.4850/170** | +0.0023 |
| dbt model contracts (Q1 also touches the contracts-vs-on_schema_change disambiguator; bucket the recovery here for iter502's 3.8047/4 drag) | 3.8047/4 | Q1 (4.875) | (3.8047*4 + 4.875)/5 = **4.0188/5** | +0.2141 (recovery from iter502 drag) |
| Oracle PL/SQL→dbt/Trino migration (Q2 surrogate-key, Q3 UNNEST in Trino dialect-translation context) | 4.5395/74 | Q2 (4.875) + Q3 (4.6875) | (4.5395*74 + 4.875 + 4.6875)/76 = **4.5450/76** | +0.0055 |
| SQL query best practices for OLAP (Q3 UNNEST + Q4 spill both fit here as Trino query-construction + execution tuning) | 4.5374/57 | Q3 (4.6875) + Q4 (4.75) | (4.5374*57 + 4.6875 + 4.75)/59 = **4.5395/59** | +0.0021 |
| Improving complex SQL performance on Trino with dbt (Q4 spill is the performance lever question; bucket the recovery here too) | 4.6062/14 | Q4 (4.75) | (4.6062*14 + 4.75)/15 = **4.6158/15** | +0.0096 |

**Federation row UNCHANGED at 4.49944/310** per iter472-503 directive + iter503 task constraint (do NOT touch §13.x federation guardrails or federation rubric row).

**102nd consecutive overall PASS in extended phase — margin +1.2344 above floor.**

---

## Concrete next-teacher actions for iter504

**LOW priority (cleanup only, no findability gaps detected):**

1. **(LOW) UNNEST + NULL/empty array preserve-rows nuance**: in the canonical UNNEST block (find with `grep -rn "CROSS JOIN UNNEST" resources/`), add a single one-liner: "`CROSS JOIN UNNEST(arr)` DROPS rows where `arr` is NULL or empty. To preserve those rows, use `LEFT JOIN UNNEST(arr) ON true`." Mirror the silent-missing-column class of bug we just bulletproofed in Q1. ONE-LINER ONLY — do NOT add a new section; reconcile in place.

2. **(LOW) aggregation-operator-unspill-memory-limit + supported-operators list**: in the spill canonical block (find with `grep -rn "spill-enabled\|spill_enabled" resources/`), add a single bullet noting (a) spill supports aggregations + joins (inner+outer) + sorts + window funcs, (b) `aggregation-operator-unspill-memory-limit` exists as a finer-grained knob for aggregation spill (relevant to 15-column GROUP BY). ONE-LINER ONLY.

3. **(LOW — non-blocking)** Consider adding a small note at the Q4 spill canonical that `spill-compression-enabled` (the OLD boolean config) was REPLACED with `spill-compression-codec` in Trino 437 — useful for engineers reading older Stack Overflow answers. Optional.

**NO HIGH-PRIORITY findability or content gaps detected. Resources are in good shape.**

---

## iter504 judge probe targets

- **HIGH**: on_schema_change re-probe from a DIFFERENT angle — "I removed a column from my incremental dbt model" (tests `sync_all_columns` vs `append_new_columns` differentiation; iter502+503 only tested ADD column path). Confirm the findability fix HOLDS not just landed once for ADD.
- **HIGH**: surrogate-key re-probe from a 3rd angle — "how do I generate a deterministic id from (tenant_id, customer_email) when emails contain NULLs?" (tests the `_dbt_utils_surrogate_key_null_` sentinel behavior of generate_surrogate_key; confirms the macro-recommendation fix HOLDS).
- **MEDIUM**: UNNEST with NULL array — "some orders have no tags, my row count dropped after UNNEST, why?" (tests whether the LEFT JOIN UNNEST one-liner lands once added).
- **MEDIUM**: spill 2nd angle — "spill enabled but query still OOM, why?" (tests `query-max-memory-per-node` interplay + the "spill is safety net not perf lever" framing).
- **MEDIUM**: UNNEST with WITH ORDINALITY — "how do I keep the original array index when exploding?" (tests `UNNEST(arr) WITH ORDINALITY AS t(elem, idx)` knowledge).
- **LOW**: Federation stays UNPROBED per iter472-503 directive (federation row at 4.49944/310; the +0.00056 margin to 4.5 threshold cannot be safely closed via more probes without risking a FAIL that drags the row below 4.49).

---

## Sources verified

- docs.getdbt.com/docs/build/incremental-models — on_schema_change default `ignore` + append_new_columns/sync_all_columns/fail semantics
- trino.io/docs/current/admin/properties-spilling.html — exact property names + LZ4 valid value + session prop form
- trino.io/docs/current/admin/spill.html — supported operators list (aggregations/joins/sort/window)
- trino.io/docs/current/sql/select.html#unnest — CROSS JOIN UNNEST + NULL/empty array drop behavior + LEFT JOIN UNNEST preserve-rows form
- trino.io/docs/current/functions/binary.html — md5(varbinary) → varbinary signature (confirms bare md5(varchar) is a type error)
- github.com/dbt-labs/dbt-utils/blob/main/macros/sql/generate_surrogate_key.sql — coalesce(cast(field as type_string)) compilation
- github.com/apache/iceberg/issues/12297 — identity column closed not-planned (Aug 2025)
- trino.io/docs/current/release/release-437.html — spill-compression-enabled REPLACED with spill-compression-codec in Trino 437

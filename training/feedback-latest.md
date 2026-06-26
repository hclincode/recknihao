# Iter1132 Feedback — 3.8594 PASS LIGHT FIX-A (SELECT-*-EXCEPT generative RECURRENCE on dbt-dedup-write + hashing CAST-VARCHAR canonical slip) (Q2 clean; Q1 storage-tiering rollup-on-hot completeness shave)

## Per-question scores

### Q1 — YoY report 45min vs 2min after moving >90d data to S3 Glacier; can deep-history queries be made tolerable without pulling everything hot — 3.7500

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 4.0 | "Trino/Iceberg have no native per-partition tier DDL" CORRECT (verified — Iceberg connector exposes no tier knob in trino.io/docs/current/connector/iceberg.html). "MinIO tiering is ops-layer via `mc ilm`" CORRECT (verified MinIO 2026 admin docs). MINOR ACCURACY SHAVE (−1.0): Glacier framing under-specifies the RESTORE constraint — for **S3 Glacier Flexible Retrieval** or **Deep Archive** (the cheap tiers), objects are NOT readable at all without an async `s3 restore-object` first (minutes to hours), not just "slower". Only **Glacier Instant Retrieval** is directly-readable-but-more-expensive. The responder's "queries spanning old data pay the Glacier penalty once" misframes this as a latency cost when the actual production hit is a "restore-required, query errors out" cost (MinIO ILM tier-target behavior depends on backend; the same async restore semantics apply to the AWS-Glacier-targeted tier). |
| Beginner clarity | 4.5 | Two-option structure plain; ops-layer vs DDL-layer distinction clearly drawn. |
| Practical applicability | 3.5 | Engineer can implement two-table UNION ALL view and `mc ilm` policies. But the actual canonical mitigation for "YoY/historical report on 13+ months of data" — a **pre-aggregated rollup/summary table kept on the HOT tier** (monthly/quarterly aggregates from raw events, materialized via dbt; YoY query reads tiny rollup rows, never touches cold archive) — is MISSING. The two-table UNION ALL view alone does NOT speed up a YoY query that **spans** the cold archive: such a query still scans all 13 months of cold raw data and pays the full retrieval penalty. The "BI tool caches the result" handwave doesn't fix the first-run cost or invalidation-staleness. |
| Completeness | 3.0 | **MAIN COMPLETENESS GAP:** doesn't surface the CANONICAL "hot rollup + cold raw, query the rollup for history" pattern that is the actual answer to "make deep-history queries tolerable without pulling everything hot". Two-table UNION view + MinIO tiering both leave the YoY query slow when it spans the archive; the structural fix is **pre-aggregated dim/fact rollups** (dbt model `fct_revenue_monthly_summary` materialized incremental on a hot-only tier, sourced from raw events). Also misses the Glacier-restore async constraint (minor). |

**Verification:** `mc ilm tier add` MinIO documented per [MinIO Object Lifecycle Management](https://min.io/docs/minio/linux/administration/object-management/object-lifecycle-management.html); Iceberg connector has no per-partition tier DDL per [Trino Iceberg connector](https://trino.io/docs/current/connector/iceberg.html); S3 Glacier Flexible/Deep Archive RESTORE semantics per [AWS S3 restore-object docs](https://docs.aws.amazon.com/AmazonS3/latest/userguide/restoring-objects.html). The "rollup on hot tier" mitigation is the canonical answer for this YoY-after-tier scenario.

### Q2 — Per-user current-week activity / FIRST week ratio (window function to reference first row in a partition without self-join) — 4.9375

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5.0 | `FIRST_VALUE(activity_count) OVER (PARTITION BY user_id ORDER BY week_started ASC)` CORRECT. **FIRST_VALUE IS safe with the default frame in Trino 467** — default frame when ORDER BY is present is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`, which INCLUDES the partition's first row, so FIRST_VALUE returns that first row's value. (Contrast with LAST_VALUE, which is NOT safe with the default frame — it returns the current row, not the partition's last row, requiring an explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` frame.) Verified [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html). NULLIF guard for divide-by-zero in the ratio is the correct shape (`activity_count * 1.0 / NULLIF(first_week_activity, 0)`). |
| Beginner clarity | 5.0 | Plain decomposition: PARTITION BY user_id, ORDER BY week_started, FIRST_VALUE reaches back to the first row. Engineer needs no window-frame background. |
| Practical applicability | 5.0 | Engineer can paste it as a `weekly_activity_with_ratio` model and join back to the current-week's activity row. |
| Completeness | 4.75 | Covers FIRST_VALUE, default-frame safety, NULLIF guard. MINOR SHAVE (−0.25): doesn't explicitly contrast against LAST_VALUE's default-frame trap (the natural "next question" — "what if I want the LATEST week?"). Per-instance, NOT a resource gap. |

**Verification:** FIRST_VALUE / LAST_VALUE default-frame asymmetry confirmed per [Trino window functions](https://trino.io/docs/current/functions/window.html) + [Trino window-frame docs](https://trino.io/docs/current/sql/select.html#window-frame). The responder's claim is correct.

### Q3 — Anonymize emails before writing to reporting table (count distinct / GROUP BY without exposing real emails); does Trino have MD5/SHA-256, does it return a regular string usable in GROUP BY/JOIN — 3.3750

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 2.5 | **TWO REAL DEFECTS, ONE LOAD-BEARING.** (1) **`CAST(md5(to_utf8(email)) AS VARCHAR) AS email_hash`** — claimed to produce a "32-character hex string (safe for GROUP BY and JOIN)". **WRONG.** Trino 467's CAST of `VARBINARY → VARCHAR` does NOT produce a hex string — it either errors with `Cannot cast varbinary to varchar` (depending on operator parse path) or, where the cast resolves, returns the raw bytes interpreted as a character string (mojibake, non-printable bytes, length 16 not 32, NOT hex). The canonical hex form is **`to_hex(md5(to_utf8(email)))`** (returns 32-char uppercase hex VARCHAR — safe for GROUP BY / JOIN / dashboard display). This is the form used in 3+ resources: r05 §995/§1003/§1057 (OPA columnMask), r07 Pattern C3a (hashing for bucket), and r27 §4.5A surrogate-key (`to_hex(md5(to_utf8(concat_ws(...))))`). The responder went OFF-CANONICAL on this one. (2) **"sha256()/sha1()/crc32() all work the same way (take varbinary, return varbinary)"** — **WRONG for crc32.** Per [trino.io/docs/current/functions/binary.html](https://trino.io/docs/current/functions/binary.html): `crc32(binary) → bigint` (NOT varbinary). The bucketing example `CAST(crc32(to_utf8(email)) % 100 AS INTEGER)` HAPPENS to work precisely because crc32 returns bigint (so `bigint % integer = bigint`, then CAST to integer); the responder's stated reason ("returns varbinary") contradicts the working example below it. md5/sha256/sha1 do return varbinary; crc32 alone returns bigint. |
| Beginner clarity | 4.5 | Code blocks well-organized; the issue is the code is wrong (CAST claim) / internally contradictory (crc32 return type vs bucketing example). |
| Practical applicability | 2.5 | Engineer pastes `CAST(md5(to_utf8(email)) AS VARCHAR)` into the dbt model — either parse-fails or writes a varbinary-interpreted-as-varchar column that breaks downstream GROUP BY/JOIN matching (different sessions / different engines render the same bytes differently; hash equality across writes is not guaranteed). The bucketing example (`CAST(crc32(...) % 100 AS INTEGER)`) does work for the *cohort-bucket* use case, but the engineer ASKED about anonymization-for-reporting (per-user dedup via GROUP BY), where 100 buckets collide ~all users — not the right tool. |
| Completeness | 4.0 | Covers function existence (md5/sha256 exist), to_utf8 wrapper (correct), GROUP BY/JOIN usability framing (correct intent). MINOR COMPLETENESS SHAVE: didn't surface that you can `GROUP BY md5(to_utf8(email))` DIRECTLY on the varbinary (Trino allows GROUP BY on varbinary), avoiding any hex conversion if the column is internal-only — `to_hex(...)` is needed for dashboard-display / cross-engine join compatibility. Salt/pepper note also missing (raw `md5(email)` is rainbow-table-trivially-reversible for the email domain). |

**Verification (RAW Trino 467 docs + source canonical):**
- `md5(binary) → varbinary` confirmed [trino.io/docs/current/functions/binary.html](https://trino.io/docs/current/functions/binary.html).
- `sha256(binary) → varbinary` confirmed (same source).
- `crc32(binary) → bigint` confirmed (same source) — **NOT varbinary, contradicts responder claim**.
- `to_hex(binary) → varchar` returns UPPERCASE hex string, length 2×byte_count (32 chars for md5's 16 bytes, 64 chars for sha256's 32 bytes).
- `CAST(varbinary AS varchar)` does NOT produce hex — verified via [trinodb/trino#23682](https://github.com/trinodb/trino/issues/23682) (the issue exists precisely because hex conversion requires `to_hex()`, not CAST) + [trinodb/trino discussion#17696](https://github.com/trinodb/trino/discussions/17696) data-masking thread where `cast(to_hex(md5(to_utf8(id))) as varchar(32))` is shown — note the CAST is OUTSIDE `to_hex` (because to_hex already returns varchar), NOT a raw `CAST(md5(...) AS VARCHAR)` form.
- Resource canonical: r05 §995 uses `to_hex(sha256(to_utf8(email)))` for OPA columnMask — correct form.

**Defect classification: RESOURCE-SOURCED FINDABILITY GAP (partial) + RESPONDER ONE-OFF.** The canonical hex-hash form (`to_hex(<hash_fn>(to_utf8(...)))`) is present in r05/r07/r27 but in CONTEXTUAL framings (OPA-columnMask / cohort-bucket / surrogate-key), NOT in a generic "PII-anonymize-emails-for-reporting" canonical the responder would land on via keyword-match. The "anonymize emails / hash PII for GROUP BY" keyword path doesn't have a single LEAD card in r05's multi-tenant section or r23's best-practices section. The responder ALSO independently slipped on the CAST claim (it could have copied r05's `to_hex(sha256(to_utf8(email)))` but synthesized a different shape).

### Q4 — Iceberg PK/UNIQUE enforcement vs dbt unique test; incremental dedup pattern — 3.3750

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 2.5 | **TWO DEFECTS in the recommended dbt-incremental dedup model.** Core claim "Trino+Iceberg do NOT enforce PRIMARY KEY/UNIQUE at write time" is CORRECT (verified r27 §2031 + iter402 canonical). Option A (dbt unique + not_null tests post-build) is correct framing. **DEFECTS in Option B:** (1) **`SELECT * EXCEPT (rn) FROM deduplicated`** — **INVALID Trino 467 SQL**. Parse error: Trino's `EXCEPT` is a SET operator between queries (per [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html)), NOT a column-exclusion projection. Open feature requests [trinodb/trino#26402](https://github.com/trinodb/trino/issues/26402) + [#26969](https://github.com/trinodb/trino/issues/26969) confirm still NOT implemented. This is the **2nd UNPROMPTED/GENERATIVE instance in 3 iters** (iter1130 Q2 first generative; iter1131 Q1 correctly answered NO when ASKED DIRECTLY; iter1132 Q4 generates it AGAIN while writing a dbt model). (2) **`{% if execute %}`** — **WRONG jinja guard** for dbt incremental-filter. `execute` is True during both `parse` AND `run` phases (so the filter applies even on first-build, which is wrong) — the canonical guard for incremental-only delta is `{% if is_incremental() %}` (true only when target exists AND not `--full-refresh` AND model configured incremental). Verified [docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models) + r27 §3.3/§1809/§1885 + r28 §165 + §189 ("`{% if is_incremental() %}` — NEVER `{% if execute %}`"). The ROW_NUMBER + WHERE rn=1 dedup core is correct, but the two surrounding errors break the model. |
| Beginner clarity | 4.5 | Structure clear (Option A tests vs Option B merge-dedup model). |
| Practical applicability | 2.5 | Engineer pastes the dbt model and hits two errors: (a) Trino parse error on `SELECT * EXCEPT (rn)`; (b) silent semantic bug from `{% if execute %}` applying the watermark on first-build runs (model never builds the full history). |
| Completeness | 4.0 | Covers core question (Iceberg no enforcement, dbt tests, incremental dedup pattern). Misses: post-write `dbt test --select unique:user_id` as the "fail-build-if-duplicates-land" guardrail (the canonical iter402 + r27 §2031 framing). |

**Verification (SELECT-*-EXCEPT recurrence + `{% if execute %}` defect):**
- **SELECT * EXCEPT still NOT supported in Trino 467**: feature requests #26402 + #26969 + #23532 all OPEN as of 2026-06-26. Trino's `EXCEPT` is documented at [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) as a SET operator only.
- **`is_incremental()` is the canonical guard, NOT `execute`** — verified r28 §165 + §189 + r27 §1885 + dbt docs.

**Defect classification:**
- **`SELECT * EXCEPT (rn)` recurrence — RESOURCE-SOURCED FINDABILITY GAP (escalated from iter1130 RESPONDER ONE-OFF).** The existing r23 §3286 defang is on the keyword path "Trino-vs-foreign-dialect dialect comparison" / "QUALIFY rewrite" — it does NOT fire when the responder is GENERATING a dbt-incremental-dedup model and reaches for "strip the helper column on the rebuilt projection". r27 §1964 Pattern B1 has the canonical EXPLICIT column list comment but does NOT have an INLINE-WRONG `SELECT * EXCEPT (rn)` defang adjacent to the explicit-column form — so the responder synthesizes the foreign-projection form without hitting the defang. **2 generative slips in 3 iters (iter1130 + iter1132)** = pattern, not noise. **LIGHT FIX-A recommended** (see below).
- **`{% if execute %}` — RESPONDER ONE-OFF** (against existing r28 §189 + r27 §1885 explicit "NEVER `{% if execute %}`" guidance). First instance. NO-OP+WATCH. Re-probe within 2-3 iters with another "dbt incremental dedup model" question to confirm one-off vs pattern.

---

## Score table

| Q | Accuracy | Clarity | Applicability | Completeness | Q avg |
|---|---|---|---|---|---|
| Q1 storage-tiering YoY 45min vs 2min | 4.0 | 4.5 | 3.5 | 3.0 | 3.7500 |
| Q2 FIRST_VALUE for partition's first row | 5.0 | 5.0 | 5.0 | 4.75 | 4.9375 |
| Q3 anonymize emails MD5/SHA-256 for GROUP BY | 2.5 | 4.5 | 2.5 | 4.0 | 3.3750 |
| Q4 Iceberg PK + dbt unique + incremental dedup | 2.5 | 4.5 | 2.5 | 4.0 | 3.3750 |

**Iter average = (3.7500 + 4.9375 + 3.3750 + 3.3750) / 4 = 3.8594 PASS** (margin to 3.5 = +0.3594, THIN — driven by Q3 + Q4 double-defect drag)

---

## SELECT-*-EXCEPT recurrence verdict — ESCALATED from RESPONDER ONE-OFF (iter1130) → RESOURCE-SOURCED FINDABILITY GAP (iter1132)

iter1130 Q2: **1st generative instance** of `SELECT * EXCEPT (rn)` on dedup CTAS rebuild → classified RESPONDER ONE-OFF, NO-OP+WATCH per first-instance discipline.

iter1131 Q1: **direct re-probe** ("does Trino support BigQuery `SELECT * EXCEPT(col)`?") → responder correctly answered NO, cited r23 §3286 defang. Watch CLOSED on first re-probe.

iter1132 Q4: **2nd generative instance** of `SELECT * EXCEPT (rn)` on dbt incremental dedup model → RECURRENCE confirmed.

**Diagnosis:** the direct-question keyword path (`Trino SELECT * EXCEPT support / column exclusion`) lands on r23 §3286 correctly. The GENERATIVE keyword path (`dbt incremental model dedup ROW_NUMBER drop helper column`) lands on r27 §1962-1972 Pattern B1 / B3 — which has the EXPLICIT column list comment ("`-- EXPLICIT column list — Iceberg has no SELECT * rename safety`") but does NOT have an INLINE-WRONG `SELECT * EXCEPT (rn)` defang directly adjacent. The responder synthesizes the foreign-projection shorthand without ever touching the r23 §3286 defang because the question keyword path doesn't include "Trino dialect" / "BigQuery shorthand" anchors.

**LIGHT FIX-A target:** add an INLINE-WRONG defang row IN r27 Pattern B1 (around line 1964) AND r27 Pattern B3 (around line 1998) where the explicit column list appears — make the explicit-column form COPY-ATTRACTIVE and tag `-- NOT: SELECT * EXCEPT (rn) -- invalid in Trino 467, see r23 §3286`. Optional: extend the same inline-defang to r13 §5266 + r13 §5465 (the dbt-incremental dedup canonicals where engineers will land when writing the same shape).

---

## Source-verified defects

| # | Defect | Q | Classification | Recommendation |
|---|---|---|---|---|
| 1 | `SELECT * EXCEPT (rn)` generative slip on dbt-incremental dedup model | Q4 | **RESOURCE-SOURCED FINDABILITY GAP** (escalated from iter1130 RESPONDER ONE-OFF; 2 generative slips in 3 iters) | **LIGHT FIX-A** in r27 §1962-1972 Pattern B1 + §1992-2003 Pattern B3: inline-WRONG defang row "`-- NOT SELECT * EXCEPT (rn) -- invalid Trino 467 parse error`" adjacent to the explicit-column-list canonical |
| 2 | `CAST(md5(to_utf8(email)) AS VARCHAR)` claimed as 32-char hex string | Q3 | **RESOURCE-SOURCED FINDABILITY GAP (partial) + RESPONDER ONE-OFF** | **LIGHT FIX-A** in r23 §PII-anonymization (NEW LEADING CANONICAL) or r05 §user-anonymization (extend existing OPA columnMask hex form to a generic "PII hash for GROUP BY" canonical): LEAD `to_hex(md5(to_utf8(email)))` + DO-NOT-WRITE row inline-WRONG `CAST(md5(...) AS VARCHAR)` ("returns raw bytes interpreted as varchar, NOT hex; either parse-fails or produces mojibake") + crc32 return-type clarification (bigint NOT varbinary) |
| 3 | `{% if execute %}` as incremental guard | Q4 | **RESPONDER ONE-OFF** (against r28 §189 + r27 §1885 explicit "NEVER `{% if execute %}`" canonical) | **NO-OP+WATCH** — first generative instance, re-probe within 2-3 iters with another "dbt incremental dedup" question |
| 4 | YoY/historical-report mitigation = pre-aggregated rollup on hot tier (MISSING) | Q1 | **RESOURCE-SOURCED COMPLETENESS GAP** in r10 / r15 storage-tiering section | **LIGHT FIX-A** in storage-tiering canonical (wherever the two-table UNION-ALL view + MinIO ILM pattern is documented): add a 3rd canonical option "HOT-tier rollup for historical reads" — pre-aggregated dbt incremental model `fct_revenue_monthly_summary` stays on hot tier; YoY query reads tiny rollup never touches cold archive. The two-table UNION-ALL view alone does NOT help a query that SPANS the cold archive. |
| 5 | Glacier RESTORE async constraint not surfaced | Q1 | **MINOR ACCURACY SHAVE** | Per-instance / sub-shave only, doesn't warrant FIX-A on its own |

**Per-instance shaves:**
- Q2 −0.25 Compl: doesn't contrast against LAST_VALUE's default-frame trap. Per-instance.

---

## Topics updated

| Topic | Before | This iter Qs | After | Change |
|---|---|---|---|---|
| Storage tiering on Trino+Iceberg+MinIO | 4.0278/9 | Q1 (3.75) | (4.0278×9 + 3.75)/10 = 40.0002/10 = **4.0000/10 PASSED** | −0.0278 (thinnest-margin topic drag) |
| Analytical-query-patterns-Iceberg+Trino | 4.4836/84 | Q2 (4.9375) | (4.4836×84 + 4.9375)/85 = 381.5599/85 = **4.4889/85 PASSED** | +0.0053 |
| SQL-best-practices-OLAP | 4.5540/192 | Q3 (3.375) | (4.5540×192 + 3.375)/193 = 877.743/193 = **4.5479/193 PASSED** | −0.0061 |
| Oracle PL/SQL → dbt + Trino SQL migration | 4.4566/112 | Q4 (3.375) | (4.4566×112 + 3.375)/113 = 502.5142/113 = **4.4470/113 PASSED** | −0.0096 |

ALL required topics REMAIN PASSED. Storage-tiering DROPS slightly (4.0278 → 4.0000), still well above 3.5 standard threshold. Margin watch: storage-tiering now has the thinnest margin (+0.5000), Oracle-migration −0.0096 drag, SQL-best-practices-OLAP −0.0061 drag from Q3 hashing slip.

---

## Recurrence audit

- **SELECT * EXCEPT generative slip — RECURRENCE CONFIRMED** (iter1130 + iter1132; 2 in 3 iters); watch ESCALATED to LIGHT FIX-A.
- All other pinned defect families clean: ::/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/CAST-truncate/EXECUTE-rollback-on-467/Spark-Oracle-spillover/imported-prior/GREATEST-NULL-Postgres/array_sum/`->`-JSON/DATEDIFF-dialect-import/multi-arg-COUNT-DISTINCT/ts-minus-ts/over-warning/multi-clause-ADD-COLUMN/contains_sequence-array_position-arithmetic/partition-column-COUNT-data-file-folklore/population-vs-per-group-percentile/dedup-tied-tuple — no recurrence.
- **NEW WATCH STREAM:** `CAST(varbinary AS VARCHAR)` for hex-string claim (Q3) + `{% if execute %}` as incremental guard (Q4) — both LIGHT FIX-A / NO-OP+WATCH classifications.

---

## Thinnest-margin order after iter1132

1. **storage-tiering 4.0000/10 (+0.5000, NEW thinnest required-topic)** — Q1 drag took the top spot from 4.0278 → 4.0000
2. dbt-snapshots SCD2 4.1526/16 (+0.6526)
3. query-perf-basics 4.1771/23 (+0.6771)
4. cost-considerations 4.2759/22 (+0.7759)
5. query-perf-regression-diagnosis 4.3108/20 (+0.8108)
6. Oracle-migration 4.4470/113 (+0.9470, Q4 drag)
7. federation 4.5024/312 (untouched, fragile-PASS preserved)
8. SQL-best-practices-OLAP 4.5479/193 (+1.0479, Q3 drag)
9. CBO/ANALYZE 4.6105/22 (untouched)

---

## Teacher guidance — RECOMMENDATION = LIGHT FIX-A (TWO surgical edits)

### FIX-A1 — close the SELECT-*-EXCEPT generative gap at the dedup-rebuild keyword path (r27)

**Target:** r27 §1962-1972 Pattern B1 (CTAS + rename) AND §1992-2003 Pattern B3 (DELETE by unique row id).

**Edit shape (Pattern B1):**
```sql
-- Pattern B1 — CTAS + atomic rename (preferred for full-table dedup):
CREATE TABLE iceberg.analytics.t_dedup AS
SELECT customer_id, created_at, amount  -- EXPLICIT column list — Iceberg has no SELECT * rename safety
                                         -- NOT `SELECT * EXCEPT (rn)` — invalid in Trino 467 (parse error)
                                         -- see r23 §3286 (BigQuery/Databricks shorthand, not implemented; #26402/#26969)
FROM (...) WHERE rn = 1;
```

Mirror the same inline-WRONG comment in Pattern B3 right above the SELECT line. Optional: add a 1-row DO-NOT-WRITE table entry adjacent ("WRONG: `SELECT * EXCEPT (rn) FROM (...)` — parse error in Trino 467; RIGHT: spell out columns explicitly").

**Why this placement:** the responder's GENERATIVE keyword path is "dbt incremental dedup ROW_NUMBER drop helper rn" — that lands on r27 Pattern B1/B3, NOT on r23 §3286 (which is the dialect-comparison page). Adding the defang AT the generation point closes the findability gap.

### FIX-A2 — add a PII-hash-for-GROUP-BY LEAD canonical (r23 OR r05 extension)

**Target:** either r23 §SQL-best-practices PII section OR extend r05 §995 OPA columnMask `to_hex(sha256(to_utf8(email)))` form into a section-level LEAD canonical for "anonymize emails / PII for GROUP BY / JOIN".

**Edit shape (LEAD canonical):**
```sql
-- ✅ COPY THIS — PII hashing for GROUP BY / JOIN (32-char hex string)
SELECT to_hex(md5(to_utf8(email))) AS email_hash,  -- 32-char UPPERCASE hex VARCHAR
       COUNT(*) AS event_count
FROM iceberg.analytics.events
GROUP BY 1;

-- (Use sha256 for stronger collision resistance; 64-char hex:
--  to_hex(sha256(to_utf8(email))) — same shape)
```

**Inline DO-NOT-WRITE row:**
| WRONG | Why | RIGHT |
|---|---|---|
| `CAST(md5(to_utf8(email)) AS VARCHAR)` claimed as 32-char hex | **Trino 467 CAST(varbinary AS varchar) does NOT produce hex** — either parse-fails or returns raw bytes as mojibake VARCHAR (length 16, not 32; cross-engine GROUP BY/JOIN breaks) | `to_hex(md5(to_utf8(email)))` (returns 32-char uppercase hex VARCHAR) |
| `crc32(...) returns varbinary` | **WRONG** — `crc32(binary) → bigint` (not varbinary). md5/sha256/sha1 DO return varbinary; crc32 alone is bigint. | For bucketing: `CAST(crc32(to_utf8(email)) % 100 AS INTEGER)` (the bigint return is exactly why `% 100` works on the raw return) |

**Optional addition:** salt/pepper note — raw `md5(email)` is rainbow-table-trivially-reversible for the email-domain space (~10^9 entries); for stronger anonymization use `to_hex(sha256(to_utf8(concat(secret_salt, email))))` with `secret_salt` from k8s secret.

### NO-OP on Q4 `{% if execute %}` slip

First generative instance; r28 §189 + r27 §1885 already explicitly forbid it. Re-probe within 2-3 iters to confirm one-off (re-probe queue item: "dbt incremental dedup model that pulls only new rows since the last build" — must FORCE the incremental-guard choice).

### NO-OP on Q1 storage-tiering rollup-on-hot — DEFER to a separate FIX-A iteration

The "pre-aggregated rollup on hot tier" canonical IS missing from the storage-tiering section, but adding it is a >100-line architectural canonical (worked dbt model + tier-routing strategy). DEFER to a dedicated storage-tiering-FIX-A iter (this is the 10th angle and the topic is at the thinnest margin; one targeted edit suffices). For this iter, accept the Q1 3.75 score; queue as FIX-A3 candidate for next iter.

---

## Re-probe queue (post-iter1132)

1. **`{% if execute %}` GENERATIVE re-probe** (PRIORITY 1, NEW WATCH) — "write a dbt incremental dedup model on customer_profiles" or "the dbt-trino incremental filter syntax for new rows since last build" — must force the jinja guard generation
2. **`CAST(md5(...) AS VARCHAR)` GENERATIVE re-probe** — after FIX-A2 reaches, "anonymize user emails before writing to the reporting table" / "hash PII for analytics dashboards" framing
3. **`SELECT * EXCEPT (rn)` GENERATIVE re-probe — 3rd instance check** — after FIX-A1 reaches, another dedup-rebuild-strip-helper-column question on a DIFFERENT domain (e.g., "rebuild fct_orders deduping by order_id keeping latest" — must force the projection-rebuild choice)
4. **Storage-tiering 11th angle: pre-aggregated rollup framing** (PRIORITY 2, thinnest margin) — "I have raw event data going back 3 years; my YoY dashboards run forever pulling cold data — how do I make this fast without keeping everything hot?" (forces the rollup-on-hot mitigation answer)
5. dbt-snapshots-SCD2 17th angle (`check_cols` / `hard_deletes='new_record'`)
6. cost-considerations 23rd angle (`$manifests` partition-cost attribution)
7. query-perf-regression-diagnosis 21st angle

---

## Pattern observation

15-iter sustainment band shape:
- STRONG PASS: iters 1090/1092/1093/1117/1118/1119/1121/1122/1125/1127/1128/1131
- LIGHT FIX-A reaching cleanly: iters 1091/1116/1124/1129/**1132**
- NO-OP+WATCH (all CLOSED on first re-probe): iters 1120/1123/1126/1130

iter1132 3.8594 PASS+LIGHT-FIX-A breaks the 4.0+ STRONG-PASS streak (last 5 iters all 4.5+). The break is informative not concerning: Q3 + Q4 surface RECURRENT generative habits that the existing defang locations don't reach. iter1130 Q2 SELECT-*-EXCEPT was correctly classified as ONE-OFF per first-instance NO-OP discipline; iter1132 Q4 RECURRENCE escalates it to a resource-sourced findability gap precisely as the iter1130 LIGHT-FIX-A threshold ("if RECURS → LIGHT FIX-A at r27 §1962-1972") prescribed. Q3 hashing canonical surfaces a NEW resource-sourced findability gap on the PII-anonymization-for-reporting keyword path — the canonical hex-hash form exists in r05/r07/r27 but not on the responder's question-keyword path. Q2 reaffirms FIRST_VALUE default-frame safety canonical clean. Q1 storage-tiering surfaces a COMPLETENESS gap on the "hot rollup for historical reads" mitigation that the two-table UNION-ALL view + MinIO ILM canonicals don't surface — deferred to a dedicated next-iter FIX-A.

**Bottom line:** two surgical FIX-A edits (SELECT-*-EXCEPT defang in r27 dedup patterns + PII-hash-for-GROUP-BY LEAD canonical) close the two RESOURCE-SOURCED findability gaps surfaced this iter; one NO-OP+WATCH (Q4 `{% if execute %}`) and one DEFERRED FIX-A (Q1 hot-rollup storage-tiering) round out the action items.

---

## Sources verified

- [Trino 467 Binary functions and operators](https://trino.io/docs/current/functions/binary.html) — md5/sha256→varbinary, crc32→bigint, to_hex→varchar
- [Trino 467 Window functions](https://trino.io/docs/current/functions/window.html) — FIRST_VALUE / LAST_VALUE default-frame semantics
- [Trino 467 SELECT documentation](https://trino.io/docs/current/sql/select.html) — EXCEPT as set operator (not column-exclusion projection)
- [trinodb/trino#26402 — Feature Request: Support SELECT * EXCEPT](https://github.com/trinodb/trino/issues/26402)
- [trinodb/trino#26969 — Support SELECT * EXCEPT / EXCLUDE](https://github.com/trinodb/trino/issues/26969)
- [trinodb/trino#23682 — Varbinary bit manipulations](https://github.com/trinodb/trino/issues/23682) (varbinary→varchar conversion underdocumented; to_hex is the standard form)
- [trinodb/trino discussion#17696 — Data masking varbinary](https://github.com/trinodb/trino/discussions/17696) — `cast(to_hex(md5(to_utf8(id))) as varchar(32))` pattern (CAST outside to_hex, NOT on raw varbinary)
- [dbt docs — Incremental models](https://docs.getdbt.com/docs/build/incremental-models) — `is_incremental()` canonical guard
- [Trino Iceberg connector](https://trino.io/docs/current/connector/iceberg.html) — no per-partition tier DDL
- [MinIO Object Lifecycle Management](https://min.io/docs/minio/linux/administration/object-management/object-lifecycle-management.html) — `mc ilm tier add` ops-layer tiering

# Judge Feedback — Iteration 460

**Phase**: extended (end-of-iteration feedback only)
**Date**: 2026-06-05
**Overall**: 4.6875 STRONG PASS (59th consecutive extended-phase PASS)
**Federation probed**: NO — 4.49944/310 row unchanged per directive

---

## Per-question scores

### Q1 — Oracle vs Trino NULLS-default in ORDER BY ... DESC (NULLS-default RE-PROBE from iter459 Q4)

**Topic**: Oracle PL/SQL → dbt + Trino SQL migration
**Score**: Accuracy 4.75 / Completeness 5.0 / Clarity 5.0 / Actionability 5.0 → **avg 4.9375 STRONG PASS**

Responder said Oracle places NULLs at TOP on `ORDER BY x DESC` by default; Trino places NULLs at BOTTOM by default regardless of direction; fix = `ORDER BY last_login DESC NULLS FIRST` to restore Oracle behavior.

**iter459 Q4 cross-dialect-spillover fab FULLY RESOLVED on the first re-probe.** Responder explicitly states Trino default = NULLS LAST regardless of direction, exactly matching the verbatim Trino docs quote: "The default null ordering is NULLS LAST, regardless of the ordering direction." (trino.io/docs/current/sql/select.html). Did NOT claim Trino defaults NULLS FIRST for DESC. NULLS-default streak status: **1 PASS post-fix; needs another angle at iter462+ to lock it in (re-probe on the exact same phrasing only proves the literal phrasing is fixed, not the broader concept).**

**Minor imprecision (-0.25 accuracy)**: responder said "Trino (and standard SQL)" places NULLs at BOTTOM by default — ANSI SQL actually leaves NULLS-default *implementation-defined* per ISO/IEC 9075 and Oracle's own docs. Not a load-bearing fab (responder is binding Trino's behavior, not making an actionable ANSI claim) but a tiny imprecision worth correcting in the resource.

### Q2 — Iceberg snapshot storage cost + cleanup

**Topic**: Iceberg table maintenance
**Score**: Accuracy 4.75 / Completeness 4.75 / Clarity 4.5 / Actionability 4.5 → **avg 4.625 STRONG PASS**

All verified:
- `"events$snapshots"` metadata table real (trino.io/docs/current/connector/iceberg.html).
- `summary['added-files-size']` key verified per Iceberg spec (`added-files-size` is the documented snapshot summary key for bytes of added files; NOT `added-data-files-size` which doesn't exist).
- `EXECUTE expire_snapshots(retention_threshold => '30d')` syntax verified.
- "Trino 467 expire_snapshots has NO dry_run (Spark does)" verified per trinodb/trino issue #27357 — Trino's implementation supports ONLY retention_threshold; Spark's `CALL system.expire_snapshots(table, ..., dry_run)` supports dry_run.
- Branches/tags protect referenced files verified per iceberg.apache.org/docs/latest/maintenance/.
- CoW 100-300% rewrite-volume range plausible.

Zero fabrications.

### Q3 — Iceberg storage sizing for 50GB raw CSV

**Topic**: Storage sizing and growth estimation for lakehouse workloads
**Score**: Accuracy 4.0 / Completeness 5.0 / Clarity 4.5 / Actionability 4.25 → **avg 4.4375 PASS**

Compression ratios all plausible (Parquet+Zstd 5-10x typical, verified at jeronimo.dev / Dremio benchmarks 6.7-11x); 50GB CSV → ~7GB at 7x is a reasonable rule-of-thumb; +1-3% metadata/snapshots reasonable; `"your_table$files"` query with `file_size_in_bytes` + `record_count` verified.

**ONE MINOR INACCURACY (dimensionally-wrong formula)**: responder wrote a "rough formula" `On-disk Iceberg size ≈ (raw bytes × row count) ÷ compression ratio`. This is dimensionally wrong — `raw_bytes` already accounts for the total CSV size, so multiplying by `row_count` double-counts. The correct formula is:

```
on_disk_iceberg_size ≈ raw_bytes ÷ compression_ratio
                     # or equivalently:
                     # avg_row_bytes × row_count ÷ compression_ratio
```

The worked example (50GB / 7x ≈ 7GB) uses the correct math, so the formula is more typo than load-bearing fab — but an engineer who plugs `(50GB × 100M rows) ÷ 7` into the formula gets nonsense (~700 PB instead of 7 GB). Accuracy docked 1 point; verdict is still a comfortable PASS.

### Q4 — dbt incremental — how does it know what's new

**Topic**: Postgres-to-Iceberg ingestion (dbt incremental angle)
**Score**: Accuracy 5.0 / Completeness 4.75 / Clarity 4.75 / Actionability 4.5 → **avg 4.75 STRONG PASS**

All carry-forward dbt-trino fixes hold:
- `{% if is_incremental() %}` (NOT `is_incremental` without parens, NOT `execute`).
- `properties={'partitioned_by': "ARRAY['day(occurred_at)']"}` (NOT top-level `partitioning`).
- Subquery-wrapped `(SELECT COALESCE(MAX(occurred_at), TIMESTAMP '1970-01-01') FROM {{ this }})` (NOT bare MAX).
- `incremental_strategy='merge'` + `unique_key='event_id'` combo.
- `is_incremental()` TRUE only when table exists AND not full-refresh AND materialization=incremental (verified per docs.getdbt.com/docs/build/incremental-models).
- First-run full CTAS vs subsequent MERGE accurate per dbt-trino adapter behavior.

Zero fabrications.

---

## Fabrications / inaccuracies (full list)

| # | Question | Severity | Issue | Correct fact | Source |
|---|---|---|---|---|---|
| 1 | Q1 | **MINOR imprecision** | Said "Trino (and standard SQL)" defaults NULLs LAST | ANSI SQL leaves NULLS-default *implementation-defined*; only Trino is bound to NULLS LAST | ISO/IEC 9075; docs.oracle.com (Oracle's own docs note ANSI doesn't pin the default) |
| 2 | Q3 | **MINOR inaccuracy** | "Rough formula" `(raw bytes × row count) ÷ compression ratio` is dimensionally wrong (double-counts) | `raw_bytes ÷ compression_ratio` (or `avg_row_bytes × row_count ÷ compression_ratio`) | Basic dimensional analysis; the worked example in the same answer uses the correct math |

**No fabricated PR#/issue#/function/property/column/DDL-clause/version-gated feature/spillover this iteration.** Citation-hygiene streak RESTORED after iter459 Q4 NULLS-default cross-dialect-spillover fab.

---

## NULLS-default streak status

**1 PASS post-fix (iter460 Q1).** The iter459 Q4 cross-dialect-spillover fab ("Trino defaults NULLS LAST for ASC and NULLS FIRST for DESC" — Oracle's rule projected onto Trino) was fully resolved on the first re-probe. Responder verbatim states "Trino places NULLs at BOTTOM by default regardless of direction" which matches the trino.io/docs verbatim quote.

**BUT**: a same-phrasing re-probe only proves the literal phrasing is fixed. To confirm the broader NULLS-default concept is locked in, **probe again at iter462+ from a different angle** — e.g.:
- Window-function angle: `ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY login_ts DESC)` — how does row 1 differ between Oracle and Trino when login_ts has NULLs?
- DISTINCT ON-style top-N angle: `SELECT * FROM events ORDER BY event_ts DESC LIMIT 1` — does Trino return a NULL-event_ts row before a non-NULL one?
- Migration audit angle: "We have 200 legacy Oracle queries with `ORDER BY ... DESC`. What's the grep-and-rewrite checklist?"

If iter462+ holds on a different angle, the NULLS-default sub-fab class is closed.

---

## Teacher actions for iter461

### MUST-FIX

1. **Fix the storage-sizing formula in r15 (or wherever the responder pulled it from).** Grep for `raw bytes × row count` and `raw_bytes × row_count` (or any "× row_count" inside a compression-formula context) in `resources/15-storage-sizing-growth-estimation.md` and adjacent files. Replace the dimensionally-wrong formula with:

   ```
   on_disk_iceberg_size ≈ raw_bytes ÷ compression_ratio
   ```

   Add a DO-NOT-WRITE row to the resource banning the `(raw bytes × row count) ÷ compression ratio` phrasing (and the symmetric `bytes_per_row ÷ compression_ratio` without `× row_count` mistake on the other side). Include a worked example that walks the formula end-to-end (50GB CSV ÷ 7x ≈ 7GB Iceberg) so the responder copies the worked math not the wrong formula text.

2. **Tighten the Q1 ANSI-SQL aside in r27.** The iter460 LEADING CANONICAL block in r27 already says "ANSI SQL leaves the NULLS-default implementation-defined" — verify that line survived the responder's keyword path and consider promoting it to a named callout so the responder doesn't paraphrase it as "Trino (and standard SQL)" defaults NULLS LAST. Add a one-line DO-NOT-WRITE: "Do not write 'Trino and standard SQL both default NULLS LAST' — ANSI is implementation-defined; only Trino's docs are binding here."

### BREADTH DESIGN — iter461 question rotation

3. **NULLS-default RE-RE-PROBE on a different angle.** Schedule a Q1 or Q4 slot at iter462 (NOT iter461 — one iteration off so the re-probe isn't a verbatim memory test) on a different NULLS-default angle (window function, top-N, or migration audit — see streak section above). At iter461, give the NULLS-default sub-fab a one-iteration rest so other Oracle migration content can be tested.

4. **Pick a non-NULLS Oracle migration angle for iter461.** The Oracle PL/SQL→dbt/Trino migration topic just landed a 4.9375 at the NULLS angle but has many other surfaces. Suggested rotation:
   - Oracle sequences → Trino (no native sequences; UUID / `row_number()` / monotonically-increasing strategies).
   - NVL / NVL2 / DECODE → COALESCE / IF / CASE.
   - ROWNUM / `WHERE ROWNUM <= 10` → `LIMIT 10` (and the subtle ROWNUM-before-ORDER-BY pitfall).
   - PL/SQL cursor loop → set-based dbt incremental.
   - `CONNECT BY PRIOR` hierarchical query → recursive CTE (`WITH RECURSIVE`).

5. **Storage sizing follow-up at iter461.** After fixing the formula in r15, probe storage sizing once more (different question — e.g., "we have a 200M-row Postgres `events` table averaging 480 bytes/row; estimate Iceberg size and growth at 5M rows/day") to confirm the responder uses the correct formula post-fix. Don't probe it twice in a row though — alternate with another sizing-adjacent topic (cost attribution, partition design).

6. **Mid-tier rotation.** Keep cost considerations / query-perf-regression / multi-tenant warm — they all have 14-18 question populations and avg scores 4.20-4.46 (lower buffer than the 4.6+ topics). One slot at iter461 should be in this band.

7. **Federation NOT probed at iter461** unless a specific bulletproofed angle emerges. The 4.49944/310 near-miss row is structurally trapped on a thin margin; a generic federation probe is more likely to drag it below 4.5 than push it above.

### Risk watchlist for iter461

- **Same-phrasing re-probes proving "fix" when only the literal phrasing is fixed.** iter460 Q1 NULLS-default is at risk of this — the iter459 Q4 and iter460 Q1 question phrasings were both close to the verbatim NULLS-default surface. Need a different angle to truly close the fab class.
- **Dimensionally-wrong "rough formula" pattern.** Worth a grep across all resources for `bytes × .* count|count × .* bytes|rows × .* bytes|bytes × .* rows` to catch other formulas that may have the same double-count typo elsewhere (sizing, cardinality estimation, partition-size estimation).
- **Version-pin spillover and cross-dialect-spillover** fab classes remain the dominant FAIL-mode pattern. Neither was triggered in iter460, but the iter458-459 streak shows they re-emerge under different surface keywords. Keep the §4.4B consolidated spillover table in r27 and the version-pin table in r17 healthy; do not let them go stale across iterations.

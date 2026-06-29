# Judge feedback — iteration 1261

**Phase**: extended (continuous PASS loop)
**Iter avg**: **4.594 PASS** (Q1 4.6875 / Q2 4.875 / Q3 3.875 / Q4 4.9375)
**Prior iter**: 1260 = 4.516 PASS NO-OP
**State**: passed=true, all required topics PASSED
**Verdict**: PASS with one notable completeness gap (Q3 --defer omission)

---

## Per-question scores

### Q1 — Iceberg target-file-size at WRITE time (Spark backfill, 8-12MB tiny files): **4.6875 STRONG PASS**

**Topic routing**: Iceberg partition design for SaaS — strategies, small-files, compaction (row 4.4185/64 → 4.4226/65, +0.0041).

**Scores**: Acc 4.75 / Clar 4.5 / Prac 5.0 / Compl 4.5.

**What landed correct (verified)**:
- **Spark side**: respects Iceberg table property `write.target-file-size-bytes` via TBLPROPERTIES at CREATE or ALTER SET TBLPROPERTIES. Correct.
- **Trino 467 side**: Trino 467 does NOT recognize `write.target-file-size-bytes` as a connector table property — verified via WebFetch of [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html), the Iceberg connector Table-properties allow-list is `format / partitioning / sorted_by / location / format_version / orc_bloom_filter_columns / orc_bloom_filter_fpp / parquet_bloom_filter_columns / object_store_layout_enabled / data_location / extra_properties`. **`write.target-file-size-bytes` is absent.**
- Trino uses its own SESSION property `iceberg.target_max_file_size` (catalog-namespaced), backed by catalog config `iceberg.target-max-file-size` default `1GB` — verified verbatim in docs. `SET SESSION iceberg.target_max_file_size = '128MB'; INSERT ...` is the canonical Trino write-time form.
- Spark CREATE example correctly labeled as Spark syntax (TBLPROPERTIES, `USING iceberg`).
- **Retroactive fix**: correctly framed as future-writes-only — existing tiny files require Trino `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '128MB')` or Spark `CALL rewrite_data_files`.

**Verdict on the Spark-vs-Trino write-config split**: CORRECT. The responder accurately routed the engineer to the right config for whichever engine is writing.

**Minor shaves**:
- Compl -0.5: did not surface that on this on-prem k8s stack, `iceberg.target-max-file-size=128MB` could be baked into `etc/catalog/iceberg.properties` (the ConfigMap) so every Trino write picks it up without per-session opt-in.
- Clar -0.5: the cited "issue #28250" attribution was incidental and unverified — the load-bearing behavior is documented in the catalog config + table-property allow-list directly.

**No FIX-A, no new watch.**

---

### Q2 — NTILE(4) quartile split, auto-adapting: **4.875 STRONG PASS**

**Topic routing**: Analytical query patterns on Iceberg+Trino — funnels, cohorts, time-series SQL (row 4.5119/187 → 4.5138/188, +0.0019).

**Scores**: Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75.

**What landed correct (verified)**:
- `NTILE(4) OVER (ORDER BY SUM(event_count) DESC) AS quartile` inside a CTE that GROUPS BY `account_id` with a last-month date predicate.
- Quartile 1 = top 25%, 4 = bottom; flip with `ASC` if needed.
- **Verified at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html)** verbatim: `ntile(n) → bigint` "Divides the rows for each window partition into `n` buckets ranging from `1` to at most `n`. Bucket values will differ by at most `1`." Worked example "with `6` rows and `4` buckets, the bucket values would be `1 1 2 2 3 4`."
- For 15,000 accounts / 4 = 3,750 per bucket evenly (no remainder edge case).
- "Auto-adapting" semantics correct: each query recomputes NTILE thresholds from the current data — no hardcoded CASE WHEN constants in the SQL.
- NTILE used after GROUP BY is legal (window functions evaluated after grouping).
- Date-window `event_date >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1' month` is valid Trino 467 dialect.

**Minor shave**:
- Clar -0.25: "auto-adapting" mechanism could be one sentence more explicit ("each NTILE call computes its thresholds from the current row distribution; no constants appear in the SQL, so the same query keeps working as event counts shift month-to-month").

**No FIX-A, no new watch.**

---

### Q3 — dbt slim CI (--state, --defer, state:modified+): **3.875 PASS-with-COMPLETENESS-GAP**

**Topic routing**: Improving complex SQL performance on Trino with dbt (row 4.4802/75 → 4.4722/76, -0.0080).

**Scores**: Acc 4.5 / Clar 4.5 / Prac 3.5 / Compl 3.0.

**What landed correct (verified)**:
- **State artifact = `manifest.json`** from a prior PROD run (model SQL hashes, source defs, tests, DAG). Verified at [docs.getdbt.com/reference/node-selection/state-comparison-caveats](https://docs.getdbt.com/reference/node-selection/state-comparison-caveats).
- Workflow correct: prod `dbt build` writes `target/manifest.json` → store in S3/MinIO/git → PR CI fetches it → `dbt build --select state:modified+ --state <dir>` → dbt diffs current parse vs saved manifest → builds modified + downstream `+`.
- `state:modified+` semantics correct (modified resources + all downstream descendants via trailing `+`).
- GitHub Actions workflow example with `aws s3 cp manifest.json`, dbt invocation, re-save after merge — production-aligned for the on-prem MinIO stack (responder correctly mentioned MinIO as an option).
- "dbt does not auto-publish state; you fetch/save manually" — correct.

**THE GAP — `--defer` was not explained**:

The engineer's prompt literally lists "`--defer` / `--state`" as part of the explicit ask, and asked "how does CI know prod?" — that second half is precisely what `--defer` answers, and the responder skipped it entirely.

**Why this matters**:
- **Verified at [docs.getdbt.com/reference/node-selection/defer](https://docs.getdbt.com/reference/node-selection/defer)**: `--defer` resolves unselected `ref()` calls to the **production relations** named in the deferred manifest, so PR CI does NOT have to rebuild upstream models the PR didn't touch.
- Without `--defer`, a PR that modifies a leaf model with `state:modified+` would either hit `Table 'dev_pr_123.upstream_model' does not exist` errors (upstreams were never built in the PR schema) OR be forced to rebuild upstreams anyway — defeating the whole slim-CI optimization.
- Canonical slim-CI command shape: `dbt build --select state:modified+ --defer --state ./prod-artifacts` — the responder gave `dbt build --select state:modified+ --state .` (missing `--defer`).

**Resource findability check** (grep of `resources/`):
- `--defer` → ZERO hits in resources/.
- `slim CI` → ONE hit (r27 §3870 selector-methods aside listing `state:modified` with `--state target/`).
- "DEFERRED manifest" → ONE passing cross-ref at r27 §3912.

There is no copy-attractive slim-CI canonical with the full `--select state:modified+ --defer --state` shape anywhere in resources/. This is a real content findability gap — but per the no-churn-on-first-occurrence rule (`feedback_synthesis_ceiling_stop_churning.md` + `feedback_new_card_over_attracts_adjacent.md`), no FIX-A this iter.

**NEW SOFT WATCH `iter1261 Q3 dbt slim-CI --defer-omission resource findability gap`**: re-probe 4-8 iters under varied framings (e.g. "PR CI 1hr build / state:modified+ AND --defer / how does CI know prod / dbt slim CI on Trino+MinIO" / "modifying one leaf model and CI fails finding upstream tables"). If `--defer` is omitted in 2+ recurrences under different framings, escalate to LIGHT FIX-A:
- Add a LEADING CANONICAL slim-CI block (likely r27 §6.7F or r28 dbt-CI section) with copy-attractive `dbt build --select state:modified+ --defer --state ./prod-artifacts` command.
- On-prem S3/MinIO `mc cp` artifact-store recipe (production-stack-aligned).
- One-liner: "`--defer` = resolves unselected `ref()` calls to **production** relations, so PR CI doesn't have to rebuild upstreams the PR didn't touch."

**Practical impact for the engineer**: they get `state:modified+` working but on first PR with a leaf change will hit "table does not exist" errors and need a second debugging round to discover `--defer`. The answer is core-correct but the engineer's literal ask was partially unanswered.

---

### Q4 — Oracle TO_CHAR number mask → Trino: **4.9375 STRONG PIN-PERFECT PASS**

**Topic routing**: Oracle PL/SQL → dbt + Trino SQL migration (row 4.4828/228 → 4.4848/229, +0.0020).

**Scores**: Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 5.0.

**What landed correct (verified VERBATIM against docs)**:
- `format('$%,.2f', annual_revenue)` → `'$1,234,567.89'`.
- `$` is a literal in the format string; `%,.2f` = printf comma-grouped (`,` flag) double with 2 decimal places.
- Other examples: `format('%,.2f', amount)` plain; `format('%d', n)` integer; `format('%.1f%%', pct)` percent (escaped `%%`).
- Trino `to_char` is timestamp/date only (NOT numbers) — engineer's "to_char didn't accept the mask" symptom correctly diagnosed.
- **Verified at [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html)** (WebFetched this iter): `format(format, args...) → varchar` "Returns a formatted string using the specified format string and arguments" + Java printf/Formatter syntax + docs literally show `SELECT format('%,.2f', 1234567.89); -- '1,234,567.89'` as the canonical example — **exactly the responder's recommended form**.
- Trino `to_char(timestamp, format)` is Teradata-compat datetime-only per pinned `reference_trino_to_char_exists.md` (lowercase digit-class codes only).

No imported-prior, no broken-secondary, no over-warning, no fabrication. Pin-perfect canonical match to the documented example.

**No FIX-A, no new watch.**

---

## Patterns this iter

**Strong**: Q1, Q2, Q4 all clean. Q4 was a pin-perfect verbatim-match to the Trino conversion-functions docs example. NTILE canonical landed cleanly with the right pattern (NTILE-over-aggregate inside CTE). Iceberg target-file-size answered the cross-engine write-config split correctly.

**No broken-secondary cluster recurrence** (3rd clean iter in a row on the `feedback_responder_broken_secondary_alternative.md` family).

**No over-warning folklore recurrence** (`feedback_responder_overwarning_folklore.md` family clean).

**No imported-prior slips** on dialect facts (Q1 Trino-vs-Spark config split, Q2 NTILE, Q4 format() printf).

**The single gap**: Q3 slim-CI `--defer` omission — first-occurrence, NOT a resource defect of established content (resources don't yet have a copy-attractive slim-CI canonical with `--defer` in it). Documented as soft watch only.

---

## Topic row deltas

| Q | Topic row | Before | After | Delta |
|---|---|---|---|---|
| Q1 | Iceberg partition design / small-files / compaction | 4.4185 / 64 | **4.4226 / 65** | +0.0041 |
| Q2 | Analytical query patterns on Iceberg+Trino | 4.5119 / 187 | **4.5138 / 188** | +0.0019 |
| Q3 | Improving complex SQL perf on Trino with dbt | 4.4802 / 75 | **4.4722 / 76** | -0.0080 |
| Q4 | Oracle PL/SQL → dbt + Trino SQL migration | 4.4828 / 228 | **4.4848 / 229** | +0.0020 |

All four rows remain PASSED. Iter net effect: small spread across topics with one mild dip on the dbt-perf row.

---

## Open watches inventory (carried + new)

- **NEW iter1261 Q3** dbt slim-CI `--defer`-omission resource findability gap (soft watch, re-probe 4-8 iters; LIGHT FIX-A if 2+ recurrences under different framings).
- iter1260 Q1 CDC-MERGE-multi-event-dedup (soft).
- iter1260 Q3 source-hard-delete-snapshot-routing (soft).
- iter1258 Q3 SELECT-* EXCEPT alternative-fabrication regression.
- iter1257 Q4 strpos-arithmetic.
- iter1255 Q1 bloom-CREATE-syntax.
- iter1255 Q3 INSERT-OVERWRITE-broken-secondary.
- iter1253 Q4 regexp_extract-2arg.
- iter1248 Q3 MATCH_RECOGNIZE-adjacency.
- iter1241 concat-auto-coerces.
- iter1229 @v1-Spark.

---

## Recommendations for teacher

**No FIX-A this iter**. iter1261 closes as a 4.594 PASS NO-OP for teacher purposes.

**Pre-staged note for the slim-CI watch** (do NOT write yet, only if re-probe confirms recurrence):
If Q3 framing recurs with `--defer` omitted under a second-distinct phrasing, the LIGHT FIX-A target would be a sub-block at r27 §6.7F (or insertion at r28 dbt-CI section) along these lines:

> **Slim CI (PR build = only changed models + downstream)**
> ```bash
> # In CI, after fetching prior prod manifest.json into ./prod-artifacts/
> dbt build --select state:modified+ --defer --state ./prod-artifacts
> ```
> - `--state ./prod-artifacts` → dbt reads `manifest.json` from this path to detect what changed since prod.
> - `--select state:modified+` → only modified models + their downstream descendants (trailing `+`).
> - `--defer` → unselected `ref()` calls resolve to the **prod relations** named in the deferred manifest, so PR CI does NOT rebuild upstream models it didn't touch. Without `--defer`, the PR's CI schema doesn't have those upstream tables and `dbt build` fails with "table does not exist".
> - On-prem MinIO artifact transfer: `mc cp` the `manifest.json` between the prod-run target dir and the PR-CI workspace.

---

## Closing

State.json `passed=true` remains correct. All required topics PASSED with margin. iter1261 maintains the streak. Teacher action: **NO-OP**. Re-probe-and-watch only.

Training deadline: 2026-06-30 23:59 CST (in window).

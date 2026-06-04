# Judge Feedback — Iter 466 (EXTENDED PHASE, end-of-iteration)

## Overall
- **Overall avg: 4.508 — PASS** (65th consecutive extended-phase PASS).
- **Per-question**: Q1 4.656 / Q2 4.688 / Q3 4.000 / Q4 4.688.
- **Topics probed**: dbt-sources/source-freshness, iceberg-maintenance/manifest-compaction, oracle-migration/date-arithmetic, query-perf/EXPLAIN-IO.
- **Federation**: NOT probed per directive — 4.49944/310 row unchanged.
- **Citation-hygiene streak**: INTACT for fab classes; NEW semantic-completeness watchlist item from Q3.

---

## Per-question scoring detail

### Q1 — dbt source-freshness CI-gating (no fabricated flag) — 4.656 STRONG PASS

| Dim | Score | Note |
|---|---|---|
| Accuracy | 4.875 | Correctly said NO `--check-freshness` flag exists on `dbt run`/`dbt build`. `dbt source freshness` is its own command. `dbt build` does NOT include source freshness. Verified at docs.getdbt.com/reference/commands/build (lists models + tests + snapshots + seeds + UDFs; freshness NOT mentioned) and docs.getdbt.com/reference/commands/source (separate command, non-zero exit on stale). ZERO fabrications. |
| Completeness | 4.5 | CI-gating two-step shape (a) `dbt source freshness` first, exit code halts (b) `dbt build` covered. Could have mentioned the `source_status:fresher+` opt-in selector as the alternative downstream-rebuild idiom; minor. |
| Clarity | 4.5 | Two-step CI pattern is engineer-actionable. |
| Actionability | 4.75 | Engineer can copy the CI step shape directly. |

**Fab-class verdict**: iter466 teacher r27 §6.7B DO-NOT-WRITE row banning fabricated `--check-freshness` / `--skip-stale-sources` flag LANDED on first re-probe. Topic locks at 3-question PASS (4.219/3).

### Q2 — Iceberg manifest compaction on Trino 467 — 4.688 STRONG PASS

| Dim | Score | Note |
|---|---|---|
| Accuracy | 4.875 | `EXECUTE optimize_manifests` correctly NOT-on-467 — added Trino 470 (Feb 5 2025). Verified at trino.io/docs/current/release/release-470.html. On 467 the path is Spark `CALL iceberg.system.rewrite_manifests(table => 'analytics.events')`. Verified at iceberg.apache.org/docs/latest/spark-procedures/. Correctly kept the two procedure names DIFFERENT (Trino `optimize_manifests` vs Spark `rewrite_manifests`) — the canonical version-pin guardrail. |
| Completeness | 4.625 | Manifest-bloat → slow planning diagnostic context included. |
| Clarity | 4.5 | Version-cutoff (467 vs 470) called out explicitly. |
| Actionability | 4.75 | Engineer has the exact Spark CALL form for prod 467 environment. |

**Fab-class verdict**: iter466 teacher r17 myth-table DO-NOT-WRITE row banning Trino-467 `EXECUTE optimize_manifests` LANDED on first re-probe.

### Q3 — Oracle sysdate-7 / ADD_MONTHS → Trino — 4.0 PASS (thin, semantic-completeness gap)

| Dim | Score | Note |
|---|---|---|
| Accuracy | 4.5 | What was said is correct. Both `current_timestamp + INTERVAL '-3' MONTH` AND `date_add('month', -3, current_timestamp)` verified at trino.io/docs/current/functions/datetime.html. Explicit-INTERVAL requirement is real (Trino does not implicit-cast a bare number as days). CAST AS DATE for date-only output correct. |
| Completeness | 3.0 | **CRITICAL OMISSION**: Oracle ADD_MONTHS END-OF-MONTH CLAMP rule NOT mentioned. Oracle: if input is the last day of the month, output is forced to the last day of the target month (Feb 28 non-leap → Mar 31; Jan 31 → Feb 28/29). Trino `date_add('month',...)`/INTERVAL MONTH do NOT detect last-of-month — they preserve day-number or normalize on overflow. Verified at docs.oracle.com ADD_MONTHS man + asktom.oracle.com. Engineer translating naively gets silently-wrong results on month-end data. Migration-correctness defect on a migration-specific question. |
| Clarity | 4.5 | What's present is well-explained. |
| Actionability | 4.0 | Advice works for non-month-end inputs; will silently-fail on month-end data without the warning. |

**Semantic-class verdict**: Not a fabrication (the Trino forms ARE valid) — a load-bearing migration-correctness completeness gap. NEW watchlist item.

### Q4 — EXPLAIN (TYPE IO, FORMAT JSON) for pruning verification — 4.688 STRONG PASS

| Dim | Score | Note |
|---|---|---|
| Accuracy | 4.875 | `EXPLAIN (TYPE IO, FORMAT JSON)` exists + does not execute the query verified at trino.io/docs/current/sql/explain.html. `inputTableColumnInfos[]` + `columnConstraints[]` + `domain.ranges[]` output structure verified (docs list nullsAllowed + ranges with EXACTLY/ABOVE bound descriptors). EXPLAIN ANALYZE executes (correct contrast). |
| Completeness | 4.625 | Interpretation pattern ("partition column in columnConstraints with bounds = pushdown works") is the canonical reading. |
| Clarity | 4.5 | TYPE vs FORMAT separation kept clean (did NOT conflate). |
| Actionability | 4.75 | Engineer has a safe, non-executing verification method for prod tables. |

**Fab-class verdict**: ZERO fabrications. Correctly required FORMAT JSON for TYPE IO output (TYPE IO is JSON-only).

---

## Fabrications / inaccuracies found

**None across Q1, Q2, Q4.** All three answers verify cleanly against trino.io/docs/current + docs.getdbt.com + iceberg.apache.org.

**Q3 — semantic-completeness gap (not a fabrication)**:
- Omission: Oracle ADD_MONTHS end-of-month CLAMP rule (last-day-in → last-day-out).
- Correct fact: Oracle ADD_MONTHS detects when the input day equals the last day of its month and forces the output to the last day of the target month; Trino has no equivalent built-in.
- Source: docs.oracle.com (ADD_MONTHS function reference) + asktom.oracle.com confirmation.
- Trino has `last_day_of_month(x)` (NOT Oracle's `LAST_DAY`) which is the building block for a portable wrapper.
- Source: trino.io/docs/current/functions/datetime.html.

---

## Teacher actions for iter467

### PRIMARY — add canonical Oracle ADD_MONTHS end-of-month section to r27

Add a callout block to the date-arithmetic translation section of `resources/27-oracle-plsql-to-dbt-trino.md`:

1. State the Oracle CLAMP RULE explicitly: "If the input is the last day of its month, ADD_MONTHS returns the last day of the target month, NOT the same day-number." Give two examples:
   - Oracle: `ADD_MONTHS(DATE '2026-02-28', 1)` → `2026-03-31` (Feb 28 is last-of-Feb → clamp to last-of-Mar)
   - Oracle: `ADD_MONTHS(DATE '2026-01-31', 1)` → `2026-02-28`
2. State that Trino `date_add('month', n, x)` and `+ INTERVAL 'n' MONTH` do NOT detect last-of-month — they preserve day-number or normalize on overflow. Counter-example:
   - Trino: `date_add('month', 1, DATE '2026-02-28')` → `2026-03-28` (NOT 2026-03-31 like Oracle).
3. Provide the portable wrapper pattern (verified Trino 467 syntax):
   ```sql
   CASE
     WHEN day(input) = day(last_day_of_month(input))
       THEN last_day_of_month(date_add('month', n, input))
     ELSE date_add('month', n, input)
   END
   ```
4. Add a DO-NOT-WRITE row banning the bare `date_add('month', n, x)` / `INTERVAL n MONTH` as a 1:1 Oracle ADD_MONTHS replacement.
5. Cite docs.oracle.com ADD_MONTHS + trino.io/docs/current/functions/datetime.html (`last_day_of_month`, `date_add`).

### Breadth design for iter467 (no dedicated federation probe)

Candidates for 4 non-federation angles:
- **Oracle ADD_MONTHS end-of-month re-probe** — verify the new canonical lands on first re-probe (Oracle-migration date-arithmetic angle).
- **dbt-trino incremental MERGE config** — re-test no `--check-freshness` fab persists in a different phrasing (dbt-sources/source-freshness adjacent).
- **Iceberg `rewrite_position_delete_files` Spark-vs-Trino split** — table-maintenance / EXECUTE-vs-CALL boundary re-test.
- **EXPLAIN ANALYZE `physicalInputDataSize` vs EXPLAIN (TYPE IO) IO trade-off** — query-perf / EXPLAIN angle, contrast executing-vs-not.

### NO dedicated federation probe

The 4.49944/310 row sits 0.0006 below the 4.5 raised threshold. Thin probe in either direction locks or breaks the row. Hold.

### Citation-hygiene watchlist for iter467

- **Fabricated Trino `LAST_DAY` function** — Trino has `last_day_of_month`, NOT Oracle/MySQL's bare `LAST_DAY`. Watch for cross-dialect spillover.
- **Fabricated `MONTHS_BETWEEN`** — Trino has `date_diff('month', a, b)`, NOT Oracle's `MONTHS_BETWEEN` (which returns a fractional month count, a subtle behavior difference even when the name is mapped).
- **Fabricated dbt-trino-specific freshness flag** — `--check-freshness` / `--skip-stale-sources` still banned; watch any phrasing of "block downstream on stale" that invents flag-based gating instead of the two-step CI shape.
- **Fabricated Trino `optimize_manifests` on 467** — version-pin ban must hold across re-phrasings.
- **Fabricated EXPLAIN TYPE/FORMAT combinations** — FORMAT JSON is the only valid format for TYPE IO; TYPE LOGICAL is deprecated; do not invent TYPE IO with FORMAT TEXT.

---

## Score history note

- dbt-sources/source-freshness: 4.0/2 → **4.219/3** (PASSED, now 3-angle confirmed)
- Iceberg table maintenance: 4.4874/127 → **4.4889/128**
- Oracle PL/SQL → dbt/Trino migration: 4.5896/39 → **4.5749/40** (Q3 4.0 below topic avg dragged but still PASSED comfortably)
- SQL query best practices / EXPLAIN: 4.5734/42 → **4.5761/43**
- Federation: 4.49944/310 (unchanged, NOT probed)

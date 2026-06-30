# Judge Feedback — Iteration 1291

**Overall: 4.828 — STRONG PASS. iter1288-Q1 COUNT(*)-slow HARD WATCH CLOSES (FIX-A REACHED on 1st re-probe with explicit canonical citation).**

| Q | Score | Acc | Clar | Prac | Compl | Topic | Result |
|---|---|---|---|---|---|---|---|
| Q1 (COUNT(*) slow re-probe) | **4.875** | 5.0 | 4.75 | 5.0 | 4.75 | Iceberg table maintenance | iter1288 FIX-A REACHED, WATCH CLOSES |
| Q2 (NTILE quartiles) | **4.875** | 5.0 | 4.75 | 5.0 | 4.75 | Analytical query patterns | Clean |
| Q3 (dbt vars) | **4.8125** | 5.0 | 4.75 | 5.0 | 4.5 | Oracle PL/SQL → dbt+Trino | Clean |
| Q4 (Oracle COUNT(col) NULL) | **4.75** | 5.0 | 4.75 | 4.75 | 4.5 | Oracle PL/SQL → dbt+Trino | Clean (resisted false-divergence trap) |

Average: (4.875 + 4.875 + 4.8125 + 4.75) / 4 = **4.828**

---

## Q1 — COUNT(*) slow MoR/MERGE re-probe — **iter1288 FIX-A REACHED, HARD WATCH CLOSES**

Responder fully inverted the iter1288 FAIL. Verified:

- **"Plain COUNT(*) is normally metadata-only (sums record_count from manifests)"** — CORRECT. Trino Iceberg connector executes COUNT(*) with no predicate as a manifest-sum operation, returning instantly on clean v2 tables.
- **"Once position-delete files exist, Trino can't trust raw counts, must open data files + apply deletes"** — CORRECT per [trinodb/trino#13092](https://github.com/trinodb/trino/issues/13092) (DeleteFilter re-opens delete files per page, slow scales with delete-file count) and [#17114](https://github.com/trinodb/trino/issues/17114).
- **Diagnostic `$files GROUP BY content`** — CORRECT (content=0 data, content=1 position deletes, content=2 equality deletes).
- **Fix: `EXECUTE optimize(file_size_threshold => '512MB')` + `expire_snapshots(retention_threshold => '7d')`** — CORRECT per pinned `reference_trino_optimize_clears_position_deletes` (raise threshold above already-large delete-bearing files to force-clear; default 100MB; see [trinodb/trino#12617](https://github.com/trinodb/trino/issues/12617) + [#24086](https://github.com/trinodb/trino/issues/24086)).
- **Did NOT recommend approx_distinct for a row count** — this was the iter1288 broken recommendation; now correctly absent.
- **Cited r18 §"Why is my SELECT COUNT(*) slow on Iceberg?"** by name — the new FIX-A canonical anchored cleanly.

**Outcome: iter1288-Q1 HARD WATCH CLOSES.** Inverted fact + broken approx_distinct both gone; canonical findability confirmed by name-citation. Same pattern as iter1272 bloom-CREATE close (FIX-A REACHED on 1st re-probe with explicit canonical citation).

Tiny Compl shave (-0.25): didn't mention that **MERGE-via-dbt on Iceberg defaults to MoR position-deletes** so the rate of accumulation is proportional to the number of incremental dbt runs — useful framing for "how often should we optimize?" follow-up. Tiny Clar shave (-0.25): "Trino can't trust raw counts" anthropomorphizes; the mechanism is that position-delete files reduce logical row count below the manifest sum and the connector falls back to a regular scan to apply deletes.

No imported-prior, no broken-secondary, no over-warning, no fabrication.

---

## Q2 — NTILE(4) quartiles — clean

Verified facts:

- **`NTILE(4) OVER (ORDER BY ... DESC)` in subquery** — CORRECT.
- **"Remainder rows go to EARLIEST buckets (95 → 24/24/24/23)"** — CORRECT per [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html): "If the number of rows in the partition does not divide evenly into the number of buckets, then the remainder values are distributed one per bucket, starting with the first bucket."
- **"Window fns can't go in WHERE; no QUALIFY in Trino 467 → wrap in CTE/subquery"** — CORRECT (pinned reference).
- **"Ties arbitrary → add tiebreaker `ORDER BY SUM(order_total) DESC, account_id`"** — CORRECT. NTILE explicitly ignores ties (creates evenly-sized buckets even if same value lands in different buckets); without a deterministic tiebreaker, two accounts with identical revenue may end up in different quartiles non-reproducibly.

Tiny Compl shave (-0.25): could have noted that for "top quartile = bucket 1" framing, the outer `CASE WHEN ntile = 1 THEN 'top' ...` is more readable than reversed ordering. Tiny Clar shave (-0.25): "remainder goes to earliest buckets" deserves the explicit "so bucket 1 is the largest by 1 row when uneven" callout.

No imported-prior, no broken-secondary, no over-warning, no fabrication.

---

## Q3 — dbt vars at runtime — clean

Verified facts against [docs.getdbt.com/reference/dbt-jinja-functions/var](https://docs.getdbt.com/reference/dbt-jinja-functions/var) + [docs.getdbt.com/docs/build/project-variables](https://docs.getdbt.com/docs/build/project-variables):

- **`var("retention_days", 90)` with default** — CORRECT.
- **Top-level `vars:` block in `dbt_project.yml` (sibling to `models:`)** — CORRECT (top-level vars override per-project scoping; both forms supported).
- **`dbt run --vars '{retention_days: 365}'` YAML-dict flag** — CORRECT.
- **Precedence: CLI `--vars` > `dbt_project.yml` `vars:` > `var()` inline default** — CORRECT per dbt docs: "Variables defined using --var override values defined in dbt_project.yml."
- **`{% set retention_days = 90 %}` defang** ("compile-time hardcoded, not overridable") — CORRECT pedagogical framing: `{% set %}` is a Jinja assignment baked at compile time and cannot be overridden by CLI flags.

Cited r27 §6.7G.

Tiny Compl shave (-0.5): could have mentioned (a) `--vars` can be passed in JSON form on the CLI too; (b) for the on-prem k8s deployment, the typical pattern is to pass `--vars` from a CI/CD job's env-substituted YAML, not interactively — practical context for SaaS infra.

No imported-prior, no broken-secondary, no over-warning, no fabrication.

---

## Q4 — Oracle COUNT(column) NULL → Trino — clean (correctly resisted false-divergence trap)

Verified:

- **"Oracle and Trino handle COUNT(column) IDENTICALLY — both skip NULLs (ANSI SQL)"** — CORRECT. Per [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html): "Except for count(), count_if(), max_by(), min_by() and approx_distinct(), all aggregate functions ignore null values" — count(col) skips NULLs; Oracle behaves identically (`COUNT(expr)` returns the count of non-null rows). No divergence here.
- **Empty-string-vs-NULL** — CORRECT framing: Oracle treats `''` as NULL (Oracle deviates from ANSI SQL), Trino treats `''` as distinct from NULL. **IF cancelled_at is a STRING column**, Oracle would skip `''` rows while Trino would count them — responder correctly hedges with the IF.
- **Likely real causes** (type coercion strictness, migrated data differences, JOIN/GROUP BY shape changes) all reasonable diagnostic angles.
- **Debug queries** (COUNT(*) vs COUNT(col); empty-vs-NULL counts; SHOW CREATE TABLE for column types) are exactly the right triage steps.

Strong probe — this is the same pattern as the carried `iter1289-Q4 LPAD-RPAD-false-divergence` watch (responder correctly resists inventing a divergence where the ANSI behavior matches). Pattern of correctly-resisting-false-Oracle-vs-Trino-divergence accumulating across iterations.

Caveat (-0.25 Prac, -0.5 Compl): `cancelled_at` is typically a TIMESTAMP column (it reads as "when was it cancelled"), so the empty-string angle is unlikely the actual root cause for this field-name. Responder hedged correctly but spent the most words on the least-likely-for-this-field-name explanation. The more probable real causes for `cancelled_at`-named column are (a) NULL-vs-sentinel-date in the source (Oracle SQL*Loader sometimes loads a `0000-00-00` or epoch-zero sentinel that Trino sees as a non-NULL date while Oracle stored as NULL); (b) JOIN cardinality changes during migration (LEFT vs INNER); (c) timezone-stripping converting NULLs differently across the porting tool.

No imported-prior, no broken-secondary, no over-warning, no fabrication.

---

## Watches

- **CLOSE iter1288-Q1 COUNT(*)-slow canonical (HARD).** FIX-A REACHED on 1st re-probe with explicit canonical citation; responder correctly states metadata-only normally, identifies position-deletes as cause, recommends EXECUTE optimize, no approx_distinct. r18 §"Why is my SELECT COUNT(*) slow on Iceberg?" canonical is reliably findable by name.
- **CARRY iter1290-Q3 small-files-routing (SOFT, re-probe 4-8).** Not exercised this iter.
- **CARRY iter1289-Q2 position-delete-Spark-vs-Trino (SOFT).** Adjacent to today's Q1 framing but the Spark-vs-Trino axis was not directly re-probed.
- **CARRY iter1289-Q4 LPAD-RPAD-false-divergence (SOFT).** Today's Q4 confirms the broader pattern (responder correctly resists inventing false Oracle-vs-Trino divergence); LPAD-RPAD-specific re-probe still pending.
- **CARRY perf-triage-recall-ceiling periodic.**
- No new watches.

## FIX-A

None. All 4 answers clean. iter1288 FIX-A REACHED; no new defects identified. No churn.

## Rubric updates

- **Iceberg table maintenance**: 4.4534/246 → (1095.5364 + 4.875)/247 = **4.4551/247** (+0.0017, margin +0.9551). HARD WATCH CLOSES.
- **Analytical query patterns on Iceberg+Trino**: 4.4823/208 → (932.3184 + 4.875)/209 = **4.4842/209** (+0.0019, margin +0.9842).
- **Oracle PL/SQL → dbt+Trino**: 4.4938/260 → (1168.388 + 4.8125 + 4.75)/262 = **4.4960/262** (+0.0022, margin +0.9960).

All topics PASSED. All-topics-passed terminal state preserved.

## Sources

- [trinodb/trino#13092 — Iceberg scanning with Delete Files is extremely slow](https://github.com/trinodb/trino/issues/13092)
- [trinodb/trino#12617 — Remove unused position deletes when running Iceberg optimize](https://github.com/trinodb/trino/issues/12617)
- [trinodb/trino#24086 — Delete files not removed after Iceberg maintenance](https://github.com/trinodb/trino/issues/24086)
- [trinodb/trino#17114 — Iceberg v2 with many delete files very slow](https://github.com/trinodb/trino/issues/17114)
- [Trino Window functions docs](https://trino.io/docs/current/functions/window.html)
- [dbt var() Jinja function](https://docs.getdbt.com/reference/dbt-jinja-functions/var)
- [dbt Project variables](https://docs.getdbt.com/docs/build/project-variables)
- [Trino Aggregate functions docs (COUNT NULL skip)](https://trino.io/docs/current/functions/aggregate.html)
- [trinodb/trino#21457 — aggregate over null behavior](https://github.com/trinodb/trino/issues/21457)

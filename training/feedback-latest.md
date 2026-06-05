# Judge Feedback — Iter 487

**Phase**: extended (end-of-iteration feedback only)
**Overall**: 4.7344 STRONG PASS (~1.23 above 3.5 floor; +0.34 above iter486)
**Federation**: NOT probed this iter — 4.49944/310 row HELD per iter472-487+ directive

---

## Headline

**Both iter486 surgical fixes CONFIRMED LANDED on 1st re-probe.** Q1 (dbt seed path) and Q2 (Spark Iceberg file-size conf key) closed their respective fab classes (outdated-default-path / fabricated-conf-property) cleanly. The LEADING CANONICAL anchor + DO-NOT-WRITE matrix pattern is now validated for both stale-default-path and fabricated-namespaced-key fab classes.

One small new fab surfaced on Q2 (option-key-prefix-confusion) that is NOT load-bearing and is addressable with a small clarifier in the same r13 card.

---

## Per-question breakdown

### Q1 — dbt seed RE-PROBE (4.875 STRONG PASS)
- **Accuracy 5.0** — `seeds/` default since dbt 1.0 (Dec-2021) cited correctly; pre-1.0 `data/` flagged as deprecated; override path via `seed-paths: ["data"]` correctly identified as the only way to keep `data/`. ref('plans') basename no-extension correct. `dbt seed` not run by `dbt run`/`dbt build` correct, `dbt build --select seeds+` correct. Size guidance (<1MB) matches dbt docs best practice.
- **Completeness 4.75** — covers default dir + override + load command + ref usage + when-to-use vs source + size threshold.
- **Clarity 4.75** — zero unexplained jargon; clear seed-vs-source decision rule.
- **Actionability 5.0** — paste-and-run on a default dbt 1.0+ project.
- **Fab status**: ZERO fabs. iter486 teacher edit (r27 §6.7D LEADING CANONICAL dbt seeds anchor) **LANDED on 1st re-probe**.
- **Doc verification**: docs.getdbt.com/reference/project-configs/seed-paths CONFIRMS "By default, dbt expects seeds to be located in the `seeds` directory. For example, `seed-paths: [\"seeds\"]`".

### Q2 — Spark Iceberg write tiny-files + OOM RE-PROBE (4.50 STRONG PASS)
- **Accuracy 4.25** — primary recipe correct: TABLE PROPERTY `write.target-file-size-bytes` + `write.distribution-mode='hash'` (default since Iceberg 1.2 / Spark 3.3); explicit DO-NOT-WRITE on fabricated `spark.sql.iceberg.target_file_size_bytes` session conf (iter486 fix LANDED). **MINOR key-nuance inaccuracy (not load-bearing)**: responder's DataFrameWriter per-write OPTION was written as `.option("write.target-file-size-bytes", "134217728")` — per iceberg.apache.org/docs/latest/spark-writes#controlling-file-sizes the documented DataFrameWriterV2 OPTION key is `target-file-size-bytes` (NO `write.` prefix). Doc example: `df.writeTo("catalog.db.table").option("target-file-size-bytes", "268435456").append()`. The `write.` prefix is the TABLE-PROPERTY form only (via `TBLPROPERTIES` or `.tableProperty()`). The ALTER TABLE SET TBLPROPERTIES 'write.target-file-size-bytes' form that the responder ALSO gave IS correct.
- **Completeness 4.75** — both levers covered, default values cited, fanout-writer OOM mechanism explained.
- **Clarity 4.5** — 3-tier explanation clear; per-write OPTION vs persistent TBLPROPERTY distinction was the missed nuance.
- **Actionability 4.5** — engineer applying the ALTER TABLE form succeeds; engineer pasting the `.option("write.target-file-size-bytes", ...)` per-write form gets the key silently ignored (Spark accepts any string option without validation), file size stays at the table-property/default value.
- **Fab status**: iter486 fabricated-conf-property fab class **CLOSED on 1st re-probe**. NEW small fab class logged: **option-key-prefix-confusion** (conflating the TABLE-PROPERTY namespace `write.*` with the DataFrameWriter OPTION key namespace which strips the `write.` prefix).
- **Side note**: `.save("s3a://...")` path-style write is the legacy non-catalog write; preferred is catalog-aware `writeTo("catalog.db.t")` API on Iceberg-Spark. Minor.

### Q3 — Trino CTE inlining vs materialization (4.8125 STRONG PASS)
- **Accuracy 5.0** — "Trino INLINES CTEs and re-runs them every reference" CONFIRMED via trino.io/docs/current/sql/select.html WITH clause: "Currently, the SQL for the `WITH` clause will be inlined anywhere the named relation is used. This means that if the relation is used more than once and the query is non-deterministic, the results may be different each time"; doc quote cited verbatim; CTE-referenced-2x-runs-the-GROUP-BY-2x is the correct behavioral implication; ephemeral=CTE-inlined matches dbt-trino adapter behavior; "2+ references → dbt table" operationally sound.
- **Completeness 4.75** — covers inlining behavior + dbt materialization choice (ephemeral=CTE vs table=materialized) + rule of thumb.
- **Clarity 4.5** — clear lay explanation of inlining vs materialization.
- **Actionability 5.0** — engineer knows exactly when to switch from ephemeral to table.
- **Fab status**: ZERO fabs.

### Q4 — Oracle CONNECT BY → Trino WITH RECURSIVE (4.75 STRONG PASS)
- **Accuracy 5.0** — `WITH RECURSIVE` real Trino feature CONFIRMED via trino.io/docs/current/sql/select.html "Trino supports `WITH RECURSIVE` common table expressions"; experimental flag CONFIRMED in doc warning; default `max_recursion_depth`=10 CONFIRMED; session-property override `SET SESSION max_recursion_depth = N` CONFIRMED; "quadratic plan growth with recursion depth" matches the doc verbatim. Base-case (START WITH → WHERE) + recursive-step (CONNECT BY PRIOR → JOIN org_tree) + UNION ALL + manual `level+1` mapping is the canonical Oracle→Trino rewrite.
- **Completeness 4.75** — covers structure + experimental flag + depth tuning + pre_hook + closure-table fallback for deep trees.
- **Clarity 4.5** — Oracle-to-Trino side-by-side mapping clear; doesn't assume prior Trino recursive-CTE knowledge.
- **Actionability 4.75** — paste-and-run with pre_hook scaffolding for per-model depth raising; closure-table fallback is operationally sound for deep hierarchies.
- **Fab status**: ZERO fabs.

---

## Topic average updates

| Topic | Before | After | Delta |
|---|---|---|---|
| SQL query best practices (Q1 dbt seed maps here) | 4.5492/50 | **4.5556/51** | +0.0064 |
| Iceberg partition design (Q2 file-size + distribution-mode) | 4.4946/35 | **4.4948/36** | +0.0002 |
| Improving complex SQL perf on Trino with dbt (Q3 CTE materialization) | 4.7781/4 | **4.785/5** | +0.0069 |
| Oracle PL/SQL->dbt/Trino migration (Q4 CONNECT BY) | 4.5029/59 | **4.5070/60** | +0.0041 |
| Trino federation / cross-source connectors | 4.49944/310 | **4.49944/310 UNCHANGED** | NOT PROBED |

---

## Fix-landing status

| iter486 fab | Q | Class | Status iter487 |
|---|---|---|---|
| `data/plans.csv` as seed dir | Q1 | outdated-default-path / version-pin-spillover | **CONFIRMED FIXED** (responder used `seeds/`, banned `data/` as deprecated default) |
| `spark.conf.set("spark.sql.iceberg.target_file_size_bytes", ...)` | Q2 | fabricated-conf-property | **CONFIRMED FIXED** (responder explicitly banned the fake conf, used TABLE PROPERTY + distribution-mode='hash') |

Both iter486 LEADING CANONICAL + DO-NOT-WRITE pattern edits landed on **1st re-probe**.

---

## Fabrications / inaccuracies inventory (iter487)

| # | Question | Class | Severity | Correct fact | Source |
|---|---|---|---|---|---|
| 1 | Q2 | option-key-prefix-confusion | MINOR (non-load-bearing) | DataFrameWriter OPTION key is bare `target-file-size-bytes` (no `write.` prefix); `write.` prefix is TABLE-PROPERTY form only | iceberg.apache.org/docs/latest/spark-writes#controlling-file-sizes |
| 2 | Q2 | legacy-API-preference (style nit) | TRIVIAL | Path-style `.save("s3a://...")` is the legacy non-catalog write; catalog-aware `writeTo("catalog.db.t")` is preferred for Iceberg-Spark | iceberg.apache.org/docs/latest/spark-writes |

No load-bearing fabrications this iter. Q1, Q3, Q4 all ZERO fabs.

---

## Teacher actions for iter488

### PRIMARY — SMALL clarifier in r13 LEADING CANONICAL 3-tier Spark write file-size card

The iter487 r13 LEADING CANONICAL card already has the 3-tier hierarchy (TABLE PROPERTY / DataFrameWriter OPTION / NO session-conf). Tighten the DataFrameWriter OPTION tier to disambiguate the key:

- **Before/after pair**: clearly show the DataFrameWriter OPTION key is `target-file-size-bytes` (NO `write.` prefix), distinct from the TABLE PROPERTY `write.target-file-size-bytes` (WITH the `write.` prefix).
- **Working example** from the official doc: `df.writeTo("catalog.db.table").option("target-file-size-bytes", "268435456").append()`.
- **DO-NOT-WRITE row**: ban `.option("write.target-file-size-bytes", ...)` as the silently-ignored variant (Spark accepts any string option key without validation; the `write.` prefix on a DataFrameWriter OPTION makes it a no-op).
- **Mnemonic**: "TABLE PROPERTY uses the FULL `write.*` namespace; DataFrameWriter OPTION strips the `write.` prefix."
- **Citation**: iceberg.apache.org/docs/latest/spark-writes#controlling-file-sizes.

Also worth adding a tiny line preferring catalog-aware `writeTo("catalog.db.t")` over legacy path-style `.save("s3a://...")` for Iceberg-Spark on the MinIO+Hive Metastore stack — keeps writes inside the catalog so Trino's Iceberg connector sees them.

### SECONDARY — breadth design for iter488 (NO dedicated federation probe)

- Federation 4.49944/310 row HELD per iter472-487+ directive. **DO NOT count any iter488 probe as a federation probe.**
- Low-count topics worth additional datapoints (each tested from >=2 angles for durability):
  - dbt sources / source freshness (3, 4.219) — re-probe loaded_at_field + warn_after/error_after blocking semantics
  - dbt model contracts (3, 4.1146) — re-probe contract.enforced + not_null runtime-enforced via Iceberg
  - Storage tiering on Trino+Iceberg+MinIO (2, 4.25) — re-probe MinIO lifecycle `mc ilm tier add` recipe
  - dbt snapshots SCD2 (2, 4.5625) — re-probe dbt_valid_from/dbt_valid_to + check vs timestamp strategy
  - complex-SQL-perf-on-Trino-with-dbt (5, 4.785) — keep probing dbt materialization tuning
- Consider 2nd-angle re-probe on either iter487 fix (dbt seed-path OR Spark write file-size key prefix) to lock 2+ confirmations.

### Schedule note

5-min cadence — `delaySeconds=300`.

---

## Streak / margin status

- **86th consecutive overall PASS in extended phase.**
- Margin at 4.7344 (STRONG PASS) — +0.34 above iter486's 4.3906 PASS; comfortably above 3.5 floor.
- **Double-fix landing iter**: both iter486 surgical fixes (Q1 seeds/-not-data/ + Q2 Spark conf-key DO-NOT-WRITE) confirmed on 1st re-probe.
- **Citation-hygiene status**: 3 of 4 Qs ZERO-fab; Q2 has one minor non-load-bearing option-key nuance.
- **Federation**: 4.49944/310 — 23rd+ consecutive iteration with the row HELD per iter472-487+ directive. **DO NOT probe federation in iter488.**

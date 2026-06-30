# Judge Feedback — Iteration 1292

**Overall: 4.828 — STRONG PASS. All 4 clean, no new FIX-A, no new watches. Continuous-PASS-loop streak holds.**

| Q | Score | Acc | Clar | Prac | Compl | Topic | Result |
|---|---|---|---|---|---|---|---|
| Q1 (UNION vs UNION ALL) | **4.875** | 5.0 | 4.75 | 5.0 | 4.75 | SQL query best practices for OLAP | Clean |
| Q2 (Iceberg ADD COLUMN nullable, metadata-only) | **4.8125** | 5.0 | 4.75 | 5.0 | 4.5 | Lakehouse schema design | Clean |
| Q3 (dbt docs generate / lineage / persist_docs) | **4.875** | 5.0 | 4.75 | 5.0 | 4.75 | Oracle PL/SQL → dbt+Trino | Clean |
| Q4 (Oracle REGEXP_SUBSTR → Trino regexp_extract) | **4.75** | 5.0 | 4.5 | 5.0 | 4.5 | Oracle PL/SQL → dbt+Trino | Clean (cosmetic typo only) |

Average: (4.875 + 4.8125 + 4.875 + 4.75) / 4 = **4.828**

---

## Accuracy confirmations (all 4 verified)

### Q1 — UNION vs UNION ALL — CONFIRMED

- **"UNION removes duplicates (dedup pass = sort/hash-aggregate, slower); UNION ALL keeps all incl duplicates (cheaper, no dedup)"** — CORRECT. Verified at [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) (UNION default is DISTINCT; ALL keeps duplicates) and [SQL UNION vs UNION ALL — Atlassian](https://www.atlassian.com/data/sql/what-is-the-difference-between-union-and-union-all). UNION requires sort/hash to dedupe — computational overhead scales with row count.
- **"For 'no duplicate customer IDs' use bare UNION (= UNION DISTINCT)"** — CORRECT mapping. Trino bare `UNION` defaults to `DISTINCT`.
- **"Coworker partially right but BACKWARDS: bare UNION is the SLOWER one; UNION ALL skips dedup"** — CORRECT inversion of the coworker's "UNION-everywhere is slower" claim, which is the OPPOSITE of reality (UNION ALL is the faster default, and is what should be used "everywhere" when dedup is not needed).
- **Nuance: "if the two queries are already disjoint (date-partitioned), UNION wastes a dedup pass — but here customers overlap across quarters so UNION is correct + the cost is unavoidable"** — CORRECT practical framing. Matches [trinodb/trino#14 — Optimize union all of similar aggregations](https://github.com/trinodb/trino/issues/14) (Trino has optimizer paths specifically for UNION ALL, not for UNION).

### Q2 — Iceberg ADD COLUMN metadata-only + old-rows-NULL — CONFIRMED

- **"ALTER TABLE ADD COLUMN on Iceberg is METADATA-ONLY, no downtime, completes in ms even on 8 months data"** — CORRECT. Verified at [iceberg.apache.org/docs/latest/evolution/](https://iceberg.apache.org/docs/latest/evolution/): "Iceberg schema updates are metadata changes, so no data files are rewritten." Iceberg uses immutable numeric field IDs (not column names) to map columns to Parquet files — adding a new field assigns a new field ID, never touches existing data.
- **"Old rows return NULL for the new column"** — CORRECT. Per the same Iceberg spec page: when a column is added, existing files have no field ID for it, so reads project NULL. No backfill required.
- **"Added columns are nullable by design"** — CORRECT for Trino 467 specifically. Per [trinodb/trino PR #13673](https://github.com/trinodb/trino/pull/13673) (release 393), Trino disallows `ALTER TABLE ADD COLUMN ... NOT NULL` on Iceberg precisely because existing files would violate; nullable is the only path on an existing table. Responder did not explicitly raise this caveat (engineer didn't ask), but everything stated is consistent with it.
- **`ALTER TABLE iceberg.analytics.fct_events ADD COLUMN device_type VARCHAR` syntax** — CORRECT per [trino.io/docs/467/sql/alter-table.html](https://trino.io/docs/467/sql/alter-table.html) and [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html).
- **"For non-NULL historical: one-off Spark backfill"** — CORRECT secondary alternative. Spark `UPDATE` (or CTAS-and-swap on this stack) is the documented backfill path.

Pin alignment: matches iter1237 Q1 + iter1205 Q1 prior canonicals (field-ID schema evolution); no regression.

### Q3 — dbt docs generate / lineage / persist_docs — CONFIRMED

- **"`dbt docs generate` builds `target/manifest.json` (DAG / model + test + macro nodes) + `target/catalog.json` (warehouse column metadata via `information_schema`)"** — CORRECT per [dbt docs cmd-docs](https://docs.getdbt.com/reference/commands/cmd-docs) + [Manifest JSON](https://docs.getdbt.com/reference/artifacts/manifest-json): generate copies `index.html`, compiles into `manifest.json`, queries warehouse for `catalog.json`.
- **"Does NOT run SQL / does NOT materialize models"** — CORRECT. `dbt docs generate` only reads `information_schema` (cheap metadata query) — it does NOT execute model SQL or refresh tables.
- **"View: `dbt docs serve` → http://localhost:8080"** — CORRECT. Default port 8080, `--port` flag overrides.
- **"Useful beyond a diagram: search-by-column, lineage upstream/downstream per model, team knowledge from descriptions, BI integration"** — CORRECT.
- **"GOTCHA: `dbt docs generate` does NOT push descriptions into Trino — for SHOW COLUMNS / BI native comments use `+persist_docs: {relation: true, columns: true}` (writes COMMENT ON TABLE/COLUMN on `dbt build`)"** — CORRECT and load-bearing for this on-prem Trino+dbt stack. Per [persist_docs](https://docs.getdbt.com/reference/resource-configs/persist_docs): the config translates yml `description:` into native database comments. dbt-trino supports this; comments then surface in Trino via `SHOW CREATE TABLE` / `information_schema.columns.comment` and in any BI tool that reads native comments. This is exactly the distinction a SaaS engineer needs to know to avoid the "I wrote descriptions in dbt but my BI tool can't see them" trap.

Cited r27 §6.7 (dbt docs / persist_docs canonical zone).

### Q4 — Oracle REGEXP_SUBSTR → Trino regexp_extract 3-arg group — CONFIRMED

- **"Trino 467 has NO regexp_substr (parse error)"** — CORRECT. Verified via WebFetch of [trino.io/docs/467/functions/regexp.html](https://trino.io/docs/467/functions/regexp.html): the only documented regex functions are `regexp_count`, `regexp_extract`, `regexp_extract_all`, `regexp_like`, `regexp_position`, `regexp_replace`, `regexp_split`. No `regexp_substr`.
- **"Use `regexp_extract(string, pattern)` for full match, `regexp_extract(string, pattern, group)` for a capture group"** — CORRECT both signatures verified verbatim from docs.
- **"Capture groups are 1-indexed, group 0 = full match, not-found returns NULL"** — CORRECT. Trino regex uses JONI (re2j-style) where capturing group 0 conventionally references the entire match; groups 1..N are explicit parentheses. Not-found → NULL is the documented behavior.
- **Mapping table: Oracle `REGEXP_SUBSTR(url, 'utm_source=([^&]+)', 1, 1, NULL, 1)` (6th arg = group 1) → Trino `regexp_extract(url, 'utm_source=([^&]+)', 1)` (3rd arg = group 1)** — CORRECT mapping. Oracle's 6th positional arg is the capture-group selector (position, occurrence, match_param, sub_expression respectively at args 3–6); Trino collapses positional / occurrence / flags into the pattern itself, leaving only the group selector as the 3rd arg.
- **"Trino regex engine is JONI, `'\d'` works"** — CORRECT, matches pinned `reference_trino_regex_backslash` (single-backslash works in actual SQL because string literals do not process backslash escapes; the rendered-HTML double-backslash is a Sphinx artifact).

Cosmetic Clar shave (-0.25): "lookahead / lookahead" typo (likely meant "lookahead / lookbehind"). Doesn't change the substance. Cosmetic Compl shave (-0.5): could have noted `regexp_extract_all` as the multi-occurrence alternative (Oracle's 4th arg = `occurrence`, so anyone migrating from `REGEXP_SUBSTR(..., 1, 2)` to extract the 2nd occurrence needs `regexp_extract_all(...)[2]` not 3-arg `regexp_extract`).

---

## Watches

- **CARRY iter1290-Q3 small-files-routing (SOFT, re-probe 4-8).** Not exercised this iter.
- **CARRY iter1289-Q2 position-delete-Spark-vs-Trino (SOFT).** Not exercised this iter.
- **CARRY iter1289-Q4 LPAD-RPAD-false-divergence (SOFT).** Today's Q4 lands in the broader "Oracle→Trino function dialect" family with `regexp_extract` correctly mapped (NOT a false divergence — Oracle and Trino genuinely differ here, and responder correctly named both); pattern of correct divergence-vs-non-divergence discrimination accumulating.
- **CARRY perf-triage-recall-ceiling periodic SOFT.** Not exercised this iter (pure breadth round).
- **No new watches.**

## FIX-A

**None.** All 4 answers clean. Pure breadth round, continuous-PASS-loop streak (4.828 this iter, 4.828 iter1291, 4.97 iter1093, 4.95 iter1092) holds. No churn.

## Rubric updates

- **SQL query best practices for OLAP**: 4.5879/306 → (1403.8974 + 4.875)/307 = **4.5887/307** (+0.0008, margin +1.0887).
- **Lakehouse schema design**: 4.4940/21 → (94.374 + 4.8125)/22 = **4.5085/22** (+0.0145, margin +1.0085).
- **Oracle PL/SQL → dbt+Trino**: 4.4960/262 → (1177.952 + 4.875 + 4.75)/264 = **4.4984/264** (+0.0024, margin +0.9984).

All topics PASSED. All-topics-passed terminal state preserved.

## Sources

- [Trino 467 regexp functions](https://trino.io/docs/467/functions/regexp.html)
- [Trino SELECT (UNION semantics)](https://trino.io/docs/current/sql/select.html)
- [trinodb/trino#14 — Optimize union all of similar aggregations](https://github.com/trinodb/trino/issues/14)
- [Iceberg schema evolution](https://iceberg.apache.org/docs/latest/evolution/)
- [Trino 467 ALTER TABLE](https://trino.io/docs/467/sql/alter-table.html)
- [Trino 467 Iceberg connector](https://trino.io/docs/467/connector/iceberg.html)
- [trinodb/trino PR #13673 — disallow ADD COLUMN NOT NULL on Iceberg](https://github.com/trinodb/trino/pull/13673)
- [dbt docs commands](https://docs.getdbt.com/reference/commands/cmd-docs)
- [dbt manifest.json](https://docs.getdbt.com/reference/artifacts/manifest-json)
- [dbt persist_docs](https://docs.getdbt.com/reference/resource-configs/persist_docs)

# Iter1215 Judge Feedback — BORDERLINE PASS (3.50 avg) | **FIX-A REQUIRED** on Q1 (compression_codec resource-sourced 477+ gate miss across r11/r03/r17/r27/r25) | Q4 strpos 3-arg myth CONFIRMED RECURRENCE → ACCEPT-CEILING NO FIX-A | Q3 iter1212 over-statement watch CLOSES

**Overall verdict:** **BORDERLINE PASS at threshold (3.50)** with TWO confirmed hard problems:

1. **Q1 = HARD FAIL on mechanism (2.875)** — multiple LEADING CANONICAL blocks teach `compression_codec` as a Trino 467 Iceberg TABLE property (CREATE TABLE WITH + ALTER TABLE SET PROPERTIES). **Verified FALSE for Trino 467**: in 467, `compression_codec` is a SESSION property (`SET SESSION iceberg.compression_codec = 'ZSTD'`), NOT a table property. PR #25755 (merged Aug 2025, milestone **Trino 477**) added the table-property form AND dropped the session property simultaneously. Resources teach the 477+ form against the 467 stack. **FIX-A REQUIRED — resource-sourced defect.**
2. **Q4 = HARD FAIL (2.0) — CONFIRMED RECURRENCE (2nd consecutive, iter1211+1215)** of the `strpos` 3-arg assumed-absence myth despite maximally-defanged + responder-CITED resource at r27 §4.3 L990. **Confirmed Haiku base-prior ceiling — ACCEPT-CEILING, NO FIX-A** per iter1211 pre-commitment + feedback_synthesis_ceiling_stop_churning + feedback_new_card_over_attracts_adjacent.

**Q3 (iter1212 over-statement watch): CLOSES.** No "must NOT be in schema.yml" or equivalent over-claim. Safe to retire from active watch.

| Q | Topic | Score | Verdict |
|---|---|---|---|
| Q1 | Storage tiering / compression_codec on Trino 467 Iceberg | **2.875** | **FAIL — resource-sourced; FIX-A REQUIRED** |
| Q2 | Analytical patterns — median/percentile via approx_percentile + GROUP BY | 4.75 | STRONG PASS (no PERCENTILE_CONT, approx_percentile array form, qdigest_agg tunable accuracy all clean) |
| Q3 (WATCH) | dbt seed column_types in dbt_project.yml | 4.375 | PASS — watch CLOSES, no over-statement recurrence; minor completeness gap on the "or schema.yml" choice question |
| Q4 (WATCH) | Oracle INSTR Nth occurrence → Trino strpos 3-arg | **2.0** | **FAIL — CONFIRMED RECURRENCE / Haiku ceiling — NO FIX-A** |

**Iter avg: (2.875 + 4.75 + 4.375 + 2.0) / 4 = 3.50** — borderline PASS at threshold. Strong Q2+Q3 mask two hard fails.

---

## Q1 — Iceberg compression CHECK + ZSTD vs Snappy + Trino impact — FAIL on mechanism

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 1.5 | `SHOW CREATE TABLE` showing `WITH(...compression_codec='...')` — FALSE for 467 (compression_codec not in 467 table-property list). `ALTER TABLE ... SET PROPERTIES compression_codec='ZSTD'` — FALSE for 467 (would parse-error: `Catalog 'iceberg' table property 'compression_codec' does not exist`). Both lifted directly from resources. ZSTD-vs-Snappy I/O-bound reasoning IS correct. `"events$properties"` metadata table IS valid in 467. |
| Beginner clarity | 4.0 | Clear narrative; explains the trade-off well; gives action verbs. |
| Practical applicability | 2.0 | Engineer pastes the ALTER TABLE form → **parse error in production**. The actual correct 467 lever (`SET SESSION iceberg.compression_codec = 'ZSTD'` before writes) is missing. EXECUTE optimize for re-compaction IS valid. |
| Completeness | 4.0 | Covers all three sub-questions (CHECK / which codec / does it matter). |

**Avg: 2.875 — FAIL**

### Verification trail

- [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) Iceberg connector table-properties list: `format`, `format_version`, `partitioning`, `sorted_by`, `location`, `data_location`, `orc_bloom_filter_columns`, `orc_bloom_filter_fpp`, `parquet_bloom_filter_columns`, `object_store_layout_enabled`, `extra_properties`. **`compression_codec` is ABSENT from this list.**
- Only `iceberg.compression-codec` catalog config is documented in the 467 page; in 467 the session property `iceberg.compression_codec` existed (per PR #24851 context + WebSearch confirmation) and was wired through PR #24851 (Mar 2025, milestone 473) to actually write the underlying `write.parquet.compression-codec` native key. The session property was dropped in PR #25755 (Aug 2025, milestone 477) when the table-property form was added.
- **PR #25755** (verified): "Support setting compression_codec table property for Iceberg" — merged **2025-08-07**, **milestone Trino 477**. Adds both `CREATE TABLE WITH(compression_codec=...)` AND `ALTER TABLE SET PROPERTIES compression_codec=...` and simultaneously drops the session property.
- `"<table>$properties"` metadata table IS exposed in Trino 467 (verified at the 467 Iceberg page — Metadata tables section). Responder's query form `SELECT key, value FROM "events$properties" WHERE key LIKE '%compression%'` IS valid Trino 467 — the user can use this lookup, but the key returned will be the NATIVE Iceberg key `write.parquet.compression-codec`, not `compression_codec`.

### Resource-sourced defect — grep findings (THIS IS A RESOURCE DEFECT, not a responder slip)

- `resources/11-lakehouse-storage-sizing.md` L262: **LEADING CANONICAL block titled "Trino-Iceberg compression: the ONE correct property name + DDL forms"** explicitly claims compression_codec is the Trino 467 table property; gives `CREATE TABLE ... WITH (compression_codec = 'ZSTD')` AND `ALTER TABLE ... SET PROPERTIES compression_codec = 'ZSTD'` as canonical 467 forms; cites `trino.io/docs/current` (version-creep — `current` is now 482, not 467; later docs do have the table property).
- `resources/03-columnar-storage.md` L189, 204, 215, 225-228: same canonical pattern (CREATE TABLE WITH + ALTER SET PROPERTIES + DO-NOT-WRITE table all premised on `compression_codec` being a 467 table property).
- `resources/17-iceberg-table-maintenance.md` L1209, 1213-1214: cross-engine translation table claims Trino: `WITH (compression_codec = 'ZSTD')` / `SET PROPERTIES compression_codec = 'ZSTD'`.
- `resources/27-oracle-plsql-to-dbt-trino.md` L1697: claims `WITH (..., compression_codec = 'ZSTD')` is the Trino correct form.
- `resources/25-trino-materialized-views-iceberg.md` L110: lists `compression_codec` as a table property in a properties table.

### The PATTERN miss

r17 ALREADY gates other 477+ features correctly:
- L193: TRUNCATE "absent from 467/470/474/476, present from 477+"
- L345: `ADD COLUMN ... DEFAULT` is a "Trino 477+ feature"
- L566, L651: CREATE TABLE column DEFAULT same 477 gate

The 477+ gating awareness exists in the resource — but `compression_codec` was MISSED. This is the iter1173 `parquet_bloom_filter_columns` CREATE-vs-ALTER 469+ cutoff pattern repeated on a different surface — version-cutoff awareness applied unevenly across surfaces.

### FIX-A RECOMMENDATION (Q1): REQUIRED — reconcile-in-place at all 5 locations

1. **r11 §262-312 LEADING CANONICAL** (highest priority — most copy-attractive): rewrite to put SESSION property (`SET SESSION iceberg.compression_codec = 'ZSTD'`) as the Trino 467 canonical form; gate `CREATE TABLE WITH(compression_codec=...)` + `ALTER TABLE SET PROPERTIES compression_codec=...` as **Trino 477+** with explicit version note. For 467 read-side verification keep `"<table>$properties"` query (looks for `write.parquet.compression-codec` native key). Replace `trino.io/docs/current` citations with `trino.io/docs/467` to pin the verification.
2. **r03 §189-228**: same correction — session-property canonical for 467, table-property form gated 477+.
3. **r17 §1209/1213-1214** translation table: correct Trino column to "467: session property `iceberg.compression_codec`; 477+: table property `compression_codec`".
4. **r27 §1697**: same 477+ gate annotation.
5. **r25 §110**: same gate.

### Anchoring citations

- [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) — table-properties list (compression_codec ABSENT)
- [github.com/trinodb/trino/pull/25755](https://github.com/trinodb/trino/pull/25755) — merged Aug 2025, milestone 477, adds table-property form, drops session property
- [github.com/trinodb/trino/pull/24851](https://github.com/trinodb/trino/pull/24851) — merged Mar 2025 (473), session-property `iceberg.compression_codec` wires through to `write.parquet.compression-codec` table-prop on writes

---

## Q2 — median(order_amount) per plan tier — STRONG PASS

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All correct: no exact PERCENTILE_CONT/MEDIAN in Trino 467; `approx_percentile(order_amount, 0.5) GROUP BY plan` is the right grouped-median form; array overload `approx_percentile(x, ARRAY[0.5,0.9,0.99])` correct; no published error figure for approx_percentile (matches reference_trino_approx_percentile_error pin — the 2.3% figure is approx_distinct ONLY); `qdigest_agg(x, 1, accuracy) + value_at_quantile(...)` for tunable accuracy correct. |
| Beginner clarity | 4.5 | Clean narrative; explains why Postgres syntax doesn't port; copy-pasteable SQL with GROUP BY. |
| Practical applicability | 5.0 | Engineer can paste-and-run directly. |
| Completeness | 4.5 | Array form is bonus; T-Digest mention is correct. |

**Avg: 4.75 — STRONG PASS**

---

## Q3 (WATCH iter1212) — dbt seed column_types — PASS, WATCH CLOSES

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | `dbt_project.yml` `seeds: <project>: <seed>: +column_types: { col: type, ... }` form is correct and matches r27 §3478. The `+` prefix correctly used. `dbt seed --select plan_tiers` correct. |
| Beginner clarity | 4.5 | Clear; shows the YAML structure; explains `dbt seed --select` to re-load. |
| Practical applicability | 4.5 | Engineer can paste-and-run. |
| Completeness | 3.5 | **Question explicitly asked "dbt_project.yml OR separate YAML next to CSV?"** — responder answered only the first option. Per [docs.getdbt.com/reference/seed-configs](https://docs.getdbt.com/reference/seed-configs), the schema.yml (properties YAML next to CSV) form IS ALSO valid: `seeds: - name: plan_tiers; config: column_types: {...}`. Responder didn't address the user's choice question. **BUT — did NOT recur the iter1212 over-statement "must NOT be in schema.yml"** — so the watch CLOSES without regression. |

**Avg: 4.375 — PASS**

**WATCH STATUS: iter1212 over-statement → CLOSES.** No "must NOT be in schema.yml" or equivalent over-claim in this answer. Resource r27 §3472 also makes no such over-claim — it's titled "Optional" and only shows the dbt_project.yml form without negating alternatives. Safe to remove from active watch list.

**Minor completeness gap (NO FIX-A):** the choice-question framing was not addressed. Optional one-line addition to r27 §3472 would help, but borderline (recall ceiling vs one-line gain). Recommend: NO-OP for now; light watch under "seed-column_types-location" — re-probe once with the choice-question framing.

---

## Q4 (WATCH iter1211) — Oracle INSTR Nth occurrence — HARD FAIL, CONFIRMED RECURRENCE

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 1.0 | "Trino 467 has NO direct equivalent" of Oracle's 4-arg INSTR is **FACTUALLY FALSE**. Verified at [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html): `strpos(string, substring, instance) -> bigint` is documented — *"Returns the position of the N-th `instance` of `substring` in `string`. When `instance` is a negative number the search will start from the end of `string`."* So `strpos(description, ',', 2) = 2` directly answers the Oracle `INSTR(description, ',', 1, 2)` use case in one call. The marker-insertion / nested-strpos / split-array workarounds the responder proposed are unnecessary complexity. |
| Beginner clarity | 3.0 | Workaround prose is clear and well-explained — but the workarounds are SOLUTIONS TO A PROBLEM THAT DOESN'T EXIST. |
| Practical applicability | 1.5 | Engineer copies a 5-line `split(description, ',')[2]` or marker-insertion idiom when `strpos(description, ',', 2)` is the one-call answer. Wasted CPU + readability cost in production ETL. |
| Completeness | 2.5 | Did address the question; gave multiple workarounds; missed the correct one-call answer. |

**Avg: 2.0 — HARD FAIL (confirmed recurrence)**

### Verification

- [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html): `strpos(string, substring) → bigint` AND `strpos(string, substring, instance) → bigint` both documented. The 3-arg form's docs quote: *"Returns the position of the N-th `instance` of `substring` in `string`. When `instance` is a negative number the search will start from the end of `string`."*

### Resource status (NOT a resource defect — resource is maximally correct)

- `resources/27-oracle-plsql-to-dbt-trino.md` §4.3 L990: row titled `INSTR(s, sub, 1, n)` → `strpos(s, sub, n) — the 3-arg form` with verbatim docs quote AND explicit DO-NOT-WRITE: *"Trino strpos is 2-arg only / has no n-th-occurrence form" — that is a base-training myth; the 3-arg form exists.*
- Keyword anchors at L990: "position of the second occurrence, nth occurrence of a character Trino, find the 2nd/3rd instance, position of last occurrence, find n-th delimiter position."
- The responder **CITED the §4.3 String functions section (L984-1050 range)** in their answer reasoning yet still produced the myth. Findability layer succeeded; recall/synthesis layer failed.

### This is CONFIRMED Haiku base-prior ceiling

2nd consecutive recurrence (iter1211 + iter1215) despite maximally-defanged + responder-cited resource content. Joins the imported-prior assumed-absence family: starts_with / to_char / listagg / array_sum / format_number / migrate / LATERAL → now **strpos-3-arg** is the 8th member.

### FIX-A RECOMMENDATION (Q4): ACCEPT-CEILING / NO-OP

Per iter1211 pre-commitment + feedback_synthesis_ceiling_stop_churning + feedback_new_card_over_attracts_adjacent risk:

1. **Findability is already intact** — responder cited the correct section; the row exists with keyword anchors + DO-NOT-WRITE defang. The recall layer (responder navigating table row → emitting from the row) is failing, not findability.
2. **Elevation to a standalone LEADING CANONICAL block at section top** would risk:
   - Adjacent regression on the `position(... IN ...)` / `split_part` / `regexp_position` neighbors (per feedback_new_card_over_attracts_adjacent — iter858 geometric_mean stole harmonic_mean precedent).
   - Likely insufficient to override base prior since the responder ALREADY navigated to §4.3 AND cited it AND still produced the myth. The breakdown is not at navigation, it's at base-prior override of the cited row.
3. **Per synthesis-ceiling rule**: when a maximally-defended resource is correctly findable AND cited AND the responder STILL produces the myth, the residual is a recall ceiling, not a resource gap. Stop churning. Accept the occasional Q cost.

**Decision: NO FIX-A.** Log as confirmed ceiling, re-probe in 8-12 iters with fresh phrasing ("find the Nth comma" / "2nd separator position" / "position of the 3rd dot") to confirm STABLE ceiling (not regression from a different cause). If a third consecutive recurrence appears on novel phrasing, then consider one-shot findability-elevation as a last try — but not now.

---

## Rubric topic touches (this iter)

- **Q1** (Storage tiering on Trino+Iceberg+MinIO — compression_codec is explicitly named in this topic's title; also touches Storage sizing r11 + Iceberg table maintenance r17 + Column-oriented storage r03) → log SCORE **2.875** against **Storage tiering** as primary.
- **Q2** (Analytical query patterns on Iceberg+Trino — approx_percentile is canonical) → log **4.75**.
- **Q3** (Oracle PL/SQL → dbt+Trino migration — seeds are in r27 §3460+) → log **4.375** against Oracle PL/SQL migration.
- **Q4** (Oracle PL/SQL → dbt+Trino migration — string-function rewrite is core scope) → log **2.0** against Oracle PL/SQL migration.

---

## Watches — carry forward

**CLOSING (this iter):**
- iter1212 dbt-seed-column_types-NOT-in-schema.yml over-statement → **CLOSED**, no recurrence.

**ACTIVE (carry forward, not probed this iter):**
- iter1213 session_properties findability + (+)-mnemonic
- iter1214 expire_snapshots retention_days vs retention_threshold duration-string param
- iter1214 config()-YAML-colon vs Jinja-equals syntax

**NEW (this iter):**
- **iter1215 compression_codec Trino-467-table-property FALSE claim** — after FIX-A lands, re-probe within 4-6 iters with a CHECK/CHANGE-codec phrasing to confirm corrected mechanism (SET SESSION form for 467; gate table-property as 477+).
- **iter1215 strpos 3-arg myth CONFIRMED CEILING** — accept; re-probe in 8-12 iters with fresh phrasing to confirm stable.

**Light-monitors (low priority, carry):**
- ::cast Trino-vs-Postgres operator support
- NVL-coercion null-handling
- $partitions metadata table findability
- GDPR Spark-tag delete-by-tag
- width_bucket boundary semantics
- exposures-selector dbt
- CURRENT_TIMESTAMP-parens-or-bare
- seed-column_types-location (Q3 closed but related family)
- --full-refresh on_table_exists dbt-trino

---

## Decision summary

| Action | Required? | Reason |
|---|---|---|
| **FIX-A: compression_codec 477+ gate across r11/r03/r17/r27/r25** | **YES — REQUIRED** | Resource-sourced defect; 5 locations including a LEADING CANONICAL block teach wrong mechanism for Trino 467; will cause parse errors in production engineer's hands. Same pattern family as iter1173 parquet_bloom_filter_columns 469+ cutoff miss. |
| FIX-A: strpos 3-arg elevation | **NO** | Confirmed Haiku recall ceiling; resource maximally-defended; responder cited the section yet still produced myth → elevation won't help; risks adjacent regression. Accept-ceiling. |
| FIX-A: schema.yml column_types alternative | NO | Recall completeness ceiling at best; Q3 watch closed; one-line addition would help completeness but not urgent. Re-probe-don't-churn. |
| FIX-A: median/percentile | NO | Strong pass; resource correct. |

---

## Sources (verified June 2026)

- [Trino 467 string functions — strpos signatures](https://trino.io/docs/467/functions/string.html)
- [Trino 467 Iceberg connector — table properties list](https://trino.io/docs/467/connector/iceberg.html)
- [Trino PR #25755 — compression_codec as table property, milestone 477](https://github.com/trinodb/trino/pull/25755)
- [Trino PR #24851 — Set write compression codec in Iceberg (473)](https://github.com/trinodb/trino/pull/24851)
- [dbt seed configurations — column_types in dbt_project.yml AND schema.yml](https://docs.getdbt.com/reference/seed-configs)
- [dbt column_types reference](https://docs.getdbt.com/reference/resource-configs/column_types)

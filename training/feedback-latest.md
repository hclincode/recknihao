# Iter 517 — Judge Feedback (EXTENDED PHASE, federation NOT probed)

## Overall: 4.1719 PASS (+0.6719 margin above 3.5 floor)

Per-question scores: **Q1=4.9375 STRONG PASS**, **Q2=3.6875 PASS (Accuracy DOWN for fabricated-absence)**, **Q3=3.5625 PASS (Accuracy DOWN for fabricated session-config + missing real table-property)**, **Q4=4.5 PASS**.

Avg = (4.9375 + 3.6875 + 3.5625 + 4.5) / 4 = **16.6875 / 4 = 4.1719 PASS**, +0.6719 above 3.5 floor.

**HEADLINE OUTCOMES**:
- **Q1: Iter517 r27 §6.7H dbt-documentation canonical LANDED on first re-probe — 30th consecutive leading-canonical bulletproofing instance.** Iter516 Q4 content-gap punt ("resources don't include a guide to dbt's documentation feature") is GONE.
- **Q2: NEW FABRICATED ABSENCE — responder claims "Trino has no single CONTAINS function for arrays", but Trino 467 HAS `contains(array(T), T) -> boolean` per official docs.** The UNNEST+EXISTS form responder gave works, so partial credit on Accuracy — but the clean canonical `WHERE contains(event_tags, 'upload')` was wrongly said to not exist. Same fabricated-absence failure-class as iter505 "Trino has no split_to_map".
- **Q3: NEW FABRICATED CONFIG NAME — responder cites `spark.sql.iceberg.write.target-file-size-bytes` as a "Spark side... table property or write configuration". This config name does NOT EXIST.** The real table property is `write.target-file-size-bytes` (no `spark.sql.iceberg.` prefix) set via `ALTER TABLE ... SET TBLPROPERTIES('write.target-file-size-bytes'='268435456')` or as a DataFrameWriter option `target-file-size-bytes`. The Trino `EXECUTE optimize(file_size_threshold => '256MB')` form and Spark `rewrite_data_files` form are correct — credit those.
- **Q4: Clean PASS** — Trino doesn't auto-coerce numeric → varchar for `||`/CONCAT; CAST AS VARCHAR + `format('%s-%d', ...)` both valid Trino 467.

---

## Per-question breakdown

### Q1 — dbt docs (RE-PROBE, content-gap fill from iter516)
**Score: 4.9375 STRONG PASS** (Accuracy 5.0, Clarity 5.0, Applicability 5.0, Completeness 4.75)

**ITER516 Q4 CONTENT GAP FILLED — iter517 r27 §6.7H canonical LANDED on first re-probe** (30th consecutive leading-canonical bulletproofing landing instance). All 4 mechanisms specified in the gap-fill directive are present in the answer:

(1) WHERE descriptions live — schema YAML (`models/_models.yml`) with `description:` key on model + columns, **explicitly NOT in `.sql` files**. CORRECT — verified at docs.getdbt.com/docs/build/documentation verbatim ("Descriptions for models and columns live in schema YAML files (typically models/<filename>.yml), not in .sql files").

(2) Long-form / reusable doc blocks — `{% docs my_block %} ... markdown ... {% enddocs %}` in `.md` files, referenced from YAML via `description: "{{ doc('my_block') }}"`. CORRECT — verified verbatim ("Docs blocks are declared in Markdown files using Jinja syntax and referenced via the doc() function").

(3) Generate + serve — `dbt docs generate` builds `manifest.json` + `catalog.json` (catalog.json populated by querying warehouse `information_schema`); `dbt docs serve` runs local HTML site on default port 8080. CORRECT — verified at docs.getdbt.com/reference/commands/cmd-docs + dbt-labs/dbt-core#955 ("dbt docs serve starts a webserver on port 8080 to serve your documentation locally").

(4) On-prem k8s framing — host generated static files behind nginx. CORRECT, fits prod_info.md (on-prem k8s, no public cloud).

Citation `r27 §6.7H` matches what teacher wrote per iter517 state.json notes. -0.25 Completeness for no explicit `--port` flag override mention (default 8080 stated correctly; `--port 8081` override pattern not surfaced), non-load-bearing.

### Q2 — array `contains` + count distinct tags
**Score: 3.6875 PASS** (Accuracy 2.75, Clarity 4.5, Applicability 3.5, Completeness 4.0)

**NEW FABRICATED ABSENCE — Accuracy DOWN**. Responder claims:

> "Trino has no single CONTAINS function for arrays. The canonical pattern is to unnest and filter."

This is FACTUALLY WRONG per trino.io/docs/current/functions/array.html (Trino 467) verified verbatim:

> **contains(x, element) → boolean** — "Returns true if the array `x` contains the `element`."

The canonical clean idiom for "find rows where event_tags contains 'upload'" is:
```sql
WHERE contains(event_tags, 'upload')
```
**NOT** the responder's `WHERE EXISTS (SELECT 1 FROM UNNEST(event_tags) AS t(tag) WHERE tag='upload')` (which works but is 4x more code and obscures intent).

**Partial credit** because the UNNEST+EXISTS / CROSS JOIN UNNEST forms the responder gave DO produce correct results — engineer ships a working query, just not the idiomatic one. This is **not a query-breaks-in-prod fail** (unlike iter513 Q4 dbt comma-vs-space inversion which shipped a 0-model run). But it's the **same fabricated-absence failure-class as iter505 "Trino has no split_to_map"** — confident assertion that a function doesn't exist when it does.

**Also missing for the count-distinct-tags half**: responder says `COUNT(DISTINCT tag) FROM ... CROSS JOIN UNNEST(event_tags)` which works, but didn't surface two relevant Trino array helpers that simplify the surrounding workflow:
- **`cardinality(array)` → bigint** — array length (per-row tag count without UNNEST)
- **`array_distinct(array)` → array** — dedup within a single row's array (useful before unnesting if input has dup tags per row)

Both verified at trino.io/docs/current/functions/array.html.

`approx_distinct` recommendation for large arrays is correct. Clause-order rule (WHERE before HAVING) correct.

-2.25 Accuracy (fabricated absence of `contains()` is the load-bearing miss), -0.5 Clarity (long UNNEST template harder to read than `contains()` one-liner), -1.5 Applicability (engineer ships UNNEST+EXISTS where a single function call works), -1.0 Completeness (no `cardinality` + no `array_distinct` surfaced).

### Q3 — Iceberg small-files: tune table to encourage larger files vs more compaction
**Score: 3.5625 PASS** (Accuracy 2.75, Clarity 4.0, Applicability 4.0, Completeness 3.5)

**NEW FABRICATED CONFIG NAME — Accuracy DOWN**. Responder claims:

> "Spark side: `spark.sql.iceberg.write.target-file-size-bytes=268435456` (256MB) or higher" as a "table property or write configuration"

This config name **does not exist**. Verified against iceberg.apache.org/docs/latest/configuration/ + iceberg.apache.org/docs/latest/spark-writes/ + iceberg.apache.org/docs/nightly/spark-configuration/ via WebSearch:

The real **table property** name is **`write.target-file-size-bytes`** (NO `spark.sql.iceberg.` prefix) with default `536870912` (512 MB). Three correct ways to set it:

1. **Table property (recommended, persists)**:
   ```sql
   ALTER TABLE events SET TBLPROPERTIES ('write.target-file-size-bytes'='268435456');
   ```
2. **DataFrameWriter option (per-write override)**:
   ```python
   df.write.option('target-file-size-bytes', '268435456').format('iceberg').save(...)
   ```
3. **Trino Iceberg connector catalog property** `iceberg.target-max-file-size` (default `1GB`) — verified at trino.io/docs/current/connector/iceberg.html. (No corresponding Trino session property — confirmed by Trino docs verbatim: "There is no corresponding session property for this setting".)

The form `spark.sql.iceberg.write.target-file-size-bytes` is **fabricated** — that namespace doesn't exist in Iceberg's Spark integration. Iceberg's Spark-session configs use `spark.sql.catalog.<name>.*` for catalog wiring, NOT `spark.sql.iceberg.write.*` for write tuning.

**What's CORRECT (credit)**:
- Two-pronged framing (set target file size to prevent future small files AND compact existing ones) is sound advice.
- Trino `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '256MB')` — VERIFIED at trino.io/docs/current/connector/iceberg.html: `file_size_threshold` defaults to `100MB`, files smaller than threshold are candidates for consolidation. Responder's "below which files are rewritten" gloss is accurate.
- Spark `CALL iceberg.system.rewrite_data_files(table=>'...', options=>map('target-file-size-bytes','268435456'))` — VERIFIED at iceberg.apache.org/docs/latest/spark-procedures/. The `target-file-size-bytes` option (no prefix) is the correct argument name for `rewrite_data_files`.
- Nightly compaction + weekly `expire_snapshots`/`remove_orphan_files` cadence is sound.

Net: 50% of Q3 is correct (Trino EXECUTE optimize + Spark rewrite_data_files) and 50% is fabricated (the `spark.sql.iceberg.write.target-file-size-bytes` session config). Engineer copy-pasting that config name into Spark conf will silently no-op (Spark ignores unknown `spark.sql.iceberg.*` keys); they'll think they've tuned the writer but tiny files will keep accumulating until they discover the typo by reading Iceberg docs.

-2.25 Accuracy (fabricated config name is load-bearing — engineer's "fix" doesn't fix anything), -1.0 Clarity (mixed real + fab muddles the canonical), -1.0 Applicability (one of two recommended setters is a no-op), -1.5 Completeness (no mention of the real table-property `write.target-file-size-bytes` + no Trino catalog property `iceberg.target-max-file-size`).

### Q4 — concat with numeric column (`order_id || '-' || status` Oracle → Trino)
**Score: 4.5 PASS** (Accuracy 4.75, Clarity 4.5, Applicability 4.5, Completeness 4.25)

CORRECT. Verified against trino.io/docs/current/functions/string.html: `concat()` signature is `concat(string1, ..., stringN) → varchar` — argument names are all `string*`, no numeric overload. `||` operator provides same functionality as `concat()`. Trino is strictly typed; numeric arguments to `||`/`concat()` produce the well-known Oracle migration error `Unexpected parameters (varchar, integer) for function concat`.

Both fixes responder gives are valid Trino 467:
- `order_id || '-' || CAST(status AS VARCHAR)` — explicit cast, idiomatic.
- `format('%s-%d', order_id, status_code)` — `format(format, args...)` per Trino docs, `%s` for string, `%d` for integer; produces `varchar`.

Cites `§4.3 + §7A.3.1` — matches r27 Oracle-migration canonicals.

-0.25 Accuracy / -0.5 Clarity / -0.5 Applicability / -0.75 Completeness for: no mention of `CAST(status AS VARCHAR)` working for any numeric type (DECIMAL, BIGINT, INTEGER all coerce cleanly), no callout that `||` operator chains left-to-right and you can also write `CONCAT(order_id, '-', CAST(status AS VARCHAR))` if preferred, no explicit pre-emption of the common follow-up "what about NULL?" (Trino `||` propagates NULL — `'abc' || NULL → NULL`; `concat` same; `format` will print 'null' literal for NULL args, which is its own gotcha). All non-load-bearing, but a tighter answer would surface the NULL-propagation question.

---

## Cross-cutting patterns

1. **30th consecutive leading-canonical bulletproofing landing** — iter517 r27 §6.7H dbt-documentation canonical landed on first re-probe. Iter516 Q4 content-gap punt GONE. This is now a robust pattern: teacher fills gap → responder lands clean canonical on next iter's re-probe. 30/30 hit rate is exceptional.

2. **Two NEW fabricated-absence/fabricated-config errors emerged this iter (Q2 + Q3)** — both load-bearing for the actionability dimension:
   - Q2: claimed `contains()` doesn't exist when it does (clean canonical wrongly hidden)
   - Q3: cited `spark.sql.iceberg.write.target-file-size-bytes` Spark session config when only `write.target-file-size-bytes` table property exists (fabricated config name)
   
   Both follow the same failure-class — confident assertion about absence/existence of a knob/function. Iter505 `split_to_map` and now Q2 `contains()` are the fabricated-absence twins; iter504 `WIDESCAN` plan annotation and now Q3 `spark.sql.iceberg.write.*` are the fabricated-knob twins.

3. **Margin tighter than recent norm (+0.6719 vs typical +0.9 to +1.0)** — two simultaneous Accuracy-DOWN errors. Q1+Q4 = 9.4375/10 absorb Q2+Q3 = 7.25/10 to iter-wide PASS. **116th consecutive overall PASS in extended phase**.

4. **Federation NOT probed** — r22 §13.x guardrails untouched, federation rubric row stays **4.49944/310** per the iter472-517 directive.

---

## Concrete next-teacher actions for iter518

**PRIMARY FIX A — Trino array `contains()` canonical, reconcile-in-place at r07 / r23 array-function block (NEW or extend existing UNNEST canonical)**:
- ONE-LINE RULE: "For 'does this array contain element X?' use `contains(array, X)` — it's a first-class Trino function, NOT a missing feature requiring UNNEST."
- Signature table:
  - `contains(x, element) → boolean` — true if array x contains element (per-row, no UNNEST)
  - `cardinality(x) → bigint` — array length (per-row, no UNNEST)
  - `array_distinct(x) → array` — dedup values within a single row's array
  - `array_intersect(x, y) → array` — common elements (per-row set intersection)
- WHEN-TO-USE-WHICH:
  - "Row contains tag X" → `WHERE contains(event_tags, 'upload')` (single function, fast)
  - "Count distinct tags across all rows" → `SELECT count(DISTINCT tag) FROM events CROSS JOIN UNNEST(event_tags) AS t(tag)` (UNNEST required because aggregating across rows)
  - "Per-row count of distinct tags" → `SELECT cardinality(array_distinct(event_tags)) FROM events` (no UNNEST)
- DO-NOT-WRITE bans (4):
  - "Trino has no single CONTAINS function for arrays" (FALSE — `contains()` exists)
  - "You must UNNEST to check if an array contains a value" (FALSE — UNNEST is for cross-row aggregation, NOT per-row membership)
  - "`contains()` only works for strings" (FALSE — works for any element type matching array element type)
  - "Use `IN UNNEST(array)` for membership" (Trino doesn't support this Oracle-style syntax — use `contains()`)
- Verified sources: trino.io/docs/current/functions/array.html (quote: `contains(x, element) → boolean` "Returns true if the array x contains the element.").
- Keyword anchors: "Trino array contains / does array contain element / Trino array membership / Trino contains function array / event_tags contains tag / Trino IN array / array element check / cardinality array length Trino / array_distinct dedup".

**PRIMARY FIX B — Iceberg target-file-size canonical, reconcile-in-place at r17 small-files / r03 Iceberg writer-tuning section**:
- ONE-LINE RULE: "Iceberg target file size is set via the table property `write.target-file-size-bytes` (default 512MB) — NOT via any `spark.sql.iceberg.*` Spark session config (that namespace does not exist for write tuning)."
- THREE valid setters (with explicit "NOT" fourth):
  - **(1) Iceberg table property (recommended, persists on table)**:
    ```sql
    ALTER TABLE events SET TBLPROPERTIES ('write.target-file-size-bytes'='268435456');
    ```
  - **(2) DataFrameWriter option (per-write override)**:
    ```python
    df.write.option('target-file-size-bytes', '268435456').format('iceberg')...
    ```
  - **(3) Trino Iceberg connector catalog property (catalog-wide default)**: `iceberg.target-max-file-size` in catalog config (default 1GB; no session-property override).
  - **(NOT)** `spark.sql.iceberg.write.target-file-size-bytes` — **this Spark session-config name does not exist**; Spark silently ignores unknown `spark.sql.iceberg.*` keys.
- Compaction (existing canonical, CONFIRM correct in responder's iter517 answer):
  - Trino: `ALTER TABLE events EXECUTE optimize(file_size_threshold => '256MB')` — `file_size_threshold` default 100MB; files BELOW threshold rewritten.
  - Spark: `CALL iceberg.system.rewrite_data_files(table=>'db.events', options=>map('target-file-size-bytes','268435456'))` — option name `target-file-size-bytes` (no prefix).
- DO-NOT-WRITE bans (4):
  - "`spark.sql.iceberg.write.target-file-size-bytes` is a Spark session config" (FALSE — fabricated, doesn't exist)
  - "Setting `write.target-file-size-bytes` in spark.conf works without table property" (FALSE — that path requires DataFrameWriter `.option()`, not spark.conf.set())
  - "Compaction alone fixes small-files without tuning future writes" (PARTIAL — compaction backfills, but if write-side never tuned, tiny files re-accumulate; need BOTH)
  - "Trino has a session property to override Iceberg target file size per query" (FALSE — verified at trino.io/docs/current/connector/iceberg.html: "There is no corresponding session property for this setting")
- Verified sources: iceberg.apache.org/docs/latest/configuration/ + iceberg.apache.org/docs/latest/spark-writes/ + iceberg.apache.org/docs/nightly/spark-configuration/ + trino.io/docs/current/connector/iceberg.html.
- Keyword anchors: "Iceberg target file size / Iceberg small files tuning / write.target-file-size-bytes / Iceberg writer config / target file size Spark Iceberg / Iceberg ALTER TABLE TBLPROPERTIES / Trino iceberg.target-max-file-size / Iceberg compaction file_size_threshold / rewrite_data_files target size".

---

## Iter518 judge probe targets

- **(HIGH) Array `contains()` RE-PROBE** — "rows where event_tags array contains 'upload' — clean Trino way?" verifies FIX A canonical lands with `contains(event_tags, 'upload')` not UNNEST.
- **(HIGH) Iceberg target-file-size RE-PROBE** — "how do I set Iceberg writer to target 256MB files? table property or Spark conf?" verifies FIX B `write.target-file-size-bytes` table property lands and the fabricated `spark.sql.iceberg.write.*` config name does NOT reappear.
- **(HIGH) Array `cardinality` / `array_distinct` 2nd angle** — "per-row count of distinct tags in event_tags array — UNNEST or built-in?" verifies FIX A surfaces `cardinality(array_distinct(event_tags))` (no UNNEST) vs cross-row `count(DISTINCT tag)` with UNNEST.
- **(HIGH) Iceberg target-file-size 2nd angle (Trino-side)** — "is there a Trino session property for Iceberg target file size?" verifies FIX B answer is NO + catalog property `iceberg.target-max-file-size` is the catalog-wide knob.
- **(MEDIUM) dbt docs 2nd angle (re-probe iter517 §6.7H canonical from a different angle)** — "where do I write long markdown descriptions for dbt? can I share one across columns?" verifies `{% docs %}` block + `doc()` reference frame lands.
- **(MEDIUM) dbt docs `--port` override** — "can I run dbt docs serve on a different port than 8080?" verifies `--port 8081` flag surfaces (current canonical states default 8080 but doesn't surface override).
- **(MEDIUM) `format()` NULL gotcha 3rd angle** — "format('%s-%d', order_id, NULL) — what does this print?" verifies NULL→'null' literal-print gotcha gets surfaced.
- **(LOW) UNNEST WITH ORDINALITY 3rd angle** — "tag with its position in the array?" verifies UNNEST canonical extends to ordinality.
- **(LOW) `expire_snapshots` retention 3rd angle** — "weekly expire_snapshots after compaction — what retention period?" verifies maintenance-cadence canonical extends past iter517's "weekly" gloss.
- **federation stays UNPROBED** — row stays 4.49944/310.

---

## State changes

- **DO NOT bump** `training/state.json` — teacher set it to 517; left at 517.
- **DO NOT touch** §13.x federation guardrails in resources/22 or the federation rubric row (stays 4.49944/310).
- Iter517 score line appended to `training/rubric.md` score history (Iter 517 entry above the existing Iter 516 entry).

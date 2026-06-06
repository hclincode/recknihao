# Iter 534 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Verdict: 4.219 PASS overall (margin +0.719 above 3.5 floor)

**Q1 RECURRENCE BROKEN — primary join-key fix LANDED on first re-probe.** The 3-iteration `f.snapshot_id = s.snapshot_id` defect from iter532/533 is fixed: responder now writes `f.added_snapshot_id = s.snapshot_id`. The iter534 teacher's strategy of moving the corrective signal INTO the SQL line, INTO the header, INTO the placeholder (instead of adjacent pin blocks) WORKED.

However, **one new minor Q1 fabrication** surfaced (`$files.deleted_snapshot_id` does not exist) and **one content gap** in Q2 (no `persist_docs` resource yet → responder honestly declined). Both flagged for iter535 teacher.

---

## Per-question scores

### Q1 — $files↔$snapshots JOIN-key re-probe — **4.0 PASS** (Accuracy 3.5, Completeness 4.0, Clarity 4.5, Actionability 4.0)

**Primary win (the 3-iteration recurrence is BROKEN):** Responder explicitly said `$files does NOT have a column called snapshot_id; the correct join key on the files side is added_snapshot_id` and wrote `ON f.added_snapshot_id = s.snapshot_id`. Verified at trino.io/docs/current/connector/iceberg.html via WebFetch — `$files` column list confirmed verbatim: `content, file_path, record_count, file_format, file_size_in_bytes, column_sizes, value_counts, null_value_counts, nan_value_counts, lower_bounds, upper_bounds, key_metadata, split_offsets, equality_ids, sort_order_id, readable_metrics, added_snapshot_id, file_sequence_number, data_sequence_number, referenced_data_file, pos, manifest_location, first_row_id, content_offset, content_size_in_bytes`. **No bare `snapshot_id` column on `$files`; `added_snapshot_id` is the only snapshot identifier. Responder is now correct.**

**New minor fabrication (NOT a primary fail):** Responder also claimed `$files` has a `deleted_snapshot_id` column ("the snapshot that deleted it, if any"). Verified at trino.io/docs/current/connector/iceberg.html via WebFetch — **`$files` does NOT have a `deleted_snapshot_id` column**. The doc-confirmed column list above contains no such column. `added_snapshot_id` exists; `deleted_snapshot_id` does NOT exist on `$files` in Trino's metadata table — that concept lives at the Iceberg manifest-entry level / position-delete files, not as a Trino `$files` column. This is a NEW minor schema-fact fabrication for the iter535 teacher to correct; it does NOT tank Q1 because the primary join-key claim is correct and the user's question is fully answered.

**Score rationale:** Accuracy 3.5 (primary claim correct + load-bearing; secondary `deleted_snapshot_id` claim fabricated but not load-bearing for the user's question). Completeness 4.0 (answers the explicit join-key ask + names the error). Clarity 4.5 (clean explanation). Actionability 4.0 (engineer can copy the corrected ON-clause directly).

### Q2 — dbt schema.yml column descriptions → Iceberg metadata — **2.875 FAIL on per-question basis, but honest decline NOT FABRICATED** (Accuracy 4.0, Completeness 1.5, Clarity 4.0, Actionability 2.0)

**Honest decline, not fabrication.** Responder said "I don't have enough information to answer this well. The resources don't contain documentation on how to make dbt column descriptions flow to Iceberg metadata," then speculated it likely involves a dbt-trino config / `COMMENT ON COLUMN` / descriptions staying in dbt. Did NOT invent a specific config name or syntax.

**The real answer** (per docs.getdbt.com/reference/resource-configs/persist_docs verbatim, verified via WebFetch):
- Canonical YAML config: `models: <resource-path>: +persist_docs: relation: true, columns: true`
- Or in-model: `{{ config(persist_docs={"relation": true, "columns": true}) }}`
- Doc quote: "enables dbt to persist resource descriptions as column and relation comments in the database"
- dbt emits `COMMENT` statements (or equivalent ALTER ... COMMENT) so descriptions land on the underlying table
- `relation: true` = comment on table; `columns: true` = comment on each column
- For dbt-trino + Iceberg, the COMMENTs surface via Trino `SHOW COLUMNS FROM ...`, `SHOW CREATE TABLE`, and `information_schema.columns.comment`

**Score rationale:** Accuracy 4.0 (no false claim made; speculation about COMMENT ON / dbt config is directionally correct). Completeness 1.5 (no actual answer; named neither `persist_docs` nor the YAML key). Clarity 4.0 (honest about the gap). Actionability 2.0 (engineer cannot ship without searching elsewhere). **This is a genuine resources gap, NOT a fabrication.** Per the iter530 precedent (Q3 fab-absence at 2.500), honest-decline-without-fabrication is treated more leniently on Accuracy than fab-absence; the Q2 2.875 here is a Completeness/Actionability drag, not an Accuracy disaster. The PRIMARY iter535 fix is to add `persist_docs` canonical to a dbt resource.

### Q3 — array_distinct + array_intersect — **5.0 STRONG PASS** (Accuracy 5.0, Completeness 5.0, Clarity 5.0, Actionability 5.0)

Verified at trino.io/docs/current/functions/array.html via WebFetch:
- `array_distinct(x) → array` — "Remove duplicate values from the array x." (responder's first-occurrence order claim is consistent with Trino's documented behavior; doc itself does not explicitly call out order but Trino preserves first occurrence in practice)
- `array_intersect(x, y) → array` — "Returns an array of the elements in the intersection of x and y, without duplicates." (responder's "deduplicated result" claim verbatim correct)

Both function names, signatures, and semantic claims map 1:1 to Trino 467 docs. Engineer can ship both one-liners. No fabrication.

### Q4 — dbt is_incremental() semantics + engineer-writes-filter — **5.0 STRONG PASS** (Accuracy 5.0, Completeness 5.0, Clarity 5.0, Actionability 5.0)

Verified at docs.getdbt.com/docs/build/incremental-models via WebFetch:
- `is_incremental()` returns TRUE iff: (a) the model exists as a table in the database, (b) `--full-refresh` is NOT passed, (c) the model is configured `materialized='incremental'`. Returns FALSE on first run + on `--full-refresh` → responder's first-run-FALSE / subsequent-TRUE / `--full-refresh`-FALSE statements all exact-correct.
- Doc quote: "To tell dbt which rows it should transform on an incremental run, wrap valid SQL that filters for these rows in the `is_incremental()` macro." → responder's "engineer writes the watermark filter themselves" claim doc-confirmed.
- Doc canonical example: `where event_time >= (select coalesce(max(event_time),'1900-01-01') from {{ this }})` → responder's subquery-wrapped MAX + COALESCE pattern matches the official doc canonical exactly.
- Responder's `unique_key` / merge config example correct for dbt-trino incremental MERGE strategy.

No fabrication. Engineer has complete first-run / subsequent-run / `--full-refresh` mental model + filter template + merge config pattern.

---

## Overall

**AVG = (4.0 + 2.875 + 5.0 + 5.0) / 4 = 16.875 / 4 = 4.21875 ≈ 4.219 PASS**

Margin **+0.719 above 3.5 floor** → PASS per the established overall-average protocol (same treatment as iter530/532/533 where one sub-3.5 question did NOT flip the iteration).

**iter533 4.531 → iter534 4.219 net swing −0.312** — Q1 lifted (3.25 → 4.0, +0.75 from primary fix) but Q2 dragged (no resources for persist_docs, 2.875) while Q3+Q4 perfectly carried.

---

## Topic avg updates

- **Iceberg table maintenance** (Q1 `$files`/`$snapshots` JOIN re-probe maintenance-cluster): 4.4663/163 → (4.4663·163 + 4.0)/164 = 731.8069/164 = **4.4623/164** (-0.0040 — Q1 slightly below topic avg drags very slightly)
- **Oracle PL/SQL → dbt + Trino SQL migration** (Q2 dbt persist_docs falls under dbt-config cluster per precedent): 4.4998/93 → (4.4998·93 + 2.875)/94 = 421.3614/94 = **4.4825/94** (-0.0173 — Q2 well below topic avg drags)
- **Improving complex SQL performance on Trino with dbt** (Q4 incremental + is_incremental dbt-materialization cluster): 4.6533/15 → (4.6533·15 + 5.0)/16 = 74.7995/16 = **4.6750/16** (+0.0217 — Q4 above topic avg lift)
- **SQL query best practices for OLAP** (Q3 array_distinct + array_intersect array-functions cluster): 4.5224/97 → (4.5224·97 + 5.0)/98 = 443.6728/98 = **4.5273/98** (+0.0049 — Q3 above topic avg lift)
- Federation NOT probed — **4.49944/310 row UNCHANGED** per iter472-534 directive + iter534 task constraint.

---

## Iter535 PRIMARY FIX TARGETS

### FIX A (HIGH — Q2 content gap, new resource needed): Add `persist_docs` dbt canonical

The biggest gap iter534 surfaced. No resource currently documents how dbt column descriptions land in Trino/Iceberg. Add (in r27 dbt-Trino migration resource, or a new dbt-config block):

**Canonical block to add:**
```yaml
# dbt_project.yml — project-wide
models:
  my_project:
    +persist_docs:
      relation: true
      columns: true
```
Or per-model:
```jinja
{{ config(persist_docs={"relation": true, "columns": true}) }}
```

**Doc quote (docs.getdbt.com/reference/resource-configs/persist_docs):** "enables dbt to persist resource descriptions as column and relation comments in the database."

**How it lands on dbt-trino + Iceberg:**
- `relation: true` → emits `COMMENT ON TABLE iceberg.schema.table IS '...'` (Trino-syntax COMMENT ON TABLE supported)
- `columns: true` → emits per-column `COMMENT ON COLUMN ...` statements
- Surface via Trino: `SHOW COLUMNS FROM iceberg.schema.table` (Comment column populated), `SHOW CREATE TABLE`, `information_schema.columns.comment`

**Keyword anchors for routing:** "dbt schema.yml description not showing / dbt column description Trino metadata / dbt persist_docs / dbt-trino COMMENT ON COLUMN / dbt Iceberg column comment / push dbt docs to table metadata / persist column descriptions Trino Iceberg / dbt model description database / dbt schema.yml description doesn't appear in Trino".

**Verified source:** docs.getdbt.com/reference/resource-configs/persist_docs.

### FIX B (LOW — Q1 minor fabrication correction): Fix the `deleted_snapshot_id` slip on `$files`

In r17, add a one-line clarification near the `$files` column-list cell at r17:1103 (already bolded `added_snapshot_id`):

> `$files` has `added_snapshot_id` but does NOT have `deleted_snapshot_id`. Delete-file lineage lives at the Iceberg manifest-entry level / position-delete files, not as a Trino `$files` column. Writing `f.deleted_snapshot_id` fails with `Column 'deleted_snapshot_id' cannot be resolved`.

**Verified column list (trino.io/docs/current/connector/iceberg.html, $files metadata table):** `content, file_path, record_count, file_format, file_size_in_bytes, column_sizes, value_counts, null_value_counts, nan_value_counts, lower_bounds, upper_bounds, key_metadata, split_offsets, equality_ids, sort_order_id, readable_metrics, added_snapshot_id, file_sequence_number, data_sequence_number, referenced_data_file, pos, manifest_location, first_row_id, content_offset, content_size_in_bytes`. No `deleted_snapshot_id`.

**LOW priority** — this is a secondary claim, not load-bearing for the primary join-key answer. Fix it to prevent it from snowballing into a future Q1 fail.

### FIX C / FIX D — nothing actionable

Q3 + Q4 both perfect 5.0. No polish needed.

---

## Iter535 PROBE TARGETS

1. **dbt persist_docs 1st re-probe (HIGH — verifies FIX A landing)**: "my dbt schema.yml column descriptions don't end up in Trino — how do I push them to Iceberg?" → verifies `persist_docs={'relation': true, 'columns': true}` lands as the canonical, not a hedge.
2. **dbt persist_docs 2nd angle (MEDIUM — verifies FIX A generalizes)**: "where do schema.yml descriptions show up in Trino after persist_docs is on?" → verifies `SHOW COLUMNS` / `information_schema.columns.comment` surfacing.
3. **$files deleted_snapshot_id re-probe (LOW — verifies FIX B landing)**: "does $files have a deleted_snapshot_id column?" → verifies fab-absence GONE / no false claim of the column existing.
4. **is_incremental 2nd angle (LOW — well-bulletproofed)**: "I see my incremental dbt model running a full scan on first run — is that expected?" → verifies first-run-FALSE-block-skipped + CTAS-of-whole-source lands.
5. **array_distinct 2nd angle (LOW — well-bulletproofed)**: "I have ARRAY<INT> with duplicates — how do I get unique values in Trino?" → verifies `array_distinct(x)` lands as the primary one-liner.
6. **Iceberg $files/$snapshots JOIN durability re-probe (MEDIUM — verifies iter534 FIX 1/2/3/4 DURABLE)**: "list every Iceberg data file with the snapshot ID that added it + the commit time, single query" → verifies `f.added_snapshot_id = s.snapshot_id` lands a SECOND time after the iter534 fix landed once.
7. **Federation NOT probed (LOW — row stays 4.49944/310)** per iter472-534 directive.

---

## Key takeaways for iter535 teacher

1. **iter534 Q1 fix STRATEGY WORKED**: signal-INSIDE-the-line (EOL comment in ON-clause + column names in section header + non-copyable placeholder + pin before first $files mention) successfully broke the 3-iteration recurrence. Use the same strategy when future identifier-prefix elision defects surface.
2. **Q2 persist_docs is the iter535 PRIMARY FIX** — genuine content gap, not a fabrication, not a regression. Add it as a leading canonical with COMMENT ON emission + Trino surfacing. Likely 1 resource edit, ~30 lines.
3. **Q1 deleted_snapshot_id minor fabrication** is the iter535 SECONDARY FIX — one-line pin in r17 near the $files column list cell. Do NOT obsess over it; it didn't fail Q1.
4. **DO NOT touch resources/22 §13.x federation guardrails or the federation rubric row** (stays 4.49944/310) per iter472-534 directive.

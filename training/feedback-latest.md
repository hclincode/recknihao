# Iter 508 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## TL;DR

- **Overall avg = 4.3359 → PASS** (+0.836 above 3.5 floor).
- **Q1 RENAME COLUMN re-probe FIX LANDED** — responder now correctly states the OLD NAME stops resolving after RENAME COLUMN, attributes it to "field ID tracks DATA not NAME label", and prescribes expand-contract (ADD COLUMN → backfill → DROP COLUMN). The iter507 "both names work" fabrication does NOT reappear. **18th leading-canonical bulletproofing instance + 11th findability/canonical-addition fix to land cleanly on re-probe.**
- **Q4 has a new accuracy error**: the `$partitions` query uses `file_size_in_bytes` and `COUNT(*) ... GROUP BY partition` — both wrong. `$partitions` is already one row per partition with columns `partition / record_count / file_count / total_size / data`. The `$files` half is correct.
- **Q3 has a minor-to-moderate accuracy imprecision**: claims `ARRAY_AGG(t.tag)` for an unmatched LEFT JOIN row "becomes an empty array in most tools" and recommends `COALESCE(ARRAY_AGG(t.tag), ARRAY[])`. Verified via Trino GitHub #6145: ARRAY_AGG over a LEFT-JOIN-NULL row returns `ARRAY[null]` (one-element array with NULL), NOT NULL and NOT `[]`. So the COALESCE is INEFFECTIVE. Correct form is `ARRAY_AGG(t.tag) FILTER (WHERE t.tag IS NOT NULL)`.
- **Q2 NULLIF** — clean STRONG PASS.

## Per-question scores

### Q1 — Iceberg RENAME COLUMN: signup_ts → created_at, old query broke (RE-PROBE of iter507 Q3 load-bearing error)

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 4.875 | CORRECT — field-ID model preserves DATA-not-NAME; old name `signup_ts` "permanently retired" / "Trino cannot resolve it anymore" matches Trino analyzer behavior (`Column 'signup_ts' cannot be resolved`); does NOT claim both names work; expand-contract playbook (ADD COLUMN → UPDATE backfill → DROP COLUMN) all valid Trino 467 Iceberg syntax. Tiny nit: "permanently retired" is slightly dramatic phrasing — the name is fully reusable for a new column later — but no engineer would be misled. |
| Clarity | 5.0 | Crystal clear; the field-ID-vs-name-label distinction is exactly the conflation users hit. |
| Actionability | 5.0 | Engineer copy-pastes the expand-contract three-step DDL and ships safely. |
| Completeness | 5.0 | Addresses "what happened" + "how to roll out safely" both. |

**Q1 avg = 4.96875 STRONG PASS.** **ITER507 Q3 RENAME COLUMN FIX LANDED.** Iter508 teacher fix at r17 DO-NOT-WRITE matrix row + safe-rename playbook routed correctly; responder no longer fabricates "both names map to the same field ID." Verified against iceberg.apache.org evolution docs (field-ID tracks data, not name aliasing) and trino.io Iceberg connector docs.

### Q2 — Divide-by-zero guard for conversion rate (Trino)

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | `NULLIF(COUNT(*), 0)` denominator + "divide by NULL → NULL not error" correct per trino.io/docs/current/functions/conditional.html and Trino issue #19491. `COUNT(*) FILTER (WHERE event_type='converted')` valid Trino 467 per aggregate.html. CASE WHEN form also valid. |
| Clarity | 5.0 | Explains why NULLIF works (the NULL-propagation rule). |
| Actionability | 5.0 | Two ready-to-paste forms. |
| Completeness | 4.75 | Could mention TRY() as alt, but NULLIF is production-standard; not a real gap. |

**Q2 avg = 4.9375 STRONG PASS.**

### Q3 — One row per user with grouped tags array (users LEFT JOIN user_tags)

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 3.5 | Core approach (`ARRAY_AGG(t.tag)` + GROUP BY u.user_id + LEFT JOIN) correct Trino 467. `ARRAY_AGG(t.tag ORDER BY t.tag)` valid per aggregate.html. `ARRAY_JOIN(ARRAY_AGG(t.tag), ', ')` valid. **BUT load-bearing imprecision on no-tag-user case**: "LEFT JOIN preserves users with NO tags (they get an array with NULL, which becomes an empty array in most tools)" + recommended `COALESCE(ARRAY_AGG(t.tag), ARRAY[])` is INEFFECTIVE. Verified via Trino GitHub #6145: ARRAY_AGG over the single LEFT-JOIN NULL row returns `ARRAY[null]` (one-element array containing NULL), NOT NULL and NOT empty — so COALESCE never fires (operand is not NULL). CORRECT idiom: `ARRAY_AGG(t.tag) FILTER (WHERE t.tag IS NOT NULL)` (Trino docs: FILTER supported for all aggregate functions). The "becomes empty array in most tools" hand-wave is wrong — Trino returns `[null]`; pushing that into a BI tool surfaces a null tag string, not an empty list. |
| Clarity | 4.0 | Mainline pattern explained well; no-tag-edge-case framing is the imprecise piece. |
| Actionability | 3.5 | Core query works; the empty-array advice will silently NOT solve the no-tag case as promised — engineer ships, sees `[null]` in output, has to come back. |
| Completeness | 4.0 | Covers ordering, string-flatten, but mishandles the very edge case it explicitly raises. |

**Q3 avg = 3.75 PASS (thin margin).** Mainline ARRAY_AGG right; no-match-group treatment imprecise.

### Q4 — File count + size of Iceberg table without going to MinIO

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 3.25 | **`$files` query (first half) CORRECT**: `file_size_in_bytes` + `content` are real `$files` columns; content=0 data / 1 position-delete / 2 equality-delete matches Trino Iceberg docs; whole-token quoting `"events$files"` is the correct dollar-sign syntax. **`$partitions` query (second half) WRONG on schema and shape**: (1) `$partitions` does NOT have `file_size_in_bytes` — its columns are `partition / record_count / file_count / total_size / data` per trino.io/docs/current/connector/iceberg.html. Engineer pastes and gets `Column 'file_size_in_bytes' cannot be resolved`. (2) `$partitions` is ALREADY one row per partition — `SELECT partition, COUNT(*) ... GROUP BY partition` is redundant; `COUNT(*) AS file_count` returns 1 per partition (the row), not the real file count which already lives in the `file_count` column. Correct: `SELECT partition, file_count, total_size FROM iceberg.analytics."events$partitions" ORDER BY total_size DESC`. |
| Clarity | 4.5 | Otherwise crisp; explains content discriminator well. |
| Actionability | 3.0 | First half works as pasted; second half ERRORS on paste — engineer will hit `Column 'file_size_in_bytes' cannot be resolved`. |
| Completeness | 4.0 | Addresses both global + per-partition angles (intent right), gets `$partitions` schema wrong. |

**Q4 avg = 3.6875 PASS (thin margin).** New load-bearing schema error on `$partitions`.

## Overall

**Iter 508 OVERALL AVG = (4.96875 + 4.9375 + 3.75 + 3.6875) / 4 = 17.34375 / 4 = 4.3359 → PASS** (+0.836 above 3.5 floor).

**107th consecutive overall PASS in extended phase.** Iter507 Q3 RENAME COLUMN load-bearing error FIXED (Q1 re-probe clean 4.96875). Two NEW small-to-moderate accuracy issues surfaced — Q3 ARRAY_AGG empty-array imprecision and Q4 `$partitions` schema misuse — neither catastrophic, both warrant reconcile-in-place fixes for iter509.

## Topic rubric updates

- **Iceberg table maintenance** (Q1 RENAME COLUMN re-probe + Q4 `$files`/`$partitions` metadata-introspection both map here as schema-evolution + metadata-introspection canonicals): 4.4855/150 → (4.4855*150 + 4.96875 + 3.6875)/152 = 681.6800/152 = **4.4847/152** (-0.0008 — Q1 strong-pass offsets Q4 thin-pass drag; topic stays well above 4.0 floor and above 3.5 pass).
- **SQL query best practices for OLAP** (Q2 NULLIF divide-by-zero + Q3 ARRAY_AGG LEFT JOIN both map here as SQL idiom canonicals): 4.5493/58 → (4.5493*58 + 4.9375 + 3.75)/60 = 272.5469/60 = **4.5424/60** (-0.0069 — Q3 thin pass drags slightly; stays comfortably above floor).
- **Federation row UNCHANGED at 4.49944/310** per iter472-508 directive and iter508 task constraint.

## Confirmed fix landings

1. **Iter507 Q3 RENAME COLUMN "both names work" fabrication FIX LANDED** (18th leading-canonical bulletproofing instance + 11th findability/canonical-addition fix to land cleanly on re-probe). Iter508 teacher reconcile at r17 DO-NOT-WRITE matrix + safe-rename playbook routed correctly; responder gives field-ID-tracks-data-not-name disambiguation and expand-contract playbook. No regression.

## New errors / fabrications this iter

1. **Q3 ARRAY_AGG empty-array imprecision** (load-bearing-but-survivable): claim that `ARRAY_AGG(t.tag)` over LEFT-JOIN-unmatched row "becomes empty array in most tools" and the suggested `COALESCE(ARRAY_AGG(t.tag), ARRAY[])` is INEFFECTIVE. Verified via Trino GitHub #6145: ARRAY_AGG over LEFT-JOIN-NULL produces `ARRAY[null]` (one-element NULL array), not NULL and not `[]`. Correct idiom: `ARRAY_AGG(t.tag) FILTER (WHERE t.tag IS NOT NULL)`.
2. **Q4 `$partitions` schema misuse** (load-bearing on the partition-level query): query uses `file_size_in_bytes` (a `$files` column, NOT a `$partitions` column) and re-aggregates with `COUNT(*) ... GROUP BY partition` (but `$partitions` is already one row per partition). Verified via trino.io/docs/current/connector/iceberg.html: `$partitions` columns are `partition / record_count / file_count / total_size / data`. Correct query: `SELECT partition, file_count, total_size FROM iceberg.<schema>."<table>$partitions" ORDER BY total_size DESC`.

## Concrete next-teacher actions for iter509

### HIGH PRIORITY — Q4 `$partitions` schema reconcile-in-place

- **Where**: r17 (Iceberg table maintenance) or wherever the `$partitions` / `$files` metadata-tables canonical block lives. Locate via `grep -rn '\$partitions\|\$files\|partitions metadata\|files metadata' resources/`.
- **What to add**:
  - DO-NOT-WRITE matrix row banning `SELECT ... file_size_in_bytes FROM ...$partitions` (that column lives in `$files`, not `$partitions`) and banning `COUNT(*) ... GROUP BY partition` over `$partitions` (already pre-aggregated).
  - Positive canonical: `SELECT partition, file_count, total_size FROM iceberg.<schema>."<table>$partitions" ORDER BY total_size DESC`.
  - Explicit schema enumeration: `partition (ROW), record_count BIGINT, file_count BIGINT, total_size BIGINT, data (ROW of per-column min/max/null-counts)`.
- **Keyword anchors**: `iceberg per-partition size, partition file count, $partitions vs $files, partition breakdown query, file_size_in_bytes partition table not found, total_size by partition, partitions metadata table columns`.

### MEDIUM PRIORITY — Q3 ARRAY_AGG no-match-group reconcile-in-place

- **Where**: r07 (analytical query patterns) or wherever the ARRAY_AGG / LEFT JOIN tag-aggregation canonical lives. Locate via `grep -rn 'ARRAY_AGG\|array_agg\|tags array\|LEFT JOIN.*tag' resources/`.
- **What to add**: callout that ARRAY_AGG over a LEFT-JOIN-unmatched row returns `ARRAY[null]` (one-element array containing NULL), NOT NULL and NOT empty `[]`; therefore `COALESCE(ARRAY_AGG(col), ARRAY[])` is INEFFECTIVE. The canonical empty-array form is `ARRAY_AGG(col) FILTER (WHERE col IS NOT NULL)`. Reference Trino GitHub #6145 for documented behavior.
- **Keyword anchors**: `array_agg left join no match, array_agg empty array, array_agg returns null array, tags grouped array empty, FILTER WHERE col IS NOT NULL array_agg, no matching rows aggregate left join`.

### Untouched (per directive)

- r22 §13.x federation guardrails — NOT TOUCHED.
- Federation rubric row 4.49944/310 — UNCHANGED.

## Judge probe targets for iter509

1. **`$partitions` metadata RE-PROBE** (HIGH): "I want per-partition file count and total size for my Iceberg events table without scanning the data — what query should I run?" → verify responder uses `$partitions` correctly (no `file_size_in_bytes`, no redundant GROUP BY) and names columns `partition / record_count / file_count / total_size / data`.
2. **`$partitions` vs `$files` disambiguation 2nd angle** (HIGH): "Should I use $files or $partitions for per-partition size — what's the difference?" → verify responder distinguishes per-file row (`$files`, has `file_size_in_bytes`) from already-aggregated per-partition row (`$partitions`, has `total_size`).
3. **ARRAY_AGG no-match-group RE-PROBE** (HIGH): "Users with zero tags should produce an empty array `[]`, but my query gives a one-element NULL array — what's the fix?" → verify responder gives `FILTER (WHERE col IS NOT NULL)` and does NOT prescribe COALESCE-around-ARRAY_AGG as the fix.
4. **RENAME COLUMN 3rd angle** (MEDIUM — verify durability): "Can I keep the old column name working as an alias after RENAME COLUMN?" → verify responder routes to view-aliasing pattern (`CREATE OR REPLACE VIEW ... AS SELECT *, new_name AS old_name FROM t`) and explicitly says Iceberg has no native alias mechanism — does NOT say "both names work."
5. **Iceberg metadata-tables overview 4th angle** (MEDIUM): "$snapshots vs $history vs $manifests — what's each for?" → verify responder distinguishes the metadata-table family without conflating columns across tables (same failure mode as Q4 this iter).
6. **Federation** — STAYS UNPROBED per directive.

## Pattern note

The iter507→508 RENAME COLUMN fix is the **18th leading-canonical bulletproofing instance and 11th findability/canonical-addition fix to land cleanly on first re-probe** — the teacher's reconcile-in-place playbook continues to work reliably. Both new iter508 errors (Q3 ARRAY_AGG empty-array, Q4 `$partitions` schema) are the same class of failure as prior fixes: imprecise mental model on a Trino-specific behavior (LEFT-JOIN-NULL ARRAY_AGG semantics, metadata-table schemas). Both are solvable by the same reconcile-in-place pattern + keyword anchors — no structural resource gaps, just targeted corrections.

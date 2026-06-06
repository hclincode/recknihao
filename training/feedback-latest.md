# Iter532 Judge Feedback — JOIN-key column slip on Q1 ($files.snapshot_id does not exist)

**Verdict**: FAIL (avg 4.46875 numerically passes the >=3.5 floor, but Q1 itself is 3.25 — an execution-blocking column-name slip that errors at parse time. Flagging as FAIL because the failure mode is exactly what kills the "copy-paste and run" promise for a SaaS engineer with no OLAP background.)

---

## Per-question scoring

### Q1 — Every data file WITH the exact commit timestamp (ONE query)

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 2 | Wrong JOIN key. Responder wrote `f.snapshot_id = s.snapshot_id` but the Iceberg `$files` metadata table has NO `snapshot_id` column — only `added_snapshot_id`. The query as written will fail at planning with `Column 'snapshot_id' cannot be resolved` on `f`. Verified against [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) via WebFetch — exact quote: *"content, file_path, record_count, file_format, file_size_in_bytes, column_sizes, value_counts, null_value_counts, nan_value_counts, lower_bounds, upper_bounds, key_metadata, split_offsets, equality_ids, sort_order_id, readable_metrics, **added_snapshot_id**, file_sequence_number, data_sequence_number, referenced_data_file, pos, manifest_location, first_row_id, content_offset, content_size_in_bytes"*. The canonical at `resources/17-iceberg-table-maintenance.md:1180` uses `f.added_snapshot_id = s.snapshot_id` — the responder is one identifier prefix away from correct and slipped on copy. Other facts are right (single-query shape, whole-token quoting `"events$files"`, `committed_at` is TIMESTAMP(3) WITH TIME ZONE on `$snapshots`). |
| Completeness | 4 | Headline intent is right — ONE joined query (resolves the iter531 completeness gap of "two separate queries"). Mentions quoting, ORDER BY, snapshot operation. Missing `WHERE f.content = 0` to exclude position/equality delete files — a small caveat for any cluster with row-level deletes. |
| Clarity | 4 | SQL is readable; column list clean; aliases sensible (`f`/`s`). Quoting reminder is helpful. |
| Actionability | 3 | Engineer copy-pastes and gets a parser error. The fix is one identifier (`snapshot_id` → `added_snapshot_id`), but for the target audience (no OLAP background) this is exactly the slip that ruins the "I copied the snippet and it worked" promise. |

**Avg Q1**: 3.25 — FAIL.

### Q2 — Map lookup with default ('theme' missing → 'light')

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | `COALESCE(element_at(settings, 'theme'), 'light')` is exactly the documented Trino idiom. Verified against [trino.io/docs/current/functions/map.html](https://trino.io/docs/current/functions/map.html): *"element_at(map(K,V), key) → V: Returns value for given key, or NULL if the key is not contained in the map."* Combined with [conditional.html](https://trino.io/docs/current/functions/conditional.html) `COALESCE` returning the first non-NULL — composition is canonical. Note that bracket `settings['theme']` errors on missing key is also correct (raises `Key not present in map`). |
| Completeness | 4.5 | Hits both pillars: NULL-on-missing semantics of `element_at` + COALESCE wrap for default. Could mention `IF(contains(map_keys(...), 'theme'), ..., ...)` as a slower verbose alternative for contrast, but not required. |
| Clarity | 5 | One-liner SQL with clear semantics. Contrast against the bracket operator is pedagogically strong. |
| Actionability | 5 | Engineer can paste this directly and it runs. |

**Avg Q2**: 4.875 — STRONG PASS.

### Q3 — NULL-safe equality

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | `IS NOT DISTINCT FROM` is the documented Trino null-safe equality. Verified against [trino.io/docs/current/functions/comparison.html](https://trino.io/docs/current/functions/comparison.html) — exact quote: *"SELECT NULL IS DISTINCT FROM NULL; -- false"* and *"SELECT NULL IS NOT DISTINCT FROM NULL; -- true"*. Calling out `IS DISTINCT FROM` as the negation is correct. CASE-expression usage is fine. |
| Completeness | 4.5 | Covers the both-NULL→TRUE semantic plus the negation. Could note preference over `(a = b) OR (a IS NULL AND b IS NULL)` boilerplate, but the chosen form is the modern idiom. |
| Clarity | 5 | Direct, no fluff. |
| Actionability | 5 | Drops straight into JOIN / CASE / WHERE. |

**Avg Q3**: 4.875 — STRONG PASS.

### Q4 — Elapsed time between two timestamps

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | `date_diff('hour', created_at, resolved_at)` and `date_diff('day', ...)` are canonical. Verified against [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html): signature `date_diff(unit, timestamp1, timestamp2) → bigint` returning `timestamp2 - timestamp1` in `unit`. Argument order matches (unit, from, to → returns from→to). Caveat about `day` measuring unit-boundary crossings (and casting to `date(...)` for calendar-day arithmetic) is technically correct. Unit list day/week/month/hour/minute/second is in spec. |
| Completeness | 4.5 | Covers hour + day (the asked units) plus the calendar-day-vs-elapsed-day nuance. Could mention `millisecond` for sub-second precision but not asked. |
| Clarity | 5 | Clean. |
| Actionability | 5 | Direct. |

**Avg Q4**: 4.875 — STRONG PASS.

---

## Overall

`(3.25 + 4.875 + 4.875 + 4.875) / 4 = 17.875 / 4 = ` **4.46875**

Numerically passing on average, but Q1 fails the per-question 3.5 threshold (3.25), and the failure mode is execution-blocking (parser error from a fabricated column name). Counting this as **FAIL** — a "copy and run" promise that errors at parse-time is the worst failure mode for the target SaaS-engineer audience.

---

## NEW slip introduced this iteration — column-name fabrication on `$files`

**Slip**: Q1 join uses `f.snapshot_id = s.snapshot_id`. The `$files` table has NO `snapshot_id` column. The correct column is `added_snapshot_id`.

**Why this slipped despite the iter532 teacher edit**: The teacher correctly promoted the JOIN to a leading canonical at `resources/17-iceberg-table-maintenance.md:1169-1184` using `f.added_snapshot_id = s.snapshot_id`. The pin block immediately below (lines 1186-1191) ALSO uses `added_snapshot_id` in the correct-shape cell. So the canonical resource is right. The responder either:
1. Read the canonical, internalized the JOIN shape, but elided the `added_` prefix when paraphrasing — keyword-routing on "snapshot_id" let the prefix drop, OR
2. Read the surrounding text where bare `snapshot_id` appears (it's a real column on `$snapshots`) and conflated the two sides of the JOIN.

**This is not a teacher resource-content failure** — the resource has the correct identifier in the leading canonical (line 1180) and the pin block (line 1190). It is a responder-side identifier-elision when summarizing.

---

## Iter533 teacher action — make `added_snapshot_id` impossible to elide

Concrete reconcile-in-place edits (no appended duplicate blocks):

1. **`resources/17-iceberg-table-maintenance.md`, immediately above line 1180** (inside the leading canonical block): insert a one-line WRONG-IDENTIFIER pin reading something like:
   > **Identifier pin**: the `$files`-side column is **`added_snapshot_id`** — NOT `snapshot_id`. `$files` has NO `snapshot_id` column; bare `snapshot_id` lives only on `$snapshots`. Writing `f.snapshot_id = s.snapshot_id` fails with `Column 'snapshot_id' cannot be resolved` on `f`. The `added_` prefix is required on the `$files` side.

2. **Same file, in the existing DO-NOT-WRITE pin row at line 1190**: add a SECOND wrong-claim row whose wrong cell is exactly `f.snapshot_id = s.snapshot_id` (the prefix-elision case) and whose correct cell is `f.added_snapshot_id = s.snapshot_id`. The current pin only enumerates the missing-`committed_at`-column wrong shape — it does not enumerate THIS specific prefix-elision wrong shape, so keyword-routing on "join $files to $snapshots" doesn't hit a stop sign for the wrong-prefix case.

3. **Same file, `$files` column-list rows at lines 1103 and 1155**: in the column enumeration, bold or asterisk `added_snapshot_id` and add an inline parenthetical `**(NOT `snapshot_id` — the `added_` prefix is required)**` so any read of the column list reinforces the identifier prefix.

These three reconcile-in-place edits should close the prefix-elision gap. The iter531 pin and iter532 leading canonical both STAY intact.

---

## What worked (preserve next iteration)

- **Q2** — the iter532 LOW-priority adjacent COALESCE+element_at idiom inserted at `resources/09-lakehouse-schema-design.md` (between lines ~595-597) landed cleanly: responder used exactly `COALESCE(element_at(settings, 'theme'), 'light')` and also surfaced the bracket-operator-errors warning from the locked element_at block above. Reconcile-in-place placement worked.
- **Q3** — `IS NOT DISTINCT FROM` is consistently surfaced across resources; responder used it cleanly with CASE and named the negation.
- **Q4** — `date_diff(unit, from, to)` argument order and unit naming are consistently right; calendar-day vs elapsed-day nuance came through.
- **Q1 single-query shape** — the iter532 MEDIUM-priority leading canonical promotion above the iter531 pin DID achieve its intended outcome of making the JOIN (not two queries) the responder's first instinct. Remaining failure is identifier-elision, not query-shape.

---

## Do NOT touch

- `resources/22` §13.x federation guardrails — zero edits.
- Federation rubric row (4.49944 / 310) — no probe this iteration.
- iter495-iter531 locks all preserved.

---

## Sources (WebSearch + WebFetch verified 2026-06-06)

- [Iceberg connector — Trino docs](https://trino.io/docs/current/connector/iceberg.html) — `$files` columns list (confirms `added_snapshot_id`, no `snapshot_id`)
- [Map functions and operators — Trino docs](https://trino.io/docs/current/functions/map.html) — `element_at` returns NULL on missing key
- [Conditional expressions — Trino docs](https://trino.io/docs/current/functions/conditional.html) — `COALESCE` returns first non-NULL
- [Comparison functions and operators — Trino docs](https://trino.io/docs/current/functions/comparison.html) — `IS NOT DISTINCT FROM` NULL = NULL → TRUE
- [Date and time functions — Trino docs](https://trino.io/docs/current/functions/datetime.html) — `date_diff(unit, ts1, ts2) → bigint` returning `ts2 - ts1`

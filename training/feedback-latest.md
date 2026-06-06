# Iter 530 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall: 3.969 PASS (margin +0.469 above 3.5 floor — TIGHT)

| Q | Topic | Acc | Clar | Appl | Comp | Avg | Pass |
|---|---|---|---|---|---|---|---|
| 1 | from_unixtime epoch-MILLISECONDS | 5.0 | 4.75 | 5.0 | 4.75 | **4.875** | STRONG PASS |
| 2 | json_extract vs json_extract_scalar + json_array_length | 5.0 | 4.75 | 5.0 | 4.75 | **4.875** | STRONG PASS |
| 3 | Oracle TRANSLATE → Trino | 1.5 | 3.5 | 2.5 | 2.5 | **2.500** | FAIL — fab-absence |
| 4 | Iceberg "state of the table" $snapshots/$files/$history | 3.5 | 4.0 | 3.5 | 3.5 | **3.625** | PASS (slim) |

Overall = (4.875 + 4.875 + 2.500 + 3.625) / 4 = 15.875 / 4 = **3.96875 ≈ 3.969 PASS** (margin +0.469 above 3.5 floor). Q3 fab-absence dragged hard; Q1+Q2 carried the iter.

---

## A. Q1 — epoch-MILLISECONDS bigint → Trino timestamp (4.875 STRONG PASS)

**Verdict**: iter529's r13 epoch-MS polish LANDED on first re-probe.

Responder correctly:
- States `from_unixtime` expects **SECONDS** not milliseconds.
- Emits `from_unixtime(event_ts_ms / 1e3)` — preserves sub-second precision because `/1e3` does double-division (not integer truncation).
- Notes `/1000` integer-division would drop millis (correct subtle gotcha).
- Mentions `from_unixtime_nanos` for nanosecond epochs.
- Implicit explanation of the year 56000 anomaly: raw ms passed as seconds → ~ms x 1000 seconds since 1970 → roughly year 56000.

Doc verification at trino.io/docs/current/functions/datetime.html:
> "Returns the UNIX timestamp `unixtime` as a timestamp with time zone. `unixtime` is the number of seconds since `1970-01-01 00:00:00 UTC`."

And for nanoseconds:
> "`from_unixtime_nanos(unixtime) → timestamp(9) with time zone` — `unixtime` is the number of nanoseconds since `1970-01-01 00:00:00.000000000 UTC`"

**Iter529 r13 epoch-MS canonical CONFIRMED LANDED**: the SECONDS-vs-MS callout + `/1e3` vs `/1000` precision distinction + `from_unixtime_nanos` cross-link all surfaced on first re-probe. -0.25 Clarity / -0.25 Completeness for not explicitly stating the year-56000 arithmetic (responder hints but doesn't name the math); non-load-bearing.

---

## B. Q2 — VARCHAR payload JSON → user id int + roles array length (4.875 STRONG PASS)

**Verdict**: iter530's r13 JSON-family canonical LANDED on first re-probe.

Responder correctly:
- Emits `CAST(json_extract_scalar(payload, '$.user.id') AS INTEGER)` for the scalar leaf.
- Emits `json_array_length(json_extract(payload, '$.user.roles'))` for array length.
- Explains the central pitfall: `json_extract_scalar` returns NULL when the JSON path resolves to a non-scalar (object or array), so you must use `json_extract` to first get the JSON value, then count with `json_array_length`.

Doc verification at trino.io/docs/current/functions/json.html:
> "`json_extract(json, json_path) → json` — Evaluates the JSONPath-like expression `json_path` on `json` (a string containing JSON) and returns the result as a JSON string"
> "`json_extract_scalar(json, json_path) → varchar` — Like `json_extract()`, but returns the result value as a string ... The value referenced by `json_path` must be a scalar (boolean, number or string)."
> "`json_array_length(json) → bigint` — Returns the array length of `json` (a string containing a JSON array)"

**Iter530 r13 JSON canonical (json_extract vs json_extract_scalar + json_array_length + json_size + json_parse + json_format signature table) CONFIRMED LANDED on first re-probe** — the classic "why does my json_extract_scalar return NULL?" pitfall (path hits non-scalar) is now explicitly framed and routed correctly. -0.25 Clarity / -0.25 Completeness for no `try_cast` mention as a defensive variant (non-load-bearing); the canonical answer ships.

---

## C. Q3 — Oracle TRANSLATE → Trino (2.500 FAIL — fab-absence)

**Verdict: FABRICATED ABSENCE — load-bearing.**

Responder claims:
> "Trino does not have a direct equivalent to Oracle's TRANSLATE function."

**This is WRONG.** Trino 467 HAS `translate(source, from, to)`. Doc verification at trino.io/docs/current/functions/string.html:
> "`translate(source, from, to) → varchar` — Returns the `source` string translated by replacing characters found in the `from` string with the corresponding characters in the `to` string."

Additional semantics confirmed verbatim from the doc:
> "If the `from` string contains duplicates, only the first is used. If the source character does not exist in the `from` string, the source character will be copied without translation. If the index of the matching character in the `from` string is beyond the length of the `to` string, the source character will be omitted from the resulting string."

Oracle `TRANSLATE(phone_number, '0123456789', '##########')` ports **DIRECTLY 1:1** to Trino:
```sql
translate(phone_number, '0123456789', '##########')
```

Same name, same arg order, same positional-substitution semantics. The exact 1:1 Oracle→Trino port is one identifier copy-paste away.

Responder's fallbacks:
- `regexp_replace(phone_number, '\d', '#')` — TECHNICALLY VALID for digit-only masking and gives the same result; pattern-based, not the exact 1:1 port. Trino's `regexp_replace` accepts `\d`.
- Nested `replace()` calls — works but is the Postgres-style workaround that Trino's `translate` exists specifically to avoid.

Same fab-absence failure class as iter505 split_to_map + iter517 contains + iter520 CAST(map AS JSON) + iter520 string_agg + iter522 try() + iter524 WITH ORDINALITY + iter524 approx_distinct(x,e) + iter526 width_bucket + iter527 map_filter.

**Content gap, not teacher-fix regression**: per iter530 teacher's grep notes, `translate` had ZERO matches anywhere in resources/ (genuine gap). Iter530 teacher's grep correctly identified the string-family gap (translate, levenshtein_distance, reverse, position, json_size) but **chose the JSON family for the optional polish slot, deferring string-family**. The Oracle-migration framing of Q3 hit the deferred string-family gap before the deferral could be reversed.

Scoring breakdown:
- **Accuracy 1.5**: load-bearing denial of a real Trino function with the exact same name AND semantics.
- **Clarity 3.5**: regexp_replace fallback is well-explained.
- **Applicability 2.5**: regexp_replace works for digit masking, but the engineer would commit `regexp_replace` to a dbt model instead of the simpler, semantically-identical `translate`; for non-digit char masks (e.g. masking specific letters or swapping pairs) the regex fallback becomes awkward.
- **Completeness 2.5**: misses the exact 1:1 port, the central question.

---

## D. Q4 — Iceberg "state of the table" (3.625 PASS — slim)

**Verdict**: $snapshots block + whole-token quoting correct; two wrong column names in $files and $history.

Correct:
- `$snapshots` query with `snapshot_id, committed_at, summary` ordered by `committed_at DESC LIMIT 1` — verified at trino.io/docs/current/connector/iceberg.html, $snapshots columns are `committed_at | snapshot_id | parent_id | operation | manifest_list | summary`. Good.
- Whole-token quoting rule (the `$` symbol must be quoted as a whole `"db"."tbl$snapshots"` identifier) explained correctly.

Wrong column names:

**(i) `$files` does NOT have `committed_at`.** Doc verification:
> "$files columns: content | file_path | record_count | file_format | file_size_in_bytes | column_sizes | value_counts | null_value_counts | nan_value_counts | lower_bounds | upper_bounds | key_metadata | split_offsets | equality_ids | added_snapshot_id | file_sequence_number | data_sequence_number | referenced_data_file | pos | manifest_location | first_row_id | content_offset | content_size_in_bytes"

`committed_at` is a `$snapshots` column, not a `$files` column. The responder's `SELECT file_path, file_size_in_bytes, record_count, committed_at FROM "db"."tbl$files"` would error: `Column 'committed_at' cannot be resolved`. If the responder wanted per-file lineage to a commit time, the correct join is `$files.added_snapshot_id = $snapshots.snapshot_id` and then take `$snapshots.committed_at`.

**(ii) `$history` uses `made_current_at`, NOT `made_at`.** Doc verification:
> "$history columns: made_current_at | snapshot_id | parent_id | is_current_ancestor"

`ORDER BY made_at` would error: `Column 'made_at' cannot be resolved`. Correct column is `made_current_at`.

Scoring breakdown:
- **Accuracy 3.5**: $snapshots is correct (the primary table that answers "state of the table"), but $files + $history queries each have a wrong column name that would fail at parse time. Partial credit because the $snapshots block alone answers the question (last write time + current snapshot is in $snapshots).
- **Clarity 4.0**: whole-token quoting rule is good.
- **Applicability 3.5**: an engineer who runs the $snapshots query gets a working answer; if they try $files or $history they hit errors and must look up correct column names.
- **Completeness 3.5**: doesn't mention `$partitions` or `$manifests` as siblings, and the column slips lose points.

Not a fab-absence — the $files / $history tables exist; the wrong-column slip is a schema-fact error within a real metadata-table family. Routine column-name fix, not a leading-canonical gap.

---

## Other fabrications / no-fab-absence run status

- Q1: no fab.
- Q2: no fab.
- Q3: **fab-absence** (translate denied).
- Q4: no fab-absence (column slips, not denied function).

**The no-fab-absence run that started at iter528 (broken at iter527 by map_filter denial) ENDED at iter530 Q3.** Two-iter clean run (iter528 + iter529) → iter530 broke it on the string-family gap that iter530 teacher consciously deferred.

---

## Iter531 next-teacher actions (CONCRETE)

**FIX A (HIGH — fab-absence prevention, NEW LEADING CANONICAL) — String-function family canonical** in r13 string section (or new r07 §1a string-helpers block). Add one tight signature table covering:

| Function | Signature | When to use |
|---|---|---|
| `translate` | `translate(source, from, to) -> varchar` | Char-by-char positional substitution. 1:1 Oracle TRANSLATE port. |
| `reverse` | `reverse(string) -> varchar` | Reverse a string. |
| `position` | `position(substring IN string) -> bigint` | Find substring index (1-based; 0 if not found). |
| `levenshtein_distance` | `levenshtein_distance(string1, string2) -> bigint` | Edit distance for fuzzy matching. |
| `concat_ws` | **DOES NOT EXIST in Trino** | Use `array_join(ARRAY[...], 'sep')` instead. (already pinned in r27 — cross-link only) |

Worked example for Oracle TRANSLATE:
```sql
-- Oracle: TRANSLATE(phone_number, '0123456789', '##########')
-- Trino (1:1):
SELECT translate(phone_number, '0123456789', '##########') FROM users;
```

DO-NOT-WRITE bans:
1. "Trino does not have a direct equivalent to Oracle's TRANSLATE" — FALSE (iter530 Q3 fab-absence).
2. "For per-character substitution in Trino you must use regexp_replace or nested replace()" — FALSE; `translate` is the exact 1:1 port. (regexp_replace IS valid for pattern-based masking, but not necessary for positional char-by-char substitution.)
3. "Trino's translate behaves differently from Oracle's" — FALSE; verbatim doc semantics match Oracle's positional substitution incl. the "to shorter than from -> omit" rule.

Keyword anchors (place in r13 string section AND r27 Oracle migration table row): "Oracle TRANSLATE Trino / port Oracle TRANSLATE / Trino translate function / char-by-char substitution Trino / positional character replacement Trino / mask digits Trino / Trino string function family / Trino reverse / Trino position / Trino levenshtein / Trino fuzzy match / Trino concat_ws alternative".

Verified-source: trino.io/docs/current/functions/string.html.

**FIX B (MEDIUM — schema-fact correction) — $files / $history column-name pins** in r17 (Iceberg maintenance) or wherever the metadata tables are documented. Add explicit DO-NOT-WRITE notes:

1. `$files` does NOT have a `committed_at` column. Columns: content, file_path, file_format, record_count, file_size_in_bytes, column_sizes, value_counts, null_value_counts, lower_bounds, upper_bounds, key_metadata, split_offsets, equality_ids, added_snapshot_id, file_sequence_number, data_sequence_number, etc. To attach a commit time per file, JOIN `$files.added_snapshot_id = $snapshots.snapshot_id`.
2. `$history` uses `made_current_at`, NOT `made_at` or `committed_at`. Columns: `made_current_at`, `snapshot_id`, `parent_id`, `is_current_ancestor`.
3. Worked "state of the table" canonical query: `SELECT snapshot_id, committed_at, summary FROM "db"."tbl$snapshots" ORDER BY committed_at DESC LIMIT 1;` plus a cross-link to `$history` for the full audit trail.

Keyword anchors: "Iceberg $files columns Trino / Iceberg $history columns Trino / made_current_at vs made_at / $files committed_at not exist / Iceberg state of table query / Iceberg last write time query / current snapshot Trino Iceberg / Iceberg metadata tables Trino".

Verified-source: trino.io/docs/current/connector/iceberg.html.

**FIX C (LOW — polish)** — add `try_cast` defensive variant to the JSON canonical (`CAST(... AS INTEGER)` blows up on malformed VARCHAR — `try_cast` returns NULL instead). Non-load-bearing, no FAIL risk.

---

## Iter531 probe targets

- **translate RE-PROBE (HIGH — fab-absence prevention verification)**: "I have a column with mixed digits and letters, mask the digits 0-9 with `#` using a one-liner — Trino?" — verifies FIX A `translate` canonical lands + fab-absence GONE.
- **translate 2nd angle (HIGH)**: "port Oracle `TRANSLATE(account_id, 'O0', '0O')` (swap two characters) to Trino — same signature?" — verifies translate generalizes to non-digit-masking framing.
- **$files / $history column-name RE-PROBE (HIGH — schema-fact verification)**: "list every Parquet file in an Iceberg table with its commit time" — verifies the JOIN `$files.added_snapshot_id = $snapshots.snapshot_id` pattern lands instead of fabricating `$files.committed_at`.
- **$history canonical (HIGH)**: "show me the full ancestor chain of an Iceberg table's snapshots" — verifies `made_current_at` (not `made_at`) is emitted.
- **JSON family 2nd angle (MEDIUM — iter530 polish re-probe)**: "I have `{\"items\":[{\"id\":1},{\"id\":2}]}` and need the count + the first item's id" — verifies json_array_length + json_extract chain holds, and json_extract_scalar with `$.items[0].id` lands.
- **epoch-MS 3rd angle (LOW — well-bulletproofed)**: "convert a BIGINT column of microseconds (not ms, not s) to a Trino timestamp" — verifies the `from_unixtime(micros / 1e6)` derivation holds.
- **Federation stays UNPROBED** (LOW — row stays 4.49944/310 per iter472-530 directive).

---

## Streak status

- 126th consecutive overall PASS in extended phase (slim — margin +0.469 above floor).
- Iter529 epoch-ms polish CONFIRMED LANDED on first re-probe (Q1 5.000 Accuracy).
- Iter530 JSON-family canonical CONFIRMED LANDED on first re-probe (Q2 5.000 Accuracy).
- Iter530 teacher's deferred string-family gap surfaced as Q3 fab-absence on translate — no-fab-absence run BROKEN at 2 consecutive iters (iter528 + iter529 clean).
- No federation probe. Federation row 4.49944/310 UNCHANGED.
- No new fabricated signatures or wrong-version claims; the issues are the translate fab-absence (Q3) and two $files/$history column slips (Q4).

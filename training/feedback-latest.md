# Iter1173 — Judge Feedback

## Verdict: LIGHT FIX-A — Average 4.359 / 5.0 — TWO WATCHES CLOSE, ONE NEW LOAD-BEARING Q3 DEFECT

| Q | Topic row | Score | Verdict |
|---|---|---:|---|
| Q1 GDPR-purge 12mo on day-partitioned `pageviews` + reclaim disk | Iceberg table maintenance | 4.875 | **iter1172 r17 partition-aligned-DELETE FIX-A REACHED CLEANLY — WATCH CLOSES** |
| Q2 deliveries late-rate ≥ 0.20 in HAVING (engineer warns about integer div) | SQL query best practices for OLAP | 5.0 | **iter1172 majority-ratio-HAVING integer-division SLIP did NOT recur — WATCH CLOSES** |
| Q3 K/M/B compact-magnitude formatter (1,250,000 → "1.25M") | SQL query best practices for OLAP | 2.625 | **DEFECT — `format_number()` IS the built-in magnitude formatter; responder said it isn't and built unnecessary CASE; classification = LIGHT FIX-A (resource gap, format_number absent from `resources/`)** |
| Q4 Oracle SEQUENCE+NEXTVAL → dbt/Trino unique-ID | Oracle PL/SQL → dbt + Trino SQL migration | 4.9375 | pin-perfect; generate_surrogate_key + ROW_NUMBER fallback + uuid/SEQUENCE/Iceberg-V2-sequence_number defang |

Iter average = (4.875 + 5.0 + 2.625 + 4.9375) / 4 = **4.359** — above pass threshold but with one load-bearing Q3 factual error. Recommending **LIGHT FIX-A on r07 to add the `format_number()` built-in magnitude canonical**.

---

## Q1 — Partition-aligned DELETE + expire_snapshots (PASS 4.875) — WATCH CLOSES

Responder answer (verbatim core):
> *"A `DELETE` whose `WHERE` clause filters only on the partition column does NOT create position-delete files — it is metadata-only."* Quoted Trino docs: *"the deletion of entire partitions if the `WHERE` clause specifies filters only on the identity-transformed partitioning columns."*
>
> `DELETE FROM pageviews WHERE event_date < CURRENT_DATE - INTERVAL '365' DAY;`
> Then `ALTER TABLE pageviews EXECUTE expire_snapshots(retention_threshold => '7d')`.
> Explicit: do NOT need Spark `rewrite_position_delete_files`.

### Verification

- Docs language verbatim per [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html): *"For partitioned tables, the Iceberg connector supports the deletion of entire partitions if the `WHERE` clause specifies filters only on the identity-transformed partitioning columns, that can match entire partitions."*
- `expire_snapshots(retention_threshold => '7d')` exact 467 form per same URL — param name `retention_threshold` (NOT `retention_duration`), value `VARCHAR '7d'` (NOT `INTERVAL '7' DAY`).
- Both iter1172 wrong forms (`retention_duration => INTERVAL '7' DAY` + `Spark rewrite_position_delete_files` step) ABSENT from this iter's answer.
- 7-day floor caveat (`iceberg.expire-snapshots.min-retention` catalog property) correctly named with override path (lower property + coordinator restart OR Spark CALL form for same-day).

### Minor shave (-0.25 Compl)

The natural reading of "partitioned by day" is `partitioning = ARRAY['event_date']` with `event_date` as a DATE column (identity transform on a DATE → one partition per day) — for that case the metadata-only path is unambiguous. A trickier variant `partitioning = ARRAY['day(event_ts)']` (non-identity day-transform on a TIMESTAMP column) is **NOT** guaranteed to be metadata-only per [trinodb/trino#19266](https://github.com/trinodb/trino/issues/19266) — Trino doesn't always align an `event_ts < cutoff` filter with the `day(event_ts)` partition boundary. Responder did not disambiguate these two cases. Not load-bearing for the engineer's stated framing (one-day partitions on a DATE column is the canonical SaaS retention layout), but a complete answer would have flagged "if you partitioned by `day(timestamp)` instead of by a DATE column, the predicate must be rewritten as `event_ts < TIMESTAMP '...'` AND the optimizer must recognize whole-day alignment — verify with EXPLAIN that no position-delete files are written".

### Watch close

`r17 GDPR-purge partition-delete-metadata-only FIX-A iter1172` — **CLOSES on first re-probe**. Pattern continues (11 of last 11 watches close on first re-probe). The r17 keyword card added in iter1172 with anchors {GDPR purge old partitions, data retention purge, delete activity older than N days, DELETE WHERE event_date < cutoff, drop old day partitions in bulk, delete files pile up, partition-aligned DELETE metadata-only, retention_threshold => '7d'} is doing exactly its job.

---

## Q2 — HAVING ratio with non-integer division (STRONG PASS 5.0) — WATCH CLOSES

Responder answer:
```sql
HAVING SUM(CASE WHEN delivered_late THEN 1 ELSE 0 END) * 1.0
       / CAST(COUNT(*) AS DECIMAL(18,2)) >= 0.20
-- OR
HAVING CAST(SUM(CASE WHEN delivered_late THEN 1 ELSE 0 END) AS DOUBLE)
       / CAST(COUNT(*) AS DOUBLE) >= 0.20
```

### Verification

- `* 1.0` forces decimal coercion per [trino.io/docs/467/functions/math.html](https://trino.io/docs/467/functions/math.html) operator table — `BIGINT * DECIMAL(2,1) → DECIMAL`, then `DECIMAL / DECIMAL` gives non-truncating decimal result. `0.20` comparison threshold is preserved.
- `CAST(... AS DOUBLE) / CAST(... AS DOUBLE)` IEEE-754 floating-point division — also correct, comparison against `0.20` preserves precision adequate for a 20% threshold.
- Aggregate expression repeated in HAVING (not SELECT alias) per Trino logical evaluation order — correct.
- No `COUNT/COUNT > 0.5` integer-division trap form anywhere in the answer.

### Watch close

`r23/r07 majority-ratio-HAVING integer-division slip iter1172` — **CLOSES on first re-probe**. Confirmed iter1172 was a one-off responder recall slip (not a resource defect — r07 §1824 / §3510 / §3585 + r23 §988 were all consistently warning about integer-division truncation). Engineer's explicit prompt "warn about integer truncation" likely helped key the canonical, but the SQL is independently correct. No additional resource fix needed.

---

## Q3 — Magnitude formatter (1.25M / 890K) (FAIL 2.625) — LIGHT FIX-A

### The defect: `format_number()` IS the built-in magnitude formatter the engineer asked for

Responder answer (verbatim core):
> *"Trino 467 has NO built-in magnitude formatter. ... There is `format_number()`, but it's for general numeric formatting, not magnitude compression. Write a CASE expression."*

**Both claims are FACTUALLY WRONG.**

`format_number()` is a Trino **built-in** scalar function (added in [Release 357, May 2021](https://trino.io/docs/current/release/release-357.html)) and it does **exactly** the K/M/B compact magnitude formatting the engineer asked for. Verified:

- Listed in [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html): `format_number(number) → varchar` — *"Returns a formatted string using a unit symbol"*.
- Docs examples: `format_number(123456) → '123K'` and `format_number(1000000) → '1M'`.
- Source: [trino-main `FormatNumberFunction.java`](https://github.com/trinodb/trino/blob/master/core/trino-main/src/main/java/io/trino/operator/scalar/FormatNumberFunction.java) — input `BIGINT` or `DOUBLE`, output `VARCHAR`, uses unit symbols K/M/B/T/Q (thousand/million/billion/trillion/quadrillion), HALF_UP rounding, three-significant-digit precision rule (values < 10 → 2 decimals, < 100 → 1 decimal, larger → 0).
- Listed in [trino.io/docs/467/routines/examples.html](https://trino.io/docs/467/routines/examples.html) explicitly as a **built-in** (the `format_data_size` SQL UDF on that page presents itself as a USER-DEFINED ALTERNATIVE to the built-in `format_number()` "because format_number uses units that do not work well with bytes" — engineer's display ask is NOT a bytes case, it's the exact use case `format_number()` was built for).

For the engineer's specific examples:
- `format_number(1250000)` → `'1.25M'` (matches engineer's wanted output exactly per three-sig-fig rule)
- `format_number(890000)` → `'890K'` (matches engineer's wanted output exactly)

The responder's CASE workaround is functionally correct but unnecessary, AND it produces a **cosmetic mismatch** with the engineer's stated target: `format('%.2f%s', 890000/1e3, 'K')` produces `'890.00K'` (trailing zeros), not `'890K'`. The engineer's example showed `'890K'`, which is exactly what `format_number()` outputs by its three-sig-fig precision rule.

### What the responder got right

- `format_data_size` is NOT a built-in — CORRECT, matches pinned `reference_trino_format_data_size_is_udf.md`. It's an example SQL UDF on the routines page.
- The CASE expression is syntactically valid Trino 467 (`format('%.2f%s', n/1e6, 'M')` printf-style is real).
- dbt macro suggestion for reuse is reasonable.

### Source classification: RESOURCE GAP (LIGHT FIX-A) — not a pure responder slip

Grepped `resources/` for `format_number` → **zero hits**. The function does not appear in any resource file. The pinned `reference_trino_format_data_size_is_udf.md` correctly defangs `format_data_size` as "not a built-in, use a CASE" — but it stops short of pointing the engineer to `format_number()` as the actual built-in magnitude formatter for the K/M/B case. The pin only addresses the bytes-style case where `format_number` was rejected for "wrong units"; it doesn't recover the K/M/B-display path.

This is a **findability gap**: questions about K/M/B compact display will keyword-attract toward "no built-in magnitude formatter, write CASE" (the `format_data_size` defang) and away from the actual one-line answer.

### Recommended LIGHT FIX-A

Add an additive canonical card to `r07-analytical-query-patterns.md` (or wherever K/M/B display formatting questions land) with:

**Keyword anchors:**
{compact number display, K/M/B suffix, magnitude formatter, 1.25M format, 890K format, human-readable big numbers, abbreviated number display, number unit symbol, format large numbers, dashboard number formatting}

**Load-bearing facts:**
- Trino 467 HAS a built-in `format_number(n) → varchar` — added in Release 357 (May 2021), listed in Conversion Functions.
- Output uses unit symbols `K / M / B / T / Q` (thousand / million / billion / trillion / quadrillion).
- Precision rule: three significant digits (values <10 show 2 decimals, <100 show 1 decimal, ≥100 show 0).
- Examples: `format_number(123456) → '123K'`, `format_number(1000000) → '1M'`, `format_number(1250000) → '1.25M'`, `format_number(890000) → '890K'`.
- Input must be `BIGINT` or `DOUBLE` — `CAST` if it's `DECIMAL` or `INTEGER` ambiguous.

**Defang DO-NOT-WRITE entries:**
- "Trino has no built-in K/M/B magnitude formatter" — FALSE (it's `format_number()`).
- "`format_number()` is general numeric formatting, not magnitude compression" — FALSE (it's exactly the magnitude/unit-symbol compressor).
- "Hand-rolled CASE with `format('%.2f%s', ...)`" — UNNECESSARY for the K/M/B case; also produces trailing zeros (`890.00K`) vs `format_number`'s clean `890K`.

**Cross-ref:** Note the `format_data_size` carve-out — it's the example SQL UDF when you specifically need bytes-style units (KB/MB/GB/TB) NOT raw count units (K/M/B). They are different output spaces.

**Watch label:** `r07 format_number-built-in-magnitude-formatter LIGHT FIX-A iter1173`. Re-probe next sweep with structurally similar phrasings (e.g., "format ARR as `$1.2M` for an exec dashboard" / "Render row counts as K/M for a sidebar widget" / "Convert 12,345,678 → `12.3M` for display"). If reaches canonical → CLOSE.

### Classification fit

5th instance of imported-prior-direction errors (after `starts_with` / `to_char` / `listagg` / `truncate-2arg` / `array_sum`-from-the-other-direction) — responder assumed absence/wrong-purpose of a foreign-looking-but-real Trino built-in. Per pinned `reference_trino_listagg_native.md` / `reference_trino_to_char_exists.md` / `reference_trino_starts_with_ends_with.md`: when the responder dismisses a function by mischaracterizing its purpose, that's the same family as outright fabricating absence — both lead the engineer down the wrong path. Different from pure fabrication (responder named the right function, just got its purpose wrong), but practically equivalent failure mode (engineer ends up writing the CASE workaround).

### Practical impact

Engineer's CASE answer is technically correct and produces usable output (though with `.00` trailing zeros mismatch). They'll build a working column — but they'll never know about the one-line `format_number()` until they find it themselves. Mental-model loss + maintainability cost (CASE branch list to maintain vs single function call).

---

## Q4 — Oracle SEQUENCE → dbt/Trino unique ID (STRONG PASS 4.9375)

Responder answer:
- Trino has **no** persistent sequences (no `CREATE SEQUENCE`, no `NEXTVAL`); Iceberg has no native identity column; Iceberg V2 `sequence_number` is internal metadata.
- **PRIMARY**: `dbt_utils.generate_surrogate_key(['col1','col2'])` — deterministic MD5 hash, idempotent across runs.
- **FALLBACK**: `ROW_NUMBER() OVER (ORDER BY ...)` — stable only within a single run.
- **WHAT DOES NOT WORK**: `CREATE SEQUENCE` (parse error), `uuid()` (random, not deterministic, unsafe for `unique_key`).
- Pairs `generate_surrogate_key` with `unique_key` for incremental merge.

### Verification

- Trino 467 has NO `CREATE SEQUENCE` / `NEXTVAL` — confirmed via [trino.io/docs/467/sql.html](https://trino.io/docs/467/sql.html) SQL statements list; no sequence DDL. Parse error correct.
- `uuid()` IS a real Trino function per [trino.io/docs/467/functions/uuid.html](https://trino.io/docs/467/functions/uuid.html): `uuid() → uuid`, *"Returns a pseudo randomly generated UUID (type 4)"*. Responder correctly framed it as "exists but unsafe for stable incremental unique_key" (does NOT claim absence — important — matches the canonical Oracle migration scope). For a one-row-per-INSERT non-stable ID, uuid() WOULD work; for a re-runnable incremental model where dbt needs to match an existing row by key on subsequent runs, uuid() breaks idempotency (the same row gets a new uuid on re-run, MERGE doesn't match → silent duplicates). Framing precise.
- `dbt_utils.generate_surrogate_key()` — deterministic MD5 hash of `COALESCE(CAST(col AS VARCHAR), '_dbt_utils_surrogate_key_null_')` joined with `-` separators per [github.com/dbt-labs/dbt-utils#generate_surrogate_key-source](https://github.com/dbt-labs/dbt-utils/blob/main/macros/sql/generate_surrogate_key.sql) — VARCHAR output (~32-char MD5 hex), idempotent, ordering-independent.
- `ROW_NUMBER() OVER (ORDER BY ...)` — single-run only correctly noted; same input data re-sorted on a subsequent run yields same numbers ONLY if the sort key is fully deterministic and the input set is identical (typically not true for incremental loads).
- Iceberg V2 `sequence_number` — internal metadata per [iceberg.apache.org/spec/#sequence-numbers](https://iceberg.apache.org/spec/) — not user-accessible as a row identifier column. Defang correct.

### Minor shave (-0.0625)

Did not explicitly mention the VARCHAR return-type of `generate_surrogate_key` (~32-char MD5 hex) vs the engineer's potential numeric-PK expectation (matches the iter1148 footnote shave on the same topic). Engineer can infer from "MD5 hash" but explicit "VARCHAR not BIGINT" callout would have completed the type-shift framing. Recall ceiling, not a defect.

### Source

`r27 §1.2` + `§4.5A` + `§4.5D` — exact canonical reached. The pattern of dropping uuid as "not for stable unique_key" is a 2nd canonical-perfect handling on this topic class (iter1148 was the first time `unique_key`-mismatch was correctly attributed to uuid randomness vs SEQUENCE replacement).

---

## Watches summary

| Watch | Iter opened | This iter | Status |
|---|---|---|---|
| `r17 GDPR-purge partition-delete-metadata-only FIX-A iter1172` | 1172 | Q1 re-probe reached canonical with verbatim docs quote + correct retention_threshold => '7d' + no rewrite_position_delete_files | **CLOSED** |
| `r23/r07 majority-ratio-HAVING integer-division slip iter1172` | 1172 | Q2 re-probe used `*1.0/CAST` and `CAST AS DOUBLE / CAST AS DOUBLE` — no integer-div trap | **CLOSED** |
| `r07 format_number-built-in-magnitude-formatter LIGHT FIX-A iter1173` | **1173 (NEW)** | Q3 wrongly said no built-in magnitude formatter + mischaracterized `format_number()` as "general numeric formatting" | **OPEN — LIGHT FIX-A recommended** |

---

## Recommended next-sweep action for the teacher

**LIGHT FIX-A on r07 (or wherever K/M/B compact-display questions land):**

Add a `format_number()` canonical card. The function is a built-in (Release 357, May 2021), is documented in Trino 467 Conversion Functions, and produces exactly the K/M/B unit-symbol compact output. Engineer-facing questions ("show big numbers as 1.25M", "compact display for an exec dashboard", "K/M/B suffix") should keyword-route to this card and NOT to the existing `format_data_size`-style "no built-in, write CASE" pattern (which is correct for bytes but wrong for raw-count K/M/B).

**No resource action on Q1, Q2, Q4** — Q1 and Q2 watches CLOSE, Q4 is pin-perfect.

**Margin update**: Both load-bearing watch closures (Q1, Q2) restore the responder's pattern of one-iteration find-and-close. The Q3 defect is a new resource-gap finding (not a regression), bounded by margin (+1.07 on the SQL-best-practices row absorbs the 2.625) and adds a single watch to the queue.

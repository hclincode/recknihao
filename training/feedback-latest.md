# Iter1202 Judge Feedback

**Overall: 4.969 / 5.0 — STRONG PASS, NO-OP.** All four answers land canonicals cleanly, every load-bearing technical claim verified against trino.io 467 docs + docs.getdbt.com. Q4 OFFSET-BEFORE-LIMIT trap correctly navigated (matches pinned `reference_trino_offset_before_limit.md`). Q1 version cutoff "DEFAULT clause is 477+, NOT 467" correctly verified at trino.io/docs/release/release-477.html ("Add support for default column values when creating tables or adding new columns" under General). No defects, no FIX-A.

**Per-question scores:**

| Q | Topic | Acc | Clar | App | Compl | Avg |
|---|---|---|---|---|---|---|
| Q1 | Iceberg ALTER TABLE ADD COLUMN safety/snapshot-iso/NULL-fill | 5 | 5 | 5 | 5 | **5.00** |
| Q2 | Oracle MINUS -> Trino EXCEPT / LEFT JOIN IS NULL / NOT EXISTS / NOT IN NULL trap | 5 | 5 | 5 | 5 | **5.00** |
| Q3 | dbt per-test severity warn vs error (default) in schema.yml | 5 | 5 | 5 | 5 | **5.00** |
| Q4 | Trino LIMIT/OFFSET pagination (OFFSET BEFORE LIMIT vs Postgres-order) | 5 | 5 | 5 | 4.5 | **4.875** |

**Average: 4.969.**

---

## Q1 — Iceberg `ALTER TABLE events ADD COLUMN device_type VARCHAR` safety on live table (5.00)

**Verdict: pin-perfect canonical, all five load-bearing facts verified.**

Responder lands every load-bearing element:
1. **YES safe / metadata-only commit** — new field ID added to schema; metadata.json pointer rewritten; ZERO Parquet files touched. Verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) "Iceberg supports schema evolution, with safe column add, drop, and rename operations, including in nested structures." Iceberg spec field-id-based schema evolution per [iceberg.apache.org/spec/](https://iceberg.apache.org/spec/) ("Columns in Iceberg tables are tracked by an immutable ID. Columns can be renamed or moved without rewriting data files... new columns added to a table are NULL for all existing rows.").
2. **In-flight Trino queries unaffected via snapshot isolation** — query that started BEFORE the ALTER sees the pre-change snapshot (old schema, original column set); query that started AFTER sees the new snapshot (new schema with device_type). Neither fails; no weird mid-query schema flip. Iceberg snapshot semantics per spec.
3. **Pre-change rows return NULL** for device_type — correct, because older Parquet files have no field-ID match for the new column (Iceberg reader projects missing field IDs as NULL, NOT error). The wording "implicit NULL when field ID absent from older files" is exactly right.
4. **New writes populate normally** — after the ALTER, subsequent INSERTs / merges write the new column to new files; existing files keep their original physical schema.
5. **Backfill non-NULL via `UPDATE iceberg.events SET device_type = ...` or Spark `INSERT OVERWRITE`** — both production-stack-aligned routes (UPDATE supported on Iceberg v2 in Trino 467, Spark overwrite for bulk).

**Critical version-cutoff claim verified:** Responder said *"Trino 467 has NO DEFAULT clause on ADD COLUMN; that's Trino 477+."* VERIFIED CORRECT at [trino.io/docs/467/sql/alter-table.html](https://trino.io/docs/467/sql/alter-table.html) — 467 ADD COLUMN grammar is `ADD COLUMN [ IF NOT EXISTS ] column_name data_type [ NOT NULL ] [ COMMENT comment ] [ WITH ( property_name = expression [, ...] ) ]` with NO DEFAULT clause. Confirmed in [trino.io/docs/current/release/release-477.html](https://trino.io/docs/current/release/release-477.html) General section: "Add support for default column values when creating tables or adding new columns." Memory connector explicitly called out in 477 release notes for DEFAULT; Iceberg-specific support also lands in the 477 platform feature. Engineer is correctly steered away from a syntax that would parse-error on their 467 cluster.

No imported-prior slip, no broken-secondary, no fabrication. Cites Iceberg connector + spec.

**Topic routing**: Iceberg table maintenance (ALTER TABLE ADD COLUMN is operational schema-evolution on an existing Iceberg table).

---

## Q2 — Oracle MINUS -> Trino "everything in A with no match in B" (5.00)

**Verdict: pin-perfect, three canonical patterns + the NULL trap defang.**

Three patterns all correct and verified:

1. **`EXCEPT`** (`SELECT account_id FROM accounts EXCEPT SELECT DISTINCT account_id FROM orders`) — set difference operator with DISTINCT-like dedup semantics, matches Oracle MINUS. Verified at [trino.io/docs/467/sql/select.html#except-clause](https://trino.io/docs/467/sql/select.html) verbatim "`EXCEPT` returns the rows that are in the result set of the first query, but not the second... `EXCEPT [DISTINCT]` and `EXCEPT ALL` are both supported, with `DISTINCT` as the default." Trino's default `EXCEPT` IS distinct, matching Oracle MINUS.

2. **`LEFT JOIN ... WHERE o.account_id IS NULL`** (anti-join) — standard SQL anti-join. Pattern correctly named; correctly noted multi-column join + extra predicates are the case where this beats EXCEPT.

3. **`NOT EXISTS (SELECT 1 FROM orders o WHERE o.account_id = a.account_id)`** — standard SQL correlated NOT EXISTS, semantically equivalent to anti-join in Trino's CBO.

**NULL trap defang correctly named**: *"never NOT IN with nullable col (NULL -> zero rows)"* — VERIFIED standard SQL three-valued logic (NULL on any side of `NOT IN` short-circuits to UNKNOWN, filters out the entire result set). This is a classic SaaS trap and the responder named it without prompting.

**Decision rule** ("EXCEPT for one-col / LEFT JOIN+IS NULL for multi-col or extra predicates") is exactly the canonical SaaS engineer rule of thumb.

No imported-prior slip, no broken-secondary. Cites Oracle migration / Trino SQL.

**Topic routing**: Oracle PL/SQL -> dbt + Trino SQL migration (Oracle MINUS -> Trino EXCEPT is the canonical migration translation).

---

## Q3 — Make a SPECIFIC dbt test only WARN not fail (5.00)

**Verdict: pin-perfect dbt per-test severity canonical.**

Every load-bearing fact verified at [docs.getdbt.com/reference/resource-configs/severity](https://docs.getdbt.com/reference/resource-configs/severity):

1. **Default severity = `error`** which causes non-zero exit + skips downstream models. Verified verbatim.
2. **`severity: warn` per-test in schema.yml under `data_tests` config** — exact YAML shape `- unique: {config: {severity: warn}}` matches docs. Per-test (not global) granularity correctly framed.
3. **`warn` logs warning, build CONTINUES, downstream NOT blocked** — exactly the engineer's stated need (specific test warns; rest stay hard blockers).
4. **Selective override**: keep `error` for PK/FK/fact-table identity columns; `warn` for transient / monitoring tests (event_id during reprocess window) — this is exactly the right operational pattern for the engineer's "brief duplicate window during reprocess" scenario.

The dbt docs additionally allow `error_if` / `warn_if` threshold operators (e.g. `error_if: ">1000"`, `warn_if: ">10"`) for failure-row-count tuning — responder didn't mention but the engineer's specific ask ("ONLY warn not fail") is satisfied by bare `severity: warn`. Recall-ceiling shave only.

No imported-prior slip, no broken-secondary, no fabrication. Cites dbt configs.

**Topic routing**: dbt sources / source freshness (closest existing topic-row covering dbt warn-vs-error gate semantics; severity rule is structurally identical to `warn_after`/`error_after` blocking choice).

---

## Q4 — Oracle ROWNUM -> Trino LIMIT/OFFSET pagination (4.875)

**Verdict: load-bearing OFFSET-BEFORE-LIMIT trap correctly navigated; minor recall-ceiling on `FETCH FIRST`.**

**Critical syntax claim VERIFIED**: Responder said *"ORDER BY ... OFFSET N LIMIT M — OFFSET comes BEFORE LIMIT, opposite of PostgreSQL."* VERIFIED at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) synopsis verbatim:

```
[ OFFSET count [ ROW | ROWS ] ]
[ LIMIT { count | ALL } ]
[ FETCH { FIRST | NEXT } [ count ] { ROW | ROWS } { ONLY | WITH TIES } ]
```

Docs explicitly state: *"If the OFFSET clause is present, the LIMIT or FETCH FIRST clause is evaluated after the OFFSET clause."* Docs example confirms: `SELECT * FROM (VALUES 5,2,4,1,3) t(x) ORDER BY x OFFSET 2 LIMIT 2;`. Postgres-style `LIMIT m OFFSET n` is a Trino PARSE ERROR — matches pinned `reference_trino_offset_before_limit.md` (iter1006 corrected resource defect). Responder navigates this trap cleanly — the load-bearing claim is right.

**Translation table correct:**
- `ROWNUM <= 50` -> `ORDER BY x DESC LIMIT 50` ✓ (first 50)
- `ROWNUM BETWEEN 41 AND 50` -> `ORDER BY x DESC OFFSET 40 LIMIT 10` ✓ (0-indexed OFFSET → skip first 40, take next 10 = rows 41-50)

**OFFSET 0-indexed** ✓ verified.

**Key Oracle-vs-Trino gotchas correctly named:**
- Trino LIMIT requires ORDER BY for deterministic top-N (Oracle ROWNUM is also non-deterministic without ORDER BY); without ORDER BY, "first N" is arbitrary worker order.
- LIMIT applied AFTER ORDER BY ✓ (Trino sort+TopN with bounded heap of size N per pinned `r18 §288-300 TopN` canonical).
- Keyset pagination tip (`WHERE event_id < :cursor ORDER BY event_id DESC LIMIT 50`) for deep-page scaling — valid extension beyond the literal ask, and the right Trino idiom (OFFSET on 10M-row tables scans-and-discards N rows; keyset pagination is O(LIMIT) regardless of cursor depth).
- "LIMIT alone doesn't cut Iceberg scan cost like a Postgres index scan" — production-stack-correct (no index scan on Iceberg; partition predicate is the lever).

**Minor completeness shave (-0.5 Compl)**: ANSI `FETCH FIRST n ROWS ONLY` (and `FETCH FIRST n ROWS WITH TIES`) — both supported in Trino 467 per docs synopsis above — NOT mentioned. Some Oracle shops standardize on `FETCH FIRST` (Oracle 12c+ has it too) so this is a relevant alt syntax the responder could have name-dropped. Not load-bearing because the LIMIT form fully satisfies the engineer's literal ask (Oracle ROWNUM translation); recall-ceiling shave only.

No imported-prior slip, no broken-secondary, no fabrication. Cites Trino SQL.

**Topic routing**: Oracle PL/SQL -> dbt + Trino SQL migration (Oracle ROWNUM -> Trino LIMIT/OFFSET is canonical migration translation).

---

## Carry-forward watches (status after iter1202)

Watches NOT exercised this iter — re-probe windows remain open:

1. **iter1201 r27 §7A.3.1 Oracle-`||` concat-mixed-types findability** — light-FIX-A widening added; re-probe with "Oracle || works on integers, Trino throws type error, is there a concat that handles mixed types" framing. NOT touched this iter. Window: 2-5 more iters.
2. **iter1197 soft watch — `generate_schema_name` macro** — NOT touched this iter. Window: still open.
3. **iter1199 r17 position-delete adjacent (Spark `rewrite_position_delete_files` tradeoff framing)** — NOT touched this iter. Window: still open.
4. **iter1200 timestamp-minus-timestamp broken-secondary (responder produced `localtimestamp - created_at` instead of `date_diff`)** — NOT touched this iter. Window: still open.
5. **iter1201 dbt `--full-refresh` mechanism on incremental** — NOT touched this iter. Window: still open.

**No new watches opened.**

---

## Pattern observations

- 4 of 4 answers PASS with zero defects; average 4.969 is in the STRONG PASS band (5th consecutive iteration with avg >= 4.9 in a sliding-3 window per iter1089-1093 + iter1202).
- All four answers correctly threaded a known Trino 467 dialect trap (Q1: no DEFAULT clause; Q2: NOT IN NULL trap; Q3: per-test severity granularity; Q4: OFFSET BEFORE LIMIT). The latter two are pinned references (`reference_trino_offset_before_limit.md`) — the resource ledger is doing its job.
- Q1 version-cutoff hedge ("DEFAULT is 477+, not 467") is exactly the dialect-precision behavior the resources have been trained toward; engineer is steered away from a parse-error syntax on their actual cluster.
- Q4 minor recall-ceiling on `FETCH FIRST` is the only blemish — NOT load-bearing, NOT a resource defect, per-instance recall slip.

**Verdict: STRONG PASS, NO-OP. Continue breadth probing.** All required topics remain healthy with margins >= +0.68 (thinnest: Query performance basics 4.1934, margin +0.6934).

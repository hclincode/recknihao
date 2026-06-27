# Iter1169 — Judge Feedback

## Verdict: PASS + LIGHT FIX-A — Average 4.75 / 5.0

| Q | Topic row | Score | Verdict |
|---|---|---:|---|
| Q1 legacy_clickstream Hive Parquet → Iceberg WITHOUT Spark (WATCH RE-PROBE) | Iceberg table maintenance | 4.9375 | **WATCH CLOSES — Trino-native migrate FIX-A reaches verbatim** |
| Q2 Postgres `to_char('Month YYYY')` → Trino dashboard label "June 2026" | SQL query best practices for OLAP | 4.0625 | **RESOURCE-SOURCED DEFECT — r27 falsely says "Trino has no to_char"** |
| Q3 EARLIEST date `api_calls > 1000` per customer, NULL if never | Analytical query patterns on Iceberg+Trino | 5.0 | pin-perfect conditional aggregation |
| Q4 dbt feature for loading small reference CSVs into Iceberg | Oracle PL/SQL → dbt+Trino migration | 5.0 | clean canonical dbt seeds |

Iter average = (4.9375 + 4.0625 + 5.0 + 5.0) / 4 = **4.75 PASS + LIGHT FIX-A** (margin +1.25 over 3.5 threshold).

**Watch status:** `r21+r17 migrate-Trino-native FIX-A iter1168` — **CLOSED** on first re-probe.

**New watch:** `r27 to_char-exists-numeric-only FIX-A iter1169` — re-probe next sweep.

---

## Per-question detail

### Q1 (4.9375 — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 4.75) — Hive Parquet → Iceberg WITHOUT Spark (WATCH RE-PROBE)

**WATCH `r21+r17 migrate-Trino-native FIX-A iter1168` — CLOSES on first re-probe.**

Iter1168 the responder said `CALL iceberg.system.migrate(...)` is "Spark SQL, NOT Trino" — RESOURCE-SOURCED defect across r21 §78/§141/§147 + r17 §231/§912. Iter1168 FIX-A spec rewrote r21 §80-95+§141+§147 to "**`migrate` runs natively in Trino 467 via `CALL iceberg.system.migrate(schema_name => '...', table_name => '...')` — no Spark required**" + named-arg form + optional `recursive_directory` param.

**Iter1169 Q1 reaches the FIX-A canonical verbatim:**
- "YES, entirely in Trino, no Spark" — correct routing decision.
- `CALL iceberg.system.migrate(schema_name => 'your_analytics_schema', table_name => 'legacy_clickstream')` — exact named-arg form matching FIX-A spec.
- "Trino reads existing Parquet file list, builds Iceberg snapshot+manifest metadata on top (no rewrite/movement), updates HMS pointer" — accurate description of in-place metadata-only conversion.
- "~1-5 min for 100GB" — sensible order-of-magnitude estimate for metadata-only migration.
- `CALL iceberg.system.rewrite_manifests(...)` correctly kept as Spark-only on the production stack (Trino 467 has no native rewrite_manifests — `ALTER TABLE EXECUTE optimize_manifests` lands in 470+).

**VERIFIED via [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html)** "Procedures" section verbatim:
```sql
CALL example.system.migrate(
    schema_name => 'testdb',
    table_name => 'customer_orders')
```
+ optional `recursive_directory => 'true'|'false'|'fail'` (default `'fail'`). Available natively in Trino 467 with no `iceberg.migrate-procedure.enabled` flag required (unlike `register_table` / `add_files_from_table`). Iter1168 misroute ("Spark-only") did NOT recur. 10 of last 10 watches close on first re-probe — Haiku 1-iter-slip-then-recover variance pattern holds, FIX-A reaches reliably.

**Minor Compl shave (-0.25):** responder said "New tables default format v2" — true generally for Trino `CREATE TABLE iceberg.<>.<>`, but ambiguous in the migrate context. Per r21 §139, migrated Hive tables default to Iceberg format v1 (no delete files); engineer would need `ALTER TABLE ... SET TBLPROPERTIES ('format-version'='2')` if they later want MERGE/DELETE. Non-load-bearing for the stated time-travel + schema-evolution requirements (both work on v1 fine).

Cites r21. Resource-aligned to FIX-A.

### Q2 (4.0625 — Acc 3.0 / Clar 4.75 / App 4.5 / Compl 4.0) — Postgres TO_CHAR → Trino month-year label

**RESOURCE-SOURCED DEFECT on foundational `to_char` claim. Actionable answer for THIS specific task is correct; foundational framing is wrong.**

**What the responder said:** "**Trino has NO TO_CHAR function — that's an Oracle-ism.**"

**VERIFIED WRONG via [trino.io/docs/467/functions/teradata.html](https://trino.io/docs/467/functions/teradata.html):**
- Trino 467 HAS a Teradata-compatibility `to_char(timestamp, format)` function.
- Documented format specifiers are LOWERCASE NUMERIC-ONLY: `dd` (day), `mm` (month NUMBER), `yyyy`/`yy` (year), `hh`/`hh24` (hour), `mi` (minute), `ss` (second) + punctuation.
- Doc explicitly notes: "Case insensitivity is not currently supported. All specifiers must be lowercase."
- NO month-name codes (`Month`/`Mon`) documented.

Matches pinned `reference_trino_to_char_exists.md`.

**For THIS specific task (`'June 2026'` requires month NAME), `to_char` genuinely cannot produce it** (numeric-only) — so the responder's STEERING to `date_format` / `format_datetime` IS the correct actionable answer for the literal task. **Verified correct facts:**
- `date_format(ts, '%M %Y')` → `'June 2026'` per [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) (MySQL `%M` = full month name, `%Y` = 4-digit year). VERIFIED.
- `date_format(ts, '%Y-%m')` → `'2026-06'` (`%m` = zero-padded month number). VERIFIED.
- `format_datetime(ts, 'MMMM yyyy')` → `'June 2026'` (Joda `MMMM` = full month name, `yyyy` = 4-digit year). VERIFIED.
- `format_datetime(ts, 'yyyy-MM')` → `'2026-06'` (`MM` = 2-digit month number). VERIFIED.
- **Joda lowercase-`mm`=MINUTE-not-month caveat is ACCURATE** per JodaTime DateTimeFormat docs. Engineer-actionable trap correctly named.

**PROBLEM:** the "no to_char" framing is FACTUALLY WRONG and will misroute future tasks where `to_char` genuinely WOULD work — e.g., `to_char(order_ts, 'yyyy-mm-dd')` IS valid Trino 467 SQL with the lowercase numeric format and produces a `'2026-06-25'` date label without parse error.

**SOURCE — RESOURCE-SOURCED DEFECT confirmed via grep:**
- `resources/27-oracle-plsql-to-dbt-trino.md:549` "**Trino has NO `TO_CHAR` function** — copy-pasting `TO_CHAR(dt, 'YYYY-MM-DD')` from Oracle into a Trino query or a dbt-Trino model produces `Function 'to_char' not registered` (function-resolution error)."
- `resources/27-oracle-plsql-to-dbt-trino.md:659` table row "`TO_CHAR(order_ts, 'YYYY-MM-DD')` | Oracle | `Function 'to_char' not registered` (function-resolution error) | `date_format(order_ts, '%Y-%m-%d')` or `format_datetime(order_ts, 'yyyy-MM-dd')`"
- `resources/27-oracle-plsql-to-dbt-trino.md:1685` similar table row.

All three are flat false — `to_char` exists in Trino 467 Teradata-compat, no parse error for lowercase numeric formats. **NOT a one-off responder slip** — responder repeated what r27 teaches verbatim. Per pinned `feedback_trace_recurring_folklore_to_resource_root_cause.md`.

This is the **6th instance** of the imported-prior recurring class (assumed-absence direction: starts_with / to_char / listagg / array_sum / trim 2-arg / truncate 2-arg) — and the assumed-absence claim for `to_char` is still in r27 unchanged despite pinned `reference_trino_to_char_exists.md` correcting it.

**FIX-A SPEC (LIGHT):**

1. **r27 §549** — REWRITE: replace "Trino has NO `TO_CHAR` function" with:
   > "**Trino 467 HAS a `to_char(timestamp, format)` function** (Teradata-compatibility connector function) — but with **LOWERCASE NUMERIC-ONLY format codes**: `dd` (day), `mm` (month NUMBER 01-12 not month NAME), `yyyy`/`yy` (year), `hh`/`hh24` (hour), `mi` (minute), `ss` (second), plus punctuation. NO month-name codes (`Month`/`Mon`) — uppercase specifiers are INVALID (parse error). For month-name labels (`'June 2026'`) use `date_format(ts, '%M %Y')` (MySQL-style) or `format_datetime(ts, 'MMMM yyyy')` (Joda)."

2. **r27 §659 + §1685 table rows** — UPDATE: `TO_CHAR(order_ts, 'YYYY-MM-DD')` Oracle uppercase form is invalid in Trino BUT lowercase `to_char(order_ts, 'yyyy-mm-dd')` IS valid (case-sensitivity is the trap, not function existence); preferred forms still `date_format(order_ts, '%Y-%m-%d')` or `format_datetime(order_ts, 'yyyy-MM-dd')` for portability + Joda month-name capability.

3. **Add explicit row:** `TO_CHAR(dt, 'Month YYYY')` Oracle → **NOT possible via Trino `to_char`** (no month-name codes) → use `date_format(dt, '%M %Y')` (MySQL) or `format_datetime(dt, 'MMMM yyyy')` (Joda).

4. **DO-NOT-WRITE defang** at r27 §549: "Trino has no to_char function" — WRONG; `to_char` exists in 467 Teradata-compat but is numeric-only.

5. **Citations:** [trino.io/docs/467/functions/teradata.html](https://trino.io/docs/467/functions/teradata.html) for to_char existence + lowercase-numeric-only constraint.

6. **Pin alignment:** verify pinned `reference_trino_to_char_exists.md` already states the correct existence-but-numeric-only fact; the resource correction brings r27 into alignment with the pin.

**Watch label:** `r27 to_char-exists-numeric-only FIX-A iter1169` — re-probe next sweep with structurally similar question. Two angles for the re-probe:
- Numeric-format angle: "Postgres `to_char(ts, 'YYYY-MM-DD')` → Trino equivalent" — verify responder mentions `to_char(ts, 'yyyy-mm-dd')` IS valid (lowercase).
- Month-name angle: "Trino label 'Q2 2026' or 'June 2026' from a timestamp" — verify steering to date_format/format_datetime + reason ("to_char is numeric-only, no month-name codes").

If both reach the corrected fact, watch closes. If responder still says "Trino has no to_char" → escalate.

Cites r27 §4.1.

### Q3 (5.0 — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0) — EARLIEST date `api_calls > 1000`, NULL if never

**Pin-perfect canonical conditional-aggregation idiom.**

```sql
SELECT customer_id,
       MIN(CASE WHEN api_calls > 1000 THEN activity_date END) AS first_milestone_date
FROM daily_usage
GROUP BY customer_id;
```

**Verified correct on all load-bearing facts:**
- **CASE returns `activity_date` on qualifying rows, NULL on non-qualifying rows** — standard ANSI CASE-WITHOUT-ELSE semantics returns NULL on no match.
- **`MIN` ignores NULLs** per [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) verbatim ("aggregate functions ignore null values" applies to MIN/MAX/SUM/AVG/COUNT).
- **Returns smallest qualifying date** — engineer gets earliest milestone date.
- **Customer with zero qualifying rows** — MIN sees only NULLs → returns NULL → engineer gets the "NULL if never" semantic automatically without a separate guard.
- **Single-pass, single GROUP BY** — no CTEs, no anti-join, no correlated subquery. The cleanest possible shape.
- **Standard ANSI** — works identically across Trino/Postgres/Oracle.

Zero defects, full reach. Engineer ships the one-liner.

### Q4 (5.0 — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0) — dbt feature for loading small reference CSVs

**Clean canonical dbt seeds reach.**

**Verified correct on all facts:**
- **CSV at `seeds/plans.csv`** — correct per [docs.getdbt.com/docs/build/seeds](https://docs.getdbt.com/docs/build/seeds) verbatim ("seed CSV files live in the `seeds` directory of your dbt project").
- **`ref('plans')` in models** — correct (standard ref function works for seeds; verified in dbt docs example `select * from {{ ref('country_codes') }}`).
- **`dbt build` or `dbt seed` then `dbt run`** — correct; `dbt build` runs seeds + tests + models in dependency order, `dbt seed` is the seeds-only command.
- **CSV version-controlled in git** — correct, seeds are best for "static data that changes infrequently" per dbt docs.
- **Loads as Iceberg table on dbt-trino** — correct; dbt-trino adapter materializes seeds as tables on the configured catalog (Iceberg here).
- **Truncate+reload full CSV each build** — correct (seeds default to full-refresh semantics; runs `CREATE OR REPLACE` / `TRUNCATE` + `INSERT`).
- **Size guidance NOT for >~1MB / millions of rows** — correct per dbt docs verbatim: "**Loading CSVs using dbt's seed functionality is not performant for large files. Consider using a different tool to load these CSVs into your data warehouse.**" Engineer's threshold reasoning aligns with docs.
- **Use case alignment** — dbt docs explicit examples ("country code mappings, test email lists, employee account ID lists") map verbatim to engineer's "currency codes, country mappings, plan-tier labels."
- **Spark-ingested dbt source alternative for larger reference data** — correct fallback per dbt docs "For large data loading, use alternative ETL/ELT tools rather than dbt seeds."

Cites r27 §6.7D. Clean 5.0 all dimensions.

---

## Topic row updates

| Topic | Before | After | Delta |
|---|---|---|---|
| Iceberg table maintenance (Q1) | 4.4480 / 194 | (4.4480 × 194 + 4.9375)/195 ≈ **4.4505 / 195** | +0.0025 Q1 lift |
| SQL query best practices for OLAP (Q2) | 4.5871 / 238 | (4.5871 × 238 + 4.0625)/239 ≈ **4.5849 / 239** | -0.0022 Q2 drag |
| Analytical query patterns on Iceberg+Trino (Q3) | 4.5327 / 120 | (4.5327 × 120 + 5.0)/121 ≈ **4.5366 / 121** | +0.0039 Q3 lift |
| Oracle PL/SQL → dbt+Trino migration (Q4) | 4.4714 / 137 | (4.4714 × 137 + 5.0)/138 ≈ **4.4745 / 138** | +0.0031 Q4 lift |

ALL required topics REMAIN PASSED.

---

## Source-verified outcomes this iter
- 0 dialect errors on Q1/Q3/Q4
- 0 findability gaps
- **1 RESOURCE-SOURCED false fact** (Q2 r27 §549/§659/§1685 "Trino has NO to_char" — FACTUALLY WRONG per trino.io/docs/467/functions/teradata.html) — **LIGHT FIX-A REQUIRED**
- 0 over-warning folklore
- **1 successful watch closure on first re-probe** (Q1 — r21+r17 migrate-Trino-native FIX-A iter1168 reaches with verbatim named-arg form; engineer routed correctly to Trino-direct migration with no Spark detour)
- 1 minor Compl shave (Q1 — "new tables default v2" ambiguous in migrate context; non-load-bearing for time-travel + schema-evolution stated requirements)

## Recommendation

**PASS + LIGHT FIX-A** on r27 §549/§659/§1685 to_char-exists-but-numeric-only correction per spec above.

Iter average 4.75 well above threshold; topic margins intact. Q2 defect is **RESOURCE-SOURCED** (r27 teaches the wrong "Trino has no to_char" claim across three locations) — teacher to fix per the FIX-A spec. Q1 watch CLOSES cleanly. Q3/Q4 clean canonical reaches.

**Open watches:**
- ~~`r21+r17 migrate-Trino-native FIX-A iter1168`~~ — **CLOSED** on first re-probe (iter1169 Q1 reached verbatim FIX-A spec).
- `r27 to_char-exists-numeric-only FIX-A iter1169` — new, re-probe next sweep with both numeric-format AND month-name-format angles.

**Pattern observation:** Two consecutive iters surfaced RESOURCE-SOURCED defects of the same family (assumed-absence claims for functions/procedures that actually exist in Trino 467): iter1168 Q3 migrate (claimed Spark-only, is Trino-native) and iter1169 Q2 to_char (claimed nonexistent, exists with numeric-only codes). This continues the recurring "imported-prior assumed-absence" pattern documented across CLAUDE.md memory pins (starts_with, listagg, array_sum, trim 2-arg, truncate 2-arg, to_char, migrate). Verify-first against trino.io/docs/467 official function and connector pages catches these every time; treat any "Trino doesn't have X" claim in resources as guilty until proven innocent.

The Q1 watch closure on FIRST re-probe with DIFFERENT framing ("Hive-format Parquet in HMS, no Spark, Trino only" vs iter1168 "register Parquet on MinIO as Iceberg") confirms the iter1168 FIX-A was structurally sound — engineer arrives at exact named-arg form without needing the original phrasing. The 10-watch run of first-probe closures continues.

**Q2 lesson:** even when the actionable steer is correct (date_format/format_datetime for month-name labels IS the right answer), a false foundational claim in the supporting prose ("Trino has no to_char") propagates from resource to responder. The pin `reference_trino_to_char_exists.md` records the correct fact, but r27 was never reconciled — per pinned `feedback_reconcile_dont_append.md`, the fix must rewrite the wrong claim in place, not append a correction elsewhere.

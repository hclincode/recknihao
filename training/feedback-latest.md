# Iter 536 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall verdict: 4.500 PASS (margin +1.000 above 3.5 floor) — 131st consecutive overall PASS

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|---|
| Q1 | Trino date_trunc('week') Monday/ISO | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** STRONG PASS WIN |
| Q2 | Trino timestamp formatting ("June 06, 2026") | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** STRONG PASS |
| Q3 | dbt snapshot: check vs timestamp strategy | 3.0 | 4.5 | 4.5 | 4.0 | **4.000** PASS w/ COLUMN SLIP |
| Q4 | Iceberg partition month → day (evolution) | 3.5 | 4.0 | 4.5 | 4.0 | **4.000** PASS w/ OVERSTATED SPARK CLAIM |
| **Overall** | | | | | | **4.500 PASS** |

Iter535's 4.375 → iter536's 4.500 net swing **+0.125** (Q1 LIFTED +2.250 from 2.750 FAIL to 5.000 STRONG PASS because iter536 teacher's r07 Monday/ISO canonical landed perfectly; Q2 perfect 5.000 strong-pass new probe; Q3 dropped to 4.000 due to dbt_is_deleted-vs-dbt_updated_at column slip; Q4 dropped to 4.000 due to overstated "MUST use Spark" claim).

---

## PRIMARY WIN: Q1 date_trunc('week') Monday/ISO — gap CLOSED on first re-probe (5.000)

**The defect**: Iter535 Q4 was a 2.750 FAIL — responder honestly declined on Monday-vs-Sunday, THEN invented a WRONG `date_trunc('week', d + INTERVAL '1' DAY) - INTERVAL '1' DAY` "workaround" to force Monday, which actually produces SUNDAY-start.

**Iter536 teacher's FIX A** added the Monday/ISO canonical to r07 directly adjacent to the locked date_trunc return-type note at L610, including (a) keyword anchors line, (b) TRUTH paragraph with Monday/ISO + day_of_week 1=Monday..7=Sunday, (c) worked example `date_trunc('week', DATE '2020-01-01') = 2019-12-30`, (d) in-line signal in canonical SQL block with EOL comment, (e) DO-NOT-WRITE ban on the harmful INTERVAL-shift workaround, (f) Sunday-start framed only as US-style.

**Iter536 responder Q1 outcome**:
- Stated unambiguously "Trino does it by default, no offset needed. `date_trunc('week', order_ts)` ALWAYS starts weeks on Monday, ISO-8601."
- Worked example: Wednesday 2026-01-15 → Monday 2026-01-12.
- Explicitly said do NOT need an offset/CASE/adjustment.
- Said Sunday-start only if business wants US-style (rare).
- **Did NOT emit the harmful `date_trunc('week', d + INTERVAL '1' DAY) - INTERVAL '1' DAY` shift.**

**Doc verification (trino.io/docs/current/functions/datetime.html)**:
- `day_of_week()` doc quote: "Returns the ISO day of the week from `x`. The value ranges from `1` (Monday) to `7` (Sunday)."
- date_trunc('week', x) worked example in docs: timestamp `2001-08-22 03:04:05.321` truncates to week `2001-08-20 00:00:00.000` — 2001-08-20 was a Monday. Confirms ISO Monday-start.

**Win pattern**: Same as iter400 (dbt config), iter402 ($partitions metadata), iter535 (persist_docs) — single in-place canonical adjacent to locked content + explicit DO-NOT-WRITE banner closes the gap on first re-probe. The signal-INSIDE-the-SQL-line strategy (iter534 onward) continues to work as the primary closure mechanism for harmful-speculation defects.

---

## Q2 — Trino timestamp formatting ("June 06, 2026") — 5.000 STRONG PASS

**Verbatim claim**:
- `format_datetime(ts, 'MMMM dd, yyyy')` (Joda) → "June 06, 2026" ✓
- `date_format(ts, '%M %d, %Y')` (MySQL-style) → "June 06, 2026" ✓
- Trino has NO strftime ✓
- Gotcha table: Joda MM=month / mm=minute; MySQL %m=month / %i=minute ✓

**Doc verification (trino.io/docs/current/functions/datetime.html)**:
- `format_datetime(timestamp, format) → varchar`: Formats `timestamp` using Joda-Time pattern (`MMMM` full-month name, `dd` zero-padded day, `yyyy` 4-digit year). Output for 2026-06-06 = "June 06, 2026" — correct.
- `date_format(timestamp, format) → varchar`: Formats `timestamp` using MySQL-style specifiers (`%M` full-month name, `%d` zero-padded day, `%Y` 4-digit year). Output for 2026-06-06 = "June 06, 2026" — correct.
- No `strftime` function in Trino — confirmed (only `format_datetime` and `date_format`).
- Joda MM-vs-mm and MySQL %m-vs-%i are the canonical pitfalls — gotcha table is accurate.

---

## Q3 — dbt snapshot check vs timestamp — 4.000 PASS w/ COLUMN SLIP

**What was correct**:
- timestamp strategy: needs `updated_at` column, faster, per-row timestamp compare ✓
- check strategy: `check_cols` list, hashes columns, slower, no updated_at needed ✓
- Query current with `WHERE dbt_valid_to IS NULL` ✓
- "When to use which" guidance is reasonable.

**SLIP CONFIRMED — dbt_is_deleted SWAPPED for dbt_updated_at**:

The responder claimed both strategies produce four metadata columns: `dbt_scd_id, dbt_valid_from, dbt_valid_to, dbt_is_deleted`.

**The correct DEFAULT four** (verified at docs.getdbt.com/reference/resource-configs/snapshot_meta_column_names):
1. `dbt_scd_id` — unique key generated for each snapshot row
2. `dbt_updated_at` — the `updated_at` timestamp of the source record when the snapshot row was inserted
3. `dbt_valid_from` — timestamp when the snapshot row was first inserted and became valid
4. `dbt_valid_to` — timestamp when the row is no longer valid

**`dbt_is_deleted` is NOT a default meta-column** — doc verbatim: "`dbt_is_deleted` is **only added when the `hard_deletes='new_record'` config is set**. It is not added by default."

The responder swapped `dbt_updated_at` (always present) for `dbt_is_deleted` (only present with hard_deletes='new_record'). This is a factual error a beginner will copy-paste and then be confused when their snapshot table doesn't have a `dbt_is_deleted` column (the default) OR doesn't have `dbt_updated_at` (which the responder did NOT mention).

**Note**: The rubric row for "dbt snapshots SCD2" already lists all five columns correctly: "dbt_valid_from/dbt_valid_to/dbt_scd_id/dbt_updated_at/dbt_is_deleted in 1.9+" — so the rubric anchor is correct; the responder slipped at runtime, suggesting the resource (r09 dbt-snapshot section) may not have a clear "DEFAULT vs CONDITIONAL" separation.

**Accuracy 3.0**: strategy semantics fully correct, but the column-list slip is non-trivial because it's the exact thing a SaaS engineer needs to JOIN/SELECT against. Half-credit Accuracy reflects "right intent, wrong column".

---

## Q4 — Iceberg partition month → day — 4.000 PASS w/ OVERSTATED SPARK CLAIM

**What was correct**:
- Step 1: `ALTER TABLE iceberg.analytics.events SET PROPERTIES partitioning = ARRAY['day(occurred_at)']` — VALID Trino 467 syntax. Verified at trino.io/docs/current/connector/iceberg.html: `ALTER TABLE table_name SET PROPERTIES partitioning = ARRAY[<existing partition columns>, 'my_new_partition_column']` is documented for partition evolution. Doc quote: "Partitioning can also be changed and the connector can still query data created before the partitioning change."
- Step 1 framing as metadata-only with old files staying on month spec and Trino reading across both specs is correct (Iceberg partition evolution semantics).
- Step 3: `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` — valid Trino 467 syntax, explicit param is fine.

**OVERSTATED CLAIM — Step 2 "MUST use Spark"**:

Responder said: "Trino's `EXECUTE optimize` does NOT repartition files to a new spec — it only compacts file sizes. You MUST use Spark" + gave `CALL iceberg.system.rewrite_data_files(...)`.

**Verification verdict (with explicit uncertainty)**:
- Trino docs for `optimize` (trino.io/docs/current/connector/iceberg.html) state: "is used for rewriting the content of the specified table so that it is merged into fewer but larger files. If the table is partitioned, the data compaction acts separately on each partition selected for optimization." — does NOT explicitly state whether `optimize` rewrites files INTO the CURRENT (new) partition spec after partition evolution.
- Starburst blog (starburst.io/blog/iceberg-partitioning-and-performance-optimizations-in-trino-partitioning/) verbatim: "The existing data will remain partitioned by day unless the table is recreated." — supports the responder's "old data stays on old spec" framing for default behavior.
- Trino GitHub issue #25279 ("Add support to optimize iceberg table on newly added partition predicate"): "Newly added partition column can not be used as part of the predicate during optimize" — confirms KNOWN GAPS in Trino's optimize-after-partition-evolution support.
- Trino GitHub issue #12983: open feature request to "allow specifying specific partition spec ids" for optimize — strong signal that optimize-across-multiple-partition-specs is NOT fully supported as of Trino 467.
- Trino GitHub issue #12362 ("Ability to OPTIMIZE a single time-based partition in Iceberg"): "if a table is partitioned using the hidden partition column feature (e.g. day(timestamp)), there does not seem to be a way to target a single day for optimization."

**Judge verdict**: The responder's "MUST use Spark `rewrite_data_files`" claim is **overstated but defensible** — the documented Trino limitations DO suggest Spark is the more reliable path for rewriting historical data into a new partition spec, but the claim that Trino `optimize` "only compacts file sizes" (i.e. never repartitions) is too categorical given the docs are silent on the explicit behavior. The Starburst article supports "existing data remains partitioned by day unless the table is recreated" — which is consistent with the responder's framing.

**Accuracy 3.5**: Step 1 + Step 3 fully correct; Step 2 is more confident than the docs warrant but is NOT clearly wrong and gives the SaaS engineer a working path (Spark rewrite_data_files). The user is NOT harmed by following the advice — they'll get the correct result. The defect is "overstated certainty," not "wrong answer."

**iter537 verification probe recommended**: empirically test whether Trino 467 `ALTER TABLE ... EXECUTE optimize` after `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY['day(...)']` rewrites historical files into the new day-spec or leaves them on the old month-spec. If optimize DOES rewrite into the current spec, the responder's "MUST use Spark" is a fabrication and r17 needs a corrective canonical. If optimize does NOT rewrite into the current spec, the responder is correct and r17 should add a pin documenting this.

---

## iter537 NEXT-TEACHER ACTIONS

### FIX A (HIGH — Q3 dbt snapshot column slip)

**Location**: resources/09 dbt-snapshot canonical (the iter532 COALESCE-default block area, or wherever the meta-columns list lives).

**The fix**: Add a clear DEFAULT-vs-CONDITIONAL separation to the dbt snapshot meta-columns list:

```
DEFAULT four meta-columns (always added by dbt snapshots):
  1. dbt_scd_id       — unique key per snapshot row (MD5 hash internally)
  2. dbt_updated_at   — the updated_at timestamp of the source record at insert time
  3. dbt_valid_from   — when this row version became valid (Type-2 SCD start)
  4. dbt_valid_to     — when this row version stopped being valid (NULL = current)

CONDITIONAL fifth meta-column:
  5. dbt_is_deleted   — only added when config sets hard_deletes='new_record'
                        (NOT a default — beginners will be confused if they expect it)
```

**Doc quote anchor** (from docs.getdbt.com/reference/resource-configs/snapshot_meta_column_names):
> "`dbt_is_deleted` is only added when the `hard_deletes='new_record'` config is set."

**Keyword anchors**: "dbt snapshot columns / dbt_is_deleted default / dbt snapshot default columns / dbt_updated_at vs dbt_is_deleted / dbt snapshot meta-fields / SCD2 dbt columns".

**Signal-INSIDE-the-line corrective** (per iter534 strategy): in any sample `SELECT *` from a dbt snapshot, add EOL comment on the dbt_is_deleted column: `-- only present if hard_deletes='new_record'; NOT a default column`.

**DO-NOT-WRITE banner**: "Do NOT claim the four default snapshot columns are `dbt_scd_id, dbt_valid_from, dbt_valid_to, dbt_is_deleted` — that swaps `dbt_updated_at` (default) for `dbt_is_deleted` (conditional). The correct four defaults are `dbt_scd_id, dbt_updated_at, dbt_valid_from, dbt_valid_to`."

### FIX B (MEDIUM — Q4 Trino optimize after partition evolution: verify-then-pin)

**Recommended approach**: empirical verification first.

**Probe step**: have a teacher (or operator with Trino access) run:
1. CREATE Iceberg table partitioned by `month(ts)`.
2. INSERT several months of data.
3. `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY['day(ts)']`.
4. `ALTER TABLE ... EXECUTE optimize` (no WHERE clause).
5. Check `"events$files"` — what partition spec do the rewritten files reference?

**If optimize DOES rewrite into the new day spec**: the responder's "MUST use Spark" is a fabrication. r17 needs a corrective canonical: "Trino `EXECUTE optimize` rewrites files into the CURRENT partition spec — after partition evolution, optimize completes the repartitioning of historical data. Spark `rewrite_data_files` is NOT required." Add DO-NOT-WRITE banner against the responder's overstated claim.

**If optimize does NOT rewrite into the new day spec**: the responder is correct. r17 needs a pin: "After ALTER TABLE SET PROPERTIES partitioning, Trino `EXECUTE optimize` does NOT repartition existing data files to the new spec — only compacts within the old spec. To rewrite historical data into the new day spec, use Spark `CALL iceberg.system.rewrite_data_files(...)`." Cite Trino GitHub issues #25279 / #12983 / #12362.

**Until verified**: do NOT add a contradicting canonical to r17 — the current responder answer is at minimum harmless (Spark rewrite_data_files works in all cases) and consistent with the Starburst article framing.

### NO FIXES NEEDED — Q1, Q2

Q1 closure is PERFECT — iter536 teacher's r07 Monday/ISO canonical at L611 landed on first re-probe. No regression risk for 1-2 iterations.

Q2 strong-pass — format_datetime + date_format + Joda/MySQL gotcha table all bulletproofed.

---

## TOPIC AVG UPDATES

- **Common analytical query patterns** (Q1 date_trunc week-start cluster) 4.6886/12 → (4.6886·12 + 5.000)/13 = (56.2632 + 5.000)/13 = 61.2632/13 = **4.7126/13** (+0.0240 — Q1 above topic avg lift)
- **SQL query best practices for OLAP** (Q2 datetime-formatting / format_datetime cluster) 4.5321/99 → (4.5321·99 + 5.000)/100 = (448.6779 + 5.000)/100 = 453.6779/100 = **4.5368/100** (+0.0047 — Q2 above topic avg lift)
- **dbt snapshots SCD2** (Q3 check-vs-timestamp + meta-columns cluster) 4.2969/4 → (4.2969·4 + 4.000)/5 = (17.1876 + 4.000)/5 = 21.1876/5 = **4.2375/5** (-0.0594 — Q3 below topic avg drags slightly; column slip is real but PASS overall)
- **Iceberg partition design for SaaS** (Q4 partition evolution + optimize cluster) 4.4947/36 → (4.4947·36 + 4.000)/37 = (161.8092 + 4.000)/37 = 165.8092/37 = **4.4813/37** (-0.0134 — Q4 below topic avg drags slightly)

**Federation row UNCHANGED**: stays 4.49944/310 per iter472-536 directive (no federation probe this iter).

---

## Iter537 probe targets

1. **dbt snapshot meta-columns 2nd angle (HIGH — verifies FIX A landing)**: "I queried `dbt_is_deleted` on my snapshot and got 'Column cannot be resolved' — what's the default snapshot column set?" OR "What snapshot meta-columns does dbt give me out of the box for SCD2?"
2. **Iceberg partition evolution + optimize 2nd angle (MEDIUM — verifies FIX B landing IF verified)**: "I changed my Iceberg partitioning from month to day, then ran EXECUTE optimize — did it rewrite the old files into day partitions?" OR "Do I need Spark to repartition historical data after Iceberg partition evolution?"
3. **date_trunc('week') 2nd re-probe (MEDIUM — durability check)**: "My US customer wants weeks to start on Sunday — how do I switch from Trino's default?" — verifies Monday/ISO canonical stays sticky AND the Sunday-as-US-recipe survives a flip in question framing.
4. **format_datetime 2nd angle (LOW — well-bulletproofed)**: "I need to format dates as `Mon Jun 06 2026` (RFC-2822-ish) — Joda or date_format?"
5. **dbt snapshot timestamp-vs-check 2nd angle (LOW)**: "My source table has no updated_at column — what's my snapshot strategy?"
6. **Federation stays UNPROBED (LOW)** — row stays 4.49944/310 per directive.

**131st consecutive overall PASS in extended phase — margin +1.000 above floor.** **PRIMARY WIN: iter536 teacher's r07 Monday/ISO canonical closed the iter535 Q4 harmful-speculation gap on first re-probe.** Two new fix targets identified: Q3 dbt_is_deleted-vs-dbt_updated_at column slip (HIGH, fab) and Q4 overstated "MUST use Spark" claim (MEDIUM, needs empirical verification before adding contradicting canonical).

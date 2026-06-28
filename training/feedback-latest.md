# Iteration 1228 — Judge Feedback

**Verdict: 3.94 PASS (margin +0.44) with TWO FIX-As recommended.** Q1 (WATCH) and Q2 land canonical 5.0; Q3 (WATCH) and Q4 both miss in-resources canonicals → two structurally distinct findability gaps. Iter average (5.0+5.0+3.0+2.75)/4 = 3.9375.

- **iter1224 CoW-MoR scenario-diagnosis WATCH: CLOSES** on first re-probe (Q1 5.0). Responder correctly bridges "delete files visible = ALREADY on MoR / accumulated position-deletes = the slowdown / EXECUTE optimize compaction = the fix" — exactly the multi-hop synthesis iter1224 failed to assemble. 15th consecutive 1st-re-probe-CLOSE pattern.
- **iter1226 r27 packages.yml-troubleshooting WATCH: DID NOT REACH** (Q3 3.0). The FIX-A card EXISTS at r27 §4.5A L1768-L1775 with the version-rename row LISTED FIRST in the troubleshooting table, but the responder didn't surface it as THE answer — landed instead on the generic location/format/`dbt_packages/` checklist that the engineer's stated facts already RULE OUT, then padded with a fabricated-then-retracted `{%- do dbt_utils ... -%}` "macro import" suggestion. Recommendation: STRENGTHEN the §4.5A card (LIGHT FIX-A) — version-rename row needs a top-line anchor "macro 'generate_surrogate_key' not found in any package = VERSION issue" and physical reordering above the 3-step setup block.
- **Q4 MISS — new findability gap**: in-resources `format('$%,.2f', total_revenue)` Trino-native canonical (r23 §3.1A LEADING CANONICAL L690-714 + L917) NOT reached when engineer asked "Oracle TO_CHAR(amount, 'FM$999,999.00') → Trino" / "currency formatting / dollar amount with commas". §3.1A's keyword anchors don't cover "currency / TO_CHAR number / dollar amount / FM mask / number format mask"; r27 §4.2A TO_CHAR canonical covers ONLY dates, has no TO_CHAR(number,...) row. Recommendation: LIGHT FINDABILITY FIX-A — extend anchors in r23 §3.1A + add TO_CHAR(number,...) row to r27's Oracle-function-translation table.

Per-question summary:
- **Q1 5.0 (WATCH CLOSE)** — MoR position-delete accumulation correctly diagnosed as cause; `SELECT content, COUNT(*) FROM "orders$files" GROUP BY content` correct diagnostic ($files.content enum 0=DATA / 1=POSITION_DELETES / 2=EQUALITY_DELETES); `EXECUTE optimize(file_size_threshold => '128MB')` correct Trino-native fix (no Spark coordination needed, production-stack-aligned); `EXECUTE expire_snapshots(retention_threshold => '7d')` correct duration-STRING param shape (NOT `retention_days => 7`; iter1214 fab-proofed).
- **Q2 5.0** — `AVG(new_signups) OVER (ORDER BY signup_date RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW)` canonical Trino 467 sliding-time-window form; RANGE-vs-ROWS distinction load-bearing for time-series with missing days.
- **Q3 3.0 (WATCH DID NOT REACH)** — version-rename (dbt_utils 1.0.0 Nov 2022 renamed `surrogate_key` → `generate_surrogate_key`) was the #1 cause; r27 §4.5A FIX-A card HAS it but the responder didn't surface it. Engineer's checklist contains a fabricated-then-retracted macro-import suggestion. STRENGTHENING WARRANTED.
- **Q4 2.75 (MISS)** — in-resources `format('$%,.2f', total_revenue)` at r23 §3.1A NOT reached on "currency / Oracle TO_CHAR number / dollar amount with commas" framing; `format_number` ALSO mischaracterized as "Spark-only / example UDF" (Trino HAS `format_number` but produces compact-units `'1.2M'`/`'500K'`, not comma-mask). LIGHT FINDABILITY FIX-A WARRANTED.

---

## Q1 (WATCH) — Spark nightly MERGE INTO on Iceberg orders; Trino dashboard 3-4x slower; "Trino reads delete files alongside data files" — what does it mean / is that the slowdown / what to do

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**WATCH OUTCOME: `iter1224 CoW-MoR scenario-diagnosis-when-symptom-implies-mode + compaction-not-mode-switch` CLOSES on first re-probe.**

iter1224 was a scenario-diagnosis MUDDLE — responder failed to bridge "delete files visible → engineer is ALREADY on MoR → the fix is COMPACTION not a mode-switch" and instead floated mode-switching guidance against an already-MoR table. iter1228 lands the FULL diagnosis cleanly under a structurally different framing (nightly Spark MERGE INTO + Trino dashboards slower + teammate explanation vs iter1224's "teammate says switch to MoR" framing).

**Responder shape.**
1. **What "delete files" are**: Spark MERGE INTO on Iceberg V2 produces *positional delete files* (tombstones referencing invalidated rows by ordinal) instead of rewriting the affected data files. The orders table is on Merge-on-Read mode.
2. **Why dashboard reads slow down**: Trino's reader merges ALL delete files against the data files at scan time. Each nightly MERGE adds more positional delete files; after ~2 weeks the reconciliation cost dominates, giving the 3-4x slowdown that scales with delete-file count.
3. **Diagnostic** (Trino-native): `SELECT content, COUNT(*) FROM iceberg.<schema>."orders$files" GROUP BY content` — content enum (0=DATA, 1=POSITION_DELETES, 2=EQUALITY_DELETES). If POSITION_DELETES > 10% of DATA, that's the cause.
4. **FIX (Trino-native, no Spark coordination required)**: `ALTER TABLE iceberg.<schema>.orders EXECUTE optimize(file_size_threshold => '128MB')` — rewrites affected data files with deleted rows physically excluded; readers stop paying the reconciliation cost. Follow with `ALTER TABLE iceberg.<schema>.orders EXECUTE expire_snapshots(retention_threshold => '7d')` for storage hygiene.
5. Production-stack alignment: Trino EXECUTE optimize fits the on-prem stack — engineer doesn't need to coordinate with the Spark side that already owns ingestion.

**Load-bearing facts VERIFIED:**

1. **MoR position-delete accumulation = read amplification** — verified at [iceberglakehouse.com/iceberg/iceberg-merge-on-read](https://iceberglakehouse.com/iceberg/iceberg-merge-on-read/) "as more changes accumulate in delete files, query performance can start to degrade" + [trinodb/trino PR #12704](https://github.com/trinodb/trino/pull/12704) (positional delete merge at scan). Matches r13 §2996 CoW-vs-MoR comparison table.
2. **`$files.content` enum** — verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) Iceberg metadata tables section (0=DATA, 1=POSITION_DELETES, 2=EQUALITY_DELETES). The `SELECT content, COUNT(*) FROM "<t>$files" GROUP BY content` form is the canonical diagnostic; matches r17 §109 and §2568.
3. **`EXECUTE optimize` reconciles position-deletes during rewrite** — verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) "rewriting the content of the specified table so that it is merged into fewer but larger files." Caveat per [trinodb/trino#24086](https://github.com/trinodb/trino/issues/24086): physical removal of orphan delete files can require additional snapshot expiration, and there are partition-predicate constraints when calling optimize with a predicate. For the *read-time slowdown* (the engineer's actual symptom), the canonical optimize call DOES rewrite data files and stop the reconciliation cost — that's the fix.
4. **`file_size_threshold => '128MB'`** — duration/size STRING form (default `100MB`); valid Trino 467 syntax.
5. **`expire_snapshots(retention_threshold => '7d')`** — duration STRING form, NOT `retention_days => 7`. Matches pinned iter1214 retention_threshold-shape correction. Floor: `iceberg.expire-snapshots.min-retention` (default 7d).
6. **Production-stack alignment**: Trino-native EXECUTE optimize fits prod_info.md (on-prem Trino 467 + Spark ingestion). Engineer doesn't need to coordinate a Spark `rewrite_position_delete_files` call (which would also work but adds coordination cost).

**iter1224 muddle inverted.** iter1224 responder said "teammate is right, switch to MoR / CoW would rewrite your whole table" against a table that was ALREADY on MoR (the delete files visible in EXPLAIN ANALYZE = the proof). iter1228 responder correctly reads "delete files visible" as the SIGNAL that they're already on MoR + the accumulation IS the slowdown + compaction is the fix. Clean multi-hop synthesis.

No imported-prior, no broken-secondary, no over-warning, no fabrication. Engineer leaves with correct mental model + one-line diagnostic + Trino-native one-EXECUTE fix + storage-hygiene follow-on. Cites r13/r17.

---

## Q2 — 7-day rolling avg of new signups per day; signups_daily(signup_date, new_signups); never done a sliding time window in Trino

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**Responder shape.**
```sql
SELECT
  signup_date,
  new_signups,
  AVG(new_signups) OVER (
    ORDER BY signup_date
    RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW
  ) AS rolling_7d_avg
FROM signups_daily
ORDER BY signup_date;
```
Plus the load-bearing **RANGE vs ROWS** correctness note: RANGE is value-based (calendar-aware — if Sept 14 is missing in the source table, Sept 15's window correctly includes Sept 9-15 by date); ROWS is positional ("6 preceding rows" — if Sept 14 missing, the 7th-back ROW is actually Sept 7, wrong window for "last 7 days"). For a daily signup series where any day could have zero rows, the engineer MUST use RANGE.

**Load-bearing facts VERIFIED:**

1. **`AVG(...) OVER (ORDER BY date RANGE BETWEEN INTERVAL 'N' DAY PRECEDING AND CURRENT ROW)` is the canonical Trino 467 sliding-time-window rolling-aggregate form** — verified at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) verbatim: *"Range frames can be defined with a window frame value of the type `INTERVAL`. The ORDER BY column must be of a numeric or date/time type for `INTERVAL` frame bounds."*
2. **`RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW` = 7-day window** — current day + 6 prior calendar days = 7 days inclusive. Engineer can read the spec literally and arrive at correct cardinality.
3. **`INTERVAL 'N' DAY` qualifier is valid Trino 467** — DAY is one of the supported interval qualifiers (YEAR/MONTH/DAY/HOUR/MINUTE/SECOND per pinned `reference_trino_interval_qualifiers.md` git-tag SqlBase.g4). NOT WEEK / NOT QUARTER (those are date_trunc unit strings but not interval qualifiers).
4. **RANGE vs ROWS distinction is correctness-critical, not stylistic** — responder calls it out explicitly with the missing-day example. This is the most common bug in this query shape (engineer writes ROWS BETWEEN 6 PRECEDING and gets a wrong window on a series with gaps).

Engineer leaves with: a one-spec window function + the RANGE-vs-ROWS correctness gate. No imported-prior, no broken-secondary, no over-warning, no fabrication. Cites r07.

---

## Q3 (WATCH) — packages.yml in root, `dbt deps` succeeded, `{{ dbt_utils.generate_surrogate_key([...]) }}` invocation correct, but `dbt run` errors "macro 'generate_surrogate_key' not found in any package" — what causes that

**Score: 3.0** — Acc 3.0 / Clar 4.0 / App 2.5 / Compl 2.5

**WATCH OUTCOME: `iter1226 r27 packages.yml-troubleshooting FIX-A` DID NOT REACH.** Card EXISTS at r27 §4.5A L1768-L1775 with the version-rename row LISTED FIRST in the troubleshooting table, but the responder didn't surface it as THE answer.

**Responder shape (verbatim summary).** Checklist:
1. packages.yml in dbt project root (next to dbt_project.yml, not in models/) — engineer ALREADY STATES this in the question;
2. Format `packages: - package: dbt-labs/dbt_utils version: 1.1.1`;
3. Verify `dbt deps` created `dbt_packages/dbt_utils/macros/` (re-run `dbt deps -d` if missing);
4. Call pattern `{{ dbt_utils.generate_surrogate_key([...]) }}` — engineer is ALREADY using this;
5. "**Common hidden cause: some dbt versions/adapters require you to explicitly ref the macro... add `{%- do dbt_utils.generate_surrogate_key([...]) -%}` at top — Actually, that's not the right pattern. The correct pattern is just call it in SELECT... if still not found check logs for download errors.**"

**The actual #1 cause the responder MISSED: dbt_utils 1.0.0 (Nov 2022) RENAMED `surrogate_key` → `generate_surrogate_key`.** On any pin allowing `< 1.0.0`, `generate_surrogate_key` is GENUINELY undefined under that name → exact "macro 'generate_surrogate_key' not found in any package" runtime error. Verified at [docs.getdbt.com/docs/dbt-versions/core-upgrade/Older versions/upgrading-to-dbt-utils-v1.0](https://docs.getdbt.com/docs/dbt-versions/core-upgrade/Older%20versions/upgrading-to-dbt-utils-v1.0) + [brooklyn-data/dbt_artifacts#257](https://github.com/brooklyn-data/dbt_artifacts/issues/257) "surrogate_key is replaced by generate_surrogate_key in dbt utils v1" + [dbt-utils CHANGELOG](https://github.com/dbt-labs/dbt-utils/blob/main/CHANGELOG.md) (v1.0.0 release notes). Engineer's symptom — `dbt deps` succeeds (package installs fine) + macro invisible at `dbt run` (it doesn't exist by that name) — is THE textbook signature of this cause.

**Resource-source check — the FIX-A card EXISTS but isn't being surfaced.**

```
$ grep -n "version-rename\|RENAMED to" resources/27-oracle-plsql-to-dbt-trino.md
1771: | **Wrong macro NAME for the installed version** | dbt_utils **< 1.0.0** has the macro as
      **`dbt_utils.surrogate_key`** — it was RENAMED to **`generate_surrogate_key` in dbt_utils 1.0.0**
      (Nov 2022). On an old pinned version, `generate_surrogate_key` is genuinely undefined. |
```

Keyword anchor on the §4.5A card preamble L1758: *"dbt_utils not found, generate_surrogate_key undefined / can't resolve / not defined, dbt deps ran but macro missing, packages.yml setup, how to install dbt_utils, dbt package macro won't resolve, 'dbt_utils' is undefined."* Matches the engineer's question framing well.

**Hypothesis for why the card didn't surface as THE answer.** Responder's keyword-match found §4.5A and read the 3-step SETUP block (L1760-L1766) first, then padded a generic troubleshooting checklist of its own without reaching the TROUBLESHOOTING TABLE at L1769-L1774. The table containing the version-rename row physically follows the setup block, and the responder appears to have stopped before reaching it. The engineer's STATED FACTS (packages.yml in root + `dbt deps` printed "Dependencies installed" no errors + `{{ }}` invocation) RULE OUT every item in the responder's checklist — none of them are actionable, the engineer can't fix anything from this answer.

**Plus a fabrication.** The "`{%- do dbt_utils.generate_surrogate_key([...]) -%}` macro import" suggestion does not exist as a dbt pattern. Responder self-retracts ("actually, that's not the right pattern") but the noise still installs a false mental model before the retraction. Per `feedback_responder_broken_secondary_alternative.md` family — but here it appears as a PADDING aside on a Q where the lead is ALSO incomplete, so it compounds the App/Compl shave.

**STRENGTHENING RECOMMENDED (LIGHT FIX-A on the iter1226 §4.5A card).** Two structural changes:

1. **Lead the troubleshooting block with a top-line VERSION anchor.** Before (or as a one-line preamble of) the troubleshooting TABLE, add a callout:
   > **`macro 'generate_surrogate_key' not found in any package` after `dbt deps` succeeded? 90% of the time it's a VERSION issue — your pin allows `dbt_utils < 1.0.0`, which has the macro under its OLD name `dbt_utils.surrogate_key`. Bump to `version: [">=1.1.0","<2.0.0"]` and re-run `dbt deps`.**

   Anchor keywords: *"macro not found in any package", "macro 'generate_surrogate_key' not found", "dbt deps succeeded but macro invisible", "macro invisible at runtime", "dbt run fails generate_surrogate_key", "generate_surrogate_key undefined after dbt deps".*

2. **Reorder physical sequence.** Move the troubleshooting TABLE EARLIER in §4.5A — directly after the keyword-anchor preamble L1758 and BEFORE the 3-step setup block L1760-L1766. The responder's keyword-match landed at L1758 first; the table needs to be the next thing they read, not the 3-step setup block. (The setup block can move below the table, or be appended as "If you don't have packages.yml at all, here are the 3 setup steps.")

3. **Optionally**: defang the macro-import `{%- do dbt_utils -%}` form inline as a DO-NOT-WRITE row, since this is the second time-ish the responder has padded a similar fabrication in this family.

**WATCH STATUS**: keep `iter1226 r27 packages.yml-troubleshooting card-findability` OPEN; re-probe in 4-8 iters after strengthening lands under fresh framing ("dbt deps Dependencies installed but dbt_utils macro can't resolve at runtime"). NEW soft watch `iter1228 Q3 macro-import {%- do dbt_utils -%} fabrication padding` — re-probe 4-8 iters.

---

## Q4 — Oracle `TO_CHAR(total_revenue, 'FM$999,999,999.00')` → dollar amount with commas + 2 decimals; Trino parse error; Trino to_char is for timestamps; does it handle NUMBER formatting / way to format a number with thousands separators + currency symbol in Trino, or app layer?

**Score: 2.75** — Acc 2.5 / Clar 4.0 / App 2.5 / Compl 2.0

**MISS.** Responder did NOT reach `format('$%,.2f', total_revenue)` — the in-resources Trino-native one-liner that IS the literal answer to this question.

**Responder shape (verbatim summary).** "Trino 467 has NO built-in number formatter like Oracle TO_CHAR(amount, 'FM$999,999.00'); to_char works ONLY for timestamps. Options:
1. PRIMARY format in the app layer (Python f-string `f'${revenue:,.2f}'`);
2. FALLBACK string concat with `format_number(ABS(revenue),'#,##0.00')` BUT format_number is NOT a Trino built-in (Spark-only / example UDF);
3. Fragile substring-comma hack.

Recommendation: keep `decimal(18,2)` in Trino, format in app/dashboard layer."

**The actual in-resources Trino-native answer the responder MISSED:**
```sql
SELECT format('$%,.2f', total_revenue) AS revenue_label FROM ...;
-- => '$1,234,567.89'
```
`format(format_string, args...)` IS Trino 467's printf / Java-Formatter-style string builder. `%,.2f` produces a thousands-grouped 2-decimal float; the literal `$` in the format string yields `$1,234,567.89`.

**Load-bearing verification:**

1. **`format()` IS documented Trino 467 native** — verified at [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html) (WebFetched this iter): `format(format, args...) → varchar` *"Returns a formatted string using the specified [format string](https://docs.oracle.com/en/java/javase/23/docs/api/java.base/java/util/Formatter.html#syntax) and arguments"*. Docs explicitly show `'%,.2f'` → `'1,234,567.89'`.
2. **`format()` IS in resources** — verified `grep "%,.2f"` in `resources/`:
   - `resources/23-sql-best-practices-olap.md:703` LEADING CANONICAL row: `` `%,.2f` | Float with thousands grouping + 2 decimals | `format('%,.2f', 1234567.89)` | `1,234,567.89` ``
   - `resources/23-sql-best-practices-olap.md:708` worked example: `format('User %s made %d purchases totaling $%,.2f', user_id, purchase_count, total_amount)` → `'User U-1234 made 17 purchases totaling $1,234.56'`
   - `resources/23-sql-best-practices-olap.md:917` DO-NOT-WRITE table row: `'$' || total_amount` (DECIMAL/DOUBLE) → DECIMAL/DOUBLE rejected by varchar-only `||` → RIGHT: `format('$%,.2f', total_amount)`

3. **`format_number` IS Trino 467 native (but does compact-units, NOT comma-mask)** — verified at [github.com/trinodb/trino/blob/master/core/trino-main/src/main/java/io/trino/operator/scalar/FormatNumberFunction.java](https://github.com/trinodb/trino/blob/master/core/trino-main/src/main/java/io/trino/operator/scalar/FormatNumberFunction.java): signatures `formatNumber(BIGINT) → VARCHAR` and `formatNumber(DOUBLE) → VARCHAR`; produces compact-unit output like `'1.2M'`, `'500K'`, `'1.5B'` using DecimalFormat patterns `#.##` / `#.#` / `#`. **Responder's claim "format_number is NOT a Trino built-in (Spark-only / example UDF)" is FALSE.** Correct framing: "Trino HAS format_number but it's the compact-units `'1.2M'`-style formatter (BIGINT/DOUBLE → VARCHAR), NOT Oracle's comma-mask. Use `format('$%,.2f', n)` for the Oracle-style output."

**Engineer's loss.** Engineer leaves with: rejects fragile substring hack (good); routes to app-layer Python (FORFEITS the Trino-native one-liner); installs wrong mental model "Trino can't format a number" (FALSE — Trino's `format()` does printf for numbers). The recommended decimal(18,2) in Trino + format in app layer is a valid architectural choice, but the engineer wasn't even shown the alternative — they cannot make an informed choice.

**FINDABILITY ROOT CAUSE — `grep` evidence on resources/:**

- `resources/23-sql-best-practices-olap.md` §3.1A LEADING CANONICAL L690-714 + L917 has `format('$%,.2f', total_amount)` as a copy-attractive answer with full worked example.
- Keyword anchors on the canonical L692: *"Trino format function, printf Trino, build display string, format string Trino, String.format Trino, format number with commas, format vs concat, format thousands separator, format percent, zero-pad integer Trino, formatted display string Trino."*
- **MISSING from those anchors**: *currency*, *currency formatting*, *dollar amount*, *dollar amount with commas*, *format money*, *Oracle TO_CHAR(number, ...)*, *Oracle TO_CHAR amount*, *Oracle FM mask*, *Oracle numeric format mask*, *number format mask*, *number format string Trino*, *FM$999,999*.
- `resources/27-oracle-plsql-to-dbt-trino.md` §4.2A LEADING CANONICAL L543 covers **ONLY** `TO_CHAR(date, fmt)`. No row for `TO_CHAR(number, 'FM$999,999.00')` Oracle-numeric-mask → Trino.
- `resources/23-sql-best-practices-olap.md` L3354 Oracle dialect-fragment table has only `TO_CHAR(date, fmt)` row; no numeric TO_CHAR row pointing to `format('$%,.2f', n)`.

Engineer's question keywords ("Oracle TO_CHAR for numbers", "dollar amount with commas", "currency symbol") do NOT route to r23 §3.1A. Engineer's keyword path lands in r27 §4.2A which is date-only, then bounces.

**LIGHT FINDABILITY FIX-A RECOMMENDED:**

1. **Extend r23 §3.1A LEADING CANONICAL keyword anchors L692** to add:
   *"currency formatting, format currency, dollar amount with commas, format money, Oracle TO_CHAR(number, FM$999,999.00), Oracle FM mask, Oracle numeric format mask, thousands separator currency, number format mask Trino, number format string Trino, format vs format_number Trino"*
2. **Add a TO_CHAR(number,...) row in r27 §4.2A or §6.4 Oracle-function-translation table** mapping:
   - `TO_CHAR(amount, 'FM$999,999.00')` → `format('$%,.2f', amount)` (cross-ref r23 §3.1A canonical)
   - `TO_CHAR(amount, '999,999.00')` → `format('%,.2f', amount)`
   - `TO_CHAR(amount, 'FM$999,999')` → `format('$%,d', amount)` (integer thousands, no decimals)
3. **Defang the `format_number = Spark-only / example UDF` myth** — add a one-line note in r23 §3.1A or DO-NOT-WRITE table:
   > Trino 467 DOES have `format_number(BIGINT|DOUBLE) → VARCHAR` but it produces COMPACT-UNITS output like `'1.2M'`, `'500K'`, `'1.5B'` — NOT Oracle's comma-mask. For dollar-comma-2-decimal formatting use `format('$%,.2f', n)`.

NEW SOFT WATCH `iter1228 Q4 format('$%,.2f') findability for currency/TO_CHAR-number framing` — re-probe in 4-8 iters under "format currency / dollar amount with commas / Oracle TO_CHAR amount → Trino" framings after the FIX-A lands.

**Subtotal**: Acc 2.5 (core "no Oracle-style mask" partially right but absolute "no built-in number formatter" framing wrong; format_number characterization FALSE; missed in-resources canonical), Clar 4 (clear but installs wrong mental model), App 2.5 (engineer forfeits Trino-native one-liner, routed to app-layer without seeing alternative), Compl 2 (missed THE answer + format_number error + no defang of Trino's printf path). Average 2.75.

---

## Topic checklist updates (iter1228)

- **Q1**: Topic `Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup` — Q1 (CoW-MoR scenario-diagnosis WATCH CLOSE). Topic 4.4371/226 → (1002.7846 + 5.0)/227 = 1007.7846/227 = **4.4396/227 PASSED** (+0.0025, margin +0.9396).
- **Q2**: Topic `Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL` — Q2 (7-day RANGE-window canonical). Topic 4.5678/162 → (739.9836 + 5.0)/163 = 744.9836/163 = **4.5705/163 PASSED** (+0.0027, margin +1.0705).
- **Q3**: Topic `Oracle PL/SQL → dbt+Trino migration` — Q3 (dbt_utils version-rename WATCH DID NOT REACH). Topic 4.4588/193 → (860.5484 + 3.0)/194 = 863.5484/194 = **4.4513/194 PASSED** (-0.0075, margin still +0.9513).
- **Q4**: Topic `SQL query best practices for OLAP` — Q4 (format('$%,.2f') findability MISS). Topic 4.5897/282 → (1294.3554 + 2.75)/283 = 1297.1054/283 = **4.5837/283 PASSED** (-0.0060, margin +1.0837).

All topic averages remain above PASS threshold (3.5). No topic moves into thinnest-row band as a result.

---

## Recommended teacher actions (TWO FIX-As)

### FIX-A #1 (LIGHT, STRENGTHENING) — r27 §4.5A packages.yml troubleshooting card

**Goal**: Make the dbt_utils 1.0.0 version-rename surface as THE answer to "macro 'generate_surrogate_key' not found in any package."

**Edits to `resources/27-oracle-plsql-to-dbt-trino.md` §4.5A (around L1758-L1775):**

1. Insert a **top-line VERSION anchor** BEFORE the 3-step setup block (or before the troubleshooting table), as a bolded one-liner:
   > **`macro 'generate_surrogate_key' not found in any package` after `dbt deps` succeeded? 90% of the time it's a VERSION issue — your pin allows `dbt_utils < 1.0.0`, which has the macro under its OLD name `dbt_utils.surrogate_key` (it was renamed to `generate_surrogate_key` in dbt_utils 1.0.0, Nov 2022). Bump to `version: [">=1.1.0","<2.0.0"]` in packages.yml and re-run `dbt deps`.**

2. **Reorder the troubleshooting TABLE physically EARLIER** — directly after the keyword-anchor preamble L1758 and BEFORE the 3-step setup block. The responder's keyword-match landed at L1758; the troubleshooting table needs to be the next thing read, not the setup block (which is for "haven't set up packages.yml yet" — orthogonal to the "already set up + macro not resolving" case).

3. Extend the L1758 keyword anchors to add: *"macro not found in any package", "macro 'generate_surrogate_key' not found in any package", "dbt deps succeeded but macro invisible at runtime", "dbt run fails with macro not found", "generate_surrogate_key undefined after dbt deps".*

4. **Defang the `{%- do dbt_utils ... -%}` macro-import pattern** as a DO-NOT-WRITE row to prevent the iter1228 fabrication padding from recurring:
   > **WRONG** `{%- do dbt_utils.generate_surrogate_key([...]) -%}` at top of model "to register the macro" — this is fabricated; dbt has no such macro-registration pattern. The `{{ }}` invocation inside SELECT is the only correct form.

**Watch**: keep `iter1226 r27 packages.yml-troubleshooting card-findability` OPEN until first re-probe lands the version-rename row as THE answer.

### FIX-A #2 (LIGHT, FINDABILITY) — r23 §3.1A format() + r27 TO_CHAR(number,...) row

**Goal**: Route "currency / Oracle TO_CHAR number / dollar amount with commas" framings to the in-resources `format('$%,.2f', n)` canonical.

**Edits:**

1. **`resources/23-sql-best-practices-olap.md` §3.1A L692** — extend keyword anchors to add:
   *"currency formatting, format currency, dollar amount with commas, format money, Oracle TO_CHAR(number, FM$999,999.00), Oracle FM mask, Oracle numeric format mask, thousands separator currency, number format mask Trino, number format string Trino, format vs format_number Trino, Trino currency formatting one-liner."*

2. **`resources/27-oracle-plsql-to-dbt-trino.md`** — add a `TO_CHAR(number, mask)` row to the Oracle-function-translation table (§4.2A or §6.4), pointing to r23 §3.1A `format()` canonical:
   - `TO_CHAR(amount, 'FM$999,999,999.00')` → `format('$%,.2f', amount)` → `'$1,234,567.89'`
   - `TO_CHAR(amount, '999,999.00')` → `format('%,.2f', amount)` → `'1,234.56'`
   - `TO_CHAR(amount, 'FM$999,999')` → `format('$%,d', amount)` → `'$1,234,567'`

3. **`resources/23-sql-best-practices-olap.md`** — add one-line defang note that `format_number` exists in Trino 467 but produces compact-units output (`'1.2M'` / `'500K'`), not comma-mask. Place near the `format()` LEADING CANONICAL or in its DO-NOT-WRITE table:
   > Trino 467 HAS `format_number(BIGINT|DOUBLE) → VARCHAR` (compact-units output like `'1.2M'`, `'500K'`, `'1.5B'`), NOT Oracle's `'#,##0.00'` comma-mask form. For dollar-comma-2-decimal use `format('$%,.2f', n)`.

**Watch**: NEW soft watch `iter1228 Q4 format('$%,.2f') findability for currency/TO_CHAR-number framing` — re-probe in 4-8 iters with fresh phrasing ("how do I show $1,234.56 in Trino", "Oracle currency mask migration", "render total_revenue as a dollar string").

---

## Carry-forward watches

- **iter1224 CoW-MoR scenario-diagnosis WATCH — CLOSED** this iter (Q1 5.0; 15th consecutive 1st-re-probe-CLOSE pattern). Remove from open list.
- **iter1226 r27 packages.yml-troubleshooting WATCH — OPEN**, DID NOT REACH this iter. Apply FIX-A #1 above (LIGHT strengthening); re-probe 4-8 iters under fresh framing ("dbt run fails with macro not found in any package after dbt deps succeeded"). CLOSE on first re-probe that names the version-rename as THE cause.
- **iter1226 table_changes()-MoR card WATCH — OPEN**; NOT re-probed this iter. Continue 3-7 more iters under "Iceberg native changelog / CDC / change feed in Trino 467 / orders table written by Spark MERGE INTO" framings.
- **iter1215 strpos-3-arg synthesis ceiling — accepted CEILING**, NO churn per `feedback_synthesis_ceiling_stop_churning.md`. Light monitor only.
- **iter1213 session_properties + (+)-mnemonic WATCH — OPEN**. Re-probe under "set session property to control join distribution / sort behavior" framings.
- **iter1227 SUBSTRING-FROM-cant-do-negative fabrication soft watch — OPEN**; broken-secondary recall-ceiling. Re-probe 3-7 iters under "negative-start substring / Oracle SUBSTR(-N) → Trino" framing.
- **NEW iter1228 Q3 `{%- do dbt_utils -%}` macro-import fabrication soft watch** — recall-ceiling padding aside; re-probe 4-8 iters under "dbt macro not found / dbt_utils macro can't resolve" framing. If recurs, the FIX-A #1 DO-NOT-WRITE row defangs.
- **NEW iter1228 Q4 format('$%,.2f') findability for currency/TO_CHAR-number framing soft watch** — re-probe 4-8 iters after FIX-A #2 lands; close on first re-probe that names `format('$%,.2f', n)` for "Oracle TO_CHAR amount → Trino" / "dollar amount with commas" framings.

---

## Closing — next iter planning

**iter1228 PASS but two findability FIX-As warranted.** Iter average 3.94 (margin +0.44 over threshold). Q1 WATCH cleanly CLOSES on first re-probe; Q3 WATCH DID NOT REACH despite the FIX-A card existing (structural reordering needed to make version-rename surface as THE answer); Q4 is a NEW findability gap on currency/TO_CHAR-number framing for the in-resources `format('$%,.2f', n)` canonical. Both FIX-As are LIGHT (anchor reorderings + cross-ref rows; no canonical rewrites). NO NEW WATCHES on technically correct content — both gaps are findability/keyword-anchor only.

Training runs to 2026-06-30 23:59 CST (~1.4 days left). After applying FIX-As, continue BREADTH probing — touch any thinnest-band rows (Query performance basics 4.2091 / Iceberg partition design 4.4380 / Iceberg maintenance 4.4396) and verify Q3 + Q4 watches close cleanly on re-probe.

# Iter1201 Judge Feedback

**Overall: 4.156 / 5.0 — PASS.** Q1 (5.0) THIN-ROW LIFT lands cleanly on the thinnest topic (dbt snapshots SCD2). Q2 (4.875) PERCENTILE_CONT → approx_percentile canonical pin-perfect. Q3 (3.75) root-cause **correct** (`on_schema_change='append_new_columns'` is exactly r13 §5527–5540 canonical) but **TWO mechanism slips on `--full-refresh` semantics** — both are RESPONDER inference (NOT resource-sourced). Q4 (3.0) Option A (CAST) correct but **Option B "concat() handles mixed types" is WRONG** (concat is varchar-only, same rule as `||`) AND the **`format()` printf-style canonical was missed entirely** — the canonical lives in r23 §3.1A LEADING CANONICAL + r27 §7A.3.1. Pure FINDABILITY gap; no resource defect.

**Per-question scores:**

| Q | Topic | Acc | Clar | App | Compl | Avg |
|---|---|---|---|---|---|---|
| Q1 | dbt snapshots SCD2 — point-in-time as-of join | 5 | 5 | 5 | 5 | **5.00** |
| Q2 | SQL best practices — PERCENTILE_CONT in Trino | 5 | 4.5 | 5 | 5 | **4.875** |
| Q3 | Postgres→Iceberg ingestion — on_schema_change + --full-refresh | 3 | 4 | 4 | 4 | **3.75** |
| Q4 | Oracle PL/SQL → Trino — `\|\|` mixed-type concat | 2.5 | 4 | 3 | 2.5 | **3.0** |

Iteration mean **4.156** — passing.

---

## Q1 — dbt snapshot SCD2 as-of join (point-in-time)

**Score: 5 / 5 / 5 / 5 = 5.00 — THIN-ROW LIFT on the #1 thinnest passing topic.**

### What the responder said
```sql
SELECT ...
FROM events e
INNER JOIN accounts_snapshot s
  ON e.account_id = s.account_id
 AND e.event_timestamp >= s.dbt_valid_from
 AND (s.dbt_valid_to IS NULL OR e.event_timestamp < s.dbt_valid_to);
```
Explained that `WHERE dbt_valid_to IS NULL` gives **only the currently active row** (the trap the engineer described), while the half-open range predicate `[dbt_valid_from, dbt_valid_to)` joins each event to **the row active at its timestamp**.

### Verification
- [docs.getdbt.com/docs/build/snapshots](https://docs.getdbt.com/docs/build/snapshots) — `dbt_valid_to IS NULL` denotes the currently-active row (no `dbt_is_current` column).
- Canonical SCD-2 half-open interval pattern; matches r09 §348 + iter1158/iter1187 prior canonicals.
- `INNER JOIN` correctly drops events whose timestamp predates the earliest snapshot row (defensible; documented as the standard rule). LEFT JOIN with NULL-handling is a valid variant for "give me the event row even if no snapshot exists yet" but not what the question asked.

### Verdict
Pin-perfect SCD-2 point-in-time join — same shape as the iter1158 / iter1187 / iter1200 canonicals, applied here to **events joined to a dbt snapshot** specifically. The thin-row lift is clean.

---

## Q2 — Trino 467 PERCENTILE_CONT availability + grouped P50/P90 by priority

**Score: 5 / 4.5 / 5 / 5 = 4.875**

### What the responder said
- `PERCENTILE_CONT` does **NOT** exist in Trino 467.
- Use `approx_percentile(time_to_close_minutes, 0.5)` and `approx_percentile(time_to_close_minutes, 0.9)` GROUP BY priority.
- **Array form** for multi-percentile single pass: `approx_percentile(col, ARRAY[0.5, 0.9, 0.95, 0.99])` → returns array of percentiles in one aggregation.
- Implementation: **T-Digest** (not HyperLogLog — HLL is for `approx_distinct`).
- **No published standard error figure** for approx_percentile (matches my pinned `reference_trino_approx_percentile_error.md` — the 2.3% figure is documented for `approx_distinct` only).
- Only the approximate form is exposed; no `MEDIAN()` and no `PERCENTILE_DISC`.

### Verification
- [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) — `approx_percentile` overloads: single percentile + array percentiles + weighted variants. T-Digest implementation confirmed via Trino source. No `percentile_cont` / `percentile_disc` / `median` in 467.
- Array form returns `array(double)` for fraction-array input — exactly what the responder described.
- The "no published standard error" caveat matches my pinned reference (only `approx_distinct` has the 2.3% figure documented).

### Minor shaves
- (-0.5 Clar) The phrase "T-Digest is a probabilistic sketch — sub-percent error in practice for typical distributions" is hedged but a beginner reader may want one concrete example of the typical-error magnitude. Not load-bearing.

### Verdict
Pin-perfect Trino 467 percentile canonical with the load-bearing dialect distinction (Postgres `PERCENTILE_CONT` absent → `approx_percentile` is the equivalent). Single-pass array form is the right operational guidance for "P50 + P90 in one query."

---

## Q3 — Incremental Iceberg model + added column + `--full-refresh` on dbt-trino

**Score: 3 / 4 / 4 / 4 = 3.75 — CORE GUIDANCE CORRECT, TWO MECHANISM SLIPS.**

### What the responder said
- **Root cause** (correct, resource-sourced at r13 §5527–5540): `on_schema_change` defaults to `'ignore'`, which silently drops the new `region` column from the compiled INSERT/MERGE — that's why post-change events still show `region` populated but historical 6 months are NULL.
- **Fix**: set `on_schema_change='append_new_columns'` + run `dbt run --select fct_events --full-refresh`.
- **CLAIM A** (mechanism): "`--full-refresh` sets `is_incremental()` false, reruns entire SELECT, table is rewritten from scratch — for `materialized='incremental'` this is a **MERGE INTO that touches every row**."
- **CLAIM B** (downstream safety): "Downstream models remain queryable — they see the old table until the new one is fully written, then Trino switches the metadata pointer (**Iceberg atomic swap**); queries do **NOT** fail mid-run." Also: "if `--full-refresh` killed mid-run, Iceberg snapshot isolation → readers see old or fully-committed new."

### Verification

**Root cause + fix — CORRECT.** Verified at [docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models) + r13 §5527 (`on_schema_change` default IS `'ignore'`, NOT `'fail'`) + r13 §5614 canonical config. Engineer takes the right action.

**CLAIM A — MECHANISM WRONG.** [docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models) verbatim (WebFetch this iter):
> "To force dbt to rebuild the entire incremental model from scratch, use the `--full-refresh` flag on the command line. **This flag will cause dbt to drop the existing target table in the database before rebuilding it for all-time.**"

And [docs.getdbt.com/reference/resource-configs/full_refresh](https://docs.getdbt.com/reference/resource-configs/full_refresh) verbatim:
> "The `--full-refresh` flag will force dbt to `drop cascade` the existing table before rebuilding it."

→ `--full-refresh` on an incremental model is a **DROP + CREATE-TABLE-AS-SELECT** rebuild, NOT a `MERGE INTO`. The responder's "MERGE INTO that touches every row" is the WRONG mechanism. On dbt-trino specifically the actual statement emitted depends on the model's `on_table_exists` config (default `'rename'` → temp-build + ALTER RENAME swap; `'replace'` → `CREATE OR REPLACE TABLE`; `'drop'` → drop + create) — see r28 §964 LEADING CANONICAL. **None of these are MERGE.** Mechanically, `--full-refresh` causes `is_incremental()` to evaluate FALSE, so the incremental-only `WHERE` predicate is **skipped**, and dbt builds the full table from scratch.

**CLAIM B — TOO ABSOLUTE.** The "atomic Iceberg metadata commit" claim is **contingent on `on_table_exists`**:
- `on_table_exists='replace'` → `CREATE OR REPLACE TABLE` → ONE atomic Iceberg metadata commit, readers never see missing/empty. (r28 §964 verbatim.)
- `on_table_exists='rename'` (the dbt-trino DEFAULT) → temp-build then `ALTER TABLE ... RENAME` swap — effectively atomic.
- `on_table_exists='drop'` → `DROP TABLE` then `CREATE TABLE` — **REAL WINDOW** where the table does not exist; downstream queries fail with "table does not exist."

The responder didn't qualify with `on_table_exists`. Engineer on default `'rename'` won't see breakage, but engineer on `'drop'` will. Mid-run failures DO happen on `'drop'`. The "Iceberg atomic swap" framing also conflates Iceberg's snapshot isolation (which is real for concurrent **writes** to the SAME table) with the cross-statement DROP+CREATE window (a different mechanism).

### Slip categorization
Both Claim A (MERGE INTO mechanism) and Claim B (atomic-swap absoluteness) are **responder inference, NOT resource-sourced**. r13 §5527 + §5614 covers `on_schema_change` accurately. r28 §964 LEADING CANONICAL covers `on_table_exists` with the four-row table accurately. The responder reached `on_schema_change` cleanly but didn't compose the `--full-refresh`-mechanism story from the right cards.

Per `feedback_responder_broken_secondary_alternative.md` family — the lead (root cause + `append_new_columns` fix) is correct; the responder appended mechanism narration that wasn't asked-for and got it wrong.

### Per-instance vs resource defect
- The MERGE-INTO-on-full-refresh claim is a Trino+dbt-trino mechanism error.
- Resource state: r28 §964 already covers `on_table_exists`. r13 §5527 covers `on_schema_change`. No resource teaches the WRONG mechanism — this is purely a responder synthesis slip.

**NO FIX-A.** Per-instance slip. Re-probe in 3–6 iters with framing "what does `--full-refresh` actually do to an Iceberg incremental model on dbt-trino" to test whether the slip recurs (then it would be a candidate for a card consolidating r13 + r28).

### Verdict
Engineer leaves with the correct action (`on_schema_change='append_new_columns'` + `--full-refresh`) and a wrong mental model of what `--full-refresh` does. Actionable but mechanism-inaccurate.

---

## Q4 — Oracle `||` mixed-type concat → Trino type error: must we CAST everything, or is there a function?

**Score: 2.5 / 4 / 3 / 2.5 = 3.0**

### What the responder said
- Trino `||` is varchar-only; integers are a type error (correct).
- **Option A — CAST each integer AS VARCHAR** (recommended): correct, matches r27 §7A.3.1 RIGHT option A.
- **Option B — "Use concat() function instead: `concat('Account #', account_id, ' — active for ', days_since_login, ' days')` — concat() (if your Trino version has it) MAY handle implicit type coercion more gracefully."**
- Said Option A is safest/most readable.
- **DID NOT mention `format()` at all.**

### Verification — Option B is WRONG

[trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html) verbatim (WebFetch this iter):
> `concat(string1, ..., stringN) → varchar`

[trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html) verbatim:
> "Trino will not convert between character and numeric types. For example, a query that expects a varchar will not automatically convert a bigint value to an equivalent varchar."

→ `concat()` is **also varchar-only** — same type-error behavior as `||`. The responder's "concat() MAY handle implicit type coercion more gracefully" is FALSE and directly contradicts r27 §7A.3.1 L4513 verbatim:
> "In Trino, **`CONCAT(...)` and `||` require ALL arguments to be character types (VARCHAR / CHAR)**. Cast every non-VARCHAR argument explicitly with `CAST(... AS VARCHAR)`, or use `format('...%d...%s...', a, b)` instead."

r23 §3.1A L690 LEADING CANONICAL (keyword anchors include "format vs concat") shows the exact answer the responder should have given:
```sql
format('Account #%d — active for %d days', account_id, days_since_login)
```
- `%d` accepts BIGINT/INTEGER directly.
- `%s` accepts already-VARCHAR or any value (formats whatever's there).
- Returns VARCHAR; no CAST per integer.

This is the **load-bearing canonical** for "don't CAST everything" string-building. The responder missed it entirely.

### Slip categorization
- **Option B (concat-coerces) is a WRONG SECONDARY ALTERNATIVE** — broken-secondary-alternative family (`feedback_responder_broken_secondary_alternative.md`), 11th-or-so instance. Lead (CAST) is correct; the appended "for completeness" alternative is broken.
- **Missing `format()` is a FINDABILITY gap** — not a resource defect (the canonical EXISTS in r23 §3.1A AND r27 §7A.3.1, AND r27 L995 Oracle-`||` translation table row already cross-refs `format('FQ-%d', year_int)` with "See §7A.3.1 for the canonical fix"). The keyword path "Oracle `||` / type error varchar vs integer / concat function handling mixed types" did NOT reach those canonicals — instead the responder routed to a general "concat is varchar-only" hand-wave and made up Option B.

### Light findability FIX-A — RECOMMENDED (small, additive)

The resource CONTENT is correct (r23 §3.1A LEADING CANONICAL + r27 §7A.3.1 RIGHT-option-B both teach `format()` for mixed-type building). The gap is keyword routing on the **Oracle migration entry path**.

**Concrete recommendation** (light, additive cross-ref — NOT a content rewrite):
1. In **r27 §7A.3 / §7A.3.1**: add a one-line keyword anchor at the section opening like `> **Keyword anchors:** Oracle || varchar vs integer error, Trino concat function mixed types, build string without casting every integer, format vs concat, printf-style alternative to CAST AS VARCHAR.` This makes the keyword path "concat function handling mixed types" find §7A.3.1 directly.
2. Confirm the cross-ref at **r23 §3.1A** keyword anchors already includes "format vs concat" / "Oracle || implicit coerce" (it already does at L692 + L951 → r27 cross-ref). NO change needed on r23 side.

**Rationale**:
- Pure findability (no content change) — low risk of `feedback_new_card_over_attracts_adjacent` over-attraction.
- The two canonicals already exist and are correct; only the keyword path needs widening.
- Q4 is a recurring pattern (Oracle engineers migrating || string-building) — worth strengthening.

**WATCH label**: `iter1201 r27 §7A.3.1 Oracle-|| concat-mixed-types findability` — re-probe in 3–6 iters with framing similar to "Oracle `||` works on integers, Trino throws type error, is there a concat function that handles mixed types" to confirm the responder now lands at `format()` instead of inventing Option B.

### Verdict
Engineer leaves with a working Option A (CAST per integer) but misled by a wrong Option B (concat-coerces is false) and never sees the printf-style `format()` answer they actually asked for ("is there a Trino concat function handling mixed types?" — yes, `format()` is the printf-style answer). LIGHT findability FIX-A recommended on r27 §7A.3.1.

---

## Carry-forward watches

- **CLOSED THIS ITER**: none (no priority watches active for re-probe this iter).
- **Soft (continuing)**: `iter1197 generate_schema_name macro surface-area` — re-probe in 4–8 iters with explicit "use dbt macros to control schema" framing. Not exercised this iter.
- **Light-monitor (continuing)**: `iter1199 r17 position-delete adjacent` — Spark `rewrite_position_delete_files` tradeoff framing. Not exercised this iter.
- **Light-monitor (continuing)**: `iter1200 timestamp-subtraction broken-secondary` — re-probe under similar Oracle SYSDATE-age framing in 2–5 iters. Not exercised this iter.
- **NEW watch this iter**: `iter1201 r27 §7A.3.1 Oracle-|| concat-mixed-types findability` (Q4) — see Q4 above. LIGHT FIX-A recommended (additive keyword-anchor only).
- **NEW light-monitor this iter**: `iter1201 dbt --full-refresh mechanism on incremental` (Q3) — responder said "MERGE INTO that touches every row" + "atomic swap" without `on_table_exists` qualifier. Re-probe in 3–6 iters with explicit `--full-refresh` framing to see if the slip recurs.

---

## Topic score updates

- **dbt snapshots SCD2**: 4.2644/22 → **4.2964/23** (Q1 = 5.0; +0.0320; thinnest required topic, margin +0.7964)
- **SQL query best practices for OLAP**: 4.5827/269 → **4.5838/270** (Q2 = 4.875; +0.0011; margin +1.0838)
- **Postgres-to-Iceberg ingestion**: 4.4979/173 → **4.4936/174** (Q3 = 3.75; -0.0043; margin +0.9936)
- **Oracle PL/SQL → dbt + Trino SQL migration**: 4.4708/162 → **4.4618/163** (Q4 = 3.0; -0.0090; margin +0.9618)

All required topics remain PASSED with healthy margins. Thinnest remaining = **dbt snapshots SCD2 (4.2964)** — climbed +0.032 this iter but stays #1 thinnest.

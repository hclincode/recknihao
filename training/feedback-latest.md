# Iter666 Judge Feedback

**Iteration**: 666
**Phase**: extended
**Mode**: DURABILITY-BREADTH re-probe of iter666 r12 Spark-CALL→Trino-EXECUTE fix + 3 adjacent control questions

## Per-question scoring (Accuracy / Completeness / Clarity / Actionability, 1-5)

### Q1 — Cumulative running total
- Accuracy: **3.5** — Core SQL is valid Trino 467 and runs. BUT the explanatory note that "same-day rows show the same running value as a peer group" under a `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` frame is **technically wrong**. Peer-group semantics belong to RANGE, not ROWS. With a ROWS frame, every physical row gets its own incrementing cumulative value regardless of date ties. A SaaS engineer relying on this note will be confused when their output shows distinct running values per same-date row. (Verified against trino.io/docs/467: default frame is `RANGE UNBOUNDED PRECEDING` which includes "the last peer of the current row" — i.e., RANGE peers; ROWS does not.)
- Completeness: **4** — Answers core question; mentions frame choice but mis-explains tie semantics.
- Clarity: **4.5** — Clear shape, easy to read.
- Actionability: **4** — Paste-and-run works; the misleading note risks downstream confusion when verifying with same-date rows.
- **Q1 average: 4.0**

### Q2 — Percent of column total (empty-window grand total)
- Accuracy: **2** — **PARSE ERROR**. As written: `ROUND(100.0 * SUM(amount) / SUM(amount) OVER () AS pct_of_grand_total` — ROUND's opening paren is never closed before `AS`. Trino will reject this with a syntax error. The TECHNIQUE (empty `OVER ()` for grand total, `100.0` decimal cast) is correct and explained well, but the literal SQL does not compile.
- Completeness: **4** — Hits the empty-window concept, integer-division guard, no separate subquery — all the right ideas.
- Clarity: **4** — Good explanation prose.
- Actionability: **1.5** — A SaaS engineer pasting this gets an immediate parse error. They have to debug parens before they can even run it. Defeats the purpose of "copy this."
- **Q2 average: 2.875**

### Q3 — Per-tenant DAU last 30 days
- Accuracy: **3.5** — Shape and intent correct: `WHERE tenant_id = 42`, `COUNT(DISTINCT user_id)`, 30-day filter via `CURRENT_DATE - INTERVAL '30' DAY`. BUT the question gave the column as `event_time` (a timestamp), not `event_date`. The responder silently assumed an `event_date` column exists. A correct answer needs `date_trunc('day', event_time) AS event_date` or `CAST(event_time AS DATE)` in both SELECT and GROUP BY, and the predicate becomes `event_time >= CURRENT_TIMESTAMP - INTERVAL '30' DAY` (or similar). As written, this does not match the given schema.
- Completeness: **4** — Tenant scoping, distinct user count, day rollup, 30-day window all present; includes isolation warning.
- Clarity: **4.5** — Easy to read, intent clear.
- Actionability: **3.5** — Engineer will hit "column event_date does not exist" and have to adapt. Salvageable but not paste-and-run.
- **Q3 average: 3.875**

### Q4 — Iceberg maintenance: compact + expire snapshots
- Accuracy: **3.5** — The Trino-EXECUTE form is **correct** and aligns with trino.io/docs/467 (iter666 r12 Spark-CALL→Trino-EXECUTE fix landed correctly). All three procedures (`optimize`, `expire_snapshots`, `remove_orphan_files`) use the right `ALTER TABLE ... EXECUTE proc(param => value)` shape. The "not Spark CALL procedures" clarification is correct and useful. **BUT** the `file_size_threshold => '134217728'` value is **a raw byte string with no unit suffix**, and Trino's DataSize parser requires units (B/kB/MB/GB). Per docs and verified examples, valid values are `'128MB'`, `'100MB'`, etc. Bare numeric strings like `'134217728'` fail to parse. The correct form is `'128MB'` (which is what 134217728 bytes equals). Also `retention_threshold => '7d'` for both expire/remove is correct and matches the default `iceberg.expire_snapshots.min-retention=7d` floor.
- Completeness: **4.5** — Three procedures covered, retention floor noted, dialect disambiguation explicit.
- Clarity: **4.5** — Structured into steps, calls out the Spark-vs-Trino trap.
- Actionability: **3** — Step 2 and Step 3 paste-and-run. Step 1 fails to parse as written; engineer must change `'134217728'` to `'128MB'` (or any unit-suffixed value). The iter666 fix landed the EXECUTE form correctly but introduced a DataSize unit defect.
- **Q4 average: 3.875**

---

## OVERALL AVERAGE

(4.0 + 2.875 + 3.875 + 3.875) / 4 = **3.656**

**Verdict: PASS** (overall >= 3.5 threshold)

---

## Flagged weak answers (prose only — does NOT change PASS label per directive)

1. **Q2 missing close paren** — confirmed genuine syntax error. Pasted as-is, Trino returns a parse error. The technique is right; the literal SQL is broken. This is the most serious defect of the four.
2. **Q1 same-day-peer claim under ROWS frame** — technically wrong (peer semantics are RANGE-only, not ROWS). Misleading explanatory note attached to otherwise-correct SQL.
3. **Q3 event_date vs event_time** — schema mismatch with the question; engineer must adapt the column to `date_trunc('day', event_time)`. Minor but material since the question explicitly gave `event_time`.
4. **Q4 `'134217728'` byte literal** — Trino DataSize requires a unit suffix; bare numeric string fails to parse. Replace with `'128MB'`.

---

## Q4 Iceberg-maintenance verdict (iter666 re-probe of r12 Spark-CALL→Trino-EXECUTE fix)

**LANDED PARTIALLY CORRECT.** The Trino-native `ALTER TABLE ... EXECUTE` form is now used (Spark CALL form no longer appears as the primary maintenance directive), the "not Spark CALL procedures" disambiguation is delivered, and `retention_threshold => '7d'` matches the default min-retention floor. The fix did its job on the engine-dialect axis. However, the **value format for `file_size_threshold` regressed** — `'134217728'` (raw bytes, no unit) is not a valid Trino DataSize literal; the canonical examples in r17/r11 use `'128MB'` / `'256MB'`. Responder appears to have computed 128*1024*1024 and emitted the integer instead of the string `'128MB'`.

---

## Teacher feedback (concise, actionable)

### Priority for iter667

**FIX-A (recommended)**: Add a tightly-scoped worked example showing the CORRECT `file_size_threshold` literal format. The defect is not in r12 / r17 (which use `'128MB'` / `'256MB'` correctly) — it appears to be a value-format transcription gap where the responder synthesized a raw byte value. Add an explicit inoculation card / one-liner near the optimize template:

> `file_size_threshold` must be a DataSize string with a unit suffix: `'128MB'`, `'256MB'`, `'1GB'`. Bare numeric strings like `'134217728'` are NOT valid and will fail with a DataSize parse error. If you have a byte target, convert it: 134217728 bytes = `'128MB'`.

Place this anchor BOTH in r17 (canonical Iceberg maintenance page) and near the r11 / r12 optimize examples so keyword lookup of "file_size_threshold" always lands on the unit-suffix rule.

**FIX-B (recommended, lighter touch)**: Add a one-line "verify your SQL parses" note to the percent-of-grand-total card in r07:1170-1192. Specifically: a "copy-paste correctness" inoculation that flags the common transcription trap of unbalanced ROUND parens. Suggested wording:

> When wrapping `100.0 * x / SUM(x) OVER ()` in `ROUND(...)`, the close-paren goes BEFORE `AS`, not after. Pattern: `ROUND(100.0 * x / SUM(x) OVER (), 2) AS pct`. Count the parens — `ROUND(` opens 1, must close 1.

The Q2 defect is more transcription-slip than resource gap, but a balanced-parens worked example with explicit paren-count callout reduces recurrence.

**FIX-C (lower priority)**: Reconcile the ROWS-vs-RANGE peer-group semantics in r07:1630-1716. Verify the language explicitly states: "ROWS counts physical rows; tied ORDER BY values still get distinct running totals. RANGE peers; tied ORDER BY values share the same value." The responder produced a hybrid claim ("ROWS frame, peer group, same running value") that does not exist in either semantic. If r07 already says this clearly, no edit — this is a responder synthesis error, not a resource gap.

**FIX-D (lowest priority)**: For per-tenant DAU questions where `event_time` (timestamp) is the given column, add a recipe-card pattern explicitly using `date_trunc('day', event_time) AS event_date` to bridge timestamp→date. The r23:131 canonical uses `event_date` directly, which trains the responder to assume that column shape; a complement using `event_time` would close the schema-adaptation gap.

### Single-pick recommendation
If only one of the above is acted on: **FIX-A is the highest-value pick** — it is a verified docs-grounded defect (DataSize unit requirement) on the high-traffic Iceberg-maintenance axis, and the fix is a 2-line inoculation card. FIX-B is a useful defensive add but the Q2 defect alone is small-volume / arguably a transcription slip. FIX-C and FIX-D are quality polish; defer unless the same defects recur.

### NO-OP alternative
A defensible NO-OP if FIX-A would risk churn: Q2 + Q4 defects are each transcription-level (paren miscount, byte-value computed instead of unit-suffix-string copied) rather than fundamental gaps in r07/r17. If the next 1-2 iterations show recurrence, escalate to FIX-A immediately.

---

## Topic-rubric updates (no changes this iter)

- **Iceberg table maintenance** (current 4.4575 PASSED): Q4 3.875 reinforces PASSED status; iter666 r12 fix verified on engine-dialect axis. DataSize unit-suffix defect is a value-format polish item, not a topic regression.
- **Analytical query patterns on Iceberg+Trino** (current 4.3567 PASSED): Q1 4.0 + Q2 2.875 + Q3 3.875 mixed. Q2 parse error and Q1 ROWS-frame mis-explanation are noted but topic remains PASSED. No re-probe required unless recurrent.
- **Multi-tenant analytics** (current 4.4593 PASSED): Q3 3.875 — schema-adaptation gap is minor; topic remains PASSED.

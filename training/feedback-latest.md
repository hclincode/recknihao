# Judge Feedback — iter722 (EXTENDED PHASE)

**Verification method**: Every dialect claim checked against trino.io/docs/467 (connector/iceberg.html, functions/datetime.html, functions/string.html) — NOT against resources/.

---

## Per-question scores

| Q | Topic | Acc | Comp | Clar | Act | Q-avg |
|---|---|---|---|---|---|---|
| Q1 | Iceberg rollback (CALL rollback_to_snapshot, Trino-not-Spark) | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | YYYY-MM label (substr / format_datetime) | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | concat_ws separator + NULL-skip vs ||/concat propagate | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | BETWEEN inclusive range filter | 5 | 4 | 5 | 5 | 4.75 |

**Sub-score sum**: (20 + 20 + 20 + 19) / 16 = 79/16 = **4.9375**
**Per-Q avg**: (5.00 + 5.00 + 5.00 + 4.75) / 4 = **4.9375**
**Dim-avg**: Acc (5+5+5+5)/4=5.00 · Comp (5+5+5+4)/4=4.75 · Clar 5.00 · Act 5.00 → (5.00+4.75+5.00+5.00)/4 = **4.9375**
All three methods agree.

## GOVERNING LABEL: **4.9375 — STRONG PASS** (margin +1.4375 above 3.5 floor)

---

## Q1 ROLLBACK-ATTRIBUTION VERDICT: **RESOLVED**

The iter721 non-scoring nudge (responder had labeled `CALL iceberg.system.rollback_to_snapshot` as "(Spark)") is **RESOLVED**. This iteration the responder:
- Emitted `CALL iceberg.system.rollback_to_snapshot('analytics', 'events', 4823511203987654321)` with THREE positional args (schema varchar, table varchar, snapshot_id bigint).
- Attributed it explicitly to **native Trino 467** ("Critical for Trino 467: positional only, NOT named args"), NOT Spark-only.
- Correctly warned against the Spark form (named arguments OR a single combined `'schema.table'` string).

DOCS-VERIFIED [trino.io/docs/467/connector/iceberg.html]: verbatim `CALL example.system.rollback_to_snapshot('testdb', 'customer_orders', 8954597067493422955)` — 3 positional args; this is a system procedure invoked via CALL only; there is **no** `ALTER TABLE ... EXECUTE rollback_to_snapshot` form in 467 (EXECUTE supports only optimize, expire_snapshots, remove_orphan_files, drop_extended_stats — confirming the EXECUTE rollback form is 469+). The responder's anti-Spark warning is docs-accurate (Spark uses combined `'db.table'` single string + named args; Trino 467 uses two separate string args).

Note on citation: responder cited `resources/13-postgres-to-iceberg-ingestion.md` as the source. The canonical rollback content actually lives in r17-iceberg-table-maintenance.md; r13 citation is imperfect but the ANSWER's content is fully docs-correct, so no score penalty per directive. Citation-accuracy is a cosmetic non-scoring observation, not a gap.

---

## Q2 — Both forms valid

DOCS-VERIFIED [trino.io/docs/467/functions/datetime.html]: `format_datetime` uses JodaTime DateTimeFormat patterns (`yyyy-MM` correct — lowercase-y year, uppercase-M month) and takes a timestamp; responder correctly casts DATE→TIMESTAMP first. `substr(CAST(order_date AS varchar), 1, 7)` is valid — a DATE cast to varchar yields ISO `YYYY-MM-DD`, first 7 chars = `YYYY-MM`. Responder was not required to mention `date_format(ts, '%Y-%m')` (MySQL-style, also valid) — not penalized for the choice. Zero defects.

## Q3 — Accurate

DOCS-VERIFIED [trino.io/docs/467/functions/string.html]: `concat_ws(separator, ...)` exists and "Any null values provided in the arguments after the separator are skipped" — responder's NULL-skip claim is exact (and the separator-NULL → whole-result-NULL caveat is consistent, though not asked). `concat`/`||` are SQL-standard concatenation and propagate NULL (one NULL → whole result NULL) — responder's claim accurate.

## Q4 — Accurate, tiny completeness ding

BETWEEN is valid Trino 467 and inclusive on both ends; equivalent to `>= AND <=`. Responder's answer is correct and readable. Comp scored 4 (not 5) only because it omitted the one nuance worth a half-line in production: BETWEEN with a NULL bound/NULL column value yields unknown (row excluded), and BETWEEN cannot express an exclusive upper bound some discount-bucketing needs. Minor; does not affect the governing STRONG PASS.

---

## Teacher feedback / iter723 flags

- **No FIX-A required.** All four answers are dialect-clean and docs-accurate. The iter722 PIN edit in r17 (CALL = native Trino 467, not Spark) landed effectively — the rollback-attribution regression is closed on a fresh "we're on Trino not Spark" re-probe.
- **HOLD all locks** (~270 across iter534-721) including the r22 federation hard lock (still untouched; 4.49944 vs 4.5 thin — do NOT probe).
- **Minor citation-routing nudge (non-scoring, OPTIONAL):** responder cited r13 for rollback though the canonical lives in r17. Consider a lightweight keyword cross-ref/anchor in r13 pointing to r17's rollback card, OR confirm r17's keyword anchors are dominant enough that future rollback probes cite r17. Low priority — the answer content was correct regardless. Do NOT rewrite the working r17 rollback canonical.
- **iter723**: re-probe rollback ONCE more from a different framing (e.g. "undo last commit" / "restore to yesterday's version") to confirm the attribution fix is durable across phrasings before retiring the nudge. No new gaps to address.

Do NOT bump state.json (orchestrator handles).

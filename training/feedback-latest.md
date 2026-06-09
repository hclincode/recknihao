# Judge Feedback — iter777

**Mode**: DEFAULT NO-OP / durability-breadth sweep (teacher made ZERO resource edits). Final-phase / extended — single end-of-iteration feedback covering all 4 questions.

**Verification**: Every dialect claim verified against trino.io/docs/467 (datetime.html, string.html, conversion.html) on 2026-06-09. Resources NOT treated as ground truth.

---

## Per-question scores

### Q1 — EPOCH-SECONDS → TIMESTAMP, group by day
Answer: `date_trunc('day', from_unixtime(created_at)) AS day` + GROUP BY same expr. States `from_unixtime()` takes SECONDS not millis; millis variant `from_unixtime(created_at / 1e3)` with float divide (NOT /1000 integer, to preserve sub-second precision). Cites r13.

Verified (datetime.html): `from_unixtime(unixtime)` interprets the argument as SECONDS since 1970-01-01 UTC, returns `timestamp(3) with time zone`. So `from_unixtime(1748736000)` is correct for epoch-seconds. `date_trunc('day', ts)` zeroes time components → groups by calendar day. The millis caveat (divide by 1e3 as a float to keep sub-second precision) is correct and matches the standing epoch-seconds-not-millis pin. The seconds-vs-millis worry is addressed head-on.

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 5 | 5 | 5 | 5 | **5.00** |

### Q2 — first 4 chars of product_sku (user expected Postgres LEFT())
Answer: Trino has NO `LEFT()`. `substr(product_sku, 1, 4)` → 'ELEC'. Alternative `split_part(product_sku, '-', 1)` for delimiter-based prefix. Cites r23.

Verified (string.html): Trino has no `left()`/`right()` (those are MySQL/Postgres — standing no-LEFT pin holds). `substr(string, start, length)` is 1-indexed → `substr(sku, 1, 4)` = first 4 chars = 'ELEC'. `split_part(sku, '-', 1)` = 'ELEC' (field before first dash). Both correct; the split_part alternative is a genuinely better fit for a `ELEC-12345-BLK` SKU shape where the prefix is delimiter-bounded.

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 5 | 5 | 5 | 5 | **5.00** |

### Q3 — customers with MORE THAN 5 orders (WHERE COUNT(*)>5 errored)
Answer: use `HAVING COUNT(*) > 5` not WHERE. Full query with GROUP BY customer_id. Explains eval order FROM→WHERE→GROUP BY→HAVING→SELECT→ORDER BY; WHERE runs before aggregation so cannot reference aggregates. Cites r07 + r23.

Verified: HAVING filters groups after aggregation; WHERE cannot reference aggregates (runs before GROUP BY) → `WHERE COUNT(*)>5` is invalid, exactly the user's error. `HAVING COUNT(*)>5` correct. The logical evaluation-order explanation is accurate and directly explains WHY the user's WHERE failed — strong root-cause teaching.

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 5 | 5 | 5 | 5 | **5.00** |

### Q4 — safe varchar→number (junk 'N/A', ''), NULL for bad, no failure
Answer: `TRY_CAST(quantity_str AS INTEGER)` → NULL for 'N/A'/'', good ones convert; `COALESCE(TRY_CAST(...), 0)` for a default. Notes Trino does NOT support `::` cast shorthand (`quantity_str::INTEGER` is a parse error). Cites r23 + r27.

Verified (conversion.html): `try_cast(value AS type)` returns NULL when the cast fails (vs CAST which errors). `TRY_CAST('N/A' AS INTEGER)` and `TRY_CAST('' AS INTEGER)` both fail to parse a valid integer → both return NULL (not an error) — exactly the "no query failure" requirement. `COALESCE(..., 0)` supplies a default. The no-`::`-shorthand note is correct (standing pin — Trino uses CAST/TRY_CAST, `::` is Postgres-only and parse-errors). Complete and directly actionable.

| Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|
| 5 | 5 | 5 | 5 | **5.00** |

---

## Overall

| Q | Avg |
|---|---|
| Q1 epoch→timestamp | 5.00 |
| Q2 first-N-chars / no-LEFT | 5.00 |
| Q3 HAVING aggregate filter | 5.00 |
| Q4 TRY_CAST / no-:: | 5.00 |

**Overall average: 5.00 / 5 → STRONG PASS** (threshold 3.5).

---

## Teacher feedback

No action required. All four answers are docs-verified clean and all four standing pins held with zero drift:
- **epoch-seconds-from_unixtime-not-millis** — held (Q1: seconds interpretation + float-divide millis caveat both correct).
- **no-LEFT-use-substr** — held (Q2: no LEFT(), substr 1-indexed, split_part alt).
- **HAVING-for-aggregate-filter** — held (Q3: HAVING vs WHERE + eval-order root cause).
- **TRY_CAST-NULL-on-fail + no-::-cast** — held (Q4: NULL for bad rows, COALESCE default, no `::` shorthand).

No new defect, imprecision, or findability gap surfaced. These four traps remain well-covered and durable across fresh phrasings. Do NOT churn the relevant cards (r07 HAVING/eval-order, r13 from_unixtime, r23 substr/split_part/TRY_CAST, r27 TRY_CAST) — churn risk on verified-clean content.

**iter778 designation: DEFAULT NO-OP / durability-breadth sweep** — no open defect, no new imprecision; teacher ZERO edits. Probe 4 fresh adjacent topics that still touch known Trino traps (e.g. epoch-MILLIS-explicit / right-N-chars or suffix via substr-negative-start / FILTER-vs-HAVING on conditional counts / TRY(expr) vs TRY_CAST distinction). Continue verifying every dialect claim against trino.io/docs/467. PRESERVE all four cards above — verified clean, churn risk.

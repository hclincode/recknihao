# Iter 543 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Summary

**Overall avg = (4.6875 + 4.625 + 4.500 + 3.8125) / 4 = 17.625 / 4 = 4.4063 — STRONG PASS** (+0.9063 above 3.5 floor).

**Iter542 → iter543 net swing +0.8438** (from 3.5625 thin pass to 4.4063 strong pass). Both iter542 critical defects CLOSED on first re-probe. One minor arithmetic slip surfaced in Q4 worked example — concept is correct, just one number in the table is wrong.

138th consecutive overall PASS in extended phase. Margin doubled vs. iter542.

---

## PRIMARY WINS — iter542 defects both CLOSED

### WIN 1 — Q1 `EXECUTE PROCEDURE iceberg.system.<proc>` fab GONE (iter542 Q3 closure)
Iter542 Q3 (2.5 FAIL): responder wrote `EXECUTE PROCEDURE iceberg.system.expire_snapshots(...)` (INVALID Trino 467; parse error `mismatched input 'PROCEDURE'`).

Iter543 Q1 (4.6875 STRONG PASS): responder writes verbatim:
- `ALTER TABLE iceberg.analytics.your_table EXECUTE expire_snapshots(retention_threshold => '7d')`
- `ALTER TABLE iceberg.analytics.your_table EXECUTE remove_orphan_files(retention_threshold => '7d')`
- Explicitly says: "uses `ALTER TABLE ... EXECUTE`, NOT `CALL` (Spark-only)"
- Also adds: 7d min-retention floor (`iceberg.expire-snapshots.min-retention`), `dry_run` is Spark-only, canonical order optimize → expire → orphan

Verified verbatim at trino.io/docs/current/connector/iceberg.html:
> `ALTER TABLE test_table EXECUTE expire_snapshots(retention_threshold => '7d');`
> `ALTER TABLE test_table EXECUTE remove_orphan_files(retention_threshold => '7d');`
> "The value for `retention_threshold` must be higher than or equal to `iceberg.expire-snapshots.min-retention` in the catalog, otherwise the procedure fails"

EXECUTE PROCEDURE fab is GONE. CALL-as-Trino is NOT emitted. r17 L21/L22 in-line signal + new DO-NOT-WRITE block LANDED on first re-probe.

### WIN 2 — Q2 `COMMENT ON TABLE` standalone canonical SURFACED (iter542 Q4 closure)
Iter542 Q4 (2.5 FAIL): responder declined the COMMENT ON TABLE syntax question (findability miss; r27 §6.7J only referenced it in dbt persist_docs context).

Iter543 Q2 (4.625 STRONG PASS): responder writes verbatim:
- `COMMENT ON TABLE iceberg.analytics.fct_orders IS '...'`
- `COMMENT ON COLUMN tbl.col IS '...'`
- `COMMENT ON TABLE tbl IS NULL` to remove
- Verification path: SHOW CREATE TABLE / SHOW COLUMNS / information_schema.tables.comment + information_schema.columns.comment
- Cross-link to dbt persist_docs (auto-emits these COMMENT ON statements)

Verified verbatim at trino.io/docs/current/sql/comment.html:
> `COMMENT ON ( TABLE | VIEW | COLUMN ) name IS 'comments'`
> "The comment can be removed by setting the comment to NULL"

Findability gap CLOSED. r17 new COMMENT ON canonical block + cross-ref from r27 §6.7J LANDED on first re-probe.

---

## Per-question scores

### Q1 — Trino expire_snapshots + remove_orphan_files SQL (Iceberg table maintenance)

| Dimension | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 4.5 |
| Practical applicability | 5.0 |
| Completeness | 4.25 |
| **Average** | **4.6875 — STRONG PASS** |

PRIMARY WIN. Form `ALTER TABLE ... EXECUTE expire_snapshots/remove_orphan_files(retention_threshold => '7d')` matches trino.io verbatim. Explicitly contrasts vs. Spark `CALL` form and vs. invalid `EXECUTE PROCEDURE`. 7d min-retention floor cited (`iceberg.expire-snapshots.min-retention`). `dry_run` correctly tagged as Spark-only. Canonical order optimize → expire → orphan correct. Tiny gap: did not separately call out `iceberg.remove-orphan-files.min-retention` (also 7d floor), but `dry_run` clarification is solid.

### Q2 — COMMENT ON TABLE / COLUMN in Trino (DDL, table description)

| Dimension | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 4.5 |
| Practical applicability | 4.75 |
| Completeness | 4.25 |
| **Average** | **4.625 — STRONG PASS** |

PRIMARY WIN. Grammar verbatim-matches docs. All three variants (TABLE / COLUMN / VIEW supported per docs; responder showed TABLE + COLUMN, sufficient for the question). NULL-to-remove form included. SHOW CREATE TABLE + information_schema.tables.comment + information_schema.columns.comment verification paths correct. Distinguishes standalone DDL from dbt persist_docs cleanly. Light gap: did not show `COMMENT ON VIEW` variant (minor — engineer asked specifically about table).

### Q3 — dbt accepted_values test for status ∈ {active, paused, cancelled}

| Dimension | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 4.5 |
| Practical applicability | 4.5 |
| Completeness | 4.0 |
| **Average** | **4.500 — STRONG PASS** |

Correct test identifier `accepted_values` with `values: ['active','paused','cancelled']`. Confirmed at docs.getdbt.com/reference/resource-properties/data-tests as one of the four built-in generic tests (not_null, unique, accepted_values, relationships). Severity-config mention correct. `dbt_utils.expression_is_true` correctly identified as the escape hatch for complex predicates. "Compiles to NOT IN check" framing slightly imprecise — the actual compiled SQL is `select <col> from <model> where <col> NOT IN (<values>) AND <col> IS NOT NULL` (the test returns rows that VIOLATE the rule). Engineer's takeaway is unchanged. Minor: did not mention `quote: false` for numeric/boolean value lists, but not relevant for the asked string-list use case.

### Q4 — ROWS vs RANGE window frames — when do they differ?

| Dimension | Score |
|---|---|
| Technical accuracy | 3.5 |
| Beginner clarity | 4.0 |
| Practical applicability | 4.0 |
| Completeness | 3.75 |
| **Average** | **3.8125 — PASS** |

**CONCEPT VERIFIED CORRECT**: ROWS = physical row-count offsets; RANGE = value-based logical range that includes all peer rows tied on the ORDER BY value. RANGE-needs-numeric/date-ORDER BY framing correct. Trino default frame when ORDER BY present without explicit frame = `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` — verified at trino.io/docs/current/sql/select.html verbatim: "If the frame is not specified, it defaults to `RANGE UNBOUNDED PRECEDING`, which is the same as `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`" and "contains all rows from the start of the partition up to the last peer of the current row".

**ARITHMETIC SLIP IN WORKED EXAMPLE (row 3)**:
- Table: row1 (2024-01-01, amt=100), row2 (2024-01-01, amt=100), row3 (2024-01-02, amt=50).
- Frame: `RANGE BETWEEN INTERVAL '1' DAY PRECEDING AND CURRENT ROW` over ORDER BY order_date.
- For row3 (order_date = 2024-01-02): frame includes rows where order_date ∈ [2024-01-01, 2024-01-02]. That's row1 + row2 + row3 = 100 + 100 + 50 = **250**.
- Responder claimed row3 RANGE = **150**. That's the ROWS-1-PRECEDING answer (row2 + row3), copy-pasted into the RANGE column.
- Row1 (RANGE=200, both peers on Jan 1) and row2 (RANGE=200) are correct.

Verified via web search (trino.io/blog "Introducing new window features"): "CURRENT ROW includes all rows where values of the sort key are the same as in the current row, which are called a peer group" and "RANGE BETWEEN INTERVAL '1' month PRECEDING AND CURRENT ROW" — so the syntax is valid Trino 467 (since v346), and the frame semantics confirm the 250 answer. The responder's 150 is an arithmetic error — concept right, illustrative number wrong. Could mislead an engineer learning the difference (the example exists precisely to show ROWS ≠ RANGE on this row; if the responder's number 150 is read as authoritative, the engineer sees ROWS=150 = RANGE=150 and concludes the frames coincide — the OPPOSITE of the lesson).

`RANGE BETWEEN INTERVAL '1' DAY PRECEDING` supported on Trino since 346 — confirmed valid for Trino 467. No invalidity claim here.

r07 L692-750 ALREADY contains the canonical ROWS vs RANGE peer-semantics block (and L1212 has a correct INTERVAL '6' DAY example with proper RANGE semantics). The responder's worked-example arithmetic was a regeneration slip, not a resource lift — `grep "INTERVAL '1' DAY PRECEDING"` in r07 returns no matches (only INTERVAL '6' DAY). So this is a one-off regeneration arithmetic slip, not contaminated resource content.

---

## VERIFIED VERDICT on Q4 arithmetic

**Row3 RANGE = 250, not 150.** Confirmed by two independent paths:

1. Walking the frame semantics: row3's `RANGE BETWEEN INTERVAL '1' DAY PRECEDING AND CURRENT ROW` includes all rows with `order_date ∈ [2024-01-01, 2024-01-02]`. Rows 1, 2, 3 all qualify. 100 + 100 + 50 = 250.
2. trino.io blog "Introducing new window features" (the canonical source for Trino's INTERVAL-based RANGE semantics post-v346): peer-group inclusion at CURRENT ROW + value-range inclusion of preceding rows within the interval offset.

The responder's 150 = the row2+row3 ROWS answer transposed into the RANGE column. The concept explanation in the answer is fully consistent with the 250 result — the answer body actually argues for 250 implicitly ("RANGE includes all peer rows on the ORDER BY value"), then the table breaks that argument by listing 150. Internal contradiction.

---

## Is a ROWS-vs-RANGE canonical needed in resources/ as the iter544 fix?

**Partially.** r07 L676-750 already has the canonical ROWS vs RANGE peer-semantics block AND r07 L1212 has a correct RANGE INTERVAL example. The gap is NOT the conceptual content — it's the **lack of a small worked-numeric-example table** with explicit per-row ROWS and RANGE answers that the responder can transcribe verbatim instead of regenerating arithmetic. iter544 SHOULD add a 4-row worked example with per-row arithmetic shown so the responder doesn't regenerate the table from scratch.

---

## iter544 next-teacher actions (concrete)

### FIX A (MEDIUM — Q4 ROWS-vs-RANGE worked-example canonical to prevent arithmetic regeneration)
Add a small numeric-worked-example block to r07 §1a (or wherever the existing ROWS-vs-RANGE block lives at L692-750) that gives an explicit 4-row table with per-row ROWS and RANGE answers AND the arithmetic shown row-by-row. Use a fresh scenario (different column names from the responder's example to avoid copy-paste contamination), e.g.:

```
ORDER BY order_date ASC, then for each row:
  S_ROWS  = sum(amt) OVER (ORDER BY order_date ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)
  S_RANGE = sum(amt) OVER (ORDER BY order_date RANGE BETWEEN INTERVAL '1' DAY PRECEDING AND CURRENT ROW)

order_date | amt | S_ROWS                     | S_RANGE
2024-01-01 | 100 | 100   (no preceding row)   | 200  (row1+row2 are Jan1 peers)
2024-01-01 | 100 | 200   (row1+row2)          | 200  (row1+row2 are Jan1 peers)
2024-01-02 |  50 | 150   (row2+row3)          | 250  (row1+row2+row3 all within 1d of Jan2)
2024-01-04 |  75 | 125   (row3+row4)          |  75  (gap day — Jan3 absent, only row4 in [Jan3, Jan4])
```

Add a one-line caption: "Row3 is the load-bearing row of this example — S_ROWS=150 (the 1 preceding row), S_RANGE=250 (peers + 1-day-prior rows). If your worked numbers ever show S_ROWS = S_RANGE on row3, you've miscounted — the whole point of the example is that they differ when ORDER BY has peer ties." This guard sentence inoculates against the iter543 slip.

Row 4 deliberately demonstrates the gap-day case (Jan 3 has no rows → row4's RANGE includes ONLY row4 because Jan 3 is absent and Jan 4 is the only date in [Jan 3, Jan 4]). This drives home that RANGE is value-based, not row-count-based.

Keyword anchors: "ROWS vs RANGE example", "ROWS BETWEEN vs RANGE BETWEEN worked example", "INTERVAL DAY PRECEDING worked example", "peer rows window frame example", "RANGE window frame arithmetic", "running total ROWS vs RANGE".

### FIX B (LOW — Q3 accepted_values compiled-SQL accuracy nit)
In r27 §6.7 (or wherever accepted_values is documented), add a one-line on the actual compiled SQL: the test compiles to `select <col> from <model> where <col> NOT IN (<values>) AND <col> IS NOT NULL` — the test returns ROWS that VIOLATE the rule (any returned row = test failure; zero rows = pass). Responder's "compiles to NOT IN check" was close but slightly hand-wavy. Also add a one-line on `quote: false` for non-string value lists.

### NO Q1/Q2 fixes needed
Both PRIMARY WINS. Hold the line on r17 in-line signal + DO-NOT-WRITE block + COMMENT ON canonical block. Do NOT rewrite the iter543 landings — RECONCILE-DON'T-APPEND only if a future failure surfaces.

### Iter544 probe targets
- **HIGH — ROWS vs RANGE 2nd angle (verifies FIX A landing)**: "show me a small numeric example where ROWS and RANGE give different running-total results" OR "if I switch from ROWS to RANGE on this query with date ties, what changes numerically?" (must give correct row-by-row arithmetic; row with both day-peer-ties AND gap days should produce DIFFERENT ROWS and RANGE numbers).
- **MEDIUM — Q1 expire_snapshots 3rd angle (durability check on WIN 1)**: "do I have to run remove_orphan_files separately, or does expire_snapshots clean orphan files too?" (must answer: separate command; canonical order optimize → expire → orphan).
- **MEDIUM — Q2 COMMENT ON 2nd angle (durability check on WIN 2)**: "how do I drop a description from one column in Trino?" (must answer `COMMENT ON COLUMN tbl.col IS NULL`).
- **LOW — federation stays UNPROBED** (row stays 4.49944/310 per directive).

---

## Topic-row updates (Q4 → "Analytical query patterns on Iceberg+Trino" per r07 §1a hosting)

| Topic | Pre-iter avg / N | Q score | Post-iter avg / N | Delta |
|---|---|---|---|---|
| Iceberg table maintenance (Q1 expire_snapshots/remove_orphan_files) | 4.4543 / 164 | 4.6875 | (4.4543·164 + 4.6875)/165 = (730.5052 + 4.6875)/165 = 735.1927/165 = **4.4557 / 165** | +0.0014 |
| SQL query best practices for OLAP (Q2 COMMENT ON TABLE/COLUMN DDL) | 4.5354 / 108 | 4.625 | (4.5354·108 + 4.625)/109 = (489.8232 + 4.625)/109 = 494.4482/109 = **4.5362 / 109** | +0.0008 |
| Oracle PL/SQL → dbt + Trino SQL migration (Q3 dbt accepted_values; r27 hosts canonical) | 4.4998 / 93 | 4.500 | (4.4998·93 + 4.500)/94 = (418.4814 + 4.500)/94 = 422.9814/94 = **4.4998 / 94** | +0.0000 |
| Analytical query patterns on Iceberg+Trino (Q4 ROWS vs RANGE; r07 §1a hosts canonical) | 4.4018 / 19 | 3.8125 | (4.4018·19 + 3.8125)/20 = (83.6342 + 3.8125)/20 = 87.4467/20 = **4.3723 / 20** | -0.0295 |

Federation row UNCHANGED at **4.49944 / 310** per directive (do NOT touch §13.x or the federation rubric row).

---

## Meta-rule observation

Directive's "verify YOUR OWN corrections before asserting" caveat was DECISIVE again on Q4: I went in suspecting the responder's row3 RANGE=150 was a slip. Verified via two independent paths — (1) walking the frame semantics by hand (frame at row3 is `order_date ∈ [Jan 1, Jan 2]` → includes rows 1+2+3 → 250), (2) verifying RANGE INTERVAL peer-group semantics at trino.io blog ("CURRENT ROW includes all rows where values of the sort key are the same as in the current row, which are called a peer group" → confirms peer-group inclusion). The responder's 150 = ROWS column copied into RANGE column for row3 is a clear arithmetic error, not a frame-semantics misunderstanding. Concept right; one number wrong. Score reflects accurately: Q4 still PASSES because the conceptual content is solid and the rest of the table is right, but accuracy docked from 5 to 3.5 because a teaching example with a wrong number is actively misleading.

7th consecutive iter (iter537 NULLS-LAST + iter538 banker's-vs-HALF_UP + iter539 sorted_by + iter540 not_null + iter541 bucket-arg-order + iter542 EXECUTE-PROCEDURE-fab + iter543 ROWS-vs-RANGE-arithmetic) where the meta-rule prevented a false-positive correction in either direction.

# Feedback — Iter 276 (Extended phase)

Date: 2026-05-27
Topic: Trino federation — ILIKE pushdown behavior (Q1 FAIL) + system.query() passthrough (Q2 PASS)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | ILIKE pushdown: conditional not categorical, session property, EXPLAIN verification, plan shapes | **4.39** | FAIL |
| Q2 | system.query() passthrough: syntax, single-quote escaping, join to Iceberg, limitations | **4.86** | PASS |

**Iter 276 average: 4.625 — mixed** (Q1 FAIL dragged by PR attribution error)

**Topic update**: Trino federation: 4.490/225 → **4.491/227** (NEEDS WORK, gap 0.009 — very slow progress; Q1 FAIL cost ~0.001)

---

## What worked

### Q1 — ILIKE pushdown (4.39)
1. Correctly framed ILIKE pushdown as conditional, not categorical — correct
2. Correct session property name: `enable_string_pushdown_with_collate` — verified
3. Correct catalog property: `postgresql.experimental.enable-string-pushdown-with-collate` — verified
4. Correct that ScanFilterProject disappears on pushdown success — verified
5. Excellent fallbacks: generated lower(name) column + index, system.query() passthrough — production-realistic
6. Strong beginner clarity: two-condition rule framed accessibly

### Q2 — system.query() passthrough (4.86)
1. Correct full syntax: `SELECT * FROM TABLE(app_pg.system.query(query => '...'))` — verified
2. Correct named parameter: `query =>` — verified
3. Correct single-quote escaping: `''` (doubled) — verified and explained with before/after
4. Correctly explained no-outer-predicate-pushdown limitation — verified
5. Correct derived-table join pattern to Iceberg with partition-pruning timestamp predicate — correct
6. Mentioned absence of column statistics + LIMIT recommendation — practical
7. EXPLAIN shows TableFunctionProcessor; debug inner SQL on Postgres replica — actionable
8. Complete end-to-end copy-pasteable example matching the scenario — excellent

---

## Errors / gaps to fix before iter277

### Q1 (important — caused FAIL)
- **PR #11045 attribution wrong**: Answer stated "ILIKE pushdown to the PostgreSQL connector was added via Trino PR #11045 and is available in Trino 467." Judge verified: PR #11045 is about general JDBC function predicate pushdown machinery with LIKE as initial example, merged in release 373 — not specifically ILIKE, not in 467. The `enable_string_pushdown_with_collate` flag traces to different work. (**FIXED in resource 22 by teacher277 — removed all 7 PR #11045 mentions**)
- **`constraint=(...)` plan shape not authoritative**: Answer presented `constraint=(name ILIKE '%corp%')` inside TableScan as the canonical success signal. Official Trino docs only say "ScanFilterProject disappears" — the exact textual format is not documented and varies by version/connector. Should be hedged. (**FIXED in resource 22 by teacher277 — added hedge language**)
- Minor: The flag may not cover ILIKE specifically in all builds — the docs describe it in terms of range predicates; "verify with EXPLAIN before relying on it" caveat exists in the answer but framing was too confident.

### Q2 (minor)
- Missing caveat: `system.query()` does NOT preserve result order even with inner `ORDER BY` — Trino docs explicitly state this. Not a correctness error (LIMIT still bounds rows), but the user might be surprised if they expect ordering.
- Does not warn about `||` multi-line string concatenation escaping hazard in the complete example.

---

## Resource fixes completed (teacher277)

1. **PR #11045 attribution removed** (resource 22, ~10 locations): replaced all "PR #11045" mentions with canonical statement about LIKE/ILIKE pushdown being conditional on `enable_string_pushdown_with_collate` and column collation
2. **`constraint=(...)` hedge added** (resource 22, ILIKE pushdown section): clarified that plan shape for successful pushdown is "ScanFilterProject disappears" — exact textual format of constraint block varies and is not documented

---

## Suggested iter277 angles (MUST target Trino federation, gap 0.009)

Topic at 4.491/227. Need ~3-4 more questions at 4.875+ to cross 4.500 threshold.

1. **system.query() ORDER BY caveat + LIMIT** — engineer asks about getting fuzzy-matched results ordered by similarity score; answer must include the ORDER BY not-preserved caveat and that ordering must be applied in Trino AFTER the passthrough

2. **Federate vs ingest at scale** — engineer has 50M-row Postgres table that joins Iceberg frequently; answer: above 10M threshold → prefer ingestion; nightly MERGE INTO pattern; when to hybrid materialize

3. **Re-test: ILIKE pushdown nuance (after resource fix)** — verify the responder now gives the corrected answer: conditional on flag + collation, no PR number cited, ScanFilterProject-disappears as the success signal

4. **Metadata caching and stale Iceberg reads** — engineer sees Trino return old Iceberg data after Spark adds files; answer: metadata.cache-ttl, flush_metadata_cache (coordinator-only), CREATE OR REPLACE VIEW workaround

5. **Resource groups to limit Postgres load** — engineer wants to cap concurrent Postgres queries; hardConcurrencyLimit + maxQueued; source selector caveat; PgBouncer integration

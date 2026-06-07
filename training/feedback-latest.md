# Judge feedback — iter591

**Iteration**: 591
**Phase**: extended
**Verdict**: **PASS**
**Overall average**: **5.00** (4×5.00)
**ILIKE-resolution status**: **RESOLVED** — responder now leads with `LOWER(col) = LOWER('lit')` and does NOT emit `ILIKE` for the native-Iceberg case-insensitive match. The iter590 resource-defect-driven fabrication is gone.

---

## Per-question scores

| Q | Topic | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|---|
| Q1 | case-insensitive equals (LOWER, not ILIKE) — RE-PROBE | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | TRIM whitespace before equality | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | SUBSTR position-extraction (1-indexed year slice) | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | SELECT DISTINCT on multi-column pair | 5 | 5 | 5 | 5 | 5.00 |

Per-question gate: all four ≥ 3.5. Overall 5.00. No quality concern to flag.

---

## Verification (Trino 467 docs, pinned)

### Q1 — ILIKE absence + LOWER canonical (RE-PROBE)
- **trino.io/docs/467/functions/comparison.html** (WebFetch this iter): *"Is ILIKE listed? No, `ILIKE` does not appear anywhere on this page."* Operators listed: `<, >, <=, >=, =, <>, !=, BETWEEN, IS NULL, IS DISTINCT FROM, LIKE, NOT LIKE`. Only pattern operator is **LIKE** — quoted: *"The `LIKE` operator can be used to compare values with a pattern."* ILIKE is **not** present in Trino 467.
- **trino.io/docs/467/functions/string.html** (WebFetch this iter): *"ILIKE is not mentioned anywhere on this page. Only `LIKE` is referenced."* `lower(string) → varchar` is documented: *"Converts string to lowercase."*
- **Conclusion**: `WHERE LOWER(company_name) = LOWER('acme')` is the correct Trino 467 native form. Responder's lead is fully docs-aligned. **The iter590 r23:1576 false-claim defect is RESOLVED in the responder output.**

### Q2 — TRIM/LTRIM/RTRIM
- **trino.io/docs/467/functions/string.html**: quoted verbatim — `trim(string) → varchar` *"Removes leading and trailing whitespace from string."*; `ltrim(string) → varchar` *"Removes leading whitespace from string."*; `rtrim(string) → varchar` *"Removes trailing whitespace from string."*. Also full-form `trim([specification] [string] FROM source)` documented.
- **Conclusion**: `WHERE TRIM(country_code) = 'US'` is correct. The LTRIM/RTRIM offer for one-sided strip is accurate. Partition-pruning caveat (TRIM on the column blocks pruning) is correct and important.

### Q3 — SUBSTR arithmetic + 1-indexed + SUBSTRING FROM/FOR alias
- **trino.io/docs/467/functions/string.html**: `substring(string, start, length) → varchar` — *"Returns a substring from string of length length from the starting position start. Positions start with 1."* And: *"A negative starting position is interpreted as being relative to the end of the string."* `substr` is documented as *"an alias for substring()."*
- **Arithmetic check** on `'REG-2026-00042'`: position 1=R, 2=E, 3=G, 4=-, 5=2, 6=0, 7=2, 8=6 → `SUBSTR(s, 5, 4)` = `'2026'`. Responder's arithmetic is correct.
- **SUBSTRING FROM…FOR** alias: confirmed via Trino parser grammar (`SqlBaseParser.SubstringContext` carries SUBSTRING + FROM + FOR keyword terminals — the SQL-standard form is supported by Trino's parser). Responder's claim is accurate.

### Q4 — SELECT DISTINCT on multiple columns
- **trino.io/docs/467/sql/select.html**: *"The `ALL` and `DISTINCT` quantifiers determine whether duplicate rows are included in the result set. If the argument `DISTINCT` is specified, only unique rows are included in the result set."* DISTINCT applies to the row tuple, not per-column.
- **Conclusion**: `SELECT DISTINCT country, plan_tier FROM events ORDER BY country, plan_tier` returns distinct **pairs** — exactly what was asked. Responder correctly named "one row per unique pair" and added the partition-filter tip.

---

## What worked this iter

- **Q1 (RE-PROBE)**: The r23:1576 in-place REPLACE (iter591 teacher fix) routed cleanly. Responder anchored on the new NOT-supported truth and emitted `LOWER(company_name) = LOWER('acme')` as the lead. No residual ILIKE leakage. Disambiguator (PG-connector ILIKE pushdown lives in r22 §3.3) did its job — no cross-conflation.
- All four answers added the partition-pruning warning when wrapping a column in a function (`LOWER`, `TRIM`, `SUBSTR`) — this is the high-value Trino 467 OLAP best-practice signal and is consistently surfaced.
- Q3 arithmetic shown explicitly (count of characters), which addresses the "by position" framing without hand-waving.

## Slips / new defects

- **None observed this iter.** No fabricated features, no false absences, no `::`-cast, no wrong-frame semantics. SQL is valid Trino 467 dialect across all four answers.

---

## iter592 directive (teacher actions)

1. **DO**: Treat the ILIKE / LOWER-LIKE / native-case-insensitive-match topic as **CANONICAL LOCKED** but **probe one more angle in iter592–593** to confirm 2-framing durability before treating it as fully bulletproofed. Suggested re-probe shapes:
   - **Case-insensitive contains/starts-with** (LIKE pattern, not equals): "find rows where `description` contains 'urgent' regardless of case" — responder should emit `WHERE LOWER(description) LIKE '%urgent%'` or `WHERE regexp_like(description, '(?i)urgent')`. This stresses the **LIKE-pattern variant** of the same r23:1576 fix.
   - **Case-insensitive regex**: "match values matching pattern `^prod_` ignoring case" — responder should emit `WHERE regexp_like(col, '(?i)^prod_')` (Java inline flag). This stresses the regexp_like fork of the same canonical.
2. **DO NOT** re-edit r23:1576 — it is the freshly-corrected canonical. Re-editing risks reintroducing the false claim or churning the disambiguator pointer.
3. **DO NOT** touch r22 §3.3 PG-connector ILIKE pushdown content — it is the legitimate federation context and remains the disambiguator target.
4. **DO NOT** touch federation §13.x guardrails (federation row at 4.49944/310 — thin margin per memory note).
5. **NO-OP candidates**: Q2 TRIM, Q3 SUBSTR, Q4 SELECT DISTINCT are all canonical-clean. No resource churn needed. Resist the urge to add new content where the responder already nails the answer — manufactured churn risks introducing new false claims (the very failure mode that drove iter590).
6. **Watch list (carry-forward)**: Trino 467 dialect parse traps where a feature exists in PG/Snowflake/BigQuery but **not** native Trino — same family as the ILIKE leak. Audit candidates teacher may want to spot-check on r23: `STRING_AGG` (canonical `listagg` already locked), `TO_CHAR` (canonical `format_datetime` already locked), `NOW()` timezone semantics, `::`-cast (banned iter571). All currently appear correctly marked per state.json sweep; no edits suggested, only standing vigilance.

**Net iter591 verdict**: the iter590 RESOURCE-DEFECT root cause is fixed at the source, the responder's routing now lands on truth, and three fresh probes (TRIM/SUBSTR/DISTINCT) confirm no collateral damage from the r23:1576 edit. STRONG PASS at 5.00.

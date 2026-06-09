# Judge Feedback — iter809

**Sweep type:** LIGHT FINDABILITY FIX-A (iter808 Q3 percent-string was a cast-less-concat TYPE ERROR; iter809 added a `format('%.2f%%', x*100)` percent-string card at r07 + cast-less `||`/concat defang).
**Docs verification:** all claims verified against trino.io/docs/467 (functions/string.html + functions/conversion.html) on 2026-06-09.
**state.json:** NOT touched (already 809).

---

## Per-question scores

### Q1 — Percent-string RE-PROBE: decimal `0.158` → `'15.80%'` — FIX CHECK

Responder answer: `format('%.2f%%', return_rate * 100) AS return_rate_pct` → `'15.80%'`; `%%` = literal percent; returns VARCHAR. Cited r23 §3.1A format card.

**Docs verification (conversion.html):** `format(format, args...) -> varchar` uses Java Formatter syntax. `SELECT format('%s%%', 123)` → `'123%'` (confirms `%%` = literal percent). `SELECT format('%.5f', pi())` → `'3.14159'` (confirms `%.Nf` formats float to N decimals). Therefore `format('%.2f%%', 0.158*100)` = `format('%.2f%%', 15.8)` = `'15.80%'`. CORRECT.

**CRITICAL FIX VERDICT:** The responder LED with `format()` (NOT the iter808 cast-less `ROUND(...)||'%'` / `CONCAT(ROUND(...),'%')` concat that was a compile-time TYPE ERROR) and cited the format card. **The format-%-string fix WORKED.** This is the 1st post-fix datapoint.

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Q1 avg** | **5.00** |

---

### Q2 — Concat columns skipping NULLs: join street/city/zip with `', '`, no doubled separator — DEFECT

Responder FLOUNDERED across four forms, none of which was the clean canonical:
- (a) `array_join(array_agg(CASE WHEN street IS NOT NULL THEN street WHEN city IS NOT NULL THEN city WHEN zip IS NOT NULL THEN zip END), ', ')` — **WRONG.** The single CASE expression returns only the FIRST non-null of the three, so `array_agg` collects ONE value per row, not all three columns. Does not concatenate street+city+zip.
- (b) `ARRAY_COMPACT(ARRAY[street,city,zip])` — `ARRAY_COMPACT` does NOT exist in Trino 467 (responder correctly noted this, but should not have offered it at all).
- (c) "the cleanest approach is CONCAT_WS (if available)" — **UNCERTAINTY IS THE DEFECT.** `concat_ws` DOES exist and IS the clean answer.
- (d) a convoluted `UNION ALL` + `array_agg(piece) FILTER (WHERE piece IS NOT NULL) GROUP BY` — works but is grossly over-engineered for a 3-column single-row concat.

Cited r07 §1a.2 (`array_agg` group-concat card).

**Docs verification (string.html):** `concat_ws(string0, string1, ..., stringN) -> varchar` — "Any null values provided in the arguments after the separator are skipped." So `concat_ws(', ', street, city, zip)` with a NULL `city` = `'123 Main St, 94105'` (no doubled separator). **This is THE direct, clean answer.** The responder failed to give it confidently.

**Q2 VERDICT — DEFECT (selection / findability miss, NOT content gap):**
`concat_ws` EXISTS in the resources and IS verified-correct. It lives in **r27 (Oracle PL/SQL → dbt/Trino) §4.3-STR-FAMILY**:
- `resources/27-oracle-plsql-to-dbt-trino.md:1026` — keyword anchor line includes `concat_ws Trino`, `Trino concat_ws exists`, **`join strings with separator Trino`**, `Trino string functions`.
- `resources/27-oracle-plsql-to-dbt-trino.md:1036` — the canonical row: `concat_ws(separator, string1, ..., stringN) -> varchar` ... "**Skips NULL string arguments**" with worked example `concat_ws('-', 'a', NULL, 'c')` → `'a-c'`.
- `resources/27-oracle-plsql-to-dbt-trino.md:1050` — DO-NOT-WRITE row rescinding the false "concat_ws is Postgres/Spark-only" ban.

So the content is present and accurate. The problem is **WHERE it lives and WHAT it is filed under.** r27 is the Oracle-migration resource, and the §4.3 card's framing is "string-function family that gets fabricated as missing" (translate/reverse/position/levenshtein/concat_ws). A SaaS engineer asking "join several COLUMNS with a separator skipping nulls" does NOT carry Oracle-migration keywords — that need naturally routes to r07's SQL-patterns landing, where the responder landed on **r07 §1a.2 / §1a.2A**, which is exclusively `array_agg` / `array_join(array_agg(...))` — i.e. joining ROWS within a GROUP into a delimited string (group-concat). There is NO row-level `concat_ws` "join columns skipping nulls" card at the r07 landing. The responder picked the wrong tool because the right tool was not reachable from the question's keywords.

Note: `concat_ws`-skips-nulls was answered CLEANLY in iter779 — so this is confirmed a SELECTION/FINDABILITY MISS, not a knowledge/content gap.

| Axis | Score |
|---|---|
| Accuracy | 2 (clean answer never confidently given; array_agg-CASE form is functionally WRONG) |
| Completeness | 2 (the one correct clean form omitted; offered a nonexistent function) |
| Clarity | 3 (prose readable but riddled with hedging/uncertainty) |
| Actionability | 2 (engineer cannot copy a working query confidently from this) |
| **Q2 avg** | **2.25** |

---

### Q3 — File extension after the LAST dot: `'report.final.pdf'` → `'pdf'`

Responder answer: `substr(filename, strpos(filename, '.', -1) + 1) AS extension` → `'pdf'` (strpos 3rd arg `-1` = last occurrence); also `element_at(split(filename, '.'), -1)`.

**Docs verification (string.html):** `strpos(string, substring, instance) -> bigint` — "When `instance` is a negative number the search will start from the end of `string`." So `strpos('report.final.pdf', '.', -1)` returns the position of the LAST `.`, and `substr(..., pos + 1)` returns `'pdf'`. CORRECT. `element_at(split(filename, '.'), -1)` returns the last array element = `'pdf'`. CORRECT (negative index = from end). Both standing pins held.

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 (two valid forms) |
| Clarity | 5 |
| Actionability | 5 |
| **Q3 avg** | **5.00** |

---

### Q4 — Top-ranked row per key: single lowest-`priority_rank` contact method per person

Responder answer: `ROW_NUMBER() OVER (PARTITION BY person_id ORDER BY priority_rank ASC)` filtered to `= 1` in a subquery; `RANK()` noted for keeping ties.

**Docs verification (functions/window.html / select.html — standing pin):** `ROW_NUMBER() OVER (PARTITION BY person_id ORDER BY priority_rank ASC) = 1` selects the row with the lowest `priority_rank` (highest priority) per person; exactly one row even on ties. `RANK() = 1` keeps all tied rows. CORRECT (top-per-group / keep-latest family).

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 (ROW_NUMBER for single + RANK for ties) |
| Clarity | 5 |
| Actionability | 5 |
| **Q4 avg** | **5.00** |

---

## Overall

| Q | Avg |
|---|---|
| Q1 | 5.00 |
| Q2 | 2.25 |
| Q3 | 5.00 |
| Q4 | 5.00 |
| **Overall** | **4.3125** |

**Overall avg = 4.31 → PASS** (threshold 3.5; overall average governs, no single-Q veto). Q2 is a genuine DEFECT dragging the sweep but does not sink the pass.

---

## Teacher feedback (answers to the three required questions)

**(a) Is format-%-string CLOSED? YES — Q1 fix WORKED.** The responder LED with `format('%.2f%%', return_rate*100)` (NOT the iter808 cast-less `ROUND(...)||'%'` / `CONCAT(...)` form that was a compile-time type error) and cited the format card. `0.158` → `'15.80%'` verified against conversion.html (`%%`=literal percent, `%.Nf`=N-decimal float). This is the 1st post-fix datapoint; recommend ONE more percent-string re-probe (different phrasing) to BULLETPROOF before considering it permanently closed.

**(b) Q2 verdict — concat_ws is the clean answer the responder missed.** The direct, clean answer is `concat_ws(', ', street, city, zip)` — verified against string.html: concat_ws "skips" NULL arguments after the separator, so a NULL city yields no doubled separator. The responder floundered: (i) `array_join(array_agg(CASE WHEN ... END), ', ')` is functionally WRONG (the single CASE returns only the first non-null per row, so array_agg collects one value, not three); (ii) `ARRAY_COMPACT` does not exist in Trino 467; (iii) `concat_ws` offered only hedged "if available" when it IS available and IS the answer; (iv) a UNION ALL + array_agg-FILTER form that works but is grossly over-engineered. This is a **SELECTION / FINDABILITY MISS, not a content gap** — concat_ws (skips-nulls) is present and accurate at `resources/27-oracle-plsql-to-dbt-trino.md:1026` (anchor), `:1036` (canonical row), `:1050` (DO-NOT-WRITE rescind), but it is filed under the Oracle-migration string-family card framed around "fabricated-as-missing." The "join several COLUMNS with a separator skipping nulls" need routed to the r07 SQL-patterns landing and landed on `r07 §1a.2 / §1a.2A` (`array_agg` / `array_join(array_agg)`) — which is group-concat over ROWS, the wrong tool. concat_ws-skips-nulls was answered cleanly in iter779, confirming this is a routing/selection miss.

**(c) iter810 designation — FIX-A.**
Surface a row-level `concat_ws` "join COLUMNS with a separator, skips NULLs" canonical at the r07 SQL-patterns landing (near §1a.2 / §1a.2A), keyword-anchored on: `concat_ws columns`, `join columns with separator skip null`, `concatenate address fields skip null`, `combine columns one separator no doubled separator`, `concat_ws vs concat null`. Copy-attractive form:
```sql
SELECT concat_ws(', ', street, city, zip) AS full_address;  -- NULL city -> '123 Main St, 94105' (NULL skipped, no doubled separator)
```
CRITICALLY: **disambiguate at the same landing** —
- `concat_ws(sep, colA, colB, colC)` = join several COLUMNS in ONE row, skips NULL args (this question).
- `array_join(array_agg(x), sep)` = join the values from MANY ROWS in a GROUP into one delimited string (group-concat; r07 §1a.2A).
Inline-defang the array_agg-CASE form (mark un-copyable WRONG: "the single CASE returns only the first non-null, NOT all columns") and the nonexistent `ARRAY_COMPACT`. Keep the r27 §4.3 card intact and cross-link it. PRESERVE the iter809 format-%-string card (drove Q1 fix), r23 §3.1A, r07 ROW_NUMBER/RANK top-per-group, strpos-negative / split+element_at extension pins (all clean this sweep).

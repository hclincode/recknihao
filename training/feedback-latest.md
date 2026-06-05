# Iter 505 Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall verdict

- **Overall avg = (5.0 + 4.875 + 3.25 + 4.9375) / 4 = 18.0625 / 4 = 4.5156 PASS**
- Margin: **+1.0156** above 3.5 floor.
- BOTH iter504 fixes LANDED. Q1 (dbt unit tests — new canonical §6.7E) and Q2 (DF stats-overstatement reconcile in r23 §4) both routed cleanly and produced doctrinally correct answers.
- **NEW LOAD-BEARING Q3 SQL parse error + Q3 minor factual error on split_to_map**. Pulls Q3 to FAIL even though everything else in Q3 (SPLIT/UNNEST/TRIM/GROUP BY/LEFT-vs-CROSS-JOIN nuance) is correct.
- Federation NOT probed (per directive); r22 §13.x guardrails untouched; federation rubric row stays 4.49944/310.

---

## Per-question scores

### Q1 — dbt unit tests RE-PROBE (FIX A landing test) — 5.000 STRONG PASS — **FIX A LANDED**

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | Top-level `unit_tests:` key correct (NOT `unit-tests:`). `name:` + `model:` + `given:` (list of `- input: ref(...)` with `rows:`) + `expect:` (with `rows:`) all match docs.getdbt.com/reference/resource-properties/unit-tests verbatim. `format: dict \| csv \| sql` options correct, dict is default. Runs at build BEFORE materialize correct. `dbt test --select test_type:unit` selector correct (NOT `test_type:unit_test`). Distinguishes unit tests (verify model TRANSFORMATION LOGIC on mock input) from data tests (`not_null`/`unique` post-build output assertions). dbt 1.8+ version correct. YAML lives under `models/` (NOT `tests/`) correct. Zero fabricated keys. |
| Clarity | 5.0 | Worked example with mock input rows + expected output rows. Plain English on what each section does. DO-NOT-CONFUSE callout clean. |
| Actionability | 5.0 | Engineer can copy-paste the YAML, drop it next to the model, and run `dbt test --select test_type:unit`. |
| Completeness | 5.0 | Covers YAML schema, run command, build-pipeline ordering, vs-data-tests distinction, format options. |

**FIX A VERDICT: LANDED CLEANLY.** Iter504 Q4 was a 2.625 FAIL (content gap, responder punted honestly). Iter505 Q1 is a 5.000 STRONG PASS — the NEW r27 §6.7E canonical addition (between §6.7D seeds and §7 cutover) routed correctly on first probe. 13th leading-canonical bulletproofing instance + 6th findability/canonical-addition fix to land cleanly on re-probe.

### Q2 — Dynamic filtering 2nd-angle RE-PROBE (FIX B landing test) — 4.875 STRONG PASS — **FIX B LANDED**

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | Leads with "issue is NOT just missing ANALYZE." States DF is on-by-default + RUNTIME mechanism, works regardless of ANALYZE. 6-step checklist all correct per trino.io/docs/current/admin/dynamic-filtering.html: (1) join type INNER/RIGHT (LEFT/FULL not supported) — verified; (2) predicate `=,<,<=,>,>=,IS NOT DISTINCT FROM` — verified verbatim; (3) BROADCAST vs PARTITIONED — verified ("dynamic filters are collected before the build side is partitioned... when broadcast join is chosen" + "collected after the build side is partitioned when partitioned join is chosen"); (4) connector support — verified (Iceberg/Postgres/MySQL all support); (5) wait timeout default 1s for Iceberg — verified; (6) stats help CBO build-side / BROADCAST selection but do NOT gate DF — exactly correct. `ANALYZE iceberg.analytics.events WITH (columns = ARRAY[...])` is valid Trino 467 syntax. |
| Clarity | 4.75 | Checklist ordering is logical; explicit "stats help CBO ... but do NOT gate DF" closes the iter504 misunderstanding. Minor -0.25 for moderate density. |
| Actionability | 5.0 | Engineer who reads EXPLAIN and sees no `dynamicFilter` has a clear ordered checklist to walk through. |
| Completeness | 4.75 | Covers all the live factors. Minor -0.25 for not naming `dynamic-filtering.large-broadcast` / wait-timeout property names. |

**FIX B VERDICT: LANDED CLEANLY.** Iter504 Q2 was 3.875 PASS with stats-overstatement ("optimizer won't use DF without cardinality estimates" — wrong). Iter505 Q2 is 4.875 STRONG PASS — the reconcile-in-place at r23 line 197 (6-step checklist) routed correctly. 14th leading-canonical bulletproofing instance + 7th reconcile-in-place fix to land cleanly on re-probe.

### Q3 — Comma-separated tags split + count — 3.25 FAIL — **TWO LOAD-BEARING ISSUES**

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 2.5 | **TWO ERRORS**: (i) SQL CLAUSE-ORDER PARSE ERROR in main query: `FROM events WHERE event_date = DATE '2026-05-26' AND tags IS NOT NULL CROSS JOIN UNNEST(SPLIT(tags, ',')) AS t(tag) GROUP BY ...` — invalid SQL. JOINs (incl. CROSS JOIN UNNEST) are part of the FROM clause and MUST appear BEFORE WHERE. Engineer copy-pastes → `mismatched input 'CROSS' expecting <EOF>...`. Verified via trino.io/docs/current/sql/select.html and SQL grammar (FROM/JOIN → WHERE → GROUP BY → SELECT → ORDER BY is mandatory written order). (ii) Fabricated absence: "Trino has NO SPLIT_TO_MAP" — Trino DOES have `split_to_map(string, entryDelimiter, keyValueDelimiter)` per trino.io/docs/current/functions/string.html (returns `map<varchar, varchar>`). Minor aside (question was about counting tags, not k=v maps) but still a factual error. Otherwise SPLIT(tags, ',') → ARRAY correct, CROSS JOIN UNNEST AS t(tag) correct, TRIM(tag) correct, the LEFT JOIN UNNEST ... ON TRUE preserve-rows nuance is correct. |
| Clarity | 4.0 | Reasonably clear; clean explanation of UNNEST and CROSS-vs-LEFT semantics. |
| Actionability | 2.5 | The main query as written does NOT parse. Engineer must mentally re-order WHERE after JOIN before it runs. That defeats the purpose of a copy-pasteable answer. |
| Completeness | 4.0 | Otherwise covers split, unnest, trim, group by, ordering. |

**CORRECT QUERY (re-ordered):**

```sql
SELECT TRIM(tag) AS tag, COUNT(*) AS event_count
FROM events
CROSS JOIN UNNEST(SPLIT(tags, ',')) AS t(tag)
WHERE event_date = DATE '2026-05-26'
  AND tags IS NOT NULL
GROUP BY TRIM(tag)
ORDER BY event_count DESC;
```

### Q4 — Oracle TRUNC(amount, 2) → Trino — 4.9375 STRONG PASS

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | `truncate(x)` is 1-arg in Trino 467 (verified trino.io/docs/current/functions/math.html: "Returns x rounded to integer by dropping digits after decimal point"). 2-arg `truncate(x, n)` does NOT exist on 467 (verified via WebFetch — no two-arg variant). `truncate(amount*100)/100` is the correct 2-decimal-truncation idiom; result `truncate(123.456*100)/100 = 123.45` correct. General form `truncate(amount*power(10,2))/power(10,2)` correct. round() = HALF_UP correct. DO-NOT-WRITE list correctly bans `TRUNC(amount,2)`, `truncate(amount,2)`, `TRUNCATE(amount,2)`. |
| Clarity | 5.0 | Direct mapping with worked numeric example. |
| Actionability | 5.0 | Engineer copy-pastes the idiom and is done. |
| Completeness | 4.75 | Covers idiom, general N-decimals form, round-vs-truncate distinction, DO-NOT-WRITE matrix. Minor -0.25 for no edge case on negative N or DECIMAL-vs-DOUBLE precision note (non-load-bearing). |

---

## What landed and what didn't

- **FIX A (dbt unit tests new canonical r27 §6.7E)**: LANDED. Q1 5.000 STRONG PASS, doctrinally correct YAML, zero fabs, routed first try. Findability anchor + DO-NOT-CONFUSE callout + DO-NOT-WRITE matrix all functioning.
- **FIX B (r23 line 197 DF reconcile-in-place)**: LANDED. Q2 4.875 STRONG PASS, explicit "stats help CBO ... but do NOT gate DF" + 6-step checklist. Closes iter504 Q2's stats-overstatement.

## New issues introduced this iter

- **Q3 SQL clause-order parse error**: load-bearing. The main query has WHERE before CROSS JOIN UNNEST. Whatever resource the responder pulled from has an example with broken clause order, OR the responder hallucinated the ordering. Needs investigation + reconcile-in-place.
- **Q3 split_to_map fabricated absence**: minor. "Trino has NO SPLIT_TO_MAP" is wrong; the function exists. Probably an unsupported assertion the responder added on its own.

---

## Next-teacher actions (iter506)

### HIGH PRIORITY — Q3 clause-order reconcile (load-bearing parse error)

1. **GREP for any `WHERE ... CROSS JOIN UNNEST` pattern in resources/**. Any example with WHERE before JOIN in a single query body must be reconciled-in-place to put WHERE after the JOIN.
2. **In the SPLIT/UNNEST canonical (r07 §1a + r23 § on UNNEST + any r28/r27 example)**, add an explicit one-liner: "**Clause order**: `FROM ... CROSS JOIN UNNEST(...) AS t(col) WHERE ... GROUP BY ...` — JOINs are part of FROM; WHERE goes AFTER all JOINs. Writing WHERE before CROSS JOIN UNNEST is a parse error."
3. **DO-NOT-WRITE matrix entry** at the UNNEST canonical: ban `FROM <table> WHERE <pred> CROSS JOIN UNNEST(...)` and `FROM <table> WHERE <pred> AND <col> IS NOT NULL CROSS JOIN UNNEST(...)`.

### MEDIUM PRIORITY — split_to_map fabricated absence reconcile

1. **GREP `"NO SPLIT_TO_MAP"` / "no split_to_map" / "doesn't have split_to_map" in resources/**. If found anywhere, replace with the truth: Trino DOES have `split_to_map(string, entryDelimiter, keyValueDelimiter) -> map<varchar, varchar>` and `split_to_multimap(...)` per trino.io/docs/current/functions/string.html.
2. **In the SPLIT canonical**, add a one-row table: "**Two-level splits**: use `split_to_map('a=1,b=2', ',', '=')` returns `{a:'1', b:'2'}` when the string is k=v pairs; use `split('a,b,c', ',')` returns `array['a','b','c']` for single-delimiter lists."

### Iter506 probe targets

- **HIGH — Q3 split-and-count RE-PROBE**: same shape ("column with comma-separated tags, count per tag") to verify the clause-order fix lands and the main query parses on first paste.
- **HIGH — split_to_map angle**: e.g. "I have a column with `key1=val1;key2=val2` strings — how do I parse it in Trino?" to verify the fabricated-absence reconcile lands.
- **MEDIUM — dbt unit tests 3rd angle (fixture file form)**: e.g. "my mock input has 200 rows — can I put it in a CSV file instead of inline YAML?" to test the `fixture:` keyword + `tests/fixtures/` directory coverage of §6.7E.
- **MEDIUM — DF 3rd angle on LEFT OUTER JOIN**: "my fact-dim join is a LEFT JOIN and EXPLAIN shows no dynamicFilter — is that expected?" to verify the join-type bullet routes.
- **LOW — Trino truncate vs round vs floor distinction**: 3rd angle on Q4 to test broader rounding-family coverage.
- **DO NOT probe federation** — stays untouched per directive.

### What NOT to touch

- r22 §13.x federation guardrails (66+ DF mentions — all correct, all untouched per directive).
- Federation rubric row (stays 4.49944/310).
- r07 §1a UNNEST array-explode canonical + LEFT JOIN UNNEST ON TRUE one-liner (iter503/504).
- r27 §6.7E dbt unit tests canonical (iter505 — landed, leave it).
- r23 §4 DF 6-step checklist (iter505 — landed, leave it).
- All other locked canonicals per state.json notes (iter495-503 fixes).

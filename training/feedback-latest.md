# Iter 481 — Judge Feedback (END-OF-ITERATION, EXTENDED PHASE)

## Overall: 4.0469 PASS (thin) — 80th consecutive overall PASS

**CRITICAL: load-bearing fabrication confirmed on Q4 (listagg OVER) — fab streak BROKEN after iter480's restoration.**

Federation NOT probed this iter — 4.49944/310 row UNCHANGED per iter472-480+ directive.

---

## Per-question scores

| Q | Topic | Acc | Comp | Clar | Act | Avg | Notes |
|---|---|---|---|---|---|---|---|
| Q1 | DECIMAL vs DOUBLE for money | 5.00 | 5.00 | 4.75 | 4.75 | **4.875** | Doc-perfect; exact-vs-IEEE-754 framing, NUMBER(19,4)->DECIMAL(19,4) correct, silent-rounding-on-invoices framing correct |
| Q2 | Iceberg hidden partitioning + partition evolution read-compat | 4.75 | 4.75 | 4.75 | 4.75 | **4.75** | Write-predicate-against-source-column, SET PROPERTIES partitioning (NOT SET PARTITION SPEC), rewrite_data_files Spark-only — all doc-anchored |
| Q3 | dbt `+` graph selector + tags | 5.00 | 4.75 | 4.75 | 4.75 | **4.8125** | model+ = downstream, +model = upstream, tag: selector, combination all doc-anchored |
| Q4 | Oracle windowed LISTAGG -> Trino | **1.00** | 2.00 | 2.50 | 1.50 | **1.75** | **LOAD-BEARING FAB**: listagg-OVER claim + NULLS misdiagnosis |

**Overall avg = (4.875 + 4.75 + 4.8125 + 1.75) / 4 = 16.1875 / 4 = 4.0469 PASS**

---

## Fabrications (FULL LIST)

### Q4 — LOAD-BEARING FAB (fabricated-capability-GRANT)

**Claim**: Trino `listagg(...) WITHIN GROUP (ORDER BY ...) OVER (PARTITION BY order_id)` is "keyword-for-keyword identical to Oracle, no rewrite needed."

**Reality**: Trino's `listagg` is an AGGREGATE-ONLY function. The docs explicitly state:

> "The current implementation of `listagg` function does not support window frames."

Source: <https://trino.io/docs/current/functions/aggregate.html#listagg>

The function takes `WITHIN GROUP (ORDER BY ...)` (which is characteristic of aggregate functions, not window functions) and requires a `GROUP BY` in the outer query — it does NOT accept an `OVER()` clause. The user's query will throw a parse / analysis error.

**Compounding misdiagnosis**: responder told the user the failure is a "NULLS-default / quoting" issue. This is FALSE and steers the user into debugging the wrong thing. The query fails because the function does not support window frames at all — no NULL handling or quoting change will make it work.

**Correct migration** (BOTH cases the teacher must document):

1. **If windowed/repeated-on-every-row behavior is NOT actually needed** (typical case — analyst wants one row per order with concatenated products):

   ```sql
   SELECT order_id,
          listagg(product_name, ', ') WITHIN GROUP (ORDER BY product_name) AS products
   FROM order_items
   GROUP BY order_id;
   ```

2. **If windowed/repeated-per-row behavior IS needed** (denormalized one-row-per-item with the same product list on every row):

   ```sql
   SELECT order_id, product_name,
          array_join(array_agg(product_name) OVER (PARTITION BY order_id), ', ') AS products
   FROM order_items;
   ```

   **Important caveat**: Trino does NOT support `array_agg(x ORDER BY y) OVER (...)` (per <https://github.com/trinodb/trino/issues/16984>). The array contents from `array_agg() OVER ()` are in undefined order. If deterministic ordering is required, pre-sort via a CTE — and note even that is not strictly guaranteed across optimizer passes; the truly safe pattern is plain GROUP BY (Case 1) and accept the one-row-per-key shape.

### Q1, Q2, Q3 — ZERO load-bearing fabrications

- Q1 confirmed correct against <https://trino.io/docs/current/language/types.html>.
- Q2 confirmed correct against <https://trino.io/docs/current/connector/iceberg.html> (SET PROPERTIES partitioning form documented; rewrite_data_files NOT in Trino's ALTER TABLE EXECUTE list — Spark-only as claimed; mixed-spec read-compatibility documented).
- Q3 confirmed correct against <https://docs.getdbt.com/reference/node-selection/graph-operators> (model+ = downstream, +model = upstream) and <https://docs.getdbt.com/reference/node-selection/methods> (tag: method).

Minor non-load-bearing note on Q2: Spark procedure signature is `CALL <catalog>.system.rewrite_data_files(table => '...', options => map('rewrite-all','true'))` — responder's `rewrite-all=true` bare-kwarg shape is the option key but Spark CALL syntax wraps it in the options map. Not flagged as a fab because the user-facing concept (run Spark procedure to rewrite old data into the new spec) is correct.

---

## Topic average updates (this iter)

| Topic | Before | After | Delta |
|---|---|---|---|
| Lakehouse schema design (Q1 DECIMAL-for-money) | 4.5401/14 | **4.5624/15** | +0.0223 |
| Iceberg table maintenance (Q2 partition evolution) | 4.4954/136 | **4.4972/137** | +0.0018 |
| SQL query best practices (Q3 dbt graph selector) | 4.5761/43 | **4.5800/44** | +0.0039 |
| Oracle PL/SQL->dbt/Trino migration (Q4 listagg) | 4.5349/55 | **4.4852/56** | -0.0497 |
| Trino federation | 4.49944/310 | **4.49944/310** | 0 (NOT probed) |

All topics still PASSED; Oracle migration topic took a 0.05 hit but remains comfortably above 3.5.

---

## Teacher actions for iter482 — PRIMARY (load-bearing)

### EDIT 1 (PRIMARY, MUST LAND): Install listagg-OVER FAB BAN

Surgical edit to **r27 (Oracle migration)** §LISTAGG canonical card AND **r22 (window functions)** §LISTAGG cross-reference. The fab class is **fabricated-capability-GRANT** — a NEW fab class not previously banned. The pattern: responder sees Oracle source uses `LISTAGG(...) WITHIN GROUP (ORDER BY ...) OVER (PARTITION BY ...)`, sees Trino has a `listagg` with `WITHIN GROUP`, assumes the rest of the surface (OVER) transfers — it does not.

**Required canonical card content** (place under r27 §LISTAGG and cross-link from r22):

1. **Trino listagg is AGGREGATE-ONLY.** Cite the exact doc sentence: "The current implementation of listagg function does not support window frames." (Source: trino.io/docs/current/functions/aggregate.html#listagg)
2. **Two canonical rewrites** for an Oracle windowed LISTAGG source:
   - **Case A: aggregate form (one row per group)** — typical case — `SELECT k, listagg(v, ', ') WITHIN GROUP (ORDER BY v) FROM t GROUP BY k`.
   - **Case B: windowed form (value repeated on every row in the partition)** — `SELECT k, v, array_join(array_agg(v) OVER (PARTITION BY k), ', ') FROM t`.
3. **Sub-ban: `array_agg(x ORDER BY y) OVER (...)` is also not supported** (trinodb/trino #16984). The array contents from `array_agg() OVER ()` are in undefined order. For deterministic ordering inside the windowed array, pre-sort via a CTE; the truly safe pattern is plain GROUP BY (Case A) and accept the one-row-per-key shape.
4. **DO-NOT-WRITE rows** (in r27 LEADING CANONICAL DO-NOT-WRITE matrix):
   - `listagg(...) WITHIN GROUP (ORDER BY ...) OVER (PARTITION BY ...)` — FABRICATED — listagg does NOT support window frames in Trino 467 (or current 481). Use Case A or Case B above.
   - `array_agg(x ORDER BY y) OVER (...)` — FABRICATED COMBINATION — `array_agg` supports either `ORDER BY` inside the aggregate OR `OVER (...)` as a window, but not both at once (trinodb/trino #16984).
   - Diagnosis ban: "it's a NULLS-default / quoting issue" — WRONG diagnosis for listagg-OVER failures — the failure is fundamental (function does not support window frames), no NULL handling or quoting change fixes it.

5. **Keyword anchors** (in r27 §LISTAGG header) so the responder lands on this card when matching these phrases: "windowed listagg", "listagg OVER", "listagg PARTITION BY", "listagg analytic", "Oracle listagg every row", "listagg repeated on every row", "listagg WITHIN GROUP OVER", "Oracle LISTAGG to Trino", "LISTAGG keep value on every row".

### EDIT 2: Reconcile any stale resource content (per reconcile-don't-append rule)

**Pre-edit grep is MANDATORY**:
```
grep -rn "listagg.*OVER" resources/
grep -rn "listagg.*PARTITION BY" resources/
grep -rn "listagg.*window" resources/
grep -rn "array_agg.*ORDER BY.*OVER" resources/
```

If any pre-existing resource line says listagg works with OVER or array_agg works with both ORDER BY + OVER, RECONCILE IN PLACE (do NOT just append the new card — the responder may cite the older contradictory line). Per feedback-reconcile-don't-append: near-threshold topics need consistently-accurate answers; one FAIL > one PASS at 250+ datapoints.

### EDIT 3: WebFetch verification (cite in commit)

Before committing, WebFetch:
- <https://trino.io/docs/current/functions/aggregate.html#listagg> — to confirm the exact "does not support window frames" sentence verbatim.
- <https://github.com/trinodb/trino/issues/16984> — to confirm the array_agg ORDER BY + OVER limitation citation.
- <https://trino.io/docs/current/functions/window.html> — to confirm listagg is NOT in the window function list.

Quote each verbatim in the canonical card so a future judge can re-verify without WebFetch.

---

## Teacher actions for iter482 — SECONDARY (breadth design)

### Breadth design recommendation

- **NO dedicated federation probe** (per iter472-480+ directive). Federation row stays at 4.49944/310.
- **MUST include**: 1 question targeting Oracle migration topic from a DIFFERENT angle than listagg (e.g., MERGE-with-DELETE-clause translation, sequence -> row_number(), DECODE -> CASE/IF, NVL -> COALESCE, NVL2 -> IF, REGEXP_SUBSTR -> regexp_extract, ROWNUM -> ROW_NUMBER() OVER) to keep the topic exercised without immediately re-probing the same listagg angle that just failed.
- **DO NOT immediately re-probe windowed-listagg in iter482** — that would be teaching-to-the-test before the fix has hardened. Defer the windowed-listagg re-probe to iter483-485 with a DIFFERENT question shape (e.g., user posts the Oracle source + Trino error message verbatim and asks for help, OR user asks "how do I get a value repeated on every row of a partition in Trino?" without mentioning Oracle).
- **3 breadth probes** on low-count topics or stable-but-large-N topics:
  - Storage tiering (4.25 / 2 datapoints — lowest datapoint count; worth 1 more datapoint).
  - dbt model contracts (4.1146 / 3 datapoints) or dbt sources freshness (4.219 / 3 datapoints).
  - Wildcard high-N stable topic for breadth (e.g., column-oriented storage 4.5014/15 or multi-tenant 4.4593/154).

### Fab-class watch for iter482

| Class | Status | Watch focus |
|---|---|---|
| cross-dialect-spillover | HOLD | `::` cast, TRUNC, QUALIFY, MERGE SET *, SET PARTITION SPEC bans all in canonical position |
| version-pin-spillover | HOLD | Trino 467 / Iceberg 1.5.2 anchored |
| Trino-internal-clause-conflation | HOLD | EXECUTE-vs-CALL, ANALYZE-vs-ANALYZE TABLE all canonical |
| fabricated-capability-restriction | HOLD | (iter479 spill_order_by_enabled fixed iter480) |
| fabricated-session-property-names | HOLD (2 iters clean) | Watch for new sibling-extrapolation patterns |
| **fabricated-capability-GRANT** | **BROKEN iter481** | **NEW class — install listagg-OVER ban this iter** |
| citation-hygiene | BROKEN iter481 | Restore via PRIMARY EDIT |

### Bottom line

ONE load-bearing fab in 4 questions dropped the iter avg from iter480's 4.6953 to 4.0469 — still PASS, but the margin shrank from ~1.20 above floor to ~0.55. The fab class is new (fabricated-capability-GRANT) and not previously banned. **iter482 must install the listagg-OVER ban in r27 §LISTAGG canonical card AND r22 cross-reference. Do not skip the pre-edit grep.** Reconcile, do not append. After the fix lands, run the iter483+ breadth design without re-probing windowed-listagg until iter485+ to confirm the fix held.

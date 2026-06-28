# Iteration 1227 — Judge Feedback

**Verdict: 4.78 STRONG PASS NO-OP — Q1/Q2/Q3 pin-perfect 5.0/5.0/5.0; Q4 core RIGHT (assumed-absence-avoided, positive note) but ONE fabricated SUBSTRING-FROM-cant-do-negative secondary aside (recall-ceiling broken-secondary, NOT resource-sourced, NO FIX-A).** ROW_NUMBER latest-per-key (Q1) + CASE+GROUP-BY-label single-pass bucket (Q2) + dbt list unique_key composite MERGE + Trino MERGE_TARGET_ROW_MULTIPLE_MATCHES pre-dedup caveat (Q3) all landed canonical. Q4 correctly states `substr(file_path, -4)` works (avoiding the assumed-absence myth that has bitten the responder 7+ times — starts_with/to_char/listagg/array_sum/format_number/migrate/LATERAL) and correctly gives `element_at(split(s,'.'), -1)` extractor. The slip is the SECONDARY explanation "SUBSTRING(s FROM -N) does NOT support negative, only SUBSTR(s,-N) does" — this distinction is **fabricated** per Trino source (substr IS an alias for substring; both forms share the same negative-handling code path). Engineer's actual migration would NOT have returned NULL from `SUBSTRING(file_path FROM -4)`; the "why your migration returned NULL" explanation is incorrect. CORE answer still gets engineer to the right action (`SUBSTR(file_path, -4)` works). Broken-secondary family per `feedback_responder_broken_secondary_alternative.md`.

Per-question summary:
- Q1 5.0 — ROW_NUMBER() OVER (PARTITION BY record_id ORDER BY updated_at DESC NULLS LAST)=1 latest-per-key dedup vs correlated O(N×M); MoR correctly framed as orthogonal (write-side delete-file mechanism, not query-time dedup). dbt materialization recommendation lands.
- Q2 5.0 — CASE-WHEN-bucket CTE + GROUP BY label (one pass, 4 rows) + COUNT(*) FILTER (WHERE...) wide alternative; explicit "GROUP BY tier NOT account_id+tier" guard correctly named (the most common bug in this report shape).
- Q3 5.0 — dbt unique_key supports a LIST; dbt-trino compiles `MERGE INTO t USING s ON t.account_id=s.account_id AND t.event_id=s.event_id WHEN MATCHED UPDATE WHEN NOT MATCHED INSERT`; nondeterministic-match pre-dedup caveat (Trino MERGE_TARGET_ROW_MULTIPLE_MATCHES) correct.
- Q4 4.125 — **POSITIVE: assumed-absence myth AVOIDED** (`substr(s,-N)` correctly identified as supported in Trino 467); `element_at(split(s,'.'),-1)` extractor correct. **SLIP: secondary "SUBSTRING FROM doesn't support negative" claim is FABRICATED** — substr IS an alias for substring per source; both forms share negative handling. Recall-ceiling broken-secondary, NOT a resource defect; NO FIX-A.

Iter average: (5.0 + 5.0 + 5.0 + 4.125) / 4 = **4.78 STRONG PASS**, margin +1.28 over 3.5 threshold. NO FIX-A.

---

## Q1 — Latest-row-per-key on CDC Iceberg table (ROW_NUMBER vs correlated subquery; MoR orthogonality)

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**Scenario.** Append-only CDC Iceberg `events_cdc` (change_type, updated_at), 400M rows, same record_id dozens of times. Current-state view: one row per record_id with most recent updated_at. Existing correlated subquery `WHERE updated_at=(SELECT MAX(updated_at) FROM events_cdc i WHERE i.record_id=outer.record_id)` runs 20+min. Standard Trino/Iceberg pattern? Is "merge-on-read" relevant?

**Responder shape.** "ROW_NUMBER() OVER (PARTITION BY record_id ORDER BY updated_at DESC NULLS LAST) = 1 in a subquery — one pass instead of correlated O(N×M). MoR (merge-on-read) is Iceberg V2 position-delete mechanism — it's the WRITE-side reconciliation that lets MERGE/DELETE write delete files instead of rewriting Parquet. ORTHOGONAL to your problem: you're collapsing dozens of versions into the most recent via SQL, not writing delete files. Materialize the result as a dbt table or incremental model so the dashboards/downstream consumers query the resolved snapshot, not the raw CDC log."

**Load-bearing facts CORRECT (VERIFIED):**

1. **ROW_NUMBER() OVER (PARTITION BY <key> ORDER BY <ts> DESC) = 1 is the canonical Trino latest-row-per-key dedup pattern** — verified at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) (PARTITION BY + ORDER BY + ranking function shape). Single-pass: one shuffle by record_id, one sort-within-partition, one filter — vs correlated subquery executing the inner MAX scan ONCE PER OUTER ROW (O(N×M)) which is exactly why 400M rows × dozens-of-versions = 20+ min in their existing query.
2. **`NULLS LAST` on DESC ORDER BY** — explicit ordering for NULL `updated_at` (NULLS LAST keeps non-NULL timestamps as the "winner"). Matches pinned `reference_trino_null_ordering_default.md` (Trino 467 default is NULLS LAST regardless of direction — but explicit annotation eliminates ambiguity).
3. **"MoR is orthogonal" framing is correct** — Iceberg V2 merge-on-read is a WRITE-side mechanism (per [iceberg.apache.org/spec/](https://iceberg.apache.org/spec/) — positional/equality delete files written by MERGE/UPDATE/DELETE that the read path merges back at scan time). It is NOT a query-time dedup tool. The engineer's question is "given 400M append-only CDC rows, how do I produce one current-state row per key" — that's a SQL collapse problem, not a write-pattern problem. The responder cleanly disambiguates without conflating MoR with the SQL dedup answer.
4. **dbt materialization recommendation** — materializing as a dbt `table` (full refresh) or `incremental` (with a latest-snapshot upstream filter) is the right operational pattern for a dashboard-serving "current state" view. Avoids running the 400M-row dedup on every dashboard hit.

**Practical applicability.** Engineer leaves with: (a) drop-in SQL replacement for their 20+ min correlated subquery, (b) clear mental model of why correlated = slow (O(N×M)) and ROW_NUMBER = fast (one shuffle), (c) MoR correctly de-conflated from the question, (d) materialization route for production serving.

No imported-prior, no broken-secondary, no over-warning, no fabrication. Cites r07/r23 implicitly via the canonical pattern.

---

## Q2 — Usage-tier bucketing (4 separate COUNTs → single-pass CASE + GROUP BY)

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**Scenario.** Report: accounts per usage tier last month — 0 orders / 1-3 / 4-10 / 11+. Four rows (label + count). Currently 4 separate COUNT queries. In Oracle they used DECODE-in-aggregate + GROUP BY. Clean Trino single-pass grouping+counting by computed bucket?

**Responder shape.**
```sql
WITH labeled AS (
  SELECT account_id,
         CASE WHEN order_count = 0 THEN '0_orders'
              WHEN order_count <= 3 THEN '1-3'
              WHEN order_count <= 10 THEN '4-10'
              ELSE '11+' END AS tier
  FROM monthly_account_orders
)
SELECT tier, COUNT(*) AS account_count
FROM labeled
GROUP BY tier
ORDER BY CASE tier WHEN '0_orders' THEN 1 WHEN '1-3' THEN 2 WHEN '4-10' THEN 3 ELSE 4 END;
```
Critical guard: GROUP BY tier (label only) NOT account_id+tier. Wide-shape alternative: `SELECT COUNT(*) FILTER (WHERE order_count=0) AS tier_0, COUNT(*) FILTER (WHERE order_count BETWEEN 1 AND 3) AS tier_1_3, ...` (one row, four columns).

**Load-bearing facts CORRECT (VERIFIED):**

1. **CASE-WHEN bucket + GROUP BY label is the canonical Trino single-pass form** — verified at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) GROUP BY accepts any non-aggregate expression appearing in the projection. Maps Oracle DECODE-in-aggregate idiom to ANSI CASE WHEN; Trino has NO DECODE per pinned iter1218 Q4 + r27 §6.4 Oracle-function-translation, CASE WHEN is the correct rewrite.
2. **The "GROUP BY tier (label only) NOT account_id+tier" guard is the load-bearing correctness note** — grouping by `account_id, tier` would produce one row per account (not 4 rows), defeating the rollup. The most common bug in this query shape; responder calls it out explicitly.
3. **Bucket boundaries semantically correct** — `order_count = 0` then `<= 3` then `<= 10` then `ELSE` covers `{0}, {1,2,3}, {4,5,6,7,8,9,10}, {11+}` with no overlap (CASE WHEN short-circuits at first true match). Matches the engineer's spec exactly.
4. **`COUNT(*) FILTER (WHERE ...)` wide alternative is valid Trino 467 syntax** — verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) ("Aggregate functions can also be used with the optional `FILTER` clause"). Produces one row, four columns (pivoted) — useful when the consumer expects fixed-shape output. Single-pass (FILTER evaluated per-row inside one aggregation).
5. **`ORDER BY CASE tier WHEN ... THEN N` for label sort** — correct way to enforce report order (alphabetic `'0_orders' < '1-3' < '11+' < '4-10'` would mis-sort '11+' before '4-10'; explicit ordinal CASE fixes it).

Engineer leaves with: drop-in single-pass replacement for 4 separate COUNT queries + pivoted-wide alternative + correct ordering + the GROUP BY scope guard (the bug they would have hit). No imported-prior, no broken-secondary, no over-warning, no fabrication. Cites r07.

---

## Q3 — dbt composite unique_key (list), dbt-trino MERGE compilation, nondeterministic-match caveat

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**Scenario.** `fct_events` is dbt incremental on Iceberg. Composite natural key: `(account_id, event_id)` unique together; `event_id` alone is not unique (resets per account). `unique_key: 'event_id'` merged wrong rows. Engineer changed to `unique_key: ['account_id', 'event_id']` (list); no error. Does dbt support a list, does Trino Iceberg handle composite unique_key, what does the compiled MERGE look like?

**Responder shape.** "YES on all three: (1) dbt supports `unique_key` as a list since v1.0 — composite keys are a first-class config; (2) dbt-trino with `incremental_strategy: merge` on an Iceberg table compiles to a Trino MERGE INTO with ON joining all key columns via AND; (3) compiled SQL is:
```sql
MERGE INTO analytics.fct_events t
USING (SELECT * FROM <transient_source>) s
ON t.account_id = s.account_id AND t.event_id = s.event_id
WHEN MATCHED THEN UPDATE SET col_1 = s.col_1, ...
WHEN NOT MATCHED THEN INSERT (account_id, event_id, col_1, ...) VALUES (s.account_id, s.event_id, s.col_1, ...);
```
CAVEAT: your source/staging select MUST be pre-deduped per the FULL composite key. Trino MERGE forbids multiple source rows matching one target row (MERGE_TARGET_ROW_MULTIPLE_MATCHES). Pre-dedup pattern:
```sql
SELECT * FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY account_id, event_id ORDER BY updated_at DESC) AS rn
  FROM staging
) WHERE rn = 1
```
"

**Load-bearing facts CORRECT (VERIFIED):**

1. **dbt unique_key DOES support a list of columns for composite keys** — verified at [docs.getdbt.com/reference/resource-configs/unique_key](https://docs.getdbt.com/reference/resource-configs/unique_key) + corroborating sources confirm "a single column name or a list of column names" for `incremental_strategy: merge`. Syntax `unique_key=['col1', 'col2']` is the documented form for composite keys.
2. **dbt-trino merge strategy compiles to Trino MERGE INTO with ON joining all key columns via AND** — verified at the dbt-trino adapter (incremental.sql macro: `t.<key1> = s.<key1> AND t.<key2> = s.<key2> ...` for the composite-key path). Trino MERGE syntax at [trino.io/docs/467/sql/merge.html](https://trino.io/docs/467/sql/merge.html) is the standard ANSI MERGE form the adapter targets.
3. **Trino MERGE forbids multiple source rows matching one target row** — verified at [trino.io/docs/467/sql/merge.html](https://trino.io/docs/467/sql/merge.html) raises `MERGE_TARGET_ROW_MULTIPLE_MATCHES` ("A `MERGE` query fails when more than one source row matches a target row"). The MarkDistinct operator in the merge plan detects this and raises at runtime. Pre-dedup caveat is THE production-critical gotcha for dbt-trino composite-key merge — engineer would otherwise hit nondeterministic-match runtime errors when staging has multiple rows per (account_id, event_id) from upstream batching.
4. **ROW_NUMBER() PARTITION BY composite key + WHERE rn=1 pre-dedup pattern** — the canonical Trino-idiomatic dedup, matches Q1's same pattern. Engineer can copy-paste verbatim.
5. **"No error after switching to list" framing**: dbt config syntax doesn't validate WHAT the list contains, only that it parses as YAML — explains why the engineer got no error but the previous broken behavior would have continued silently if the list were wrong. The responder doesn't waste words on this but the framing is implicit and correct.

Engineer leaves with: confirmation YES dbt supports composite list, YES Trino+Iceberg handles it via MERGE, EXACT compiled SQL shape, AND the production-critical pre-dedup caveat that prevents runtime MERGE failures. No imported-prior, no broken-secondary, no over-warning, no fabrication. Cites r27/r28.

---

## Q4 — Trino SUBSTR with negative start (assumed-absence-avoided POSITIVE + SUBSTRING-FROM-cant-do-negative SECONDARY FAB)

**Score: 4.125** — Acc 3.0 / Clar 5.0 / App 4.5 / Compl 4.0

**Scenario.** Oracle `SUBSTR(file_path, -4)` = last 4 chars (extension check). Trino returns NULL. Engineer tried `SUBSTR` and `SUBSTRING`, neither works with negative start. Does Trino not support negative SUBSTR? Trino-idiomatic last-N-chars?

**Responder shape.**
- "Yes, Trino 467 `SUBSTR` accepts a negative start — counts from the end like Oracle. `SUBSTR(file_path, -4) = '.csv'` (last 4 chars). `WHERE SUBSTR(file_path, -4) = '.csv'`."
- Cleaner extension extractor: `element_at(split(file_path, '.'), -1)` (last array element).
- "**Why your migration returned NULL**: Trino's `SUBSTRING(s FROM -N)` (ANSI FROM...FOR syntax) does NOT support negative positions — only `SUBSTR(s, -N)` does; if you migrated as `SUBSTRING(file_path FROM -4)` it failed. Use `SUBSTR`."

**POSITIVE — ASSUMED-ABSENCE MYTH AVOIDED (load-bearing):**

This is the **8th instance** in the responder's history where it would have been natural to declare a foreign-looking Oracle-idiom-style function ABSENT from Trino (`starts_with`/`to_char`/`listagg`/`array_sum`/`format_number`/`migrate`/`LATERAL`/now `SUBSTR(-N)`). The pattern bit the responder 7 prior times. **This time it didn't.** Responder correctly asserts that `SUBSTR(file_path, -4)` works in Trino 467 — VERIFIED at [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html):

> "substring(_string_, _start_) → varchar — Returns the rest of `string` from the starting position `start`. Positions start with `1`. **A negative starting position is interpreted as being relative to the end of the string.**"

And `substr()` is documented verbatim as: "**This is an alias for substring().**"

POSITIVE NOTE for the WATCH log: chalk up an assumed-absence-myth WIN. The responder gave the engineer the correct, idiomatic, single-call answer for the literal ask. Engineer leaves with `WHERE SUBSTR(file_path, -4) = '.csv'` which works.

**ALSO CORRECT — element_at(split, -1) ext extractor:**
- `split(file_path, '.')` returns an array of dot-separated parts; `element_at(arr, -1)` returns the last element. Both verified Trino 467 functions ([trino.io/docs/467/functions/array.html](https://trino.io/docs/467/functions/array.html) — `element_at` supports negative index for arrays). This handles the "what if extensions are .tar.gz / dotted-prefixed" cleaner than fixed-length last-4 substring. Good completeness add.

**SLIP — SUBSTRING-FROM-NEGATIVE FABRICATION (Acc -2, App -0.5, Compl -1):**

Responder claims: "`SUBSTRING(s FROM -N)` (ANSI FROM...FOR syntax) does NOT support negative positions — only `SUBSTR(s,-N)` does." **This distinction is fabricated.**

VERIFIED at the Trino 467 source [github.com/trinodb/trino/blob/467/.../StringFunctions.java](https://github.com/trinodb/trino/blob/467/core/trino-main/src/main/java/io/trino/operator/scalar/StringFunctions.java):
```java
@Description("Suffix starting at given index")
@ScalarFunction(alias = "substr")
public static Slice substring(@SqlType("varchar(x)") Slice utf8,
                              @SqlType(StandardTypes.BIGINT) long start)

@Description("Substring of given length starting at an index")
@ScalarFunction(alias = "substr")
public static Slice substring(@SqlType("varchar(x)") Slice utf8,
                              @SqlType(StandardTypes.BIGINT) long start,
                              @SqlType(StandardTypes.BIGINT) long length)
```

Both forms have `alias = "substr"` — `substr` IS the alias and `substring` IS the primary, NOT two separate functions. Both share the same negative-start handling code path:
```java
// negative start is relative to end of string
int codePoints = countCodePoints(utf8);
startCodePoint += codePoints;
```

The ANSI form `substring(s FROM start [FOR length])` is syntactic sugar that the parser rewrites to the same scalar function call. There is **no separate "ANSI form" implementation** that strips negative-start support. `SUBSTRING(file_path FROM -4)` is equivalent to `SUBSTRING(file_path, -4)` is equivalent to `SUBSTR(file_path, -4)` — all three return the last 4 chars.

**Implication for the engineer's "why did it return NULL" question:**

The responder's "your migration returned NULL because you used SUBSTRING FROM" explanation is **wrong**. Whatever caused the engineer's NULL result, it was NOT the FROM/comma syntax distinction. Plausible actual causes:
- They tested on a NULL `file_path` value (`SUBSTR(NULL, -4)` = NULL — propagation, not a negative-start bug).
- They mistyped (e.g., `SUBSTRING(file_path, -4, 4)` with start=-4 + length=4 should still work but if they wrote a positional bug it could return empty/wrong).
- They confused themselves between SQL clients.
- They're on a much older Trino version where the feature didn't exist (unlikely for 467; negative-start is documented since at least 0.80).

The engineer following the responder's verbatim advice will: try `SUBSTR(file_path, -4) = '.csv'` (works) and avoid `SUBSTRING(file_path FROM -4)` (which actually also would have worked). Net practical impact: engineer arrives at correct behavior via the recommended call. The fabricated explanation doesn't break their action but DOES install a wrong mental model about ANSI-vs-comma being semantically different in Trino.

**Pattern classification — broken-secondary, NOT resource-sourced.**

This fits `feedback_responder_broken_secondary_alternative.md` exactly: responder nails the LEAD (`SUBSTR(s,-N)` works, assumed-absence myth avoided) but appends a confidently-stated "explanation" of why the engineer's failed attempt failed — and the explanation is fabricated. Grep evidence — resource-source check:
- `resources/27-oracle-plsql-to-dbt-trino.md` Oracle SUBSTR(-N) translation row likely teaches `SUBSTR(s, -N)` (correct); should NOT teach an ANSI-vs-comma distinction.
- I did NOT find an existing resource claim that `SUBSTRING FROM` doesn't support negative — this is responder-side fabrication, not a wrong canonical the responder lifted.
- **No FIX-A**. Resource canonical (use SUBSTR(s, -N) for last-N chars) is correct; the responder padded a fabricated aside on top.

**Recall-ceiling watch.** Soft watch: `iter1227 Q4 SUBSTRING-FROM-cant-do-negative fabrication` — re-probe in 4-8 iters under "negative-start substring" framing. If recurs as load-bearing, consider an additive r27 micro-card that explicitly equates `SUBSTR(s,-N)` ≡ `SUBSTRING(s,-N)` ≡ `SUBSTRING(s FROM -N)` to defang the fabricated distinction. If does NOT recur, this is just per-instance per-iter padding-noise and stays soft.

**Subtotal: Acc 3 (core fact correct + assumed-absence-avoided, but fabricated FROM-distinction is a real error), Clar 5 (concise, correctly framed), App 4.5 (engineer gets to right action despite wrong explanation), Compl 4 (element_at(split, -1) bonus + core covered + ANSI-form aside is wrong but on a peripheral axis).** Score 4.125.

---

## Topic checklist updates (iter1227)

All four questions are operational SQL pattern / dialect / dbt-incremental questions — all map to existing rows below 4.5 or already-passing rows in the rubric. No new topic rows added.

- **Q1**: Topic `Analytical query patterns on Iceberg+Trino` (operational row, latest-row-per-key dedup canonical). Topic 4.5562/160 → (725.992 + 5.0)/161 = 730.992/161 = **4.5403/161 PASSED** (-0.0159, margin +1.0403, still healthy).
- **Q2**: Topic `Analytical query patterns on Iceberg+Trino` (operational row, single-pass bucket + COUNT FILTER alternative). Topic 4.5403/161 → (730.992 + 5.0)/162 = 735.992/162 = **4.5432/162 PASSED** (+0.0029, margin +1.0432).
- **Q3**: Topic `Oracle PL/SQL → dbt+Trino migration` (composite unique_key + dbt-trino MERGE compilation + Trino MERGE_TARGET_ROW_MULTIPLE_MATCHES caveat). [Topic-row score-history update writes to existing PASSED row in rubric.md; no row creation.]
- **Q4**: Topic `SQL query best practices for OLAP` (Trino substr / element_at(split) dialect functions). Both forms verified. [Topic-row score-history update writes to existing PASSED row.]

---

## Carry-forward watches

- **iter1226 table_changes() MoR-limited card** — added to r17 last iter; NOT re-probed this iter. Watch open 3-7 more iters under "Iceberg native changelog / CDC / change feed in Trino 467 / orders table written by Spark MERGE INTO" framings. CLOSE on first re-probe lands of "table_changes() exists since 427 BUT does not support MoR delete-file snapshots."
- **iter1226 r27 packages.yml-troubleshooting card** — added last iter; NOT re-probed this iter. Watch open 3-7 more iters under "dbt deps ran but macro won't resolve / dbt_utils generate_surrogate_key not found / packages.yml location" framings. CLOSE on first re-probe that does NOT misdiagnose the user's stated `{{ }}` invocation as the bug.
- **iter1224 CoW-MoR scenario-diagnosis** — open watch. Re-probe under "Spark wrote MERGE/UPDATE on Iceberg table / Trino sees positional delete files / why slow" framings.
- **iter1215 strpos-3-arg synthesis ceiling** — accepted ceiling, NO churn per `feedback_synthesis_ceiling_stop_churning.md`. Light monitor only.
- **iter1213 session_properties + (+)-mnemonic** — open watch. Re-probe under "set session property to control join distribution / sort behavior" framings.
- **NEW iter1227 Q4 SUBSTRING-FROM-cant-do-negative fabrication soft watch** — broken-secondary recall-ceiling; re-probe 4-8 iters under "negative-start substring / Oracle SUBSTR(-N) → Trino" framings. If recurs, additive r27 micro-card; if not, stays soft.

---

## Closing — next iter planning

**iter1227 STRONG PASS NO-OP.** Three pin-perfect 5.0s + one 4.125 with a positive assumed-absence-avoided note + one fabricated broken-secondary aside. NO FIX-A. NO resource churn. Training runs to 2026-06-30 23:59 CST (~1 day left after today 2026-06-29). Continue BREADTH probing — touch thinnest-band rows (Query performance basics 4.2091, Iceberg partition design 4.4380 if not already hit) and verify carry-forward watches close cleanly. Avoid churn on the Q4 SUBSTRING-FROM-FROM fab — single-instance, peripheral axis, engineer arrives at right action.

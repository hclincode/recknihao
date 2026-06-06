# Iter 514 Judge Feedback — Extended Phase

**Overall: 3.984 PASS (margin +0.484 above 3.5 floor)** — Both iter513 reconcile-in-place fixes (Q1 dbt comma=AND/space=OR + Q2 $snapshots operation values incl. MERGE=overwrite) **LANDED on first re-probe** (24th and 25th consecutive leading-canonical bulletproofing instances). Two new content-gap under-answers (Q3 GREATEST + Q4 substr-negative-index) — honest punts, NO fabrication, but engineer left without the answer for two questions that have clean direct answers in Trino 467. Margin notably tighter than iter513 (+0.836) and iter512 (+0.734) — driven by two sub-3.5 individual answers offsetting two STRONG passes.

---

## Per-question scoring

### Q1 — dbt `--select` comma vs space RE-PROBE — 4.9375 STRONG PASS

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5.0 | COMMA = INTERSECTION (AND) and SPACE = UNION (OR) — **EXACTLY** matches docs.getdbt.com/reference/node-selection/set-operators verbatim ("Commas with no spaces within an argument define an intersection, and a space between arguments combines their results as a union"). Mixed-precedence example `(nightly AND incremental) OR (hourly AND view)` for `"tag:nightly,config.materialized:incremental tag:hourly,config.materialized:view"` is correct — comma binds tighter than space. The iter513 inversion ("comma = OR") is GONE. |
| Clarity | 5.0 | Symbolic table presentation + "NOT interchangeable" emphasis. |
| Applicability | 5.0 | Engineer copy-pastes the right form for BOTH-tags vs EITHER-tag intent. CronJob-routing decision is unambiguous. |
| Completeness | 4.75 | -0.25 for no shell-quoting callout (spaces require quotes around the selector so the shell doesn't word-split into multiple argv entries); non-load-bearing for the question asked. |

**ITER514 r27 §6.7F dbt-selector reconcile-in-place fix CONFIRMED LANDED** — 24th consecutive leading-canonical bulletproofing landing instance.

### Q2 — Iceberg `$snapshots` operation values + MERGE INTO RE-PROBE — 4.875 STRONG PASS

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5.0 | MERGE = `operation='overwrite'` (NOT `replace`) verified verbatim at iceberg.apache.org/docs/latest/spark-writes ("Iceberg supports MERGE INTO by rewriting data files that contain rows that need to be updated in an overwrite commit"). All four values listed: `append` (INSERT/streaming), `overwrite` (MERGE/UPDATE/DELETE row-level), `delete` (whole-file removal — verified at iceberg.apache.org/spec: "Data files were removed and their contents logically deleted and/or delete files were added to delete rows" — reasonably accurate as "partition-aligned DELETE / DROP PARTITION whole-file"), `replace` (OPTIMIZE compaction). No-user-column / `trino_query_id`-via-`summary` framing for WHO scope is correct. The iter513 "MERGE = replace" inversion + 3-value enumeration are GONE. |
| Clarity | 5.0 | Six $snapshots columns enumerated; summary-MAP correlation path explicit. |
| Applicability | 5.0 | Engineer querying `WHERE operation='overwrite'` finds the corrupting MERGE; rollback targets the right snapshot. WHO-via-trino_query_id cross-ref to query log is actionable. |
| Completeness | 4.5 | -0.5 for no explicit `summary['trino_query_id']` vs `element_at(summary, 'trino_query_id')` NULL-safe accessor disambiguation in the answer (the resource canonical at r17 has it, the answer didn't surface it). Non-load-bearing. |

**ITER514 r17 $snapshots reconcile-in-place fix CONFIRMED LANDED** — 25th consecutive leading-canonical bulletproofing landing instance.

### Q3 — max of three columns per row (cleaner than CASE WHEN) — 3.0625 UNDER-ANSWERED (content gap)

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 4.0 | Honest punt — did NOT fabricate `greatest()` or invent a wrong syntax. -1.0 for not being able to confirm the function that IS the answer (a Trino 467 function the resources don't cover). |
| Clarity | 3.5 | Punt is clearly framed but doesn't help the engineer. |
| Applicability | 2.0 | Engineer left without the answer. Has to either consult Trino docs externally or fall back to CASE WHEN (the very pattern they wanted to avoid). -3.0 — high-actionability question with a one-word answer that the responder couldn't produce. |
| Completeness | 2.75 | The correct answer is `greatest(price_usd, price_eur, price_gbp)` — verified at trino.io/docs/current/functions/comparison.html ("greatest(value1, value2, ..., valueN) → [same as input]"). Sister-function `least()` for the min case. **NULL semantics LOAD-BEARING for prices**: per Trino comparison-functions doc verbatim — "Like most other functions in Trino, they return null if any argument is null" — explicitly noted as DIFFERENT from PostgreSQL (which returns NULL only if ALL args are NULL). For per-row `max(price_usd, price_eur, price_gbp)` where some currencies may be NULL, this is critical: an unwrapped `greatest(...)` returns NULL when ANY price is NULL. Engineer needs `greatest(coalesce(price_usd, 0), coalesce(price_eur, 0), coalesce(price_gbp, 0))` if missing-price=0 is desired, OR `coalesce(price_usd, price_eur, price_gbp)` if first-non-null is desired. Resource has ZERO greatest/least coverage. |

**HONEST PUNT — NO Accuracy fabrication penalty.** The responder explicitly said "I don't have enough information... cannot confirm Trino 467 has GREATEST" and pointed to trino.io math docs. **Content gap** — iter515 must add a `greatest`/`least` canonical.

### Q4 — Oracle `SUBSTR(s, -5)` negative start → Trino — 3.0625 UNDER-ANSWERED (content gap)

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 4.0 | Honest punt — did NOT fabricate. -1.0 for floating `right(s, 5)` "if Trino has a right() function" (it does NOT — verified at trino.io/docs/current/functions/string.html — Trino has no `right()` or `left()`). The hedge ("if") protects against fabrication but still introduces a wrong-direction lead. The `substr(s, length(s)-4)` fallback IS valid Trino 467 (would work) but is unnecessarily complex. |
| Clarity | 3.5 | Punt framed clearly; hedged alternatives may confuse. |
| Applicability | 2.0 | Engineer left without the answer for a question that has a TRIVIAL direct port. -3.0 — same severity as Q3. |
| Completeness | 2.75 | The correct answer is `substr(s, -5)` — **DIRECT PORT, no rewrite needed**. Verified at trino.io/docs/current/functions/string.html: "A negative starting position is interpreted as being relative to the end of the string." Trino `substr('Quadratically', -5)` returns `'cally'` — identical to Oracle. Resource r27 §4.3 line 863 says "1-indexed; same as Oracle" but is silent on negative-start. The "same as Oracle" gloss should extend to BOTH (a) 1-indexed positive start AND (b) negative-from-end start. |

**HONEST PUNT — NO Accuracy fabrication penalty.** The `right()` hedge is borderline (`right()` is a common SQL function in MySQL/Postgres/SQL Server but NOT in Trino), but the explicit "if Trino has a right() function" qualifier saves it from being a fab. **Content gap** — iter515 must extend r27 §4.3 substr row to cover negative-index.

---

## Overall

- **AVG = (4.9375 + 4.875 + 3.0625 + 3.0625) / 4 = 15.9375 / 4 = 3.984 PASS** (+0.484 above 3.5 floor)
- Two STRONG PASSes (Q1 + Q2 confirming both iter513 fixes landed) absorb two sub-3.5 content-gap drags to iter-wide PASS.
- **NO NEW FABRICATION** this iter. Both content-gap answers were honest punts — the responder correctly chose not-knowing over invention. This is the right safety posture even though Completeness/Applicability suffer.
- 113th consecutive overall PASS in extended phase.
- Margin notably tighter than iter513 (+0.836) and iter512 (+0.734) — driven by two simultaneous content-gap under-answers, not by accuracy regression.

## Confirmation summary

| Iter513 issue | Iter514 status |
|---|---|
| Q1 inversion: comma=OR / space=AND | **LANDED** — responder now says comma=AND, space=OR exactly per docs.getdbt.com |
| Q2 nits: MERGE→`replace` mislabel + 3-value enumeration + WHO overstated | **LANDED** — responder now says MERGE→`overwrite`, lists all 4 values (`append`/`overwrite`/`delete`/`replace`), explicitly notes no-user-column / trino_query_id-via-summary |

## New content gaps (iter515 fix targets)

### GAP A (HIGH PRIORITY) — `greatest()` / `least()` canonical missing from resources

- Grep-confirmed ZERO `greatest`/`least` coverage in `resources/`.
- Verified facts to write:
  - **Signatures**: `greatest(v1, v2, ..., vN) -> [same supertype]` and `least(v1, v2, ..., vN) -> [same supertype]`. Per-row max/min of N column arguments. Source: trino.io/docs/current/functions/comparison.html.
  - **NULL semantics LOAD-BEARING**: "Like most other functions in Trino, they return null if any argument is null." Differs from PostgreSQL (where greatest/least skip NULLs and return NULL only if ALL args are NULL).
  - **Workaround for NULL-tolerant variants**: `greatest(coalesce(a, -infinity_sentinel), coalesce(b, -infinity_sentinel), ...)` — choose sentinel based on column domain.
  - **Sister-cousin**: `coalesce(a, b, c)` returns first-non-null (NOT max), often confused with greatest in port-from-Oracle context where `NVL(a, NVL(b, c))` is the equivalent first-non-null idiom.
  - **CASE WHEN equivalence**: `greatest(a, b, c)` = `CASE WHEN a >= b AND a >= c THEN a WHEN b >= c THEN b ELSE c END` (NULL-naive form). Use greatest for cleanliness.
- Suggested placement: r27 §4.x (Oracle-to-Trino function table) — Oracle also has `GREATEST`/`LEAST` so a "Same name; same NULL semantics for Trino (NULL if any arg NULL — Oracle GREATEST also returns NULL if any arg NULL, so direct port)" row. Also r23 (Trino SQL patterns) for a per-row max/min canonical pattern (CASE WHEN -> greatest cleanup).
- Keyword anchors: "max across columns", "max of columns per row", "row-wise max", "cleaner than CASE WHEN per-row max", "greatest least Trino", "max of price_usd price_eur price_gbp", "max of three columns SQL".
- DO-NOT-WRITE bans: "Trino has no greatest/least"; "use CASE WHEN — there's no built-in"; "greatest skips NULLs like Postgres"; "greatest returns NULL only if all args NULL" (the Postgres-folklore fab to pre-empt).

### GAP B (HIGH PRIORITY) — `substr` negative-index canonical missing from r27 §4.3

- Existing r27 line 863: `SUBSTR(s, start, len)` -> `substr(s, start, len)` -- "Both 1-indexed; same as Oracle." Silent on negative-start.
- Verified facts to write:
  - **Negative start = direct port**: `substr('Quadratically', -5)` returns `'cally'` (last 5 chars). Trino docs: "A negative starting position is interpreted as being relative to the end of the string." Source: trino.io/docs/current/functions/string.html.
  - **Trino has NO `right()` or `left()` functions**. Use `substr(s, -n)` for last-n-chars and `substr(s, 1, n)` for first-n-chars.
  - **Same as Oracle SUBSTR negative-start behavior**: Oracle `SUBSTR(s, -5)` also returns last 5 chars — port verbatim.
- Suggested placement: extend r27 §4.3 SUBSTR row gloss from "Both 1-indexed; same as Oracle" to "Both 1-indexed; same as Oracle; **negative start counts from end, also same as Oracle** — `substr(s, -5)` = last 5 chars". Add adjacent row/callout: "Trino has NO `right()` or `left()` — use `substr(s, -n)` and `substr(s, 1, n)`."
- Keyword anchors: "Trino right left function", "Trino last 5 characters", "SUBSTR negative index Trino", "Oracle SUBSTR -5 Trino port", "substring negative start Trino", "right function Trino doesn't exist", "last n chars Trino".
- DO-NOT-WRITE bans: "Trino has right() and left() functions"; "Oracle SUBSTR negative-start needs rewrite as length(s)-n+1 in Trino" (UNNECESSARY rewrite — direct port works); "negative-start substr is Oracle-only".

## Iter515 probe targets

| Probe | Priority | Verifies |
|---|---|---|
| `greatest()` / `least()` re-probe — "what's the cleanest way to get the max of three columns per row?" | HIGH | GAP A canonical lands; no `greatest`-not-in-Trino fab |
| `greatest` NULL semantics 2nd angle — "does greatest(a,b,c) return the max even if one is NULL, or does it return NULL?" | HIGH | NULL semantics callout lands (return-NULL-if-any-NULL; differs from Postgres) |
| Oracle `SUBSTR(s, -5)` direct-port re-probe — "last 5 chars in Trino, same as Oracle?" | HIGH | GAP B canonical lands |
| Trino `right()` / `left()` non-existence 2nd angle — "does Trino have right() and left() like MySQL?" | HIGH | Confirms no-right/no-left framing + substr workaround route |
| dbt comma+space mixed-precedence 3rd angle — "`tag:a,tag:b tag:c,tag:d` — which selects what?" | MEDIUM | Verifies iter514 r27 §6.7F mixed-example holds under direct probe |
| `$snapshots` summary-MAP 2nd angle — "how do I get the user who ran a MERGE — is it in `summary['trino_query_id']`?" | MEDIUM | Verifies WHO-scope framing + element_at NULL-safe accessor (iter513 left this nit) |
| `$snapshots` `replace` operation 2nd angle — "what does `operation='replace'` mean — when does it show up?" | MEDIUM | Verifies compaction/OPTIMIZE→replace mapping holds without re-inverting |
| Federation stays UNPROBED | LOW | Per long-standing directive; federation row stays 4.49944/310 |

## Topic-row updates (to be appended at rubric score-history)

- SQL query best practices for OLAP (Q3 greatest/least cleaner-than-CASE-WHEN maps here as per-row aggregation idiom): 4.5609/71 -> (4.5609*71 + 3.0625)/72 = 326.886/72 = **4.5401/72** (-0.0208)
- Oracle PL/SQL -> dbt + Trino SQL migration (Q1 dbt set-operators + Q4 SUBSTR Oracle-to-Trino port both map here): 4.5333/80 -> (4.5333*80 + 4.9375 + 3.0625)/82 = 370.664/82 = **4.5203/82** (-0.0130)
- Iceberg table maintenance (Q2 $snapshots maps here): 4.4845/154 -> (4.4845*154 + 4.875)/155 = 695.498/155 = **4.4871/155** (+0.0026)
- Federation row UNCHANGED at 4.49944/310 (NOT probed).

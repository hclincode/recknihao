# Iter1176 — Judge Feedback

## Verdict: PASS — Average 3.78 / 5.0 — Q1 SOFT-WATCH PARTIAL CLOSE + LIGHT FIX-A on findability; Q3 broken-secondary quarter pattern fabrication; Q4 RESOURCE GAP on dbt-parallelism warrants LIGHT FIX-A

| Q | Topic row | Score | Verdict |
|---|---|---:|---|
| Q1 Count accounts per tier with `enterprise` fully absent — force 4-row spine | Analytical query patterns on Iceberg+Trino | 3.75 | **SOFT WATCH on `r07 categorical-dim-spine DISTINCT-from-data static-VALUES-preferred iter1175`: construct CLOSES (responder inferred static VALUES list LEFT JOIN COALESCE, NOT DISTINCT-from-data) BUT FINDABILITY GAP confirmed — responder bailed on confidence ("don't have complete information"). Approach is correct; framing reveals no anchor. LIGHT FIX-A recommended.** |
| Q2 UNNEST WITH ORDINALITY for 1-based `line_number` on `order_items` array | Analytical query patterns on Iceberg+Trino | 5.0 | Pin-perfect — `CROSS JOIN UNNEST(order_items) WITH ORDINALITY AS t(item, line_number)`. Verified verbatim at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) "WITH ORDINALITY clause, in which case an additional ordinality column is added to the end" + doc example `UNNEST (...) WITH ORDINALITY AS t(a, b, rownumber)`. r07 §156-186 (iter720 PIN — FIX-A) canonical doing its job. |
| Q3 Format timestamp into `'Jun 2025'` and `'Q2 2025'` dashboard labels | SQL query best practices for OLAP | 3.375 | **Month label CORRECT (`format_datetime(ts, 'MMM yyyy')` → `'Jun 2025'`, bare-DATE coercion claim correct per r07 line 2202 verbatim DO-NOT-WRITE). Quarter label BROKEN — `'yyyy'Q'Q'` is INVALID Joda pattern (`Q` is NOT in supported letter set; unquoted Q = `Illegal pattern component: Q` parse error). Engineer copy-paste hits a runtime parse error.** Responder fabrication (not resource-sourced — grep confirms zero `'Q'`-quarter-format claims in resources). Classified `feedback_responder_broken_secondary_alternative` BROKEN-SECONDARY (primary month-label correct, secondary quarter-label fabricated). |
| Q4 dbt threads + Trino concurrency interaction + safe parallel count + slow-model identification | Improving complex SQL performance on Trino with dbt | 2.75 | **PARTIAL BAIL on a real resource gap.** Responder said "don't have sufficient information" and gave tangential CTE/EXPLAIN-ANALYZE advice. Grep confirms dbt `threads` config / `profiles.yml` parallelism / Trino resource-group concurrency interaction / `run_results.json execution_time` slow-model-id are NOT covered in resources. LIGHT FIX-A recommended. |

**Iter average:** (3.75 + 5.0 + 3.375 + 2.75) / 4 = **3.71875 PASS** (margin +0.21875 — thinnest iter average since iter1156 3.656).

**Soft watch outcome:** `r07 categorical-dim-spine DISTINCT-from-data static-VALUES-preferred iter1175` — **CONSTRUCT CLOSES** (responder did NOT use `SELECT DISTINCT tier FROM accounts`; correctly inferred static VALUES list). **FINDABILITY GAP CONFIRMED** by responder bail on confidence ("exact Trino 467 syntax/best practices aren't covered in detail"). Decision: **LIGHT FIX-A on r07 — add categorical-dim-spine card** (different surface from soft watch's "watch and re-probe" recommendation, but triggered by the explicit bail).

---

## Detailed scoring

### Q1 — Count accounts per tier with `enterprise` fully absent (SOFT WATCH RE-PROBE)

**Question shape:** `accounts.tier ∈ {free, starter, pro, enterprise}`; enterprise has ZERO rows; report must still show enterprise = 0.

**Response shape:** Responder INFERRED the correct static VALUES + LEFT JOIN + COALESCE approach:

```sql
WITH tier_spine AS (
  SELECT tier FROM (VALUES ('free'),('starter'),('pro'),('enterprise')) AS t(tier)
),
tier_counts AS (
  SELECT tier, COUNT(*) AS account_count FROM accounts GROUP BY tier
)
SELECT s.tier, COALESCE(c.account_count, 0) AS account_count
FROM tier_spine s
LEFT JOIN tier_counts c ON c.tier = s.tier
ORDER BY s.tier;
```

But prefaced with: *"I don't have complete information on this topic in the resources to give you a definitive Trino 467-specific answer. ... the exact Trino 467 syntax and best practices aren't covered in detail."*

**Soft-watch analysis:**
- iter1175 Q3 watch concern: responder built dimension spine via `SELECT DISTINCT tier FROM accounts` which silently drops fully-absent tiers. iter1176 Q1 framing puts a known-fixed enum (`free/starter/pro/enterprise`) with `enterprise` definitionally absent.
- **Construct CLOSES:** responder used `VALUES ('free'),('starter'),('pro'),('enterprise')` — the bulletproof static form per iter1175 footnote.
- **BUT** the bail signals findability gap. The CORRECT answer was inferred, NOT looked up. This is unstable across phrasings.

**Findability grep evidence:**
- `Grep VALUES \('free'|VALUES \('starter'|categorical spine|tier spine|enum spine|all enum values|every category|all categories.*including|VALUES.*CROSS JOIN.*GROUP BY`: ZERO matches across all resources.
- r07 §1430-1500 has the DATE-spine canonical (`UNNEST(sequence(...)) LEFT JOIN COALESCE`).
- r07 §1687-1696 has the DIMENSION-TABLE spine (`CROSS JOIN meeting_rooms` for "every room, even never-reserved") with an explicit DO-NOT-WRITE: *"Do NOT derive the room universe with `(SELECT DISTINCT room_id FROM reservations)` — that drops rooms with zero reservations in the whole window."*
- **Gap:** the dimension-TABLE form requires a separate Iceberg dim table to exist. For a known 4-value enum like tier with no separate dim table, the static VALUES form is canonical and is NOT documented anywhere in r07/r23.

**LIGHT FIX-A recommendation:**
- Add additive card to r07 immediately AFTER §1696 dimension-TABLE canonical (or cross-ref from the date-spine §1430 canonical).
- Card name: "categorical dimension spine — static VALUES list + LEFT JOIN + COALESCE for a known-fixed enum (no separate dim table)".
- Load-bearing facts: (a) `(VALUES ('free'),('starter'),('pro'),('enterprise')) AS t(tier)` is valid Trino 467 per [trino.io/docs/current/sql/values.html](https://trino.io/docs/current/sql/values.html); (b) LEFT JOIN grouped fact-side onto VALUES spine; (c) `COALESCE(count, 0)` for absent values; (d) **load-bearing** — works even when a value is fully absent from the fact table (the spine row survives the LEFT JOIN with NULL right-side, COALESCE produces 0).
- Cross-ref FROM the existing room-dimension canonical: "if there is NO separate dimension TABLE for the enum (small fixed enum: tier, status, channel, lifecycle stage), use a literal VALUES list — same shape, no dim-table dependency."
- Defang: DO-NOT-WRITE `(SELECT DISTINCT tier FROM accounts)` — drops fully-absent tier values.
- Keyword anchors: "show all tiers including zero / enum with no rows / force all categories in GROUP BY / category absent from data / display every plan tier even when zero accounts / enumerate fixed status set / all 4 tiers / values list as dimension / categorical spine / hardcoded category list".

**Score:** Acc 4.0 / Clar 4.0 / App 3.5 / Compl 3.5 = **3.75**. Approach correct, framing under-confident, syntax not anchored.

---

### Q2 — UNNEST WITH ORDINALITY

**Response shape:** `SELECT order_id, item, line_number FROM iceberg.<schema>.orders CROSS JOIN UNNEST(order_items) WITH ORDINALITY AS t(item, line_number)` with explicit 1-based bigint position appended at END, aliased via two-element list.

**Verification:**
- [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) verbatim: *"UNNEST can optionally have a WITH ORDINALITY clause, in which case an additional ordinality column is added to the end"*; example: `SELECT a, b, rownumber FROM UNNEST (ARRAY[2, 5], ARRAY[7, 8, 9]) WITH ORDINALITY AS t(a, b, rownumber)`.
- r07 §156-186 (iter720 PIN — FIX-A) is the LEADING CANONICAL "Per-element ordinal alongside each exploded element — TRUE 1-based per-row position" with full worked example + AS t(elem, ord)/AS t(tag, position) alias variants.
- Foreign-feature-audit dimension: responder CORRECTLY affirmed a real Trino 467 feature (no false-absence per the imported-prior assumed-absence family — starts_with/listagg/to_char/truncate-2arg/array_remove pattern).

**Score:** 5.0 / 5.0 / 5.0 / 5.0 = **5.0**. Clean canonical reach; resource canonical doing its job.

---

### Q3 — Format timestamp into `'Jun 2025'` / `'Q2 2025'` dashboard labels

**Response shape (month label):** `format_datetime(CAST(order_date AS timestamp), 'MMM yyyy')` → `'Jun 2025'`. Also noted: *"`format_datetime` accepts a bare DATE (implicit DATE → TIMESTAMP coercion, no CAST needed)."* Also gave `'EEEE'` weekday-name and `'yyyy-MM-dd'` ISO date examples.

**Response shape (quarter label):** *"For quarter: `'yyyy'Q'Q'` → `'2025Q2'` (fiscal quarter format — adjust the literal 'Q' as needed)."*

**Verifications:**

| Claim | Verdict | Source |
|---|---|---|
| `format_datetime(ts, 'MMM yyyy')` → `'Jun 2025'` | ✅ CORRECT | [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) — Joda DateTimeFormat pattern; `MMM` = 3-char month, `yyyy` = 4-digit year |
| `format_datetime` accepts bare DATE without CAST | ✅ CORRECT | r07 line 2202 DO-NOT-WRITE block explicitly marks "REQUIRE CAST(date AS timestamp); a bare DATE errors" as WRONG; Trino implicitly coerces DATE → TIMESTAMP(0) |
| `'yyyy'Q'Q'` → `'2025Q2'` Joda quarter format | ❌ **WRONG — PARSE ERROR** | Joda DateTimeFormat supported letters: G/C/Y/x/w/e/E/y/D/M/d/a/K/h/H/k/m/s/S/z/Z per [joda.org/joda-time DateTimeFormat docs](https://www.joda.org/joda-time/apidocs/org/joda/time/format/DateTimeFormat.html). **`Q` is NOT in the supported set.** Doc explicitly states: *"All ASCII letters are reserved as pattern letters."* — unquoted `Q` in `'yyyy'Q'Q'` (between two quote-blocks: literal "yyyy" + unquoted Q + literal "Q") raises **`Illegal pattern component: Q`** at format-parse time. Engineer copy-paste hits runtime error. |

**Correct quarter form** (responder did not name):
```sql
'Q' || CAST(quarter(order_date) AS varchar) || ' ' || CAST(year(order_date) AS varchar)  -- 'Q2 2025'
-- OR
format('Q%d %d', quarter(order_date), year(order_date))                                   -- 'Q2 2025'
```
`quarter(x)` / `year(x)` verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html); `format(format_string, args...)` verified at [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html).

**Source classification:**
- Grep for `'yyyy'Q'Q'` / `fiscal quarter.*format_datetime` / `format.*Q.*quarter` / `'Q' \|\|.*quarter`: ZERO matches in resources. **Responder fabrication, NOT resource-sourced.**
- r07 §3564 has the WHICH-QUARTER card naming `quarter(x)` 1-4 function and `week_of_year` ISO week alias — but does NOT teach a "compose quarter into a display string like `'Q2 2025'`" canonical.
- Classified `feedback_responder_broken_secondary_alternative.md` BROKEN-SECONDARY pattern: primary (month label `'Jun 2025'`) correct; secondary (quarter label `'Q2 2025'`) broken with fabricated Joda pattern letter. **No resource fix per pin** — the wrong fact is responder fabrication, not resource-sourced; adding a defang card risks `feedback_new_card_over_attracts_adjacent` on neighboring date_format/format_datetime questions.
- This is the **6th instance** of imported-prior responder fabrication of a Joda/SQL pattern letter — adjacent to the iter925 / iter1006 / iter1148 imported-prior family. Joda has no Q quarter field; java.time `DateTimeFormatter` DOES have `Q`/`QQ`/`QQQ` quarter pattern (1/01/Q1) — responder likely imported the java.time pattern letter, but Trino's format_datetime uses Joda not java.time.

**OPTIONAL FIX-A consideration:** add a "format quarter as `'Q2 2025'` string" sub-card to r07 §3564 WHICH-QUARTER card with the concat-or-format() canonical + explicit defang ("Joda has no Q pattern letter; `format_datetime(ts, 'yyyy''Q''Q')` is a parse error"). **Recommend NO-OP on first occurrence** — re-probe in next sweep with structurally similar phrasing (e.g., "format date as 'Q3 FY2026' fiscal label" or "quarter-and-year label for executive dashboard") to confirm recurrent vs one-off, per pinned `feedback_new_card_over_attracts_adjacent.md` discipline. If recurs → light FIX-A on r07 §3564.

**Score:** Acc 3.0 / Clar 4.0 / App 3.0 / Compl 3.5 = **3.375**. Month label pin-perfect; quarter label is a parse-error fabrication that wastes the engineer's time.

---

### Q4 — dbt threads / Trino concurrency / safe parallel count / slow-model identification

**Response shape:** *"I don't have sufficient information in the resources to answer the threading/parallelism question well."* Gave tangential advice:
- Convert reused CTEs to intermediate dbt models (correct but doesn't address parallelism).
- EXPLAIN ANALYZE for bottlenecks (correct but per-query not per-model).
- Iceberg MERGE delete-file slowdown (off-topic).
- *"Check dbt-trino adapter docs / profiles.yml threads key / consult cluster operator for safe concurrency."*

**Engineer's actual three sub-questions:**
1. How do dbt threads interact with Trino — won't 20 concurrent model queries overload the cluster?
2. How to pick a safe parallel count?
3. How to identify the slowest models?

**Verifications (what the answer should have been):**

| Sub-question | Correct answer | Source |
|---|---|---|
| dbt threads behavior | `threads:` in `profiles.yml` controls how many model nodes dbt builds **concurrently**; each thread submits ONE Trino query at a time (no thread-internal parallelism), so `threads` ≈ max concurrent Trino queries from dbt. Default is 4 in dbt Core. | [docs.getdbt.com/docs/running-a-dbt-project/using-threads](https://docs.getdbt.com/docs/running-a-dbt-project/using-threads) verbatim: *"The number of threads represents the maximum number of paths through the graph dbt may work on at once"*; *"We recommend setting this to 4 to start with"*. |
| Trino concurrency cap | dbt threads beyond Trino's `hardConcurrencyLimit` on the dbt user's resource group QUEUE on the Trino side — they don't run in parallel beyond the cluster cap. The cluster doesn't "overload" because of resource-group concurrency limits, but excess threads provide no speedup. | r05 §2400 resource-groups documents `hardConcurrencyLimit` (verified at [trino.io/docs/current/admin/resource-groups.html](https://trino.io/docs/current/admin/resource-groups.html)). |
| Safe parallel count | `safe_threads = MIN(profiles.yml threads, dbt-user resource group hardConcurrencyLimit)`. If your Trino dbt-user group hardConcurrencyLimit is 8, setting threads=20 just queues 12 — no benefit + harder oncall (queue depth, lock contention on MERGE). Start at threads=4-8, monitor cluster memory headroom, then bump. | Same as above. |
| Identify slowest models | (a) `target/run_results.json` after `dbt run` — sort by `execution_time` field, top-N gives slowest models per invocation; (b) dbt Cloud "Model Timing" tab if used; (c) custom dbt model on top of `run_results.json` artifacts to track over time; (d) query `system.runtime.queries` and filter by dbt's query-comment label (`dbt-trino` adds a comment with the dbt model name to every query). | [docs.getdbt.com/reference/artifacts/run-results-json](https://docs.getdbt.com/reference/artifacts/run-results-json) — `execution_time` field per node. |

**Grep evidence for resource gap:**
- Grep `dbt threads / threads: / profiles.yml threads / parallel.*model / concurrent.*model / --threads`: ZERO meaningful matches outside r13 §5447+ which covers dbt-trino incremental strategies, not threading.
- Grep `resource group.*dbt / hardConcurrencyLimit.*dbt / dbt.*queue / dbt.*concurrency`: ZERO matches connecting dbt parallelism to Trino resource groups.
- Grep `run_results / execution_time / slow model identification / dbt timing summary / model performance`: ZERO matches.
- r25 §188 mentions `dbt run --select` for materialized-view refresh orchestration but not parallelism or run_results.
- r28 covers complex-SQL-perf on Trino+dbt (EXPLAIN ANALYZE, CTE materialization, partition predicates, broadcast joins) but DOES NOT cover dbt-side parallelism, Trino concurrency interaction, or slow-model identification via dbt artifacts.

**LIGHT FIX-A recommendation:**
- Add a new section to r28 (Improving complex SQL performance on Trino with dbt) — title: "dbt parallelism + Trino concurrency interaction + slow-model identification".
- Load-bearing facts: (a) `threads:` in `profiles.yml` is the dbt-side max concurrent model graph node count, default 4 in dbt Core (1 in older); (b) each thread = ONE Trino query at a time; (c) Trino-side cap is the dbt user's `hardConcurrencyLimit` on the resource group; (d) `safe_threads = MIN(profiles.yml threads, hardConcurrencyLimit)` — excess threads queue on Trino, no speedup; (e) `dbt run --threads N` overrides for one invocation; (f) cluster memory cap = (active query memory × concurrent queries) — high threads × heavy queries can OOM nodes (still resource-group constrained via `softMemoryLimit` / `queryMaxMemoryPerNode`).
- Slow-model identification: (a) `target/run_results.json` — `results[].execution_time` per node; (b) `jq '.results | sort_by(.execution_time) | reverse | .[0:10] | .[].unique_id'` one-liner for top-10 slowest; (c) build a dbt model on top of `run_results.json` to track trends; (d) query `system.runtime.queries` filtered by dbt's query comment for model name.
- Cross-ref FROM r05 resource-groups section (Mechanism 3) ← TO the new r28 dbt-parallelism section: "for the dbt service-account user, the hardConcurrencyLimit bounds parallel model queries from dbt — see r28 §dbt-parallelism".
- Keyword anchors: "dbt threads / dbt concurrent model builds / Trino dbt parallelism / 2-hour dbt run / dbt threads 20 / dbt parallel queries Trino / dbt slow model / slowest models dbt / dbt run_results.json execution_time / dbt model timing / dbt safe threads / dbt profiles.yml threads".

**Watch label:** `r28 dbt-parallelism + slow-model-id resource gap iter1176`; re-probe next sweep with phrasings like "set threads=16 in profiles.yml but Trino still shows 4 active queries — is that resource groups?" or "dbt run takes 90min; which models?" If FIX-A reaches, close.

**Score:** Acc 3.5 / Clar 3.0 / App 2.5 / Compl 2.0 = **2.75**. Conceptually-honest bail, but the question is squarely within the dbt+Trino-perf topic, and the resource doesn't have the answer.

---

## Topic updates

| Topic | Before | After | Change |
|---|---|---|---|
| Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL | 4.5465 / 125 | (568.3136 + 3.75 + 5.0) / 127 = 577.0636 / 127 = **4.5438 / 127** | **PASSED** (-0.0027, Q1 partial drag, Q2 lift, margin +1.0438) |
| SQL query best practices for OLAP | 4.5770 / 251 | (1148.827 + 3.375) / 252 = 1152.202 / 252 = **4.5723 / 252** | **PASSED** (-0.0047, Q3 quarter-fab drag, margin +1.0723) |
| Improving complex SQL performance on Trino with dbt | 4.6283 / 27 | (124.9641 + 2.75) / 28 = 127.7141 / 28 = **4.5612 / 28** | **PASSED** (-0.0671, Q4 bail drag, margin +1.0612) |

**ALL required topics REMAIN PASSED.** No topic falls below threshold.

## Recommendations

| | Recommendation | Rationale |
|---|---|---|
| Q1 | **LIGHT FIX-A on r07 categorical-dim-spine** | iter1175 soft-watch concern construct closes (responder used VALUES, not DISTINCT) but findability gap confirmed by explicit bail. Add additive card immediately after r07 §1696 dimension-TABLE canonical with static VALUES form + cross-ref from date-spine §1430. Anchor keywords explicitly. |
| Q2 | NO-OP | r07 §156-186 doing its job; clean canonical reach. |
| Q3 | NO-OP (re-probe in next sweep) | Responder fabrication of Joda `Q` pattern, not resource-sourced. Per pinned `feedback_responder_broken_secondary_alternative.md` — primary correct, secondary broken. If recurs with structurally similar quarter-as-string question, add sub-card to r07 §3564 WHICH-QUARTER card. Watch label: `r07 Joda-Q-pattern fabrication iter1176`. |
| Q4 | **LIGHT FIX-A on r28 dbt-parallelism + slow-model-id** | Genuine resource gap for a standard dbt+Trino-perf operational topic. Add new r28 section; cross-ref from r05 resource-groups. Spec in Q4 detail above. |

**Two LIGHT FIX-A candidates this iter** (Q1 categorical-spine + Q4 dbt-parallelism). Both are additive cards — no in-place rewrites, no risk of contradicting existing canonicals.

**Open watches after iter1176:**
- `r07 categorical-dim-spine static-VALUES-list iter1176` (NEW — from LIGHT FIX-A above).
- `r28 dbt-parallelism + slow-model-id resource gap iter1176` (NEW — from LIGHT FIX-A above).
- `r07 Joda-Q-pattern fabrication iter1176` (re-probe watch, NO immediate FIX-A).
- All prior watches CLOSED in iter1175 remain closed.

**Pattern observation:** First multi-LIGHT-FIX-A iter since iter1156 (also two LIGHT FIX-A). Both gaps are on genuinely uncovered territory (categorical-as-opposed-to-time spine; dbt-parallelism as-opposed-to-SQL-optimization). The Q3 fabrication continues the imported-prior pattern (java.time DateTimeFormatter has `Q` quarter letter; responder imported it into Trino's Joda format_datetime where it's not supported) — same family as iter925/1006/1148/etc. Per pinned discipline: verify-first against trino.io/docs/467, don't bias the judge toward "this might be supported".

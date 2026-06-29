# Iteration 1253 — Judge Feedback

## Verdict

**Overall: 4.359 PASS — Q4 LOAD-BEARING REGRESSION (regexp_extract 2-arg returns-group-1 misclaim) drags an otherwise clean iter. Q3 closes the iter1249 dbt-snapshot recall-variance soft watch cleanly. ONE NEW SOFT WATCH on Q4 regexp_extract recall slip (resource r23 §3454 already correct + defang in place; NO FIX-A on first instance per stop-churning discipline).**

Per-Q scores: Q1=5.0, Q2=4.375, Q3=4.8125, Q4=3.25. Average (5.0 + 4.375 + 4.8125 + 3.25) / 4 = **4.359**.

Q4 is the load-bearing miss this iter: the responder's lead claim "regexp_extract(string, pattern) [2-arg] returns the first capture group (group 1) by default" is FACTUALLY WRONG and directly contradicts (a) the Trino 467 docs, (b) the explicit canonical block in r23 §3454, AND (c) the responder's own correct iter1250 answer. Engineer who copies the lead `regexp_extract(ref_code, 'account:(\d+)')` literally gets `'account:4892'` not `'4892'`. The 3-arg form examples later in the same answer are correct, so a careful reader self-corrects — but the LEAD is the part most likely to be copy-pasted first.

---

## Per-question scoring

### Q1 — Rename `cust_id` to `customer_id` on a live Iceberg `orders` table (8mo Parquet, views + dbt models reference cust_id); `ALTER TABLE ... RENAME COLUMN`: rewrites Parquet or metadata-only? Old queries break immediately or grace period?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All facts VERIFIED. (a) Iceberg tracks columns by **integer field IDs not names** — verified via WebSearch against Apache Iceberg evolution docs: "Iceberg identifies columns by unique integer IDs, not by names or positions. When Iceberg reads a data file, it matches columns by ID, not by name or position." (b) RENAME is metadata-only — confirmed in Iceberg spec / evolution: "Renaming a column changes the name in the metadata but the ID stays the same — existing data files still map correctly." (c) Trino 467 connector docs at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) state "Iceberg supports schema evolution, with safe column add, drop, reorder, and rename operations" (the safety guarantee). (d) No data file rewrite, no historical Parquet rewrite, atomic. (e) Old `cust_id` queries break **immediately** with `Column 'cust_id' cannot be resolved` — there is no grace period because the field-ID→name mapping is atomically updated on commit; the old name is no longer present in the table schema. CORRECT. |
| Beginner clarity | 5.0 | "Field ID not name" mental model bridges the metadata-only vs file-rewrite question directly; explicit "no grace period — atomic" eliminates the engineer's worry about timing/coordination. Three migration patterns (A/B/C) clearly differentiated. |
| Practical applicability | 5.0 | Three production-grade rollout patterns: (A) atomic rename in one PR updating all refs (works for tight code ownership); (B) expand/contract (ADD new col → backfill UPDATE → migrate readers → DROP old) for loosely-coupled consumers; (C) bridging view `CREATE VIEW orders_compat AS SELECT *, customer_id AS cust_id FROM orders` for legacy BI clients that can't redeploy. Engineer has a real menu, not just "rename it." |
| Completeness | 5.0 | All three sub-questions answered: (1) rewrites Parquet or metadata-only → metadata-only; (2) immediate or grace period → immediate, atomic; (3) implicit "what do I do about consumers" answered via the three patterns. |

**Average: 5.0 — STRONG PASS.**

---

### Q2 — First-order cohort (customers whose FIRST order fell in each calendar month, AVG first-order value, GROUP BY first-order month). Oracle MIN(order_date) per customer + join back + filter `order_date = min`. Translate to Trino or cleaner way?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | SQL is valid Trino 467: `WITH first_orders AS (SELECT customer_id, MIN(order_date) AS first_order_date FROM orders GROUP BY customer_id), cohort_orders AS (SELECT DATE_TRUNC('month', fo.first_order_date) AS cohort_month, o.order_value, o.order_id FROM first_orders fo JOIN orders o ON fo.customer_id=o.customer_id AND o.order_date=fo.first_order_date) SELECT cohort_month, AVG(order_value), COUNT(*) FROM cohort_orders GROUP BY cohort_month`. `DATE_TRUNC('month', ...)` verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html); `MIN(date) GROUP BY` standard. **MINOR CORRECTNESS DING (-0.5)**: the JOIN `ON o.order_date = fo.first_order_date` **double-counts a customer who placed 2+ orders on their first day** — `COUNT(*)` then counts that customer twice, `AVG(order_value)` is weighted by their multiple same-day orders. For a true first-order-per-customer COUNT/AVG, the deterministic form is `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date, order_id) = 1` (picks one row per customer, ties broken by order_id). NOT a Trino dialect error — the SQL is valid and **is** a faithful translation of the Oracle MIN+JOIN pattern (which has the same flaw). Engineer's results will be correct if same-day-tie is rare; will skew if same-day duplicate orders are common (e.g. multi-cart checkout, refund-then-rebuy on day 1). |
| Beginner clarity | 4.5 | Clear two-CTE structure: `first_orders` (per-customer MIN) → `cohort_orders` (join back to get first-day rows) → final GROUP BY. Engineer can read it left-to-right. `DATE_TRUNC('month', ...)` is the standard cohort-bucketing idiom; the `AS cohort_month` aliasing makes the output column self-documenting. |
| Practical applicability | 4.5 | Copy-paste-ready Trino 467 SQL. Engineer's Oracle mental model translates directly without restructuring. Engineer who runs this gets correct results for the typical SaaS shape (most customers place their first order at a distinct timestamp). |
| Completeness | 4.0 | **(-1.0) Missed the cleaner ROW_NUMBER form + same-day-tie discussion.** The question explicitly asked "Translate to Trino OR cleaner way?" — responder gave the translation only, did not offer ROW_NUMBER as the cleaner-alternative answer or flag the same-day-tie idempotency gap. A complete answer would have appended: "If a customer can place multiple orders on day 1 (e.g. multi-cart checkout), the JOIN form double-counts that customer. Cleaner alternative: `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date, order_id) AS rn` in a subquery + `WHERE rn = 1` picks exactly one first-order row per customer deterministically." Not load-bearing for the engineer's stated Oracle pattern (which the engineer chose) — but the "cleaner way?" prompt was the door for this and the responder didn't walk through it. |

**Average: (4.5 + 4.5 + 4.5 + 4.0) / 4 = 17.5/4 = 4.375 → PASS.**

---

### Q3 — [iter1249 dbt-snapshot recall-variance watch RE-PROBE] dbt snapshot `strategy: check` with `check_cols: [plan_tier]`, source also has `updated_at`. Must `updated_at` be configured, or does `check` compare VALUES regardless of timestamps? Does `check` query both snapshot + source each run? check vs timestamp?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | All load-bearing facts CORRECT. (a) **`check` strategy compares column VALUES** — verified at [docs.getdbt.com/docs/build/snapshots](https://docs.getdbt.com/docs/build/snapshots) verbatim: "The `check` strategy is useful for tables which do not have a reliable `updated_at` column. This strategy works by comparing a list of columns between their current and historical values. If any of these columns have changed, then dbt will invalidate the old record and record the new one." (b) **`updated_at` not required for `check`** — verified at the same docs verbatim: "When using the `check` strategy, dbt tracks changes by comparing values in `check_cols`. By default, dbt uses the timestamp to update `dbt_updated_at`, `dbt_valid_from` and `dbt_valid_to` fields. Optionally you can set an `updated_at` column." (c) **dbt queries both snapshot + source on every run** — implied by docs ("On subsequent runs: dbt will check which records have changed"); responder correctly identified row-by-row diff mechanic. (d) `check_cols=['col list']` vs `check_cols='all'` correctly distinguished (verified at [docs.getdbt.com/reference/resource-configs/check_cols](https://docs.getdbt.com/reference/resource-configs/check_cols): list of column names + `all` bare string). (e) timestamp-vs-check routing correct ("timestamp when source has reliable last-modified, check when no reliable timestamp"). **Minor compl shave (-0.25)**: didn't surface the nuance that `updated_at` IS **optionally** configurable WITH `check` strategy (when set, it's used to populate `dbt_valid_from`/`dbt_valid_to` from the source column instead of run-time `current_timestamp`). Per docs: "If `updated_at` is configured, the `check` strategy uses this column instead, as with the timestamp strategy. If `updated_at` value is null, dbt defaults to using the current timestamp." Not load-bearing for the engineer's question ("must I configure it?" — the answer is NO, optional, and responder correctly said NO). |
| Beginner clarity | 5.0 | Clear "row-value comparison NOT timestamps" framing addresses the engineer's mental gap directly; explicit "Do NOT need `updated_at` in `check_cols`" answers the literal yes/no question; check-vs-timestamp side-by-side contrast eliminates the routing confusion. |
| Practical applicability | 5.0 | Copy-paste-ready `{% snapshot %}` block with `target_schema`, `unique_key='account_id'`, `strategy='check'`, `check_cols=['plan_tier']`. Engineer drops it into models/snapshots/ and runs `dbt snapshot` first try. The `check_cols=['col list']` vs `check_cols='all'` distinction prevents the bare-string vs list quoting bug. |
| Completeness | 4.5 | Answers all three sub-questions (must configure updated_at? value-comparison? both-tables-query-each-run?) + bonus check-vs-timestamp routing + `'all'` mode mention. (-0.5) Could have surfaced the optional `updated_at` with `check` nuance (uses source-column timestamp for dbt_valid_from instead of run-time) — peripheral but useful for SCD-2 audit-trail completeness. |

**Average: (4.75 + 5.0 + 5.0 + 4.5) / 4 = 19.25/4 = 4.8125 → STRONG PASS.**

**iter1249 dbt-snapshot recall-variance watch status: CLOSES CLEANLY on first re-probe.** iter1249 the responder BAILED on a dbt snapshot question despite r09 having the canonical content (similar to the iter1237 outright bail that was fixed by adding the 5th materialization row + bolded routing note). This iter the responder REACHED r09 / r-snapshots, produced the correct canonical answer with config block + check-vs-timestamp contrast + check_cols list-vs-'all' distinction. No "resources don't cover dbt snapshots" misroute. The iter1237 r27 §3.1 5th-snapshot-row FIX-A + r09 §SCD anchors are holding across multiple re-probes (iter1238 Q2 5.0, iter1224 Q3 4.6875, iter1201 Q1 5.0, iter1200 Q3 5.0, iter1187 Q4 4.875, iter1158 Q1 5.0, now iter1253 Q3 4.8125). Watch resolved cleanly without resource churn.

---

### Q4 — Oracle `REGEXP_SUBSTR(ref_code, 'account:(\d+)', 1, 1, NULL, 1)` extracts group 1 → `'4892'` from `'account:4892'`. Trino `regexp_extract` capture-group support + argument order?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 2.5 | **LOAD-BEARING ERROR.** Responder claimed: *"`regexp_extract(string, pattern)` — returns the FIRST capture group (group 1) BY DEFAULT"* with lead example `regexp_extract(ref_code, 'account:(\d+)')` commented `→ '4892'`. **THIS IS FACTUALLY WRONG.** VERIFIED at [trino.io/docs/467/functions/regexp.html](https://trino.io/docs/467/functions/regexp.html) (WebFetched this iter, verbatim): *"`regexp_extract(string, pattern) → varchar` — Returns the first substring matched by the regular expression `pattern` in `string`."* The 2-arg form returns the **ENTIRE MATCH (group 0)**, NOT capture group 1. So `regexp_extract('account:4892', 'account:(\d+)')` returns `'account:4892'` (the whole matched substring), NOT `'4892'`. To get `'4892'` the engineer MUST use the 3-arg form: `regexp_extract('account:4892', 'account:(\d+)', 1)`. The 3-arg examples later in the responder's answer ARE correct (multi-group `regexp_extract('order-12345-premium', '([a-z]+)-(\d+)-(\w+)', 2)` → `'12345'`) and the 1-indexed framing is correct — but the LEAD claim ("returns group 1 by default") + lead example with the wrong commented output is the load-bearing failure, AND directly contradicts the engineer's stated Oracle Q (where `REGEXP_SUBSTR(..., 1, 1, NULL, 1)` returns `'4892'` because the 6th `subexpr` arg is explicitly `1`). The Trino equivalent of Oracle's explicit `subexpr=1` is the 3-arg form, NOT the 2-arg form. **(-2.5)** factual error on the lead. |
| Beginner clarity | 4.0 | Well-structured: lead example, 3-arg form, multi-group examples, regexp_replace cross-ref ($1 vs \1). The structure is engineer-friendly. The clarity score is held up by the structure DESPITE the wrong factual content of the lead — a careful reader who reads to the end and sees the 3-arg examples returning `'12345'` from group 2 may notice the inconsistency and self-correct. |
| Practical applicability | 2.5 | Engineer copies the LEAD form `regexp_extract(ref_code, 'account:(\d+)')`, runs it, gets `'account:4892'` (not `'4892'`), is confused for a few minutes, then either re-reads and finds the 3-arg examples or hits the docs. The 3-arg examples ARE copy-paste-ready and correct, so engineer can recover within a few minutes — but the lead form they tried FIRST is broken for their stated use case. **(-2.5)** for the broken lead. |
| Completeness | 3.5 | 3-arg form correctly covered; multi-group examples correct; 1-indexed framing correct; `regexp_replace $1 vs \1` cross-ref helpful. (-1.5) for the wrong 2-arg-returns-group-1 default claim that contradicts the engineer's Oracle baseline (Oracle's `REGEXP_SUBSTR` with explicit `subexpr=1` is the 3-arg-form equivalent, not a default). |

**Average: (2.5 + 4.0 + 2.5 + 3.5) / 4 = 12.5/4 = 3.125 → INDIVIDUAL FAIL (below 3.5 threshold).**

**Q4 regexp_extract 2-arg-returns-WHOLE-match verdict + responder-slip-vs-resource-defect + FIX-A?:**

- **Verdict — WHOLE MATCH (group 0), NOT group 1.** VERIFIED at [trino.io/docs/467/functions/regexp.html](https://trino.io/docs/467/functions/regexp.html) verbatim: `regexp_extract(string, pattern) → varchar` "Returns the first substring matched by the regular expression `pattern` in `string`." For a capture group you MUST use the 3-arg form `regexp_extract(string, pattern, group) → varchar`.

- **Classification — RESPONDER SLIP, NOT resource defect.** GREPped `regexp_extract` across resources/. r23 §3454-3486 has an EXPLICIT canonical block:
  - LEADING RULE comment: *"RULE: to extract a CAPTURE GROUP (the value INSIDE the parentheses), you MUST pass the group index: `regexp_extract(s, pattern, 1)`. The 2-arg form `regexp_extract(s, pattern)` returns the WHOLE match — a pattern WITH parentheses STILL returns the whole match unless you add `, 1`."*
  - DO-NOT-COPY defang block at §3475: `❌ regexp_extract(log_message, 'action=(\S+)') -- returns 'action=login' (the WHOLE match), NOT 'login' — you forgot the , 1 group index — DO NOT COPY`
  - Semantics section §3484 quotes Trino docs verbatim: *"`regexp_extract(string, pattern) → varchar` — returns the **FIRST substring matched** by `pattern` (NULL if no match)."*
  - r27 §1004 row: `REGEXP_SUBSTR(s, pattern) → regexp_extract(s, pattern) — Renamed. Both 1-indexed group access via 3rd arg.` — note "group access via 3RD arg," NOT "group 1 by default."
  
  Resources are CONSISTENT and CORRECT. The responder lifted the SHAPE of the defang's ❌ example (`regexp_extract(log_message, 'account:(\d+)')` form) but FLIPPED THE COMMENTED RESULT from "WHOLE match `action=login`" to "capture group `4892`" — exactly the `feedback_defang_donotwrite_snippets.md` backfire pattern (negative example reproduced as positive recommendation, with the inverted commented output).

- **iter1250 same-family answer was CORRECT** (per context note: "no 3rd arg → full match"). Recall-variance, not a structural responder defect.

- **FIX-A decision: NO FIX-A on first instance.** Per `feedback_synthesis_ceiling_stop_churning.md` discipline (one-instance variance against a resource already correct + already defanged): do NOT churn the canonical or strengthen the defang on a single slip. The r23 §3454 leading-RULE + §3475 ❌ defang + §3484 verbatim docs quote is already as explicit as it can be. Strengthening the defang risks the `feedback_defang_donotwrite_snippets.md` backfire pattern getting worse (more wrong-example bait surface). 

- **SOFT WATCH ONLY**: `iter1253 Q4 regexp_extract 2-arg-returns-WHOLE-match misrecall (lead-example flip; r23 §3454 + defang already correct)`. Re-probe in 4-8 iters under similar Oracle `REGEXP_SUBSTR` → Trino `regexp_extract` framings (especially Oracle's explicit-subexpr arg = N variants). If recurs across phrasings, consider promoting the r23 §3454 RULE block higher in the file or adding a new top-of-r07 dialect-myth routing card; on first instance, watch only.

---

## Topics touched / rubric updates

| Topic | Prior avg | Q | Score | New avg | Δ |
|---|---|---|---|---|---|
| Iceberg table maintenance | 4.4418 / 237 | Q1 | 5.0 | 4.4441 / 238 | +0.0023 |
| Analytical query patterns on Iceberg+Trino | 4.5223 / 181 | Q2 | 4.375 | 4.5215 / 182 | −0.0008 |
| dbt snapshots SCD2 | 4.2117 / 26 | Q3 | 4.8125 | 4.2339 / 27 | +0.0222 |
| Oracle PL/SQL → dbt + Trino migration | 4.4832 / 221 | Q4 | 3.25 | 4.4776 / 222 | −0.0056 |

All required topics REMAIN PASSED with healthy margins (thinnest still Query-performance-basics at 4.2040/33; Oracle-migration at 4.4776/222 absorbs the Q4 drag without falling below threshold).

---

## Source-verified outcomes this iter

- **Q1**: Iceberg field-ID schema-evolution rename semantics + Trino 467 metadata-only ALTER TABLE behavior all verified against trino.io/docs/467/connector/iceberg.html + Apache Iceberg evolution docs / spec.
- **Q2**: Trino 467 SQL form valid (DATE_TRUNC, MIN+JOIN); same-day-tie completeness gap is a faithful Oracle translation flaw, not a Trino dialect error.
- **Q3**: dbt snapshot `check` strategy semantics (value-comparison not timestamps; `updated_at` optional; queries both snapshot + source each run) VERIFIED against docs.getdbt.com/docs/build/snapshots + docs.getdbt.com/reference/resource-configs/check_cols.
- **Q4**: Trino 467 `regexp_extract` 2-arg returns WHOLE match (group 0), NOT group 1; 3-arg form returns specified capture group. VERIFIED verbatim against trino.io/docs/467/functions/regexp.html.

---

## Recommendation

**NO-OP on resources** (no FIX-A this iter). Commit rubric+feedback only.

The Q4 slip is a recall-variance responder failure against a resource (r23 §3454-3486 + r27 §1004) that is already correct AND already defanged with an explicit ❌ DO-NOT-COPY block + leading RULE comment + verbatim-docs semantics section. Per `feedback_synthesis_ceiling_stop_churning.md` discipline, do NOT churn the defang on first instance. Per `feedback_defang_donotwrite_snippets.md`, the negative-example flip is a known backfire mode; strengthening the defang risks making the bait worse.

The Q2 completeness shave (same-day-tie not flagged) is per-instance broken-secondary territory (per `feedback_responder_broken_secondary_alternative.md`) — engineer asked "translate or cleaner way" and the responder gave only the translation, missing the cleaner ROW_NUMBER alternative. Not a resource defect.

## Watches

### NEW soft watches (this iter)

- **iter1253 Q4 regexp_extract 2-arg-returns-WHOLE-match misrecall** — responder claimed "2-arg returns group 1 by default" + LEAD example `regexp_extract('account:4892', 'account:(\d+)')` commented `→ '4892'` (correct output: `'account:4892'`). r23 §3454-3486 RULE block + ❌ defang + verbatim-docs quote ALL correct; recall-variance not resource defect. iter1250 same-family answer was correct. Re-probe in 4-8 iters under Oracle `REGEXP_SUBSTR` → Trino `regexp_extract` framings (especially with explicit Oracle `subexpr` arg). NO FIX-A on first instance.

- **iter1253 Q2 first-order cohort same-day-tie not flagged** (very soft) — responder gave faithful Oracle MIN+JOIN translation without flagging the same-day-tie double-count or offering ROW_NUMBER() OVER PARTITION BY = 1 alternative. Engineer's results correct in the typical case; skews if multi-cart-per-day is common. Per-instance broken-secondary, NO FIX-A. Re-probe under "first-event-per-entity / first-order cohort / first-session-per-user" framings 6-10 iters.

### Watches CLOSING this iter

- **iter1249 Q3 dbt-snapshot recall-variance** → **CLOSES CLEANLY**. iter1249 the responder bailed on a dbt snapshot question despite r09 having canonical content; this iter the responder reached r09 + answered Q3 (`strategy='check'` check_cols values-not-timestamps + config block + check-vs-timestamp routing) correctly. The iter1237 r27 §3.1 5th-snapshot-row FIX-A + r09 §SCD anchors holding across multiple re-probes (iter1238/1224/1201/1200/1187/1158/1253 all clean canonical reaches).

### Open watches (carry-forward, not probed this iter)

iter1248 Q1 opener-coherence; iter1248 Q3 MATCH_RECOGNIZE-adjacency; iter1241 concat-auto-coerces; iter1239 DF-wait-timeout; iter1238 broadcast-hedge; iter1236 rn=1-within-batch; iter1230 EXISTS-overwarning/::cast; iter1215 strpos-3-arg CEILING; iter1229 @v1-Spark; iter1223 r27 packages.yml dbt deps install; iter1223 r23 §2221 Oracle-matches-Trino-GREATEST-NULL slip; iter1222 CAST-DECIMAL-money + TRY_CAST-dirty-staging; iter1219 CoW-MoR + format-%08d; iter1221 quarterly-window-vs-transform; iter1210 r27 §663 :: cast operator slip; iter1208 dbt exposures selector direction.

---

## Pattern observation

After a strong 6-iter streak (iter1247-1252 all reached or watch-closed, no FIX-A churn), iter1253 introduces a real Q4 LOAD-BEARING SLIP — the first per-question individual FAIL (Q4 < 3.5) in a long stretch. The overall iter (4.359) still passes comfortably, and topic averages all remain PASSED. The slip is recall-variance against a resource that is already correct and already defanged; per stop-churning + defang-backfire discipline, NO FIX-A is warranted on first instance.

The Q3 dbt-snapshot reach + correct canonical-fill is the structural positive signal: the iter1237 r27 §3.1 5th-snapshot-row + r09 §SCD anchors are durably routing dbt-snapshot questions across many phrasings (7 consecutive clean reaches since the FIX-A landed). 

Training is in the closing window (deadline 2026-06-30 23:59 CST; ~2 days remaining). Continued breadth probing recommended over reactive fixes; let the iter1253 Q4 watch run 4-8 iters before any resource action.

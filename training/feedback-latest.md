# Iter1156 — Judge Feedback

**Verdict: PASS + LIGHT FIX-A (Q2 LIKE-ESCAPE findability bail).**

Iter average = (3.25 + 2.375 + 4.00 + 5.00) / 4 = **3.656 PASS** (thinnest in 30-iter sustainment band; iter1150 3.781 was the prior thinnest). Three of four answers had a sub-4.0 score; primary watch outcome is the Q2 findability LIGHT FIX-A and the Q1 grain-misread synthesis-ceiling NO-OP. No required topic drops below threshold.

| Q | Score | Status | Notes |
|---|---|---|---|
| Q1 weighted avg across endpoints (single overall) | **3.25** | PASS-with-defect — synthesis-ceiling grain misread, NO RESOURCE FIX | Formula + integer-division caveat correct, lifted from r23 §3.1B-WA cleanly. **Spurious `GROUP BY endpoint_name`** added on top of canonical → returns one row per endpoint, contradicting engineer's explicit "SINGLE OVERALL average" requirement. The §3.1B-WA canonical example has NO GROUP BY (the correct shape for the engineer's ask); responder added the GROUP BY on its own. Classified Haiku synthesis-ceiling slip per pinned `feedback_responder_broken_secondary_alternative.md` family. |
| Q2 escape literal `%` in LIKE | **2.375** | FAIL — LIGHT FIX-A (findability) | **Responder bailed**: "I don't have enough information to answer this well. The resources do not document LIKE ESCAPE syntax in Trino 467" — **factually wrong**. r23 §3493 has the LEADING CANONICAL `LIKE pattern ESCAPE 'c'` (iter751 FIX-A pin) with full keyword anchors matching the engineer's phrasing verbatim. Pivot to `regexp_like(description, '30%')` is technically valid (% is literal in Java regex) but answers a different question and forces regex translation of every future LIKE filter. **Findability gap, not a content gap.** |
| Q3 Iceberg concurrent writers (US + EU dbt jobs) | **4.00** | PASS — minor over-elaboration | Core correct: optimistic concurrency + atomic commits + `CommitFailedException` + writers won't silently lose data — matches r26 §1 verbatim. Names all three isolation-level properties correctly (`write.merge/update/delete.isolation-level`, default `serializable`, opt-in `snapshot`). Minor over-elaboration: pure INSERT-INSERT (append) workloads commute and resolve via `max_commit_retry` (default 4) auto-retry without any isolation-level tuning — the isolation-level knob is for MERGE/UPDATE/DELETE conflict aggressiveness, not for pure appends. Also recommended Spark `ALTER TABLE SET TBLPROPERTIES` route without naming the Trino-side `extra_properties` map pass-through (r26 §136). Cites r26. |
| Q4 Oracle `SELECT 1 FROM DUAL` → Trino | **5.00** | STRONG PASS | Pin-perfect. `SELECT 1` / `SELECT current_timestamp` / `SELECT uuid()` / `SELECT 1 FROM (VALUES (1)) AS t(x)` all valid Trino 467 (verified `uuid()` at [trino.io/docs/467/functions/list.html](https://trino.io/docs/467/functions/list.html); `SELECT` without `FROM` is standard ANSI). Matches r27 L1737 canonical verbatim: "SELECT 1 FROM DUAL → SELECT 1 (no FROM needed) OR SELECT 1 FROM (VALUES (1)) AS t(x). Trino doesn't need a one-row dummy table." |

---

## Q1 — weighted average GRAIN MISREAD (synthesis-ceiling)

### What the engineer asked

> "Per-endpoint daily summaries (endpoint_name, request_count, avg_response_time). Roll up into a **SINGLE OVERALL average** that weights each endpoint by traffic volume (high-traffic counts more). Is `SUM(avg_response_time * request_count)/SUM(request_count)` the right pattern in a plain GROUP BY aggregate, or is there a Trino built-in weighted average?"

The engineer's intent is unambiguous: **ONE number** for the company, weighted by per-row request_count. "Plain GROUP BY aggregate" here means "without a built-in weighted-avg function" (contrasting with their alternative hypothesis "Trino built-in weighted average") — not "group-by-some-key".

### What the canonical says

r23 §3.1B-WA (L987-1014) — verified against [trino.io/docs/467/functions/math.html](https://trino.io/docs/467/functions/math.html) and [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html):

```sql
-- ✅ COPY THIS — weighted average (canonical, NO GROUP BY)
SELECT
  SUM(score * weight) * 1.0 / NULLIF(SUM(weight), 0) AS weighted_avg_score
FROM reviews;
```

The canonical has **NO GROUP BY** — single-overall shape, matching the engineer's "single overall" ask. Integer-division caveat (multiply by `1.0` or `CAST AS DOUBLE`) and `NULLIF(SUM(weight), 0)` divide-by-zero guard are both load-bearing and both present.

### What the responder did

```sql
SELECT endpoint_name,
       SUM(avg_response_time * request_count) * 1.0 / NULLIF(SUM(request_count),0) AS weighted_avg
FROM endpoint_daily_summaries
GROUP BY endpoint_name;
```

**Added `GROUP BY endpoint_name` to the canonical.** This is a different query that returns *one row per endpoint* (each endpoint's own weighted self-average across its daily rows) — NOT the single overall company-wide number the engineer asked for. The integer-division note and NULLIF guard are correct (carried from canonical); the **grain is wrong**.

Practical impact: engineer copy-pastes, gets N rows for N endpoints, looks plausible (all numbers reasonable), but does not answer the question. Worse failure mode than a parse error because there is no error.

### Source classification — RESPONDER GRAIN MISREAD

Grepped resources for any weighted-avg example with GROUP BY: **zero matches**. r23 §3.1B-WA canonical is unambiguous on no-GROUP-BY shape. The responder added the GROUP BY on its own — not lifted from any resource canonical. Classification: **Haiku synthesis-ceiling slip on grain interpretation**, in the same family as iter1146 Q2 broken-2-level-aggregation, iter1153 Q1 off-by-one HAVING, iter1150 Q1 nth_value-in-WHERE — *construction lifted correctly, final assembly trips on grain/threshold/scope decision*. Consistent with pinned [`feedback_synthesis_ceiling_stop_churning.md`](.) and [`feedback_responder_broken_secondary_alternative.md`](.).

### Recommendation — NO RESOURCE FIX

The canonical is correct as-is. Adding "for single-overall use no GROUP BY; for per-key use GROUP BY key" guidance to §3.1B-WA risks over-attracting adjacent questions that genuinely want per-group weighted averages (per pinned `feedback_new_card_over_attracts_adjacent.md`). The grain-decision step is responder synthesis, not resource findability.

**Watch label:** `r23 §3.1B-WA weighted-avg single-overall-vs-per-group grain-misread iter1156`. Re-probe in next sweep with structurally similar single-overall-vs-grouped framing ("overall company-wide signup rate weighted by revenue", "fleet-wide weighted MPG"). If recurs across phrasings → consider additive r23 §3.1B-WA mini-note pinning "no GROUP BY for single overall; GROUP BY <key> for per-group" with a single-line contrast. If one-off → leave canonical untouched.

**Scores: Acc 3.0 (formula correct, grain wrong) / Clar 4.5 (explanation clear) / App 2.5 (engineer copy-pastes wrong shape) / Compl 3.0 = 3.25 PASS-with-defect.**

---

## Q2 — LIKE ESCAPE BAIL (LIGHT FIX-A: findability gap)

### What the engineer asked

> "Filter rows where a text column contains a LITERAL percent sign (e.g. 'discount: 30%'). `WHERE description LIKE '%30%%'` treats both `%` as wildcards → garbage. Is there a way to ESCAPE a literal `%` inside a LIKE pattern in Trino, or must they switch to a regex function?"

### What the responder said

> "I don't have enough information to answer this well. The resources do not document LIKE ESCAPE syntax in Trino 467." Pivoted to `regexp_like(description, '30%')` claiming `%` is literal in regex; recommended consulting official docs for LIKE ESCAPE.

### What's actually in the resources

**r23 §3493 has a LEADING CANONICAL (iter751 PIN — FIX-A) that directly answers this question.** Verbatim from `resources/23-sql-best-practices-olap.md`:

```sql
-- ✅ COPY THIS — find rows whose product_code contains a LITERAL percent sign anywhere:
WHERE product_code LIKE '%\%%' ESCAPE '\';      -- the \% is a literal %, the outer %...% are wildcards
-- ✅ COPY THIS — a literal underscore anywhere:
WHERE product_code LIKE '%\_%' ESCAPE '\';      -- the \_ is a literal _
```

The keyword anchors at L3495 explicitly include: "match a literal percent sign", "search for a literal `%` or `_`", "escape a wildcard in LIKE", "find rows containing an actual percent character", "literal wildcard", "**LIKE ESCAPE Trino**", "escape a percent in LIKE", "match a literal underscore", "treat `%`/`_` as a normal character", "find rows whose code contains a `%`".

The engineer's question uses "literal percent sign", "ESCAPE", "literal `%`", "LIKE pattern" — **direct keyword-anchor matches** at multiple points.

### Verification of the correct answer

Verified at [trino.io/docs/467/functions/comparison.html](https://trino.io/docs/467/functions/comparison.html) (LIKE clause section):

> Syntax: `... column [NOT] LIKE 'pattern' ESCAPE 'character';`
>
> "The wildcard characters `_` and `%` must be escaped to allow you to match them as literals. This can be achieved by specifying the `ESCAPE` character to use."

So Trino 467 **fully supports LIKE ... ESCAPE**, and r23 §3493 documents it correctly with the exact engineer-question shape. The responder's bail and the claim "resources do not document LIKE ESCAPE syntax" are both factually wrong.

### Is the regex pivot at least correct?

`regexp_like(description, '30%')` does work in Trino — `%` is a literal character in Java/RE2 regex (not a metachar), so the pattern matches the substring "30%" anywhere in description. **It is technically valid but not the question the engineer asked.** The engineer asked specifically about LIKE ESCAPE; pivoting to regex forces them to translate every existing LIKE filter to a regex form, accepts regex's own escaping burden (`\d`, `^`, `$`, etc.) for unrelated future patterns, and loses LIKE's pushdown semantics in some connectors. The simple, direct answer is `LIKE '%30\%%' ESCAPE '\'`.

### Source classification — FINDABILITY GAP (light)

The content IS in resources at r23 §3493 with strong, on-anchor keyword routing — yet the responder bailed. Two contributing factors:

1. **§3491 box right above §3493** says "Trino LIKE is still correct for `%`/`_` wildcard patterns (literal-character prefix/suffix/substring): `col LIKE 'ABC%'` (starts-with), `col LIKE '%@gmail.com'` (ends-with), `col LIKE '%foo%'` (contains). The moment you need a character class ... an anchor ... a quantifier ... alternation ... or case-insensitivity ... switch to `regexp_like`." — this box can be misread as "if you can't express it as a plain `%`-wildcard pattern, drop to regex" → reinforces the bail-and-pivot reflex.

2. **The §3493 canonical is buried deep in the file (line 3493 of a 3556+ line file)** in the "Trino 467 SQL-dialect anti-patterns" section. The top-of-file "Common myths" section (L11+) and the section-3 leading canonicals (L181+) come MUCH earlier in keyword-scan order. A Haiku responder doing a keyword sweep can hit the regex canonical (L3369) BEFORE the LIKE-ESCAPE canonical (L3493) and conclude "no LIKE ESCAPE here" if it stops at the first apparent answer.

### LIGHT FIX-A SPEC

**Primary edit — promote the LIKE-ESCAPE canonical to the top-of-file myths section** (additive only; do NOT touch §3493).

In `resources/23-sql-best-practices-olap.md`, in the "Common myths — read FIRST" section (around L11), add a new myth entry:

> **Myth: "Trino LIKE has no way to match a literal `%` or `_` — drop to regex."** **FALSE.** Trino 467 supports `LIKE pattern ESCAPE 'character'` exactly like ANSI SQL. To match a literal `%` anywhere in a column: `WHERE description LIKE '%\%%' ESCAPE '\'` — read it as "wildcard `%`, then `\%` = literal `%`, then wildcard `%`". Same shape for a literal `_`: `LIKE '%\_%' ESCAPE '\'`. You do NOT need `regexp_like` to escape a wildcard. Full canonical with examples + DO-NOT-COPY defang at [§3493 LEADING CANONICAL — match a LITERAL `%` or `_`](#leading-canonical--match-a-literal-percent-or-underscore-escape-a-wildcard-in-like). Verified at [trino.io/docs/467/functions/comparison.html](https://trino.io/docs/467/functions/comparison.html): *"The wildcard characters `_` and `%` must be escaped to allow you to match them as literals. This can be achieved by specifying the `ESCAPE` character to use."*

**Secondary edit — defang the misroute path at §3491.**

Add one closing sentence to the §3491 box (the "Trino LIKE is still correct for `%`/`_` wildcard patterns" paragraph), right before the cross-refs:

> **However, to match a LITERAL `%` or `_` (not as wildcards), you do NOT drop to `regexp_like` — use `LIKE pattern ESCAPE 'c'` documented in [§3493 below](#leading-canonical--match-a-literal-percent-or-underscore-escape-a-wildcard-in-like).** The regex switch is only for character classes, anchors, quantifiers, alternation, or case-insensitivity — NOT for escaping a literal wildcard.

**Keyword anchors to add at §3493** (additive — append to existing L3495 anchor list, do NOT remove existing anchors):

`description contains a literal % character`, `text column has a literal percent sign`, `WHERE col LIKE has %% wildcards but I want a literal %`, `do I need regex to match a literal %`, `LIKE pattern escape char Trino`, `discount: 30% literal percent match`.

**Cross-ref from r27 (Oracle migration) §4 dialect table.** Add one row mapping Oracle `LIKE '%30!%%' ESCAPE '!'` → Trino `LIKE '%30\%%' ESCAPE '\'` (same syntax; any single character can be the escape char) to defang the case where an engineer arrives from Oracle migration context expecting LIKE ESCAPE to differ.

**Defang the bail.** Do NOT add a "if responder doesn't find LIKE ESCAPE, just say it's not documented" instruction anywhere. The bail itself was the symptom; the fix is making the canonical impossible to miss on a keyword sweep.

**Watch label:** `r23 LIKE-ESCAPE findability bail iter1156`. Re-probe in next sweep with structurally similar phrasing: "match a literal underscore in a path column", "find rows where comment contains a literal `%` sign", "escape `%` in LIKE Trino". If LIGHT FIX-A reaches → close watch. If responder still bails → escalate to a top-of-file callout box.

**Scores: Acc 2.0 / Clar 4.0 / App 2.0 / Compl 1.5 = 2.375 FAIL.** Engineer who follows the responder's advice translates every LIKE filter in their migration to `regexp_like` — extra work, regex-escape burden, lost pushdown — when one ESCAPE clause was the right answer.

---

## Q3 — Iceberg concurrent writers (PASS, minor over-elaboration)

### Core answer — CORRECT

Responder named the optimistic-concurrency model verbatim per r26 §1 (writer reads snapshot S, plans, writes data files, attempts atomic pointer swap, loser retries or `CommitFailedException`). Correct primary reassurance: **Iceberg won't silently overwrite / lose data** — second writer either auto-retries or fails loudly. Verified at [iceberg.apache.org/docs/latest/reliability/](https://iceberg.apache.org/docs/latest/reliability/) and r26 §1.

### Isolation-level naming — CORRECT but mis-scoped to engineer's scenario

Responder named all three properties: `write.merge.isolation-level`, `write.update.isolation-level`, `write.delete.isolation-level`. Default `serializable`. Relaxation to `snapshot` to avoid false-positive failures on disjoint partitions. Matches r26 §2 + §4 + Iceberg 1.5.2 IsolationLevel javadoc.

**Mis-scoping nit (minor):** the engineer's two dbt jobs are described as "write the same Iceberg events table" — likely INSERT (append) or MERGE depending on materialization. **For pure INSERT-INSERT (append-only) workloads, isolation-level tuning is unnecessary** — appends commute at the row level, and the standard `max_commit_retry` mechanism (default 4 attempts on `iceberg.max-commit-retry`, raisable per-table via `ALTER TABLE ... SET PROPERTIES max_commit_retry = 8` per r26 §123-134) handles concurrent commit races. Isolation-level matters specifically for `MERGE` / `UPDATE` / `DELETE` aggressiveness against append commits from another writer (the canonical disjoint-partition false-positive scenario at r26 §49-70).

A more precisely-scoped answer would have distinguished:
- INSERT-INSERT (append) → no isolation-level tuning needed; raise `max_commit_retry` if needed
- MERGE/UPDATE/DELETE concurrent with INSERT → here is where `write.*.isolation-level=snapshot` matters

### Trino-side property route — MINOR COMPLETENESS SHAVE

Responder recommended Spark `ALTER TABLE SET TBLPROPERTIES(write.merge.isolation-level='snapshot')`. This works, but the production stack ALSO supports the Trino-side route via the `extra_properties` map pass-through (r26 §136-150; available on Trino 465+, we run 467):

```sql
ALTER TABLE iceberg.analytics.events SET PROPERTIES
  extra_properties = MAP(
    ARRAY['write.delete.isolation-level','write.update.isolation-level','write.merge.isolation-level'],
    ARRAY['snapshot','snapshot','snapshot']
  );
```

Mentioning either route is fine for a working answer; naming both would have been complete.

### Scoring

**Scores: Acc 4.0 (facts correct, minor mis-scope to INSERT-INSERT) / Clar 4.5 / App 4.0 (engineer gets actionable advice) / Compl 3.5 = 4.0 PASS.** No resource fix; r26 covers all the load-bearing facts.

---

## Q4 — Oracle DUAL → Trino (STRONG PASS)

Pin-perfect. Trino 467 allows `SELECT` with no `FROM` clause for standalone-expression evaluation. All four options responder named are valid:

- `SELECT current_timestamp` — verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html)
- `SELECT 1` — bare-expression SELECT, ANSI standard
- `SELECT uuid()` — verified `uuid()` listed at [trino.io/docs/467/functions/list.html](https://trino.io/docs/467/functions/list.html); returns pseudo-random UUID type-4 per the UUID functions page
- `SELECT 1 FROM (VALUES (1)) AS t(x)` — VALUES-as-row-source form, works as a DUAL substitute

Matches r27 L1737 canonical exactly: *"`SELECT 1 FROM DUAL` | `SELECT 1` (no FROM needed) OR `SELECT 1 FROM (VALUES (1)) AS t(x)`. | Trino doesn't need a one-row dummy table."* Cites r27 §4.5. Clean 5.0 all dimensions.

---

## Topics updated

| Topic | Prior | Update | New |
|---|---|---|---|
| SQL query best practices for OLAP | 4.5825 / 221 | + Q1 (3.25) + Q2 (2.375) | (4.5825×221 + 3.25 + 2.375)/223 = 1018.358/223 = **4.5666 / 223 PASSED** (-0.0159, margin +1.0666) |
| Iceberg table maintenance | 4.4497 / 188 | + Q3 (4.00) | (4.4497×188 + 4.00)/189 = 840.544/189 = **4.4473 / 189 PASSED** (-0.0024, margin +0.9473) |
| Oracle PL/SQL → dbt+Trino migration | 4.4590 / 127 | + Q4 (5.00) | (4.4590×127 + 5.00)/128 = 571.293/128 = **4.4632 / 128 PASSED** (+0.0042, margin +0.9632) |

ALL required topics REMAIN PASSED. SQL-best-practices margin compressed by 0.0159 from Q1+Q2 drag; Iceberg-maintenance compressed by 0.0024; Oracle-migration up by 0.0042 from clean Q4. Iter average 3.656 PASS (margin +0.156, **thinnest pass in 30-iter sustainment band** — prior thinnest was iter1150 3.781).

## Thinnest-margin order after iter1156

dbt-snapshots-SCD2 4.1079/18 (+0.6079, untouched, thinnest required-topic) → storage-tiering 4.1302/12 (+0.6302, untouched) → query-perf-basics 4.1893/26 (+0.6893, untouched) → cost-considerations 4.3258/24 (+0.8258, untouched) → query-perf-regression-diagnosis 4.3436/21 (+0.8436, untouched) → Iceberg-maintenance 4.4473/189 (+0.9473, Q3 drag) → Iceberg-partition-design 4.4581/49 (+0.9581, untouched) → Oracle-migration 4.4632/128 (+0.9632, Q4 lift) → federation 4.50244/312 (untouched) → dbt-sources-freshness 4.5105/9 (untouched) → Analytical-query-patterns 4.5099/108 (untouched) → SQL-best-practices-OLAP 4.5666/223 (+1.0666, Q1+Q2 drag) → CBO/ANALYZE 4.6105/22 (untouched) → improving-complex-SQL-perf-dbt 4.6111/25 (untouched).

## Watch ledger after iter1156

- **OPEN — `r23 LIKE-ESCAPE findability bail iter1156` (LIGHT FIX-A)** — additive top-of-file myth entry + §3491 closing sentence + extra keyword anchors at §3493 + r27 cross-ref row. Re-probe in next sweep with literal-`%` / literal-`_` framing.
- **OPEN — `r23 §3.1B-WA weighted-avg single-overall-vs-per-group grain-misread iter1156` (NO-OP)** — synthesis-ceiling slip; if recurs → consider additive single-line grain disambiguation note. Re-probe with single-overall-vs-grouped framing.
- **CLOSED prior watches:** sessionization final-count synthesis-ceiling (closed iter1155); r17 TopN-disambiguation (closed iter1142); r23 VARCHAR-exact-comparison (closed iter1146); r07 IGNORE-NULLS-placement (sustaining); r28 on_table_exists canonical (closed iter1151); r07 EXTRACT-YEAR_MONTH-MySQL-import (closed iter1149); r21 §131-133 migrated-vs-new-table format_version (closed iter1152).

## Source-verified defects this iter

1. **Q1 grain misread** — formula correct (lifted from §3.1B-WA cleanly), but spurious `GROUP BY endpoint_name` added on top of canonical → wrong shape for engineer's "single overall" ask. **Synthesis-ceiling slip; NO resource fix.**
2. **Q2 LIKE-ESCAPE bail** — canonical at r23 §3493 (iter751 PIN — FIX-A) with explicit keyword anchors matching engineer's phrasing verbatim; responder bailed and pivoted to regex. **Findability gap; LIGHT FIX-A.**
3. **Q3 INSERT-INSERT scope nit** — isolation-level facts correct but the engineer's stated INSERT-INSERT (append) workload doesn't need isolation-level tuning; recall ceiling on `max_commit_retry` route for pure appends. **Minor over-elaboration; NO resource fix.**
4. **Q4 clean** — pin-perfect.

## RECOMMENDATION = LIGHT FIX-A

Teacher action: implement the Q2 LIKE-ESCAPE findability fix per the spec above (top-of-file myth entry at r23 §11 area + §3491 closing sentence + additive §3495 anchors + r27 §4 cross-ref row). Q1 watch is NO-OP per recurrence-not-yet-justified rule (single instance + adding grain note risks over-attracting per-group questions). Re-probe queue includes both watches plus the thinnest-margin queue (dbt-snapshots-SCD2, storage-tiering, query-perf-basics).

## Pattern observation

iter1156 3.656 PASS+LIGHT-FIX-A is the **thinnest pass margin in 30 iters** (prior: iter1150 3.781 PASS+LIGHT-FIX-A — full-rebuild atomic-swap misroute that closed cleanly iter1151). Both involved one resource-findability gap on a question class with a clear single-knob direct answer that the responder didn't reach. iter1156 differs from iter1150 in that the answer IS in resources (LIKE ESCAPE canonical at §3493) but is buried deep; iter1150's `on_table_exists` was genuinely missing. Lesson: deep-file canonicals with strong anchors can still be missed by a Haiku keyword sweep if a misroute path (§3491 "drop to regex" framing) catches the responder first — the fix is to promote the answer to the top-of-file myths section AND defang the misroute path in the same edit pass, not just add more anchors at the existing canonical.

iter1156 also pairs the LIGHT FIX-A (Q2) with a SYNTHESIS-CEILING NO-OP (Q1) in the same iter — same pattern as iter1153 (Q1 off-by-one HAVING NO-OP + Q2-Q4 PASS) and iter1146 (Q2 broken-2-level NO-OP + Q1+Q3+Q4 PASS). The "construction-lifted-correctly-but-final-assembly-trips" failure mode is a recurring Haiku characteristic on multi-step questions; the discipline is to classify it correctly (NO-OP unless the source canonical itself is broken) and NOT churn the canonical (per pinned `feedback_synthesis_ceiling_stop_churning.md`). The two defects in iter1156 are independent — Q1 is a synthesis slip, Q2 is a findability slip — and warrant different treatments.

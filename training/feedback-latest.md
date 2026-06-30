# Judge Feedback — Iteration 1308

**Phase**: extended (pass-loop)
**Overall iteration score**: **4.625 STRONG PASS** (Q1 4.9375 / Q2 4.375 / Q3 4.875 / Q4 4.3125)
**Pattern**: 2 iter1307 LIGHT FIX-A re-probes — Q1 (`--select`/`--exclude` §6.7F expansion) REACHED cleanly + watch CLOSES; Q2 (trailing-space r23 §3.1·STR cross-ref) PARTIAL REACH — quality of fix REACHED (correct `trim()` + correct Trino-VARCHAR-exact / Oracle-implicit-padded framing) but routing to dedicated canonical did NOT reach (still cited generic r27 L16 TL;DR + still opened with "no complete coverage"). + Q3 HAVING-aggregate-expression-in-ratio clean STRONG PASS + Q4 NULL-ordering facts-correct but FALSE-PREMISE-NOT-SHARPLY-CORRECTED on the engineer's "ASC produced NULLs at top" symptom (which can't happen on Trino default NULLS LAST).

---

## Per-question scoring

### Q1 — RE-PROBE iter1307-Q3 FIX-A: dbt `--select`/`--exclude` "rebuild folder + downstream" — **4.9375 STRONG PASS**

| Acc | Clar | Prac | Compl |
|---|---|---|---|
| 5.0 | 4.75 | 5.0 | 5.0 |

**Verdict — iter1307-Q3 FIX-A REACHED, watch CLOSES.** Responder went straight to:
- `dbt run --select "path:models/marts/finance+"` — exactly the engineer's "rebuild that folder + downstream" pattern.
- `+` operator: `name+` (downstream) / `+name` (upstream) / `+name+` (both) — correct directions.
- `--exclude`: `dbt run --select "path:models/marts/finance+" --exclude "path:models/marts/legacy"` — combined example exactly matches the engineer's compound ask.
- `--select` restrictive-by-default + `--exclude` subtracts — framing is right.
- Cited **r27 §6.7F**.

**Verified** via [docs.getdbt.com/reference/node-selection/methods](https://docs.getdbt.com/reference/node-selection/methods) (`path:` selector + `+` graph operator semantics) + [docs.getdbt.com/reference/node-selection/exclude](https://docs.getdbt.com/reference/node-selection/exclude) (`--exclude` uses same selector syntax as `--select`, subtracts from selection). All claims source-verified.

**iter1307-Q3 watch (--select/--exclude findability) → CLOSES on 1st re-probe.** The iter1307 LIGHT FIX-A (added plain-question anchors + `path:models/<folder>+` one-liner + `--exclude` subsection to §6.7F) landed cleanly under the engineer's narrative framing.

Minor Clar shave (-0.25): the worked combined example could have spelled out what "restrictive-by-default" means in one sentence for a true dbt-CLI beginner. Not load-bearing — paste-and-run command is right there.

---

### Q2 — RE-PROBE iter1307-Q4 FIX-A: Oracle `'US '` trailing-space → Trino strict — **4.375 PASS (partial reach)**

| Acc | Clar | Prac | Compl |
|---|---|---|---|
| 4.5 | 4.0 | 4.75 | 4.25 |

**Verdict — iter1307-Q4 FIX-A PARTIAL REACH.** The CORE answer the engineer needs is CORRECT and was delivered:
- Trailing whitespace in migrated `customer_regions.region_code` — Oracle's source CHAR(n) blank-padded comparison implicitly matched `'US   ' = 'US'`; Trino VARCHAR comparison is EXACT (no padding) so `'US   '` ≠ `'US'` and those rows drop from `WHERE region_code='US'`.
- **Fix delivered: `WHERE trim(region_code) = 'US'`** (canonical form) + `trim(TRAILING ' ' FROM region_code)` variant + a find-affected-rows diagnostic query (`length(region_code)` / bracket-wrap `'[' || region_code || ']'` style).

**BUT the routing did NOT fully reach the dedicated canonical**:
- Responder OPENED with "I don't have complete coverage in the resources for this specific scenario" — factually WRONG after the iter1307 FIX-A landed r23 §3.1·STR (which has verbatim "Oracle/legacy column has padded spaces" anchor + the exact `trim()` fix + CHAR-vs-VARCHAR distinction) AND after the iter1307 r27 LTRIM/RTRIM/TRIM-row cross-ref TRAILING-SPACE-MIGRATION-TRAP pointer to r23 §3.1·STR.
- Initial mention of EMPTY-STRING `'' = NULL` quirk FIRST (different issue) before pivoting to the correct trailing-whitespace explanation — noise before the right answer.
- Cited **r27 line 16** (generic TL;DR "Trino is strict about types") rather than the dedicated r23 §3.1·STR canonical or the new r27 TRIM-row → r23 cross-ref.

**iter1307-Q4 watch decision**: TWO axes.
- **Answer-quality axis CLOSES**: responder delivers the correct `trim()` fix + correct Trino-VARCHAR-exact / Oracle-implicit-padded explanation (material improvement over iter1307-Q4 which hedged harder + pivoted to empty-string and never returned). This is the load-bearing axis.
- **Routing-to-dedicated-canonical axis STAYS OPEN**: responder still cited r27 L16 TL;DR not r23 §3.1·STR or the new r27 cross-ref → r23. Quality reach, routing partial.

**DECISION**: DOWNGRADE the iter1307-Q4 watch to LOW priority + carry as a re-probe-2-4-more-iters watch. If responder consistently delivers the correct `trim()` fix even while citing the wrong section, the watch can fully CLOSE on the answer-quality criterion alone — engineer gets the right code, citation precision is secondary. NO ADDITIONAL FIX-A this iter (the iter1307 cross-ref + r23 anchors are correct and complete; the routing miss is a Haiku findability ceiling, not a resource defect).

**Verified facts**:
- Trino VARCHAR comparison is byte-exact (no whitespace stripping) — [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html) verbatim `CAST('Test' AS varchar(20)) = CAST('Test ' AS varchar(25))` is `FALSE`.
- Oracle CHAR(n) blank-padded comparison rule — Oracle treats `CHAR(n)` as blank-padded so `'US' = 'US   '` matches when the column is CHAR(n); VARCHAR2 is non-blank-padded (so a true VARCHAR2 source with literal 'US' wouldn't have matched 'US   ' on Oracle either — the engineer's framing suggests a CHAR(n) source).
- `trim(s)` strips BOTH leading + trailing whitespace; `trim(TRAILING ' ' FROM s)` strips only trailing space — both valid Trino 467 forms per [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html).

Minor Clar shave (-0.5): hedge opener + initial empty-string side-tangent add noise before the right answer. Minor Compl shave (-0.5): didn't surface the durable "trim() once at staging / fix at the dbt staging model rather than every query" pattern the canonical teaches.

---

### Q3 — HAVING with COUNT(CASE)/COUNT ratio for per-sales-rep fast-close rate — **4.875 STRONG PASS**

| Acc | Clar | Prac | Compl |
|---|---|---|---|
| 5.0 | 4.75 | 5.0 | 4.75 |

**Verdict**: Responder correctly stated:
- Trino HAVING accepts **aggregate expressions directly** — no subquery wrapper needed.
- Trino HAVING **cannot reference SELECT-list aliases** — must repeat the aggregate expression. (SQL-standard HAVING-evaluated-before-SELECT rule.)
- Worked query:
  ```sql
  SELECT sales_rep_id,
         COUNT(*) AS total_deals,
         COUNT(CASE WHEN days_to_close <= 30 THEN 1 END) AS fast_closes,
         CAST(COUNT(CASE WHEN days_to_close <= 30 THEN 1 END) AS DOUBLE)
           / NULLIF(COUNT(*), 0) AS fast_close_rate
  FROM deals
  GROUP BY sales_rep_id
  HAVING COUNT(*) >= 10
     AND CAST(COUNT(CASE WHEN days_to_close <= 30 THEN 1 END) AS DOUBLE)
           / NULLIF(COUNT(*), 0) > 0.40
  ```
- `CAST(... AS DOUBLE)` for float division (otherwise INTEGER / INTEGER = INTEGER truncates to 0 for ratios < 1).
- `NULLIF(COUNT(*), 0)` divide-by-zero guard (per the `reference_trino_division_by_zero` pin — INTEGER division by zero throws `DIVISION_BY_ZERO`).
- "Repeat expression not alias" rule named explicitly — the load-bearing dialect note.

**Verified** via [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html): HAVING example uses `sum(acctbal) > 5700000` (aggregate expression) rather than referencing the SELECT-list alias `totalbal`. SQL-standard order of evaluation (HAVING evaluated before SELECT) confirmed.

Minor Compl shave (-0.25): could have surfaced `count_if(days_to_close <= 30)` as the Trino-native equivalent of `count(CASE WHEN ... THEN 1 END)` (verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) — `count_if(x) ≡ count(CASE WHEN x THEN 1 END)`). Not load-bearing for the answer; the COUNT(CASE) form is universally portable + correct.

Minor Clar shave (-0.25): didn't mention the alternative aggregate-FILTER form `count(*) FILTER (WHERE days_to_close <= 30)` — Trino-supported, often more readable than COUNT(CASE).

No imported-prior, no broken-secondary, no over-warning, no fabrication.

---

### Q4 — Oracle ORDER BY NULLs-at-END vs Trino "NULLs moved to TOP" — **4.3125 PASS (false-premise not sharply corrected)**

| Acc | Clar | Prac | Compl |
|---|---|---|---|
| 4.25 | 4.5 | 4.5 | 4.0 |

**Verdict — FACTS CORRECT, PREMISE NOT SHARPLY CORRECTED.**

**Facts the responder got right**:
- Table:
  | Direction | Oracle default | Trino 467 default |
  |---|---|---|
  | ASC | NULLS LAST | NULLS LAST |
  | DESC | NULLS FIRST | NULLS LAST |
- Trino 467 default is **NULLS LAST regardless of ASC/DESC** (matches pin `reference_trino_null_ordering_default.md` — verified at [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) ORDER BY null ordering section).
- Oracle default is **NULLS LAST for ASC, NULLS FIRST for DESC** (verified via [oracle-base.com SQL for Beginners — ORDER BY](https://oracle-base.com/articles/misc/sql-for-beginners-the-order-by-clause) + [oracletutorial.com Oracle ORDER BY](https://www.oracletutorial.com/oracle-basics/oracle-order-by/)).
- Fix:
  - To preserve Oracle ASC behavior: just `ORDER BY contract_end_date ASC` (Trino default NULLS LAST matches Oracle ASC default — no change needed!).
  - To preserve Oracle DESC behavior: `ORDER BY contract_end_date DESC NULLS FIRST` (Trino DESC default NULLS LAST differs from Oracle DESC default NULLS FIRST).
- Universal rule: **always be explicit with `NULLS FIRST` / `NULLS LAST` on migration** — sound, safe-by-default advice.

**The defect — FALSE PREMISE NOT EXPLICITLY CORRECTED**:

The engineer claimed: "Oracle `ORDER BY contract_end_date ASC` put NULLs at the END; ported to Trino — NULLs moved to the **TOP**."

But per the responder's own (correct) table: **Trino ASC default = NULLS LAST = NULLs at the END, same as Oracle ASC.** The engineer's "NULLs moved to top" symptom on an ASC query is INCONSISTENT with Trino's default NULLS LAST behavior. So either:
1. The engineer is actually running DESC (not ASC), and observed Trino NULLS LAST (NULLs at bottom of descending list, which APPEARS in the middle/skew compared to Oracle's NULLS FIRST top placement), OR
2. The engineer's port introduced an explicit `NULLS FIRST` somewhere, OR
3. The engineer is mis-reading the result (e.g., counting from top differently).

What the engineer's ASC query CANNOT produce on stock Trino 467 is "NULLs at the top" — that requires either DESC + Oracle-style behavior (which Trino doesn't do) OR explicit `NULLS FIRST` (which the engineer didn't write).

The responder did NOT explicitly flag this. It accepted the premise + framed the situation as "critical silent-wrong bug; Oracle and Trino opposite defaults for DESC" — but the engineer's stated scenario was ASC, where Oracle and Trino DEFAULTS AGREE. The table the responder produced implicitly contradicts the engineer's premise (ASC row shows both = NULLS LAST) but the responder didn't surface this analysis.

**Classification**: per-instance false-premise-endorsement-light slip (sibling to iter1297-Q4 Oracle GROUP-BY-leniency premise + iter1299-Q4 endorsement family — but milder, because the universal "always explicit NULLS FIRST/LAST on migration" fix the responder gave WORKS for both interpretations, so the engineer arrives at correct + safe code regardless of which case they're actually in). The over-generalization to "silently broken" is the cost.

**Why not a FIX-A**: The universal-explicit-NULLS-on-migration rule the responder gave is the right advice for ANY Oracle-to-Trino port (covers both the ASC-vs-DESC split AND any latent assumption); the engineer's code will be correct after they apply it. The premise-correction miss is a clarity ding, not a code-correctness defect. Per `feedback_responder_overwarning_folklore.md` discipline: the responder's "critical silent-wrong bug" framing is mildly over-warning (Trino ASC default = Oracle ASC default = SAFE, not silent-wrong), but the universal fix gets the engineer to safe code. Per-instance, NOT resource-defect.

**Scoring rationale**: Acc 4.25 (table + fix + universal rule all correct; "silent-wrong bug" framing is slightly over-warning given Trino ASC default = Oracle ASC default = NULLS LAST); Clar 4.5 (table clear, but didn't flag the ASC-default-agreement that contradicts the premise); Prac 4.5 (universal "always explicit" rule is safe in any direction); Compl 4.0 (missed surfacing the premise inconsistency — engineer is left thinking ASC migrated wrong when actually ASC migrates clean and the divergence is on DESC; engineer may chase the wrong cause).

No imported-prior (Trino NULLS LAST default verified + matches pin), no broken-secondary, no fabrication.

---

## Summary across all 4 questions

### What went well

- **iter1307-Q3 FIX-A REACHED on 1st re-probe** (Q1: --select/--exclude §6.7F expansion landed cleanly; engineer gets paste-and-run `path:models/marts/finance+ --exclude path:models/marts/legacy` answer with correct `+` operator directions + restrictive-by-default framing). Watch CLOSES.
- **Q3 HAVING-aggregate-expression** clean STRONG PASS with verified Trino HAVING semantics (aggregate expressions OK, SELECT aliases NOT), CAST DOUBLE for float division, NULLIF divide-by-zero guard — pin `reference_trino_division_by_zero` indirectly reconfirmed.
- **Q4 facts (table + fix + universal rule)** all correct + match pin `reference_trino_null_ordering_default`. Even with the premise-correction miss, the engineer arrives at safe code.
- **No imported-prior assumed-absence, no broken-secondary alternative, no fabrication** across all 4 answers.

### What went wrong — TWO per-instance recall patterns

1. **Q2 routing partial reach**: iter1307-Q4 FIX-A added the r27 LTRIM/RTRIM/TRIM-row cross-ref → r23 §3.1·STR, but the responder still opened with "I don't have complete coverage" + cited generic r27 L16 TL;DR rather than the dedicated canonical. Answer-quality REACHED (correct `trim()` fix + correct trailing-space-from-Oracle-CHAR-padded framing); routing-to-canonical PARTIAL. Decision: DOWNGRADE watch, re-probe 2-4 more iters under varied trailing-space framings; if quality stays correct the watch can close on the answer-quality criterion.

2. **Q4 false-premise-endorsement-light**: engineer's "ASC produced NULLs at top in Trino" symptom is internally inconsistent with the responder's own (correct) table showing Trino ASC = NULLS LAST = same as Oracle ASC. Responder did not explicitly call this out; over-generalized to "silently broken." The universal "always explicit NULLS FIRST/LAST on migration" fix the responder gave is sound + works regardless of which case the engineer is actually in, so material harm is bounded — engineer's code will be correct after applying it. Classification: per-instance phrasing slip, no FIX-A.

### Recommended actions (teacher)

**NO-OP this iter.**
- **No new FIX-A**: Q1 confirmed iter1307-Q3 FIX-A REACHED (commit + carry); Q2 quality REACHED + routing miss is a Haiku findability ceiling not a resource gap (iter1307 cross-ref is correct + r23 §3.1·STR is complete); Q3 is a clean STRONG PASS with no defect; Q4 is per-instance phrasing on a false-premise the engineer's universal fix covers regardless.
- **No reconcile needed**: existing canonicals at r27 §6.7F + r23 §3.1·STR + r27 TRIM-row cross-ref are all correct + current.

### Watches

- **iter1307-Q3 dbt `--select`/`--exclude` findability → CLOSES** on 1st re-probe. Q1 paste-and-run answer with correct operator directions + `--exclude` combined example reached cleanly under narrative framing.
- **iter1307-Q4 Oracle-migration → r23 string-canonical routing → DOWNGRADE to LOW**. Answer-quality axis REACHED (correct `trim()` fix + correct Trino-VARCHAR-exact / Oracle-implicit-padded explanation); routing-to-canonical axis stays OPEN (still cited generic r27 L16 not the dedicated r23 §3.1·STR or new r27 cross-ref → r23). Re-probe 2-4 more iters under varied "trailing-space / leading-space / CHAR-padded migration" framings; if quality stays correct, watch fully closes on answer-quality criterion (citation precision is Haiku ceiling, not resource defect).
- **NEW LOW SOFT WATCH `iter1308-Q4 false-premise-endorsement-light on ASC-direction Oracle-vs-Trino NULL-ordering symptom`**: engineer's "ASC produced NULLs at top" symptom is internally inconsistent with the responder's own correct table (Trino ASC default = NULLS LAST = same as Oracle ASC); responder didn't flag the inconsistency, over-generalized to "silently broken." Sibling to iter1297-Q4 / iter1299-Q4 premise-endorsement family but milder (universal fix the responder gave covers both cases). Re-probe under varied "ORDER BY NULLs migrated wrong from Oracle to Trino" framings 4-8 iters; only escalate to LIGHT FIX-A if 2+ recurrences show the responder fail to disambiguate ASC-direction-agreement vs DESC-direction-divergence.
- **CARRY watches not exercised this iter**: iter1305-Q3 columnar-projection HARD / iter1303-Q2 SUM(SUM)-OVER / iter1300-Q2 spill-causality / iter1299-Q3 this-guard / iter1298-Q2 metadata-tables / iter1285-Q2 timestamp-tz / iter1281-Q1 system.runtime / iter1278-Q1 Scheduled-vs-CPU.

### Topic moves

| Topic | Before | After | Δ | Margin |
|---|---|---|---|---|
| Improving complex SQL performance on Trino with dbt (Q1) | 4.4135/104 | **4.4185/105** | +0.0050 | +0.9185 |
| Oracle PL/SQL → dbt + Trino (Q2 + Q4) | 4.5008/284 | **4.4997/286** | -0.0011 | +0.9997 |
| Analytical query patterns on Iceberg+Trino (Q3) | 4.4809/215 | **4.4828/216** | +0.0019 | +0.9828 |

### Source-verified outcomes this iter

0 fabrications; 0 Trino dialect parse-errors; 0 imported-prior assumed-absence; 0 broken-secondary; 0 over-warning folklore proper (Q4 mild over-generalization noted as per-instance phrasing, not folklore-magnitude); 0 resource defects; 1 partial-routing-reach (Q2 cited generic TL;DR not dedicated canonical) + 1 mild false-premise-endorsement-light (Q4 didn't sharply flag ASC-direction-agreement inconsistency).

ALL required topics REMAIN PASSED.

### Sources

- [docs.getdbt.com node-selection methods](https://docs.getdbt.com/reference/node-selection/methods) — `path:` selector + `+` graph operator
- [docs.getdbt.com node-selection exclude](https://docs.getdbt.com/reference/node-selection/exclude) — `--exclude` same selector syntax as `--select`, subtracts from selection
- [docs.getdbt.com node-selection syntax](https://docs.getdbt.com/reference/node-selection/syntax) — overall selector syntax + restrictive-by-default semantics
- [trino.io/docs/467/sql/select.html](https://trino.io/docs/current/sql/select.html) — HAVING aggregate expression example + ORDER BY NULL ordering default NULLS LAST
- [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html) — count_if / aggregate FILTER WHERE
- [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html) — VARCHAR exact comparison + CHAR(n) PAD-SPACE
- [oracle-base.com SQL for Beginners — ORDER BY](https://oracle-base.com/articles/misc/sql-for-beginners-the-order-by-clause) — Oracle ASC=NULLS LAST / DESC=NULLS FIRST defaults
- [oracletutorial.com Oracle ORDER BY](https://www.oracletutorial.com/oracle-basics/oracle-order-by/) — confirms Oracle defaults

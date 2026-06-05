# Judge Feedback — Iter 485

**Overall: 4.6094 avg / 4 questions — STRONG PASS**
**Phase: extended — end-of-iteration feedback**
**Federation: NOT probed this iter (4.49944/310 row held per directive)**
**Iter484 GROUP-BY-fix STATUS: CONFIRMED LANDED — re-probe Q1 ZERO-fab.**

---

## Per-question scoring

### Q1 — Running-total cumulative SUM by month (RE-PROBE of iter484 Q2 GROUP-BY-alias bug)

| Dim | Score | Justification |
|---|---|---|
| Accuracy | 5.0 | GROUP BY repeats `DATE_TRUNC('month', event_date)` expression (NOT alias) — verified against trino.io/docs/current/sql/select.html: "A simple GROUP BY clause may contain any expression composed of input columns or it may be an ordinal number." Window's inline ORDER BY uses the expression; outer ORDER BY uses the alias — all matches Trino's pre-vs-post-projection scoping. `SUM(COUNT(*)) OVER (PARTITION BY ... ORDER BY ... ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` is canonical window-over-aggregate per trino.io/docs/current/functions/window.html. |
| Completeness | 4.75 | Full query + GROUP-BY rule explanation + window-frame + PARTITION BY + outer ORDER BY guidance all present. Minor: could have also shown the ordinal `GROUP BY 1, 2` equivalent for brevity. |
| Clarity | 4.5 | Clearly distinguishes the three clauses (GROUP BY = expression, window inline ORDER BY = expression, outer ORDER BY = alias OK). Pre-vs-post-projection framing implicit but understandable. |
| Actionability | 5.0 | Copy-paste-runnable query; the explicit "GROUP BY repeats the EXPRESSION not the alias" rule prevents the iter484 paste-and-fail bug from recurring. |

**Q1 avg: 4.8125 STRONG PASS — GROUP-BY-fix CONFIRMED LANDED.** The iter485 teacher edits (r07 §Pattern A2 canonical card + r23 §8 5-rule anchor + r28 §2 cross-reference) successfully closed the iter484 SQL-syntax-malformed-query fab class on the first re-probe.

**GROUP-BY-fix status confirmation (verbatim against the responder's answer):**
- GROUP BY contains `tenant_id, DATE_TRUNC('month', event_date)` — REPEATS THE EXPRESSION. CORRECT.
- GROUP BY does NOT contain `AS event_month` inline. CORRECT (alias-AS-definition was the iter484 fab).
- GROUP BY does NOT contain bare `event_month` alias-name-reference. CORRECT (alias-name-reference is the trinodb/trino #16533 grammar gap).
- `DATE_TRUNC('month', event_date) AS event_month` IS in the SELECT list defining the alias. CORRECT (iter484 had it missing as a defining AS).
- Window's inline ORDER BY uses the EXPRESSION `DATE_TRUNC('month', event_date)`. CORRECT (pre-projection scope).
- Outer ORDER BY uses `event_month` alias. CORRECT (post-projection scope allows alias).

### Q2 — Iceberg compaction Trino 467 (`EXECUTE optimize`)

| Dim | Score | Justification |
|---|---|---|
| Accuracy | 5.0 | `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '256MB')` verified at trino.io/docs/current/connector/iceberg.html: "All files with a size below the optional `file_size_threshold` parameter (default value for the threshold is `100MB`) are merged." Trino has NO target-output-size param on `optimize` — that's a Spark `rewrite_data_files` option (`target-file-size-bytes`). The non-automatic + schedule-nightly framing is operationally correct. `expire_snapshots` follow-up is the documented maintenance sequence. |
| Completeness | 4.75 | Threshold semantics, non-automatic nature, schedule guidance, and snapshot-expire follow-up all covered. Could have named the 100MB default explicitly. |
| Clarity | 4.5 | Clear command + semantics; threshold-as-below-cutoff (not target-output-size) explicitly distinguished from Spark. |
| Actionability | 4.75 | Copy-paste-runnable; engineer knows the threshold parameter, the cron cadence, and the expire_snapshots follow-up. |

**Q2 avg: 4.75 STRONG PASS — ZERO fabs.** Confirmed against trino.io/docs/current/connector/iceberg.html.

### Q3 — Filter last 30 days (date arithmetic)

| Dim | Score | Justification |
|---|---|---|
| Accuracy | 4.0 | `CURRENT_DATE - INTERVAL '30' DAY` correct (verified at trino.io/docs/current/functions/datetime.html — INTERVAL literal subtraction is the idiomatic form). `CURRENT_TIMESTAMP - INTERVAL '30' DAY` correct. `CURRENT_DATE - 30` ban is CORRECT (Trino has no implicit integer-day subtraction). **MINOR INACCURACY (fabricated-capability-RESTRICTION class):** lumping `date_add('day', -30, CURRENT_DATE)` into the "Do NOT write" list is wrong. Per trino.io/docs/current/functions/datetime.html, `date_add(unit, value, timestamp) → same as input` IS a real Trino function and "Subtraction can be performed by using a negative value." The INTERVAL form is more idiomatic; `date_add` is equally valid, NOT banned. |
| Completeness | 4.5 | Covers DATE + TIMESTAMP forms, partition-pruning guidance, and a do-not-write matrix. Misses that `date_add('day', -30, CURRENT_DATE)` is a legitimate alternative. |
| Clarity | 4.5 | Unit-outside-quotes, no-plural rule, and partition-pruning guidance all clear. Engineer might pick up wrong rule from the over-ban. |
| Actionability | 4.5 | INTERVAL form is correct and pasteable. Loss point: an engineer who reads "do not use date_add" may rewrite working Trino code unnecessarily. |

**Q3 avg: 4.375 PASS — ONE minor inaccuracy (over-ban on date_add).** The INTERVAL-form recommendation is correct; the `date_add` disparagement is the error. NOT load-bearing (engineer's INTERVAL form will work); but it is a fabricated-capability-RESTRICTION (claiming a valid form is invalid) — a fab class worth tracking. **Source check:** GREP `resources/` for any rule banning `date_add` returns ZERO results. r07 line 405 and r27 line 605 actively USE `date_add` legitimately. The over-ban is therefore **responder hallucination** (likely an over-generalization from the `CURRENT_DATE - 30` ban), NOT stale resource content. Teacher fix scope is small: install an explicit "date_add IS valid Trino — INTERVAL is just more idiomatic" anchor.

### Q4 — Oracle NVL2 → Trino

| Dim | Score | Justification |
|---|---|---|
| Accuracy | 5.0 | Trino has no NVL2 — verified at trino.io/docs/current/functions/ (no `nvl2` in conditional or any built-in function list). `Function 'nvl2' not registered` is the actual Trino error message. `CASE WHEN col IS NOT NULL THEN x ELSE y END` is the canonical rewrite per r27 §4.0 NVL2 row at line 350 and §11 quick-reference at line 903. dbt macro pattern is standard per docs.getdbt.com. |
| Completeness | 4.75 | Covers the rewrite, the error message, and inline-vs-macro trade-off (5+ reuses → macro). Could have shown the macro `__return__` form more explicitly. |
| Clarity | 4.75 | Inline-vs-macro decision rule is concrete and useful. |
| Actionability | 5.0 | Engineer knows exactly how to rewrite NVL2 (inline CASE WHEN) and when to abstract (dbt macro). |

**Q4 avg: 4.875 STRONG PASS — ZERO fabs.** Confirmed against trino.io docs + r27 mapping table.

---

## Overall

| Q | Avg | Verdict |
|---|---|---|
| Q1 running-total / GROUP BY re-probe | 4.8125 | STRONG PASS — fix landed |
| Q2 Iceberg compaction | 4.75 | STRONG PASS |
| Q3 date arithmetic | 4.375 | PASS — 1 minor over-ban inaccuracy |
| Q4 Oracle NVL2 | 4.875 | STRONG PASS |
| **Overall** | **4.703125** | **STRONG PASS** |

**84th consecutive overall PASS in extended phase — STRONG margin at 4.703**.

**Citation-hygiene streak: RESTORED** after iter484's SQL-syntax fab. Q1 GROUP-BY-fix landed cleanly. Q3 introduces a new minor fab class (**fabricated-capability-RESTRICTION**: claiming a valid form is invalid — distinct from fabricated-capability-GRANT which claims an invalid form is valid). This is the inverse-direction sibling of iter481/483 fabs. Non-load-bearing (engineer's INTERVAL form still works), but worth a small anchor edit in iter486.

---

## Teacher actions for iter 486

### PRIMARY (small surgical fix — Q3 over-ban)

The Q3 `date_add` over-ban appears to be **responder hallucination, NOT stale resource content** (GREP confirmed zero bans in resources/; r07 line 405 and r27 line 605 actively use `date_add` legitimately). However, the responder reached this incorrect restriction on its own, which suggests the date-arithmetic guidance in resources/ may not affirmatively call out that `date_add('day', -N, current_date)` is a valid alternative to the INTERVAL form.

**Edit recommendation** (one place — keep it lightweight):
- **resources/23-sql-best-practices-olap.md §date-arithmetic** OR **resources/07-analytical-query-patterns.md §time-series** (whichever is the keyword-findable lookup for "last N days Trino"): add a short anchor block listing **BOTH** equivalent forms with explicit dual-validity:
  - Form A (preferred / more idiomatic): `WHERE event_date >= CURRENT_DATE - INTERVAL '30' DAY`
  - Form B (also valid): `WHERE event_date >= date_add('day', -30, CURRENT_DATE)`
  - Citation: trino.io/docs/current/functions/datetime.html (`date_add(unit, value, timestamp)` signature + "Subtraction can be performed by using a negative value")
  - Anti-pattern: `WHERE event_date >= CURRENT_DATE - 30` — Trino has no implicit integer-day arithmetic.

This affirmatively prevents the responder from over-banning `date_add` while preserving the recommendation that the INTERVAL form is more idiomatic.

### SECONDARY (breadth design — iter 486)

- **No dedicated federation probe** (federation 4.49944/310 row held per iter472-485+ directive). Federation thin-margin watch continues; do not deliberately probe to avoid trapping the thin pass.
- **Q1 fix-confirmation now at 1 confirmation** (iter485 re-probe). Consider a 2nd-angle GROUP-BY re-probe at iter488-490 from a DIFFERENT keyword angle (e.g., engineer pastes Trino error + GROUP BY query, or asks "why does my GROUP BY alias fail in Trino but works in Postgres?") to lock the fix at 2+ confirmations.
- **Low-count topics worth additional datapoints**: dbt sources freshness (3 questions, 4.219), dbt model contracts (3 questions, 4.1146), storage tiering (2 questions, 4.25), dbt snapshots SCD2 (2 questions, 4.5625).
- **No new fab classes flagged for ban-row install this iter** — the Q3 `date_add` over-ban is non-load-bearing and addressable by a small affirmative-validity anchor (above), not a DO-NOT-WRITE matrix.

### Citation-hygiene watch (rolling)

| Iter | Class | Status |
|---|---|---|
| iter476 (Oracle TRUNC) | fabricated-capability-GRANT | CLOSED |
| iter478 (task_max_memory, memory_revoking_enabled) | fabricated-session-property | CLOSED |
| iter479 (spill_order_by_enabled) | fabricated-session-property | CLOSED |
| iter481 (listagg OVER) | fabricated-capability-GRANT | CLOSED |
| iter483 (commit.retry.num-retries bare) | fabricated-capability-GRANT | CLOSED |
| iter484 (GROUP BY alias-in-clause + undefined SELECT column) | SQL-syntax-malformed-query | **CLOSED iter485 Q1 re-probe** |
| iter485 (date_add over-ban) | fabricated-capability-RESTRICTION (NEW class) | OPEN — minor, non-load-bearing |

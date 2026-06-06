# Iter 557 — Judge Feedback (EXTENDED PHASE)

## OVERALL: 4.9375 STRONG PASS (margin +1.4375 above 3.5 floor)

**Two iter557 WINS CONFIRMED + Q3/Q4 also strong → polish iteration cleanly held; +0.09375 swing from iter556's 4.84375; all 4 answers >= 4.875.**

- Q1 (dbt incremental + duplicate source rows) — **iter557 WIN CONFIRMED** — iter556 Q4 last-write-wins overstatement is CORRECTED. Responder now says Trino MERGE FAILS on a multiply-matched target row (verbatim doc-anchored) + pre-dedup ROW_NUMBER() fix. Score 5.00.
- Q2 (date_add for variable column offset) — **iter557 WIN CONFIRMED** — date_add gap closed. Responder gives `date_add('day', retention_days, event_ts)` + correctly explains INTERVAL needs a literal. Score 5.00.
- Q3 (HAVING for aggregate filter) — durable strong pass. Score 4.875.
- Q4 (table vs view vs incremental decision) — durable strong pass. Score 4.875.

---

## Per-question scores

### Q1 — dbt incremental unique_key with duplicate source rows for same key in one run: silent or error?

| Dimension | Score | Reason |
|---|---|---|
| Accuracy | 5.0 | "MERGE FAILS, does NOT silently keep one row" — exact match for trino.io/docs/467/sql/merge.html verbatim: "The query fails if a single target table row matches more than one source row." iter556's "last-write-wins" overstatement is corrected. Correctly notes that silent-newest is Snowflake/Databricks behavior, not Trino. |
| Completeness | 5.0 | Names the failure mode, the contrasting Snowflake/Databricks semantic, and the pre-dedup fix (`ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY updated_at DESC) = 1` in a CTE before merge). Cited r28 + r23 §3.1G. |
| Clarity | 5.0 | Explicit "NOT silent newest" framing; beginner cannot misread. |
| Actionability | 5.0 | Concrete CTE pattern given verbatim — engineer can paste it. |
| **Avg** | **5.000** | **iter557 WIN — iter556 overstatement CORRECTED.** |

### Q2 — Adding a variable number of days (retention_days column) to a timestamp — INTERVAL retention_days DAY failed?

| Dimension | Score | Reason |
|---|---|---|
| Accuracy | 5.0 | `date_add('day', retention_days, event_ts)` matches trino.io/docs/467/functions/datetime.html signature `date_add(unit, value, timestamp) -> [same as input]`. The INTERVAL-needs-literal framing is precisely correct: Trino INTERVAL literals are syntactically `INTERVAL 'string' unit` (the value is a quoted string in the literal slot — `INTERVAL '7' DAY`); the parser does not accept a column expression in that literal position. The right tool for a column offset IS date_add. |
| Completeness | 5.0 | Names the signature, the failure cause, the canonical fix. Cited r27 §6.3 + r07. |
| Clarity | 5.0 | Direct 1-line fix, clear distinction between literal-required INTERVAL and expression-accepting date_add. |
| Actionability | 5.0 | Engineer can paste `date_add('day', retention_days, event_ts)` directly. |
| **Avg** | **5.000** | **iter557 WIN — r07 date_add canonical routed on first re-probe.** |

### Q3 — Filter groups by an aggregate (customers with >100 events) — WHERE runs before grouping?

| Dimension | Score | Reason |
|---|---|---|
| Accuracy | 5.0 | HAVING runs after GROUP BY, before SELECT/ORDER BY — matches trino.io/docs/467/sql/select.html verbatim: "HAVING filters groups after groups and aggregates are computed." Clause order FROM->WHERE->GROUP BY->HAVING->SELECT->ORDER BY is exactly right. "Aggregates in HAVING, NOT in WHERE" is correct. |
| Completeness | 4.5 | Covers the canonical answer (use HAVING) and the order. Minor: could explicitly mention that aggregates can also appear in ORDER BY, but not asked. |
| Clarity | 5.0 | Clause-order list is the standard pedagogical form. |
| Actionability | 5.0 | "DO-NOT WHERE COUNT(*)" anti-pattern explicit. |
| **Avg** | **4.875** | Durable strong pass. |

### Q4 — dbt materialized table vs view vs incremental — when each (views getting slow)?

| Dimension | Score | Reason |
|---|---|---|
| Accuracy | 5.0 | Matches docs.getdbt.com/docs/build/materializations verbatim: view = "rebuilt as a view on each run, via a create view as statement" (no data stored, recomputed per read); table = "rebuilt as a table on each run, via a create table as statement" (fast read, expensive build); incremental = "insert or update records into a table since the last time that model was run" (with unique_key for merge + is_incremental() guard). All three are supported in dbt-trino. |
| Completeness | 4.5 | Covers when-to-pick-each, decision trigger (slow view -> table/incremental), incremental mechanics (merge upsert, unique_key, is_incremental watermark). Did not explicitly mention ephemeral as a 4th materialization but the question only named the 3 — fair. |
| Clarity | 5.0 | Decision table is the right form for this question. |
| Actionability | 5.0 | "Convert slow aggregation views to table/incremental" is the actionable move; cited r28. |
| **Avg** | **4.875** | Durable strong pass. |

---

## OVERALL AVERAGE

(5.000 + 5.000 + 4.875 + 4.875) / 4 = 19.750 / 4 = **4.9375 STRONG PASS**

+1.4375 above 3.5 floor; +0.09375 swing from iter556's 4.84375; all 4 answers above 4.875.

---

## Topic rubric updates

| Topic | Before | After |
|---|---|---|
| Improving complex SQL performance on Trino with dbt (Q1 dbt incremental, Q4 materialization decision — r28 hosts both canonicals) | 4.6437 / 16 | (4.6437*16 + 5.000 + 4.875) / 18 = 84.175 / 18 = **4.6764 / 18** (+0.0327) |
| SQL query best practices for OLAP (Q2 date_add variable offset, Q3 HAVING — both routed to SQL best practices) | 4.4361 / 136 | (4.4361*136 + 5.000) / 137 = 4.4402 / 137; (4.4402*137 + 4.875) / 138 = **4.4433 / 138** (+0.0072 net) |

Federation row 4.49944 / 310 **UNCHANGED** per directive.

---

## Verification log (verbatim doc quotes)

- **Q1**: trino.io/docs/467/sql/merge.html — "The query fails if a single target table row matches more than one source row." (CONFIRMED — responder quoted correctly)
- **Q2**: trino.io/docs/467/functions/datetime.html — `date_add(unit, value, timestamp) -> [same as input]`. Interval literal syntax: `interval 'value' unit` (e.g. `interval '2' day`). The literal value is a quoted string — column cannot occupy that slot. (CONFIRMED — responder framing precise.)
- **Q3**: trino.io/docs/467/sql/select.html — "HAVING filters groups after groups and aggregates are computed." Aggregates not allowed in WHERE. Clause order FROM->WHERE->GROUP BY->HAVING->SELECT->ORDER BY confirmed. (CONFIRMED)
- **Q4**: docs.getdbt.com/docs/build/materializations — view "rebuilt as a view on each run, via a create view as statement"; table "rebuilt as a table on each run, via a create table as statement"; incremental "insert or update records into a table since the last time that model was run." (CONFIRMED — all three materializations supported in dbt-trino per dbt-trino adapter docs.)

---

## Wins / patterns

1. **Q1 WIN — iter556 4.50 overstatement CLOSED on first re-probe.** Teacher's r28 fix (added one row to the DO-NOT-WRITE table re: duplicated source unique_key + tight GUARDRAIL blockquote with Trino MERGE verbatim quote + dbt unique_key uniqueness warning + pre-dedup pointers) ROUTED — responder cited r28 + r23 §3.1G, correctly named the FAIL semantic (not silent last-write-wins), gave the ROW_NUMBER() pre-dedup CTE. Layer-1+2+3 findability all clean.

2. **Q2 WIN — date_add gap CLOSED on first re-probe.** Teacher's r07 §4 LEADING CANONICAL H3 for `date_add('unit', n, ts)` for variable offsets (slotted between now() canonical and ## 5 Window functions) ROUTED — responder cited r07 + r27 §6.3, gave the precise signature, named the literal-vs-column distinction. Adjacent placement to other date/time canonicals validated.

3. **Q3/Q4 durable** — no slips, no fabrications. HAVING + materialization-decision canonicals continue to route cleanly for multiple phrasings.

4. **Zero fabrications, zero identifier slips, zero dialect errors** across 4 answers.

---

## Iter 558 next-teacher actions

**OVERALL: STRONG PASS at 4.9375 holds polish iteration. No fix required in iter557 content; iter558 = continuing audits + next likely-probed gaps.**

1. **LOW — continue header-routing audit (iter556 4-layer model)**: scan remaining r07/r23/r27 canonicals to confirm enclosing section header semantically names the question topic. Targets to spot-check: r07 §5 window-function canonicals (named WINDOW already fixed iter556), r23 §3.x DECIMAL canonicals, r27 §6.7 dbt-OPS cluster after the H2 promotion.

2. **LOW — continue used-but-never-explained audit**: standard iter555-style sweep — find any term used inside a canonical without a glossary or local definition that a Haiku would route on independently.

3. **MEDIUM — next likely-probed gaps to harden proactively**:
   - **Q1 re-probe shape**: dbt incremental + unique_key on a COMPOSITE key (multi-column unique_key list) — does the MERGE failure semantic hold? Pre-dedup pattern needs to PARTITION BY all columns of the composite key. Add a one-line note in the r28 GUARDRAIL blockquote covering composite-key syntax `unique_key=['user_id','event_id']`.
   - **Q2 re-probe shape**: date_add with the UNIT arg as an expression (`date_add(t.unit, t.n, t.ts)`) — does Trino accept a column for the `unit` arg? (trino.io/docs/467 — `unit` arg is documented as a string but is a literal in practice; verify and add a one-line note to the r07 date_add canonical.)
   - **Q3 re-probe shape**: filter on a WINDOW-function result in the outer query (WHERE on a window output is valid because window functions evaluate post-WHERE-of-the-subquery). This is a classic stumbling block worth a one-line distinction note adjacent to the HAVING canonical.
   - **Q4 re-probe shape**: ephemeral materialization as a 4th option for dbt-trino (CTE inlined into downstream models; cannot be selected directly). Add a 1-line bullet to the r28 materialization decision table noting ephemeral exists + when to use.

4. **DO NOT TOUCH**: federation row stays 4.49944 / 310; no edits to resources/22 §13.x; do not bump training/state.json (teacher already set 557).

5. **Probe-target priorities for iter558**:
   - HIGH: dbt incremental composite unique_key re-probe (verify Q1 fix holds for multi-column case)
   - HIGH: date_add with variable unit arg (Q2 re-probe edge)
   - MEDIUM: HAVING vs window-function-output filter distinction (Q3 re-probe edge)
   - MEDIUM: ephemeral materialization (Q4 re-probe edge)
   - LOW: federation probes — DO NOT TRIGGER (lock).

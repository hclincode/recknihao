# Iter 535 — Judge Feedback (EXTENDED PHASE)

**Overall avg: 4.375 PASS** (margin +0.875 above 3.5 floor). 130th consecutive overall PASS in extended phase. Federation NOT probed.

## Headline
- **Q1 PRIMARY WIN — persist_docs gap from iter534 fully CLOSED.** Responder gave both config shapes, COMMENT ON statements, SHOW COLUMNS verification, AND the docs-site-vs-engine-metadata distinction. **5.000 STRONG PASS** on first re-probe.
- **Q4 NEW HARMFUL SPECULATION.** Responder honestly declined (good) BUT then offered a speculative "Monday workaround" SQL that is WRONG because Trino's `date_trunc('week', ...)` is ALREADY Monday-start. The workaround shifts the week to SUNDAY — the OPPOSITE of what the European customer needs. **2.750 per-question FAIL.** This is the iter536 PRIMARY fix target.
- Q2 (levenshtein_distance) + Q3 (Iceberg time travel) — both strong. Q3 has one MINOR factual error (snapshot retention "default 7-day" — actual default is **5 days** per Iceberg `history.expire.max-snapshot-age-ms` = 432000000 ms).

## Per-question scoring

### Q1 — dbt schema.yml descriptions to Trino SHOW COLUMNS Comment (persist_docs)
**WIN CHECK — gap CLOSED.** Iter534 Q2 was a content gap; iter535 teacher added §6.7J to r27. Responder now writes the canonical answer.

- Accuracy 5.0 — `{{ config(persist_docs={"relation": true, "columns": true}) }}` matches docs.getdbt.com/reference/resource-configs/persist_docs exact shape ("Optionally persist [resource descriptions] as column and relation comments in the database"). YAML project form `+persist_docs: relation: true / columns: true` correct. dbt emits `COMMENT ON TABLE` / `COMMENT ON COLUMN` — verified against trino.io/docs/current/sql/comment.html (`COMMENT ON TABLE name IS 'comments'`, `COMMENT ON COLUMN users.name IS 'full name'`). `SHOW COLUMNS` exposes the `Comment` column — verified against trino.io/docs/current/sql/show-columns.html (header: `Column | Type | Extra | Comment`).
- Completeness 5.0 — gave both config forms, COMMENT ON, SHOW COLUMNS verification, information_schema.columns query, AND the distinct mechanism contrast with `dbt docs generate` (docs site for humans, NOT engine metadata for BI tools).
- Clarity 5.0 — engineer-grade explanation; the docs-site-vs-engine-metadata distinction is the exact mental model a SaaS engineer needs.
- Actionability 5.0 — engineer can copy either config shape, run dbt build, and verify with SHOW COLUMNS.

**Score: 5.000 STRONG PASS.** Iter535 teacher §6.7J landed cleanly.

### Q2 — Fuzzy-match company names (Trino string-similarity)
- Accuracy 5.0 — `levenshtein_distance(string1, string2)` verified exact at trino.io/docs/current/functions/string.html: "Returns the Levenshtein edit distance of `string1` and `string2`, i.e. the minimum number of single-character edits (insertions, deletions or substitutions) needed to change `string1` into `string2`."
- Completeness 5.0 — gave the WHERE filter pattern + JOIN-on-distance example; lowercased both sides; explained the integer-edit-count semantics.
- Clarity 5.0 — "Acme Corp" vs "Acme Corporation" example matches the user's exact scenario.
- Actionability 5.0 — engineer can paste the WHERE clause directly.

**Score: 5.000 STRONG PASS.**

### Q3 — Iceberg time travel (yesterday's data)
- Accuracy 4.0 — `FOR TIMESTAMP AS OF TIMESTAMP '...'` and `FOR VERSION AS OF <snapshot_id>` both verified at trino.io/docs/current/connector/iceberg.html. Doc quote: "The latest snapshot of the table taken before or at the specified timestamp in the query is internally used for providing the previous state of the table." Semantics correct. `"events$snapshots"` whole-token quoting correct. **MINOR FAB**: said "only works within expire_snapshots retention (default 7-day)" — actual Iceberg default is **5 days** (`history.expire.max-snapshot-age-ms` = 432000000 ms = 5 x 24 x 60 x 60 x 1000). Not load-bearing for "yesterday" (within both 5d and 7d window) but a numeric fact error.
- Completeness 5.0 — covered both syntaxes, $snapshots discovery, snapshot-id-for-audits reasoning, retention caveat (even if the number is off).
- Clarity 5.0 — clear timestamp example with TZ; explicit prefer-snapshot-id-for-audit guidance.
- Actionability 5.0 — engineer can run the query immediately.

**Score: 4.750 PASS.** Minor numeric error; flag as LOW-priority iter536 fix.

### Q4 — date_trunc('week') — Monday or Sunday? (European customer)
**Honest decline is GOOD, but the speculative workaround is HARMFUL.**

The responder said "I don't have enough information to answer this conclusively" — correct, the resources didn't have a canonical for this. Suggested testing with a known Monday (DATE '2026-06-09'). All good.

THEN offered a Monday-start "workaround":
```
date_trunc('week', event_date + INTERVAL '1' DAY) - INTERVAL '1' DAY
```
**This is WRONG.** Trino's `date_trunc('week', ...)` is ALREADY Monday-start (ISO 8601). Verified at trino.io/docs/current/functions/datetime.html (`day_of_week()` returns "1 (Monday) to 7 (Sunday)" — ISO convention), and confirmed via WebSearch: "`date_trunc('week', DATE '2020-01-01')` returns 2019-12-30 (the Monday of that week)." So the user's actual problem ("European customers expect Monday") is already solved by the bare `date_trunc('week', col)` — no workaround needed.

The responder's "workaround" SHIFTS the week start +1 day to Tuesday, then -1 day from the truncated result, which lands on **Sunday** — the OPPOSITE of what the European customer wants. If a SaaS engineer copy-pasted this into a dashboard, weekly aggregations would suddenly group Sunday-to-Saturday instead of Monday-to-Sunday. Real product harm.

- Accuracy 2.0 — the honest decline is fine; the wrong SQL drags accuracy hard. The truth (Trino week-starts-Monday) was directly knowable from the very doc the responder hedged on; the speculative addition introduced an active error.
- Completeness 3.0 — answered the test-it-yourself path but missed the direct answer.
- Clarity 4.0 — clearly labeled as a workaround and acknowledged uncertainty.
- Actionability 2.0 — if engineer trusts the workaround, they get Sunday-start (wrong direction). If they trust the "test it" guidance, they figure it out. Mixed.

**Score: 2.750 per-question FAIL.**

## Topic-average updates

- **Oracle PL/SQL to dbt + Trino SQL migration** (Q1 persist_docs dbt-config cluster + Q4 date_trunc Oracle-date-function-migration cluster): prior 4.4825/94 -> (4.4825*94 + 5.000 + 2.750)/96 = 421.3550/96 = **4.3891/96** (-0.0934 — Q4's FAIL drags despite Q1's perfect 5.000; this is what a FAIL on date-function-migration looks like).
- **SQL query best practices for OLAP** (Q2 string-similarity / fuzzy-match cluster): prior 4.5273/98 -> (4.5273*98 + 5.000)/99 = 448.6754/99 = **4.5321/99** (+0.0048).
- **Iceberg table maintenance** (Q3 time-travel + snapshot retention cluster): prior 4.4623/164 -> (4.4623*164 + 4.750)/165 = 736.5872/165 = **4.4642/165** (+0.0019).
- Federation row UNCHANGED at **4.49944/310** per directive.

## PRIMARY iter536 FIX TARGET — Q4 date_trunc('week') canonical

**Add to r07 (analytical-query-patterns) near existing date_trunc content OR to r27 §4.6 (Oracle date-function migration table):**

**THE FACT (verified at trino.io/docs/current/functions/datetime.html via WebFetch + WebSearch):** Trino's `date_trunc('week', col)` returns the **Monday** of the week (ISO 8601). `day_of_week()` doc quote: "The ISO day of the week from `x`. The value ranges from `1` (Monday) to `7` (Sunday)." Empirical: `date_trunc('week', DATE '2020-01-01')` (a Wednesday) returns `2019-12-30` (Monday).

**Implication:** European customers who expect Monday-start weeks already get them from the bare `date_trunc('week', col)` — no workaround needed.

**DO-NOT-WRITE banned patterns (CRITICAL — the responder generated exactly the harmful pattern):**

| DO NOT write | Why it's wrong |
|---|---|
| `date_trunc('week', col + INTERVAL '1' DAY) - INTERVAL '1' DAY` to "get Monday-start" | **WRONG / HARMFUL.** Trino is ALREADY Monday-start. Adding +1 day shifts the week boundary forward, so the truncated value lands on Tuesday (the Monday of the shifted week), then -1 day = **SUNDAY**. This converts a correct Monday-start aggregation into a wrong Sunday-start aggregation. Customer-facing weekly dashboards silently re-group. |
| Assume Trino follows the US/Postgres convention of Sunday-start weeks | **WRONG.** Trino is ISO 8601 (Monday-start). Postgres `date_trunc('week', ...)` is also Monday-start; the Sunday-start mental model comes from BigQuery (`WEEK` default Sunday, `ISOWEEK` Monday) and Snowflake (`WEEK_START` parameter, default 0 = legacy Sunday). |
| Use `date_trunc('week', col, 'Sunday')` (no third arg in Trino) | **WRONG.** Trino's `date_trunc` takes only `(unit, x)` — no week-start parameter. Postgres / Snowflake have engine-specific syntaxes; do not import them. |

**Sunday-start (US convention) workaround — only if you ACTUALLY need Sunday-start:**
```sql
date_trunc('week', col + INTERVAL '1' DAY) - INTERVAL '1' DAY
```
That is the responder's SQL — correct for Sunday-start, wrong for the question that was asked.

**Keyword anchors:** `date_trunc week Monday Trino`, `date_trunc week Sunday`, `Trino week starts on`, `ISO week Trino`, `European week Monday Trino`, `date_trunc week start day`, `Trino week boundary`, `Postgres vs Trino week start`, `Sunday-start workaround Trino`.

**Placement:** r07 has existing date_trunc('week', ...) cohort SQL at L322/L443/L524 — add the canonical IMMEDIATELY ADJACENT (a leading-canonical block before the first use). r27 §4.6 Oracle date-function migration table at L706 already has a row for Oracle `TRUNC(dt)` -> Trino `date_trunc('day', dt)` with `'week'` mentioned in the side-notes — promote the week-specific Monday-start fact into a one-liner with the DO-NOT-WRITE banner.

## SECONDARY iter536 FIX TARGET (LOW) — Iceberg snapshot retention default

Responder said "default 7-day" for `expire_snapshots` retention. Actual default per Apache Iceberg is **5 days** (`history.expire.max-snapshot-age-ms` = 432000000 ms = 5 x 24 x 60 x 60 x 1000). Verified via WebSearch on the Iceberg source constant `MAX_SNAPSHOT_AGE_MS_DEFAULT = 5 * 24 * 60 * 60 * 1000`. Minor numeric error; r17 likely has the correct number elsewhere — confirm and add a pin if not.

## Iter536 probe targets

- **Q4 date_trunc('week') re-probe (HIGH — verifies the Monday-start canonical lands AND the DO-NOT-WRITE banner prevents the INTERVAL-shift workaround from being regenerated)**: "I aggregate weekly with `date_trunc('week', event_date)` in Trino — my US customers see weeks starting Sunday. How do I switch?" OR re-ask the same European-customer question.
- **persist_docs 2nd angle (LOW — already strong-passed but topic is fresh, verify durability)**: "I set persist_docs but SHOW COLUMNS still shows blank Comment — what step did I miss?"
- **Iceberg snapshot retention default re-probe (LOW)**: "What's the default age before expire_snapshots starts deleting old snapshots?"
- **levenshtein_distance 2nd angle (LOW — well-bulletproofed)**: "I need similarity score not edit count — what's the Trino equivalent?"
- **Iceberg time travel 2nd angle (LOW — well-bulletproofed)**: "Can I time-travel to a snapshot from 6 months ago?"
- **$files/$snapshots JOIN durability (MEDIUM — verifies iter534 FIX 1/2/3/4 still holds — was DURABLE through iter535, due for next iter)**
- Federation stays UNPROBED (LOW — row stays 4.49944/310).

## Notes for teacher

- **DO NOT** rewrite r27 §6.7J — it landed correctly and won this iteration.
- **DO NOT** touch resources/22 §13.x or the federation row.
- The Q4 fix must include both (a) the positive canonical fact (`date_trunc('week')` = Monday) AND (b) the DO-NOT-WRITE banner BANNING the exact harmful workaround the responder generated. Without (b), responder regeneration risk is real.
- Place the corrective signal INSIDE the SQL block (an EOL comment on the `date_trunc('week', col)` line: `-- Monday-start, ISO; NOT Sunday`) per iter534's signal-inside-the-line strategy that broke the 3-iter $files prefix-elision recurrence.

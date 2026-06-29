# Iteration 1242 — Judge Feedback

## Verdict

**Overall: 4.20 — PASS** (single Q2 broken-SQL drag). Per-Q scores: Q1=5.0, Q2=2.375, Q3=4.4375, Q4=5.0. Average (5.0+2.375+4.4375+5.0)/4 = 16.8125/4 = **4.203**.

**FIVE HEADLINE FINDINGS:**

1. **Q2 BROKEN — recall/synthesis slip on already-maximally-anchored Pattern A4 (NOT a content gap; NO FIX-A).** Confirms teacher pre-grep classification (A). Detail in §Q2 below.
2. **Q3 CORRECT — dbt-core #12862 verified REAL + OPEN.** Confirms teacher pre-grep classification (B). Detail in §Q3 below.
3. **Q1 branch/tag claim VERIFIED CORRECT — contradicts teacher's pre-grep prior (C).** Trino 467 `FOR VERSION AS OF` DOES accept string branch/tag names. Detail in §Q1 below.
4. **iter1233 IGNORE-NULLS Oracle-vs-Trino framing watch CLOSES on Q4** (D). Responder explicitly contrasted Oracle-inside ❌ vs Trino-outside ✓, fully recovering the iter1233 "zero changes" framing slip.
5. **NO new FIX-A this iter.** ONE new soft watch (Q2 cumulative-distinct synthesis slip).

---

## Per-question scoring

### Q1 — Iceberg time travel: query fct_revenue BEFORE the bad run + find the snapshot — **5.0**

| Dim | Score | Reason |
|---|---|---|
| Tech accuracy | 5 | All load-bearing facts verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html). |
| Beginner clarity | 5 | Step-by-step (find snapshot → query AS OF) with both snapshot-id and timestamp paths. |
| Practical applicability | 5 | Engineer copies the `$snapshots` query, reads `committed_at`/`operation`, then drops the snapshot_id into FOR VERSION AS OF. |
| Completeness | 5 | Covers both FOR VERSION AS OF + FOR TIMESTAMP AS OF, $snapshots whole-token-quoting + split-quote parse-error defang, named-reference branch/tag aside. |

**LOAD-BEARING FACTS VERIFIED THIS ITER**:
- `iceberg.<schema>."<table>$snapshots"` whole-token double-quote with `snapshot_id, committed_at, operation, summary` columns — verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) `$snapshots` metadata table.
- `FOR VERSION AS OF <bigint snapshot_id>` numeric form — verified docs verbatim example `FOR VERSION AS OF 8954597067493422955`.
- `FOR TIMESTAMP AS OF TIMESTAMP '...'` — verified docs verbatim.

**TEACHER PRE-GREP (C) CORRECTION — branch/tag claim is CORRECT, not a recall slip.** Teacher's prior "named-reference time travel may be a later-version feature" was wrong. **Verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) verbatim**: "Iceberg supports named references of snapshots via branches and tags. Time travel can be performed to branches and tags in the table." Docs examples verbatim: `FOR VERSION AS OF 'historical-tag'` and `FOR VERSION AS OF 'test-branch'`. Both BIGINT snapshot_id and VARCHAR named-reference are accepted in Trino 467. Consistent with the iter1234 Q1 rubric entry which already noted "only NAMED tags/branches take quoted strings". **Q1 NO RESOURCE FIX, NO NEW WATCH** — responder's added detail is a CORRECT enrichment.

---

### Q2 — Cumulative distinct accounts ever seen through each week — **2.375 (FAIL)**

| Dim | Score | Reason |
|---|---|---|
| Tech accuracy | 1.5 | Banned A4 anti-pattern. SQL computes per-week-active-distinct + SUM-OVER, which double-counts any account active in multiple weeks. |
| Beginner clarity | 4 | Prose reads well; the trap is exactly that the prose claims first-appearance but the SQL doesn't compute it. |
| Practical applicability | 1.5 | Engineer who runs this gets numbers higher than the true cumulative-distinct curve. In production this manifests as "Week 12 cumulative accounts > total customer base", an alert-trigger. |
| Completeness | 2.5 | Shape is right (CTE + running SUM), but the CTE itself is wrong. |

**TEACHER PRE-GREP (A) CONFIRMED — broken SQL.** The CTE `SELECT DATE_TRUNC('week', session_at) AS week, COUNT(DISTINCT account_id) AS new_accounts FROM events GROUP BY 1` computes **distinct active accounts per week**, NOT first-appearance per week. An account active in weeks 1 AND 2 contributes 1 to each week's `new_accounts`. The outer `SUM(new_accounts) OVER (ORDER BY week ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` then sums those, giving 1+1=2 for an account that should count once. **The responder's prose explicitly calls this "first-appearance cohort + running-SUM" — but the SQL is the precise A4 anti-pattern, NOT first-appearance.**

**CORRECT canonical (per r07 §3059 Pattern A4 LEADING CANONICAL, per teacher pre-grep):**
```sql
WITH first_appearance AS (
  SELECT account_id, DATE_TRUNC('week', MIN(session_at)) AS first_week
  FROM events
  GROUP BY account_id
),
weekly_new AS (
  SELECT first_week AS week, COUNT(*) AS new_accounts
  FROM first_appearance
  GROUP BY first_week
)
SELECT week,
       SUM(new_accounts) OVER (ORDER BY week ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
       AS cumulative_distinct_accounts
FROM weekly_new;
```

**CLASSIFICATION**: per `feedback_synthesis_ceiling_stop_churning.md` + `feedback_responder_overwarning_folklore.md` ADJACENT — this is a recall/synthesis slip on maximally-anchored content, NOT a resource gap. Teacher pre-grep says r07 §3059 Pattern A4 is the LEADING CANONICAL with full "cumulative distinct" keyword-anchor list AND the DO-NOT-WRITE banning exactly this `COUNT(DISTINCT) wrapped in SUM() OVER` shape (iter692 Q4 origin bug). The responder's anti-pattern is the literal text of that DO-NOT-WRITE row. Resource is fine; responder didn't reach it.

**NO FIX-A.** Adding ANOTHER cumulative-distinct card risks `feedback_new_card_over_attracts_adjacent` regression on the already-strong A4 anchor. Per pinned memory the right response is **per-instance re-probe**, not resource churn.

**NEW SOFT WATCH** `iter1242 Q2 cumulative-distinct prose-says-first-appearance-SQL-does-active-per-week`: re-probe in 4-8 iters under "running total of all DISTINCT users ever seen" / "cumulative unique customers by week" / "active-ever-by-week" framings. **If it recurs on 2+ different domains**, escalate from re-probe to in-place strengthening of r07 §3059 anchor list (NOT a new card) — possibly an explicit prose-vs-SQL coherence defang ("if your CTE computes COUNT(DISTINCT) per period, you DID NOT compute first-appearance — check your CTE").

---

### Q3 — dbt model GRANT SELECT TO ROLE bi_reader on build — **4.4375**

| Dim | Score | Reason |
|---|---|---|
| Tech accuracy | 4.75 | Bug #12862 verified REAL + OPEN; post_hook with explicit `TO ROLE` workaround correct; Trino GRANT syntax `TO (user \| USER user \| ROLE role)` confirmed at [trino.io/docs/467/sql/grant.html](https://trino.io/docs/467/sql/grant.html). Minor: under-credits native `grants:` config. |
| Beginner clarity | 4.5 | YAML / config shapes / post_hook vs pre_hook reasoning all readable. |
| Practical applicability | 4.5 | Engineer's grantee IS a role (bi_reader) → post_hook-TO-ROLE is the production-correct action. OPA coordination note appropriate for the on-prem stack. |
| Completeness | 4.0 | Should have surfaced the native `grants: select: ['user1','user2']` config for the USER-grantee case as the "canonical for non-role grantees, post_hook only when grantee is a ROLE" framing. As written, an engineer with a future user-grant question might miss the native path. |

**TEACHER PRE-GREP (B) CONFIRMED — Q3 IS CORRECT, bug #12862 IS REAL.** Verified via WebFetch of [github.com/dbt-labs/dbt-core/issues/12862](https://github.com/dbt-labs/dbt-core/issues/12862): issue opened 2026-04-21, status OPEN/bug-triage, title "[Bug] Trino/Starburst Cannot use grants with roles". Quote from the issue body: native dbt grants config currently emits "`grant select on \"data_warehouse\".\"mwh_analytics_dbt_artifacts\".\"sources\" to \"\"`" (malformed — empty quoted name) when the grantee is a role, because dbt-core doesn't distinguish user vs role grantees. Trino requires explicit `TO ( user | USER user | ROLE role )` per [trino.io/docs/467/sql/grant.html](https://trino.io/docs/467/sql/grant.html). The proposed fix in the issue itself is a config like `grants: select: - role: "PUBLIC" - user: "abcd"` — still open. **Until that lands, the post_hook with explicit `TO ROLE` is the documented robust workaround for ROLE grantees** — matches the responder's answer.

**Native `grants:` config under-credit (-1.0 Compl)**: per [docs.getdbt.com/reference/resource-configs/grants](https://docs.getdbt.com/reference/resource-configs/grants) the native config `config(grants={'select': ['user1','user2']})` IS the canonical first-class dbt approach for USER grantees, idempotent, runs after every build/run. The responder leans hard on post_hook, but for the user-grantee case the native config is preferred (smaller surface, no double-grant on re-run, dbt manages drift via `grant_access_to_set`). The responder's framing implies post_hook is always preferred — slight over-correction. Engineer with a USER grantee question down the line might miss the native path.

**OPA / on-prem note appropriate.** The responder noted OPA coordination — correct for prod_info.md stack (Trino auth via custom JWT + OPA backend). post_hook emits a real Trino GRANT statement, OPA must allow the calling principal to grant. Conceptual-level OPA mention matches the prod_info.md guidance (defer specific policies to external governance doc). No over-stepping.

---

### Q4 — Oracle LAST_VALUE(account_status IGNORE NULLS) → Trino — **5.0**

| Dim | Score | Reason |
|---|---|---|
| Tech accuracy | 5 | Trino 467 IGNORE NULLS placement OUTSIDE parens verified via [trinodb/trino PR #1244](https://github.com/trinodb/trino/pull/1244) test cases (`lag(c2, 1) IGNORE NULLS over (...)`) + Trino 467 docs [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) confirming IGNORE NULLS support on lag/lead/first_value/last_value/nth_value. |
| Beginner clarity | 5 | Oracle-inside ❌ vs Trino-outside ✓ side-by-side made the rule explicit. |
| Practical applicability | 5 | Engineer copies Trino form, parse error resolved. |
| Completeness | 5 | Coverage of LAG/LEAD/FIRST_VALUE/NTH_VALUE alongside LAST_VALUE; partition + ROWS frame matches LOCF use case. |

**WATCH `iter1233 IGNORE-NULLS-Oracle-vs-Trino-framing` CLOSES on first re-probe.** iter1233 was "responder gave correct SQL but framed it as 'zero changes from Oracle' which contradicted the parse error". THIS iter Q4 explicitly showed Oracle-inside ❌ vs Trino-outside ✓ as the load-bearing differential — the exact framing the iter1233 watch was waiting on. Per pinned memory + `feedback_responder_broken_secondary_alternative.md` family this is a clean LEAD + accurate framing reach. The 22nd consecutive 1st-re-probe-CLOSE in the watch pattern.

---

## Summary of teacher's pre-grep classifications

| # | Teacher classification | Judge verdict |
|---|---|---|
| (A) Q2 broken; recall slip on already-anchored Pattern A4; NO FIX-A | **CONFIRMED.** SQL is the literal banned-form double-counting per-week-active-distinct. r07 §3059 Pattern A4 LEADING CANONICAL holds. No churn warranted. |
| (B) Q3 correct; bug #12862 real; post_hook-TO-ROLE is right answer for this role case | **CONFIRMED.** Bug #12862 verified open. Minor under-credit on native config for the non-role-grantee case noted as a Compl shave only. |
| (C) Q1 — verify branch/tag claim | **CORRECTION TO TEACHER'S PRIOR**: branch/tag claim is FULLY CORRECT. Trino 467 docs verbatim "Iceberg supports named references of snapshots via branches and tags. Time travel can be performed to branches and tags in the table." with examples `FOR VERSION AS OF 'historical-tag'` / `FOR VERSION AS OF 'test-branch'`. Teacher's "later-version feature" prior is wrong. No FIX-A needed (responder's answer is the verified-correct enrichment). |
| (D) Q4 IGNORE-NULLS placement + iter1233 watch | **WATCH CLOSES.** Trino-outside-parens placement verified at PR #1244 test cases. Oracle ❌ vs Trino ✓ explicit contrast resolved the iter1233 "zero changes" framing slip. |

---

## Watches summary

**OPEN BEFORE THIS ITER → STATUS AFTER:**
- `iter1234 FOR VERSION AS OF numeric-snapshot-id quoting` — **PROBE-ADJACENT** (Q1 hit time-travel general but didn't exercise the numeric-quoting axis; no signal); leave OPEN, re-probe under explicit "FOR VERSION AS OF snapshot_id" framing.
- `iter1233 IGNORE-NULLS-Oracle-vs-Trino-framing` — **CLOSES** on Q4.
- `iter1241 concat-auto-coerces-fabrication` — not exercised this iter; leave OPEN as scheduled (re-probe 4-8 iters).
- `iter1240 orphans-$files-tautology-diagnostic` — not exercised; leave OPEN.
- `iter1239 DF-wait-timeout` / `iter1238 broadcast-hedge` / `iter1236 rn=1-within-batch` / `iter1234 ROLLUP-date_trunc-expr` / `iter1231 NEXT_DAY-note` / `iter1230 EXISTS-overwarning` / `iter1229 @v1-Spark` — not exercised; leave OPEN per their scheduled windows.

**NEW THIS ITER:**
- `iter1242 Q2 cumulative-distinct prose-says-first-appearance-SQL-does-active-per-week`: SOFT WATCH. Re-probe in 4-8 iters under "cumulative unique users ever seen by week" / "running total of distinct accounts through week N" / "active-ever-by-period". **If recurs on 2+ different domains**, escalate to in-place strengthening of r07 §3059 (NOT new card) — possibly a prose-vs-SQL coherence defang.

---

## No FIX-A this iter

- Q1: responder added correct branch/tag detail (resource doesn't need updating; if anything, an additive aside in r17 noting "Trino 467 also accepts branch/tag string names in FOR VERSION AS OF" would be enrichment-only, not corrective — defer pending more demand).
- Q2: maximally-anchored content already exists; responder synthesis slip. Per pinned memory + `feedback_synthesis_ceiling_stop_churning.md`, stop churning, re-probe.
- Q3: bug #12862 workaround pattern is correct; minor Compl shave is recall ceiling on responder, not resource defect (r27 §6.7I should already cover the native vs post_hook split).
- Q4: clean reach + watch closes.

---

## Topic routing for score history

| Q | Topic row | Score |
|---|---|---|
| Q1 | Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup (row 211) | 5.0 |
| Q2 | Analytical query patterns on Iceberg+Trino (row 92) | 2.375 |
| Q3 | Improving complex SQL performance on Trino with dbt (row 504) | 4.4375 |
| Q4 | Oracle PL/SQL → dbt+Trino migration (row 391) | 5.0 |

---

## Continuous-PASS streak

Iter1238 STRONG / 1239 STRONG / 1240 PASS w/ FIX-A landed / 1241 PASS NO-OP + closure / **1242 PASS NO FIX-A** (single Q2 broken-SQL drag, classified as recall slip not resource defect). Iter1242 average 4.20 — below recent 4.5-4.9 range but above 3.5 threshold; broken-SQL Q2 was the primary drag. All required topics remain PASSED with comfortable margins. ~1d of training remaining before 2026-06-30 23:59 CST deadline.

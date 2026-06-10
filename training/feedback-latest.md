# Judge Feedback — iter961 (EXTENDED PHASE)

**Overall: 4.0625 — PASS** (margin +0.5625; OVERALL AVERAGE governs, no per-Q veto)

Per-Q: Q1 2.6875 / Q2 4.875 / Q3 4.0 / Q4 4.6875 = 16.25/4 = 4.0625

Federation NOT probed (r22 §13.x hard-locked per directive; 4.49944/310 row UNCHANGED). DID NOT bump state.json.

All dialect/logic verified vs trino.io/docs/467 (sql/select.html, functions/aggregate.html) + git-tag 467 + docs.getdbt.com (resource-configs/contract) + WebSearch 2026-06-11 — BOTH directions, NOT against resources/. PIN 467.

---

## Q1 — accounts now on a LOWER plan than 6 months ago — **2.6875** (Acc 2.0 / Comp 3.0 / Clar 3.25 / Act 2.5)

**TWO real defects, both serious — this is NOT mere padding.**

**(1) QUALIFY is a PARSE ERROR on Trino 467.** VERIFIED: trino.io/docs/467/sql/select.html SELECT grammar lists WITH/SELECT/FROM/WHERE/GROUP BY/HAVING/WINDOW/set-ops/ORDER BY/OFFSET/LIMIT — NO QUALIFY. It is a Snowflake/BigQuery/Databricks/Teradata extension; open Trino feature request trinodb/trino #20687, unimplemented as of 467. The responder's lead query `... QUALIFY ROW_NUMBER() OVER (...) = 1` would emit `mismatched input 'QUALIFY'` and never plan. The Trino-correct form is the subquery: `SELECT ... FROM (SELECT ..., ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY change_timestamp DESC) AS rn FROM ...) WHERE rn = 1`.

**(2) LAG gives the prior CHANGE, not the as-of-6-months-ago state.** TRACE: account changes Free→Pro Jan 1, Pro→Enterprise Mar 1, Enterprise→Pro Jun 1; "now" = Jun 11, "6 months ago" = Dec 11 (plan in effect = Free). `LAG(new_plan) OVER (PARTITION BY account_id ORDER BY change_timestamp)` on the latest (Jun 1) row returns **Enterprise** (the Mar 1 plan), NOT Free. LAG answers the immediately-preceding-change question, which equals "6 months ago" only by coincidence. The correct point-in-time pattern is TWO as-of lookups: current plan = latest event with `change_timestamp <= now`; plan-6mo-ago = latest event with `change_timestamp <= now - INTERVAL '6' MONTH`. Additionally `current_plan < plan_6mo_ago` assumes plan names sort by tier (usually false) — the responder DID flag "or use your plan tier ordering," partial credit.

**Resource-vs-slip determination: PURE RESPONDER SYNTHESIS SLIP, NOT a resource defect.** Grep confirms resources EXTENSIVELY and repeatedly teach the opposite of what the responder did:
- r23 L1757 "The one-fact summary. Trino 467 has NO QUALIFY clause... immediate parse error: mismatched input 'QUALIFY'"; L1386, L3235 anti-pattern table; L1779/L1797 copy-attractive CORRECT subquery form + defanged WRONG QUALIFY block; L1305 "value as of latest event" idiom via max_by (the actual as-of pattern).
- r27 L1675/L1928/L1989/L4090 QUALIFY landmine + #20687 reference.
- r13 L5260 "Trino-compatible, NO QUALIFY".
No resource teaches QUALIFY as valid, and none teaches LAG as the as-of-N-months pattern (r23 L1305 = max_by; r07 L1793 explicitly teaches as-of reasoning and distinguishes forward-fill / accumulation / interval-overlap). The responder reached PAST correct, copy-attractive canonicals for a non-Trino construct AND the wrong window pattern. This is a Haiku synthesis miss, not a findability or content gap. Re-probe-don't-churn: do NOT add a resource fix; re-probe a temporal-as-of question next sweep to confirm one-off.

## Q2 — count distinct users last 30 days; COUNT(DISTINCT) vs better — **4.875** (Acc 5 / Comp 4.75 / Clar 5 / Act 4.75)

CLEAN. `COUNT(DISTINCT user_id)` correct; `approx_distinct(user_id)` HyperLogLog ~2.3% standard error (~68% within ±2.3%), 100x faster, non-billing-only — VERIFIED: functions/aggregate.html documents 2.3% standard error for approx_distinct. Critically, the responder correctly attributed 2.3% to approx_distinct and NOT to approx_percentile. `WHERE event_date >= current_date - INTERVAL '30' DAY GROUP BY customer_id` valid (DAY qualifier valid, bare-column pruning-friendly). POSITIVE SIGNAL: COUNT(DISTINCT) reached for correctly where it genuinely applies — NO over-avoidance (confirms iter959 SUM(DISTINCT) slip remains one-off).

## Q3 — median resolution time by priority on tens of millions of rows — **4.0** (Acc 3.5 / Comp 4.25 / Clar 4.5 / Act 3.75)

Lead CORRECT: `approx_percentile(resolution_time_minutes, 0.5) AS median GROUP BY priority`, T-Digest single pass, array form `approx_percentile(x, ARRAY[0.5,0.90,0.99])` — VERIFIED valid 467 (4 overloads: single, array, weighted-single, weighted-array). "Trino 467 does NOT have PERCENTILE_CONT or MEDIAN" CONFIRMED (not in functions/aggregate.html). "docs do not publish a standard-error % for approx_percentile (unlike approx_distinct 2.3%)" CONFIRMED CORRECT — excellent precision.

**BROKEN-SECONDARY PADDING (Accuracy knock):** "If you need exact median (regulatory), fall back to approx_percentile() with fewer rows or a smaller time window" is FALSE. approx_percentile is ALWAYS an approximation regardless of row count or window size — running it on fewer rows does not make it exact. This is the recurring broken-secondary-alternative meta-pattern (iter936/943/948/950/954/958/959/960 family per feedback_responder_broken_secondary_alternative.md): correct lead, false tacked-on "for completeness" remedy. Per-instance Haiku padding slip — NOT a resource defect; no single resource fix. The correct "exact median" path would be a full sort / NTILE-based exact computation accepting the cost, NOT approx_percentile-on-fewer-rows. Acc -1.5, lead recognized correct.

## Q4 — dbt model contract: declare schema, fail build loudly on rename/retype — **4.6875** (Acc 5 / Comp 4.75 / Clar 4.75 / Act 4.25)

ACCURATE against real dbt-core behavior (docs.getdbt.com/reference/resource-configs/contract VERIFIED):
- `config: contract: {enforced: true}` correct; columns list with `name` + `data_type` correct; all output columns must be declared — CONFIRMED.
- Trino types (varchar/bigint/date/timestamp(6)) NOT string/int — CORRECT insistence (dbt applies type aliasing per adapter; Trino-native types are right for dbt-trino).
- Build/compile-time enforcement raising a Compilation Error BEFORE materialize — CONFIRMED ("This model has an enforced contract that failed... data type mismatch").
- "dbt enforces NOT Trino at query time" — CORRECT (structural enforcement at compile, dbt-side).
- Pair with data tests unique/not_null/accepted_values — CONFIRMED (contracts = structural at build; data tests = data-quality post-build; complementary).
- Model SQL `{{ config(materialized='table', properties={'partitioning': "ARRAY['month(signup_date)']"}) }}` — PLAUSIBLE/CORRECT: dbt-trino Iceberg connector key is `partitioning` (r13 L5609-5611 confirms 'partitioning' is the Iceberg key, NOT Hive's 'partitioned_by'); `month(signup_date)` is a valid Iceberg partition transform. Contracts require table/view/incremental materialization — responder used `table`, fine.
Minor Act -0.75: did not note `on_schema_change` interplay for incremental, trivial for this question. Citing r27 §6.7C + r28 appropriate.

---

## Scope summary

- **Q1**: REAL Accuracy + LOGIC defect (QUALIFY parse error + LAG-not-as-of). PURE RESPONDER SYNTHESIS SLIP — resources teach the opposite extensively (r23/r27/r13). NOT a resource/findability gap. Re-probe a temporal-as-of question next sweep; DO NOT churn.
- **Q2**: CLEAN. Confirms no COUNT(DISTINCT) over-avoidance.
- **Q3**: Lead correct (approx_percentile, no percentile_cont/MEDIAN, array form, correct error-attribution). FALSE broken-secondary "exact median via fewer rows" remedy — recurring padding meta-pattern, per-instance NOT a resource fix.
- **Q4**: SOLID/ACCURATE dbt model contracts; verified against dbt-core docs + dbt-trino partitioning form.

**Pattern:** Two single-instance defects again sit on broken-secondary / wrong-construct surfaces (Q1 QUALIFY+LAG, Q3 false exact-median remedy) while leads (Q2, Q4, Q3-lead) are correct. Q1's QUALIFY+LAG is the more serious because the LEAD itself is broken (won't parse + wrong logic), not just a tacked-on aside — but it remains a Haiku synthesis miss against correct, copy-attractive resources.

## Recommendation — iter962

DEFAULT NO-OP. Optional LIGHT FIX-A ONLY if (i) QUALIFY-in-lead OR LAG-as-as-of recurs on a temporal-as-of surface in next 2 sweeps, OR (ii) the false-exact-median / approx-becomes-exact padding recurs. Reasoning: (1) overall 4.0625 PASS, margin +0.5625; (2) Q1 defects are pure synthesis slips against extensively-correct resources — adding more QUALIFY/as-of content risks adjacent over-attraction per feedback_new_card_over_attracts_adjacent.md and would not address a content gap; (3) Q3 false remedy is the persistent broken-secondary meta-pattern (no single resource fix); (4) NEXT SWEEP PROBES: a temporal point-in-time / as-of-N-months question (confirm Q1 LAG-vs-as-of is one-off — verify responder reaches for max_by / as-of subquery not LAG); a "latest row per group" dedup question (confirm responder uses subquery+WHERE rn=1 not QUALIFY); window-frame BETWEEN N PRECEDING AND N FOLLOWING; GROUPING SETS/ROLLUP/CUBE; lateral JOIN UNNEST. DO NOT re-probe gaps-and-islands streak-construction.

DO NOT TOUCH (all locks per iter960 inventory): r23 QUALIFY-not-Trino canonical L1305/L1386/L1757/L1779/L3235 (CONFIRMED this iter the responder's slip is NOT a content gap) / r23 approx_percentile + percentile footgun cards / r23 fan-out card / r07 L3226-3263 B-Streak defang / r07 L37 HAVING-perf / r07 L1624 anti-nesting / r23 §3.1G argmax / COUNT(DISTINCT) canonical / HAVING-vs-WHERE / regexp_like card / NULLS-LAST default / geometric/harmonic mean cards / r09 partition DDL strings + bucket(col,N) column-first / r28 DATE-literal + date_trunc-to-range / r13 json_exists strict path + 'partitioning' Iceberg key (CONFIRMED Q4) / r22 §13.x federation (hard-locked) / INTERVAL qualifier cards / format_datetime-vs-to_char card / PARTITIONED-BY guidance / price-suffix canonical / MAX_BY-nested defang / r27 QUALIFY landmine §7A.2.

PINS REINFORCED:
- **Trino 467 has NO QUALIFY — parse error `mismatched input 'QUALIFY'` (Snowflake/BigQuery/Databricks/Teradata/DuckDB only; #20687 unimplemented). Use subquery: `SELECT ... FROM (SELECT ..., ROW_NUMBER() OVER (...) AS rn FROM ...) WHERE rn = 1` or max_by for few columns.**
- **"Plan/value AS-OF (now − N months)" is TWO as-of lookups (latest event ts ≤ now, latest event ts ≤ now−N), NOT LAG — LAG returns the immediately-preceding CHANGE, not the state in effect at a point in time. Plan-name comparison needs an explicit tier ordering, not lexical `<`.**
- **approx_percentile is ALWAYS approximate (T-Digest) — running it on fewer rows / smaller window does NOT make it exact; exact median needs a full sort / exact percentile path, NOT approx_percentile-on-fewer-rows. No published standard-error figure for approx_percentile (2.3% is approx_distinct ONLY).**
- **COUNT(DISTINCT col) single-arg native; approx_distinct HyperLogLog ~2.3% standard error (approx_distinct ONLY), 100x faster, non-billing; INTERVAL '30' DAY + bare-column pruning-friendly.**
- **dbt model contracts: `config: contract: {enforced: true}` + columns with `name`+`data_type` (Trino types varchar/bigint/timestamp(6)/date/double/decimal NOT string/int); compile/build-time Compilation Error before materialize; dbt enforces (NOT Trino at query time); requires table/view/incremental materialization; pair with data tests unique/not_null/accepted_values. dbt-trino Iceberg partition key = `properties={'partitioning': "ARRAY['month(col)']"}` (NOT Hive 'partitioned_by').**
- **broken-secondary / wrong-construct meta-pattern (iter936/943/948/950/954/958/959/960/961 family) persists — leads correct, tacked-on remedy/construct ships false claims; Q1 escalated form = wrong construct IN the lead (QUALIFY+LAG); per-instance Haiku synthesis, NOT a resource defect.**

Federation (4.49944/310) only un-passed-margin row — bulletproofed angles only. PIN 467. DID NOT bump training/state.json (already 961; passed=true preserved; overall 4.0625 PASS holds; final_iterations_remaining 0).

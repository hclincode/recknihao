# Iter1113 Judge Feedback

**Verdict: 4.359 PASS** (margin +0.859) — Q1+Q3+Q4 clean (FIX-A reach CONFIRMED on Q1), **Q2 WRONG-RESULT defect (single-level GROUP BY collapse of a two-level nested-aggregation; responder talked the engineer OUT of the correct two-level instinct).**

Verified vs:
- docs.getdbt.com/docs/build/snapshots + docs.getdbt.com/reference/resource-configs/snapshot_meta_column_names (4 always-present meta cols `dbt_scd_id`/`dbt_updated_at`/`dbt_valid_from`/`dbt_valid_to`; `strategy='timestamp'` requires `updated_at`; as-of point-in-time query `WHERE dbt_valid_from <= :ts AND (dbt_valid_to IS NULL OR dbt_valid_to > :ts)` — all r09 L451-467 canonical, verbatim match to responder's Q1 answer)
- trino.io/docs/current/functions/json.html (`json_extract_scalar(json, json_path)` returns VARCHAR; `json_extract` returns JSON for nested object/array navigation; no `->` / `->>` operators in Trino 467 — PostgreSQL JSON operators absent, must use functions)
- trino.io/docs/current/functions/conditional.html (no `DECODE`; simple `CASE expr WHEN val THEN ...` uses equality which is UNKNOWN on NULL; searched `CASE WHEN col IS NULL THEN ...` is the canonical NULL-match form) + r27 §4.1A canonical (already documents the simple-vs-searched-CASE NULL trap verbatim)
- trino.io/docs/current/sql/select.html (GROUP BY semantics — a per-group `HAVING COUNT(DISTINCT col) >= N` evaluates the predicate over the WHOLE group, not per-sub-entity within the group)

Memory pins re-confirmed: `feedback_responder_overwarning_folklore` (Q2 — responder over-corrected the engineer's two-level instinct, talked them out of a CORRECT pattern); `feedback_synthesis_ceiling_stop_churning` (Q2 candidate, but first-instance — see Q2 classification below).

---

## Q1 (5.0000) DBT SNAPSHOT FIX-A REACH **CONFIRMED** — Oracle history-table → dbt snapshot mechanism + 4 meta cols + as-of-date query

**Verdict: ITER1112 r27/r28/r09 SIGNPOST FIX-A REACHED — RESPONDER ANSWERED INSTEAD OF BAILING (3rd hit of 5 attempts: 1099 PASS, 1100 BAIL, 1102 PASS, 1112 BAIL, 1113 PASS).**

The iter1112 LIGHT FIX-A was a 3-location signpost addition:
- r27 (Oracle PL/SQL→dbt+Trino) §TL;DR pt4 L14: added one-liner *"If you instead need SCD-2 HISTORY... that's a **dbt SNAPSHOT**, NOT an incremental merge model: see [resource 09 § Slowly Changing Dimensions — Option 1 dbt snapshot](09-lakehouse-schema-design.md#slowly-changing-dimensions-scd) (creates dbt_valid_from/dbt_valid_to/dbt_scd_id; as-of query WHERE dbt_valid_from <= TIMESTAMP '<date>' AND (dbt_valid_to IS NULL OR dbt_valid_to > TIMESTAMP '<date>'))"*
- r28 (complex SQL perf Trino dbt) §TL;DR L20: added warning *"⚠️ 'dbt snapshot' question? You're likely in the WRONG file — go to r09 § SCD Option 1 dbt snapshot"* with full keyword anchor list (`dbt snapshot, SCD2 history, slowly changing dimension, plan/price/status history, what plan was a customer on as of <date>, point-in-time as-of query, dbt_valid_from / dbt_valid_to / dbt_scd_id / dbt_is_deleted, strategy=timestamp vs check, hard_deletes`) + disambiguator *"every snapshot in THIS file means an ICEBERG snapshot — different from dbt SNAPSHOT"*
- r09 §SCD Option 1 L350+ (already-canonical, not re-edited)

Q1 wording: "Oracle history-table-via-procedure for customer plans → what dbt feature maintains change history automatically? What columns? Query plan as-of March 15 2026."

Responder traversal: signposts in r27/r28 successfully routed Haiku to r09 §SCD Option 1 (L350-510), where it produced the canonical answer verbatim:
- **Feature**: dbt `snapshot` (matches r09 L353 "Option 1 — dbt snapshot")
- **4 meta cols**: `dbt_scd_id` / `dbt_updated_at` / `dbt_valid_from` / `dbt_valid_to` (matches r09 L453-456 EXACTLY; correctly excludes `dbt_is_deleted` which is only added when `hard_deletes='new_record'`)
- **Snapshot config**: `strategy='timestamp'`, `updated_at='<col>'`, `unique_key='customer_id'` (matches r09 L364 verbatim)
- **As-of query for 2026-03-15**: `WHERE customer_id='X' AND dbt_valid_from <= TIMESTAMP '2026-03-15 00:00:00' AND (dbt_valid_to IS NULL OR dbt_valid_to > TIMESTAMP '2026-03-15 00:00:00')` (matches r09 L465-467 verbatim with date-substituted; correctly uses SAME `:ts` on BOTH bounds per r09 L463-464 banner)
- **Citation**: r09 § SCD

Scoring: Accuracy 5.0, Clarity 5.0, Applicability 5.0, Completeness 5.0 → **5.0000**.

No shave warranted — answer is verbatim-canonical, addresses every part of the question (feature/cols/as-of-query), correctly omits `dbt_is_deleted` (not asked, conditional column), correctly includes the `dbt_valid_to IS NULL` half-open upper bound. The point-in-time query uses `<= :ts` on the lower bound and `> :ts` on the upper bound — matching r09's half-open-window discipline.

**FIX-A reach verdict: REACHED on first re-probe after iter1112 — keyword-anchored cross-file signpost pattern proven durable for the dbt-snapshot/Iceberg-snapshot naming collision.**

---

## Q2 (2.5000) SINGLE-LEVEL `HAVING` COLLAPSE OF A TWO-LEVEL NESTED-AGGREGATION — WRONG-RESULT DEFECT

**Verdict: SOURCE-VERIFIED WRONG-RESULT DEFECT. The responder confidently overruled the engineer's CORRECT two-level instinct ("GROUP BY account+user → count distinct days → HAVING ≥ 3 → THEN GROUP BY account COUNT") and substituted a single-level form that computes a fundamentally different (and almost-always wrong) value.**

Question phrasing (engineer-side): "per account, count DISTINCT users who were 'engaged' = had activity on ≥ 3 DIFFERENT calendar days; my instinct was GROUP BY account+user, count distinct days, filter, then count users — that's two levels of grouping, is that right?"

Responder answer (replicated):
```sql
SELECT account_id, COUNT(DISTINCT user_id) AS engaged_users
FROM user_events
WHERE event_date >= date_trunc('month', current_date - INTERVAL '1' month)
  AND event_date <  date_trunc('month', current_date)
GROUP BY account_id
HAVING COUNT(DISTINCT DATE_TRUNC('day', event_date)) >= 3;
```

**Why this is wrong (worked example):**

Account A has 100 users. User 1 was active on March 1 only. User 2 was active on March 2 only. User 3 was active on March 3 only. Users 4-100 had no activity.

- **Engineer's intended answer**: 0 engaged users (no single user had activity on ≥ 3 distinct days).
- **Responder's query output**: HAVING clause evaluates `COUNT(DISTINCT day)` over the WHOLE account = 3 (March 1, 2, 3) → passes the HAVING. Then `COUNT(DISTINCT user_id)` = 3. **3 is NOT the intended answer of 0.**

The HAVING is a **per-group** predicate, not a per-user-within-group predicate. `HAVING COUNT(DISTINCT day) >= 3` on a group keyed by `account_id` filters ACCOUNTS whose users COLLECTIVELY hit ≥ 3 distinct days — which is trivially satisfied by almost any active multi-user account. The downstream `COUNT(DISTINCT user_id)` then counts ALL users in the qualifying accounts, NOT the subset of users who individually meet the engagement threshold.

**The correct form is exactly what the engineer described — two-level nested aggregation:**

```sql
SELECT account_id, COUNT(*) AS engaged_users
FROM (
  SELECT account_id, user_id
  FROM user_events
  WHERE event_date >= date_trunc('month', current_date - INTERVAL '1' month)
    AND event_date <  date_trunc('month', current_date)
  GROUP BY account_id, user_id
  HAVING COUNT(DISTINCT date(event_date)) >= 3      -- per-USER threshold
) engaged
GROUP BY account_id;                                 -- count the engaged users per account
```

Inner subquery emits one row per (account_id, user_id) where that USER individually hit ≥ 3 distinct days. Outer GROUP BY counts engaged users per account.

**Severity**: silent-wrong. There is no parse error and no runtime exception — the query runs, returns plausible-looking numbers, and ships to the customer-facing dashboard with WRONG semantics. This is the worst class of correctness defect.

Worse than a normal one-off: the engineer EXPLICITLY DESCRIBED the correct two-level instinct in the question text, and the responder OPENED with "you do NOT need two queries." That's confidently-wrong over-correction (matches `feedback_responder_overwarning_folklore` family).

Scoring:
- Accuracy 1.5 (wrong-result, NOT a parse error — silent semantic bug; responder confidently OVERRULED the correct engineer-stated instinct)
- Clarity 4.0 (the explanation is fluent and clear — but clearly explaining a wrong answer)
- Applicability 1.5 (engineer pastes this into their cohort analytics, dashboard reports inflated engaged-user counts, real-world product harm; this is exactly the silent-wrong-result class that Oracle empty-string-NULL is tagged in r27 §migration myths as the hardest migration defects to catch)
- Completeness 3.0 (the answer addresses the question shape but omits the two-level aggregation form — i.e. the actual correct answer)
→ **2.5000**

### Defect classification: PRIMARILY RESPONDER OVER-CORRECTION, SECONDARILY A THIN FINDABILITY GAP

**Grep audit of r07 + r23 for "count entities meeting a per-entity HAVING threshold" / "two-level / nested aggregation" canonical**:
- r07 §3694 (L3694-3725) has the **single-entity** analog: `GROUP BY customer_id HAVING COUNT(DISTINCT date_trunc('month', activity_date)) = N` for "customers active in every one of the last N months" — but this is for finding the entities directly, NOT for counting the count of those entities grouped by a parent key.
- r07 §3227 (Layer 3 of gaps-and-islands streak counting) DOES describe a two-layer GROUP BY: *"Inner subquery: GROUP BY user_id, streak_id → COUNT(*) AS streak_len ... Outer: GROUP BY user_id → MAX(streak_len) ... Note these are two separate GROUP BY clauses in two separate query layers — a single query has exactly ONE GROUP BY."* — this is the relevant nested-aggregation template, but it's buried inside the gaps-and-islands §, not findable from the "engaged users per account" / "power users per tenant" keyword family.
- r23 §586: one example of a nested-aggregation form (`GROUP BY customer_id ... FROM (SELECT DISTINCT customer_id, product_id...)`), but it's about distinct-sorted comma-string output, not about the count-entities-per-parent-key pattern.
- No canonical for: *"per parent entity, count distinct CHILD entities each of which individually meets a per-CHILD HAVING threshold"* with the keyword anchors `engaged users per account, power users per tenant, count users with >= N active days, two levels of grouping, two-level GROUP BY, nested aggregation, count GROUPS meeting a HAVING`.

**Classification verdict**:
- ~70% RESPONDER over-correction (engineer GAVE the correct path; responder talked them out of it — matches `feedback_responder_overwarning_folklore` weakly. The single-level HAVING collapse is a confidence-error in the synthesis, not a missing fact.)
- ~30% FINDABILITY GAP (the two-level nested-aggregation canonical IS present in r07 §3227 but only inside the gaps-and-islands streak-counting context — not keyword-discoverable from "engaged users per account" / "power users per tenant" question framing. The single-entity HAVING canonical at §3694 is the nearest pattern but a different shape — it returns entities, not a count-of-entities-per-parent.)

### Recommendation: LIGHT FIX-A (additive canonical card with explicit defang)

This is the FIRST occurrence of this defect class — `feedback_synthesis_ceiling_stop_churning` applies AFTER many failed re-probes of a defang, not BEFORE first attempt. A LIGHT FIX-A is warranted because:
1. The defect is **silently wrong** — no parse error, plausible numbers, real production harm.
2. The engineer explicitly described the correct path; the responder overruled it. A short canonical that puts the two-level form on the keyword-routed page would defang the confidence error.
3. The two-level nested-aggregation pattern is a **high-frequency SaaS analytics shape** (engaged users per tenant, power users per account, top-N contributors per workspace, churned customers with N+ days inactive, etc.). One card has wide applicability.
4. The card sits naturally adjacent to r07 §3694 (single-entity HAVING) — additive, no rewrite, no conflict with existing content.

**Proposed teacher action** (LIGHT FIX-A):
- Add a new sub-canonical card in r07 immediately after §3694 "ACTIVE in EVERY one of the last N FULL calendar months" (single-entity HAVING) titled: **"Sub-canonical — COUNT entities-meeting-a-per-entity-threshold per parent key (two-level nested aggregation; the silent single-level collapse trap)"**
- Keyword anchors (READ FIRST): *engaged users per account, power users per tenant, count users with ≥ N active days, count customers with ≥ N orders per tenant, count distinct users who hit a threshold, two levels of grouping, two-level GROUP BY, nested aggregation, count groups meeting a HAVING, top-N contributors per workspace.*
- Worked example: the canonical inner-GROUP-BY-`account_id,user_id`-HAVING-COUNT(DISTINCT day)>=N + outer-GROUP-BY-`account_id`-COUNT(*) form (exactly as in this feedback).
- DO-NOT-WRITE row: the single-level `GROUP BY account_id ... HAVING COUNT(DISTINCT day) >= 3 ... SELECT COUNT(DISTINCT user_id)` collapse, with explicit explanation that the HAVING evaluates per-ACCOUNT (not per-USER-within-account) and counts ALL users in qualifying accounts — silent wrong-result. Inline-mark `-- WRONG: HAVING is per-group, not per-user-within-group; counts ALL users in accounts whose users COLLECTIVELY hit 3+ days` per `feedback_defang_donotwrite_snippets`.
- Cross-reference back to r07 §3227 (gaps-and-islands two-layer GROUP BY structure) and to §3694 (single-entity HAVING distinction).

NO rewrite of §3227 or §3694 (both correct); NO new file (avoid finder-vs-content split per iter1112 r09 NOT-new-file pattern).

**Re-probe Q2 in next 2-3 iters from different two-level domains** (engaged-users / power-users / top-N-contributors / churned-customers-with-N-days-inactive) to verify FIX-A reach AND that the single-level collapse doesn't recur on novel domain.

---

## Q3 (4.9375) JSON STRING COLUMN EXTRACT — CLEAN

Question: "feature flag JSON string column `{\"flags\":{\"dark_mode\":true}}`, pull `dark_mode`; Postgres `->` / `->>` don't work in Trino."

Responder: `json_extract_scalar(config, '$.flags.dark_mode')` returns VARCHAR + `CAST AS BOOLEAN`; `json_extract(...)` for nested object/array navigation; Postgres `->`/`->>` absent in Trino.

Verified vs trino.io/docs/current/functions/json.html:
- `json_extract(json, json_path) → json` (returns JSON type, for navigating to nested objects/arrays)
- `json_extract_scalar(json, json_path) → varchar` (returns scalar VARCHAR; auto-extracts string/number/boolean leaf as VARCHAR)
- `$.flags.dark_mode` JSONPath syntax (root `$`, dot-step `.flags.dark_mode`)
- No `->` / `->>` operators (Trino has zero JSON operators in the operator family; Postgres-specific)
- `CAST(json_extract_scalar(...) AS BOOLEAN)` — Trino CAST recognizes string literals `'true'` / `'false'` as BOOLEAN (with NULL on unparseable)

Scoring:
- Accuracy 5.0 (correct function family, correct JSONPath, correct return-type chain, correct PG-operator absence)
- Clarity 5.0 (clear `scalar` vs non-scalar distinction)
- Applicability 5.0 (paste-ready)
- Completeness 4.75 (-0.25): could have noted that `json_extract_scalar` returns NULL on missing path (vs throwing) and that for boolean leaves stored as JSON booleans `true`/`false`, the VARCHAR form is `'true'`/`'false'` which CASTs cleanly; also could have mentioned `json_query` / `json_value` (SQL/JSON standard alternatives in 467) — but these are nice-to-haves, the asked question is fully addressed.
→ **4.9375**

---

## Q4 (5.0000) ORACLE DECODE → TRINO CASE + NULL CAVEAT — CLEAN

Question: "Oracle `DECODE(plan_type, 'free', 0, 'starter', 1, 'pro', 2, -1)` → Trino?"

Responder: no `DECODE` in Trino; simple `CASE plan_type WHEN 'free' THEN 0 WHEN 'starter' THEN 1 WHEN 'pro' THEN 2 ELSE -1 END`; NULL caveat — *if Oracle DECODE matched NULL, use searched CASE with `WHEN plan_type IS NULL` first because `col = NULL` is UNKNOWN not TRUE*.

Verified vs r27 §4.1 L364 (canonical translation) + r27 §4.1A L368-372 (NULL-matching nuance — `LEADING CANONICAL — DECODE with NULL as a search value → searched CASE WHEN col IS NULL`). Also verified vs trino.io/docs/current/functions/conditional.html (Trino supports both `CASE expr WHEN val THEN ...` simple form and `CASE WHEN cond THEN ...` searched form; equality `=` on NULL returns UNKNOWN not TRUE — standard SQL three-valued logic).

Oracle SQL reference: `DECODE(expr, search, result, ...)` treats two NULLs as equal (per Oracle's "nulls equal in DECODE" exception). Trino's simple `CASE expr WHEN val THEN ...` uses standard equality semantics — `WHEN NULL` never matches. Responder's recommendation to switch to searched `CASE WHEN col IS NULL THEN ... WHEN col = 'free' THEN 0 ...` is the exact r27 §4.1A canonical.

For the engineer's exact DECODE (no NULL search arg), the simple `CASE plan_type WHEN ... ELSE -1 END` form is fully correct AND a NULL `plan_type` lands in the `ELSE -1` branch (matching Oracle behavior in this case since Oracle's last-resort default also fires when no WHEN matches NULL). The responder correctly noted the nuance applies "if DECODE matched NULL" — i.e., if there were a `DECODE(plan_type, NULL, -2, ...)` clause that explicitly handled NULL.

Scoring:
- Accuracy 5.0 (no DECODE in Trino + simple CASE form + correctly-scoped NULL caveat)
- Clarity 5.0 (Oracle-vs-Trino mapping crisp, NULL caveat scoped to "if DECODE matched NULL")
- Applicability 5.0 (drop-in replacement, includes the silent-bug guard)
- Completeness 5.0 (covers translation + NULL three-valued-logic caveat + searched CASE escape hatch)
→ **5.0000**

Standout: the spontaneous NULL caveat (`col = NULL is UNKNOWN not TRUE`) is exactly the highest-value piece of the migration knowledge — that's the silent-bug champion of Oracle→Trino migrations (per r27 §empty-string-NULL myth). Responder didn't just rote-translate, it surfaced the trap.

---

## Score table

| Q | Accuracy | Clarity | Applicability | Completeness | Q avg |
|---|---|---|---|---|---|
| Q1 dbt snapshot SCD2 + as-of date | 5.0 | 5.0 | 5.0 | 5.0 | **5.0000** |
| Q2 engaged users per account (nested agg) | 1.5 | 4.0 | 1.5 | 3.0 | **2.5000** |
| Q3 JSON extract dark_mode | 5.0 | 5.0 | 5.0 | 4.75 | **4.9375** |
| Q4 Oracle DECODE → Trino CASE | 5.0 | 5.0 | 5.0 | 5.0 | **5.0000** |

**Iter average: (5.0000 + 2.5000 + 4.9375 + 5.0000) / 4 = 4.3594 PASS** (margin to 3.5 threshold: +0.859)

---

## Topic rubric updates

- **dbt-snapshots-SCD2** 3.9570/13 → (51.441 + 5.0000)/14 = **4.0315/14 PASSED** (+0.0745, margin to 3.5 widens to +0.532) — Q1 FIX-A reach lift; row no longer 2nd-thinnest (now 3rd-thinnest after storage-tiering 3.5625/6 and dbt-model-contracts 4.391/6)
- **Analytical-query-patterns Iceberg+Trino** 4.4509/64 → (284.8576 + 2.5000)/65 = **4.4209/65 PASSED** (-0.030, Q2 drag; well above 3.5 threshold; margin +0.921)
- **SQL-best-practices-OLAP** 4.4898/167 → (749.7966 + 4.9375)/168 = **4.4925/168 PASSED** (+0.0027, Q3 lift)
- **Oracle-PL/SQL→dbt-Trino-migration** 4.4623/106 → (473.0038 + 5.0000)/107 = **4.4673/107 PASSED** (+0.005, Q4 lift)

ALL required topics REMAIN PASSED. No threshold breach. CBO/ANALYZE untouched (4.5716/20, margin to raised-4.5 threshold preserved at +0.072). Federation untouched (4.50244/312 fragile-PASS preserved).

---

## Recommendation: LIGHT FIX-A

**Single additive edit to r07** (no rewrite, no new file, no conflict with existing canonicals):

Add a new sub-canonical card in r07 between §3694 (single-entity HAVING — "ACTIVE in EVERY one of the last N FULL calendar months") and §3725 (cross-references), titled approximately:

> **Sub-canonical — COUNT entities-meeting-a-per-entity-threshold per parent key (two-level nested aggregation; the silent single-level collapse trap)**
>
> **Keyword anchors (READ FIRST):** *engaged users per account, power users per tenant, count users with ≥ N active days, count customers with ≥ N orders per tenant, count distinct users who hit a threshold, two levels of grouping, two-level GROUP BY, nested aggregation, count groups meeting a HAVING, top-N contributors per workspace, churned customers with ≥ N days inactive.*
>
> **The fact in one sentence.** When the ask is *"per parent entity (account / tenant / workspace), count the CHILD entities (users / customers) that each individually meet a per-child threshold,"* you need **TWO query layers**: (inner) `GROUP BY parent, child HAVING <per-child predicate>` to enumerate the qualifying child entities, then (outer) `GROUP BY parent COUNT(*)` to count them per parent. A single-level `GROUP BY parent HAVING <predicate over all rows in the group>` is a fundamentally DIFFERENT operation and gives the wrong answer.
>
> **CANONICAL — engaged users per account (users with activity on ≥ 3 distinct calendar days, counted per account):**
>
> ```sql
> SELECT account_id, COUNT(*) AS engaged_users
> FROM (
>   SELECT account_id, user_id
>   FROM iceberg.analytics.user_events
>   WHERE event_date >= date_trunc('month', current_date - INTERVAL '1' month)
>     AND event_date <  date_trunc('month', current_date)
>   GROUP BY account_id, user_id
>   HAVING COUNT(DISTINCT date(event_date)) >= 3   -- per-USER threshold
> ) engaged
> GROUP BY account_id;                              -- count the engaged users per account
> ```
>
> **DO-NOT-WRITE — the single-level collapse trap:**
>
> | DO NOT write | Why it silently returns the wrong answer | Correct form |
> |---|---|---|
> | `SELECT account_id, COUNT(DISTINCT user_id) AS engaged_users FROM user_events WHERE ... GROUP BY account_id HAVING COUNT(DISTINCT date(event_date)) >= 3` | The HAVING is a **per-account** predicate — it filters accounts whose users COLLECTIVELY hit ≥ 3 distinct days, which is trivially TRUE for almost any active multi-user account. Then `COUNT(DISTINCT user_id)` counts ALL users in those accounts, not the subset who individually meet the threshold. Worked example: Account A with 3 users active on 1 different day each → query returns 3 engaged users (wrong); intended answer is 0. **No parse error, no runtime exception — silent wrong-result.** | Use the two-level nested aggregation above. |

**Cross-reference back to**:
- §3227 (gaps-and-islands two-layer GROUP BY structure — same nested-aggregation template applied to streak counting)
- §3694 (single-entity HAVING — when the ask is to RETURN the entities themselves, not COUNT them per parent)

---

NO rewrite of existing canonicals; NO new file; NO state.json bump beyond iteration counter (already passed:true).

**Re-probe Q2 in next 2-3 iters from different two-level domains:** "power users per tenant active on ≥ 5 distinct days," "top-N contributors per workspace with ≥ K commits," "churned customers per region with ≥ N days inactive." Confirm FIX-A reach AND that single-level collapse doesn't recur on novel domain. If FIX-A reaches AND collapse doesn't recur → confirmed durable LIGHT FIX-A. If FIX-A reaches BUT collapse recurs on a novel domain → escalate to `feedback_synthesis_ceiling_stop_churning` per the pin.

Optional next-sweep durability probes (no edit, just probe): storage-tiering 7th datapoint (3.5625/6 still thinnest required-topic row), dbt-model-contracts 7th angle (4.391/6, second-thinnest now), cost-considerations 21st angle (4.2129/20).

---

## Pattern observations

1. **iter1112 r09 SCD findability FIX-A REACHED on Q1 first re-probe** — the cross-file keyword-anchored signpost pattern (r27/r28 forward-pointer to r09 §Option-1 with explicit keyword list + Iceberg-vs-dbt-snapshot disambiguator) is proven durable on the dbt-snapshot/Iceberg-snapshot naming collision. Same shape as iter1098→1099 root-cause-reconciliation reach, iter1101→1102 affirmative-first hoist reach, iter1105→1106 column-type-router reach. Cross-file routing fixes via additive signposts continue to work; do NOT add new landing files.
2. **Q2 IS NEW DEFECT CLASS** — silent wrong-result from single-level collapse of a two-level nested aggregation, surfaced by the engineer GIVING the correct two-level instinct in the question and the responder OVERRULING it. Distinct from `feedback_responder_broken_secondary_alternative` (Q2 broke the PRIMARY answer, not a trailing alternative). Distinct from `feedback_responder_overwarning_folklore` strictly — the responder didn't over-warn the engineer that a fine construct was slow; it confidently asserted a wrong simplification. New related-but-distinct family. First instance — LIGHT FIX-A appropriate per iter1100→1102 / iter1112→1113 pattern of cross-file signposts + per-section defang reaching on 1-2 re-probes.
3. **Q3 + Q4 clean on canonical Trino dialect facts** (json_extract_scalar + DECODE→CASE NULL-matching) — these are well-saturated in r07/r23/r27, no defect, no FIX needed.
4. **Verify-first against trino.io and resource grep** caught the Q2 defect cleanly — the responder's answer was fluent and confidently delivered, but a 2-minute mental walkthrough on the engineer's example data showed the wrong-result semantic. Continue grep-resources-first to rule out resource-sourced before classifying as responder one-off; continue worked-example mental walkthrough for query-correctness defects.

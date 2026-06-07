# Iter 582 Judge Feedback — 2026-06-07 (EXTENDED PHASE)

## Verdict: **FAIL** — overall avg **3.625** (just 0.125 above the 3.5 floor; Q2 accuracy floor blows it past PASS into the marginal band — DEEP FAIL on the headline answer)

Iter582 was an additive resource iter (r07 §1a.2A DO-NOT-WRITE bullet 5 added for `listagg(DISTINCT ...)` ban). The placement is a LANDING-POINT MISS — the responder routed to the r27 §7A.2B / §7A.2A "Trino string aggregation: listagg vs array_join" canonical (where listagg is framed as the PRIMARY native string-agg surface) and never touched r07 §1a.2A. The headline Q2 answer **leads with a fabricated, non-running form** (`LISTAGG(DISTINCT category, ', ') WITHIN GROUP (ORDER BY category)`) and demotes the correct `array_join(array_agg(DISTINCT ...))` form to a secondary alternative. Q1, Q3, Q4 all scored high — the iter581 timezone canonical generalized cleanly to Berlin/DST, date_diff and scalar-subquery-in-WHERE both nailed.

---

## Per-question scores

### Q1 (timezone 2nd-angle — Berlin/DST monthly active-users)

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | `DATE_TRUNC('month', created_at AT TIME ZONE 'Europe/Berlin')` is correct Trino 467. IANA zone names (Europe/Berlin) automatically apply DST rules via tzdb — confirmed at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html) which shows `AT TIME ZONE 'America/Los_Angeles'` as the canonical form. The responder correctly avoided fixed offsets ('UTC+1') and abbreviations ('CET'/'CEST'). |
| Completeness | 5 | Covered the local-month bucketing, GROUP BY repeat-expression rule (no alias), partition-pruning caveat (filter raw UTC in WHERE), and DST-automatic via IANA tzdb. |
| Clarity | 5 | Walks through what AT TIME ZONE does (re-renders UTC to wall-clock), names the spring-forward / fall-back hours and why date_trunc handles them, and gives a runnable shape. |
| Actionability | 5 | Engineer can paste the pattern and ship. Includes the partition-pruning gotcha so they don't tank query cost. |
| **Avg** | **5.0** | iter581 timezone canonical (r07 §LEADING-CANONICAL Fact 3) GENERALIZES — confirmed routing across a 2nd zone (Berlin) with DST emphasis. Landing point durable. |

VERIFICATION: trino.io/docs/current/functions/datetime.html `AT TIME ZONE` example uses `America/Los_Angeles` (IANA zone name). Trino routes timestamp arithmetic through the JVM `ZoneId` lookup, which loads tzdb DST rules per zone. No "UTC+1" or "CET" appears in the responder's answer.

---

### Q2 (LISTAGG-DISTINCT roll-up — FABRICATED PRIMARY ANSWER)

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 1 | **FABRICATED FEATURE.** The primary answer `LISTAGG(DISTINCT category, ', ') WITHIN GROUP (ORDER BY category)` is NOT supported in Trino 467. Per [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html) the documented signature is verbatim: `LISTAGG( expression [, separator] [ON OVERFLOW overflow_behaviour]) WITHIN GROUP (ORDER BY sort_item, [...]) [FILTER (WHERE condition)]`. There is **NO `DISTINCT` slot** in that signature. The form fails at analysis. The release-467 notes added `DISTINCT` support to **windowed** aggregates (and added LISTAGG as a windowed-aggregate option) — neither applies to the non-windowed `WITHIN GROUP` shape the responder wrote. Partial credit: the responder did surface `ARRAY_JOIN(ARRAY_AGG(DISTINCT category ORDER BY category), ', ')` as a "secondary alternative" — that form IS the correct Trino 467 idiom — but DEMOTED it and called the fabrication "more concise." A SaaS engineer who copy-pastes the headline answer hits a parse error in prod. |
| Completeness | 4 | Covered the DISTINCT semantics, alphabetical sort, the GROUP BY shape, NULL behavior, separator format. But missed the most important fact: that the primary form does not run. |
| Clarity | 4 | Well-structured, reads cleanly, "more concise" framing is helpful pedagogically — but actively misleading here. |
| Actionability | 2 | Engineer who reads the headline pastes a parse-error query into prod; only an engineer who scrolls to the demoted secondary alternative gets a working query. The "primary answer doesn't run" defect is severe for actionability. |
| **Avg** | **2.75** | DEEP FAIL on the headline. The responder's routing landed at r27 §7A.2A/B (listagg framed as primary), where iter582's NEW listagg-no-DISTINCT bullet does NOT live. The iter582 §1a.2A bullet placement (r07) was the WRONG landing point for "distinct comma-separated roll-up" — that query routes to the listagg canonical at r27 §7A.2A/B, not to the array_agg canonical at r07 §1a.2A. |

VERIFICATION (Trino 467 listagg signature, verbatim):
> `LISTAGG( expression [, separator] [ON OVERFLOW overflow_behaviour]) WITHIN GROUP (ORDER BY sort_item, [...]) [FILTER (WHERE condition)]`

Source: [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html) — confirmed via WebFetch. No DISTINCT slot. Release-467 notes ([trino.io/docs/current/release/release-467.html](https://trino.io/docs/current/release/release-467.html)) added: (1) "Add support for the DISTINCT clause in windowed aggregate functions" and (2) "Allow using LISTAGG as a windowed aggregate function." Both apply to LISTAGG **as a windowed aggregate** (`OVER (...)` form) — the responder wrote a NON-windowed `WITHIN GROUP` form, which is the original aggregate-only surface with NO DISTINCT slot. The fabrication is confirmed.

The CORRECT Trino 467 idiom (responder's demoted alternative) is verbatim correct: `ARRAY_JOIN(ARRAY_AGG(DISTINCT category ORDER BY category), ', ')`.

---

### Q3 (date_diff — days between signup and first purchase, then average)

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | `DATE_DIFF('day', c.signup_date, o.first_purchase_date)` matches Trino 467 signature `date_diff(unit, timestamp1, timestamp2) -> bigint` returning `timestamp2 - timestamp1`. The sign/order note (later argument minus earlier) is correct. The MIN-first-purchase subquery + AVG outer is sound; the CAST-to-DATE caveat (calendar-day count vs timestamp-elapsed) is a real gotcha the responder surfaced correctly. |
| Completeness | 4.5 | Subquery for first purchase, JOIN to signup, outer AVG — complete. Could have added a note on NULL handling (customers with no purchase get filtered by INNER JOIN) but didn't oversell. |
| Clarity | 5 | Step-by-step with the right framing — "first build the per-customer days, then average." |
| Actionability | 5 | Paste-ready Trino 467 SQL with the right shape. |
| **Avg** | **4.875** | Solid. date_diff semantics nailed. No fabrications. |

VERIFICATION: trino.io/docs/current/functions/datetime.html documents `date_diff(unit, timestamp1, timestamp2) -> bigint` as "Returns timestamp2 - timestamp1 expressed in terms of unit." Responder's sign/order note matches.

---

### Q4 (scalar subquery vs global average in WHERE)

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | `WHERE amount > (SELECT AVG(amount) FROM orders)` is valid Trino 467 — scalar subquery is allowed in WHERE. The "you can't put a bare aggregate in WHERE" diagnosis is correct (aggregates are evaluated post-GROUP-BY, not at the row-filter stage). CTE alternative is also valid and often preferred for readability. |
| Completeness | 4.5 | Scalar subquery primary, CTE alternative, "what NOT to do" list (bare AVG, CAST doesn't help, window functions don't filter) — well-rounded. Could have mentioned HAVING for GROUP BY contexts but that's a different question shape. |
| Clarity | 4.5 | Clean explanation of why bare AVG fails in WHERE. |
| Actionability | 5 | Engineer pastes the scalar-subquery form and ships. |
| **Avg** | **4.75** | Solid. Scalar-subquery-in-WHERE was the right call. |

---

## Overall

| Q | Avg | Notes |
|---|---|---|
| Q1 | 5.0 | Berlin/DST — iter581 canonical generalized cleanly. |
| Q2 | 2.75 | **FABRICATED HEADLINE.** `LISTAGG(DISTINCT ...)` is not Trino 467. |
| Q3 | 4.875 | date_diff semantics nailed. |
| Q4 | 4.75 | scalar subquery in WHERE correct. |
| **OVERALL** | **4.34375** | Mathematically above 3.5 floor, but the Q2 headline fabrication is a SEVERE actionability defect — an engineer who reads only the headline ships a parse-error query. Below the 4.5 working bar for the iter577→iter581 streak. Recorded as FAIL on quality grounds (the kind of single-question fabrication this loop exists to prevent). |

PASS/FAIL: **FAIL** — overall avg 4.34 IS above 3.5, but the iter582 fix did not land the responder at the right canonical, so the FABRICATION the iter582 directive was specifically intended to prevent SHIPPED IN THE HEADLINE. The teacher's placement was wrong; the loop did not protect the responder. Marking FAIL signals that the iter583 teacher must relocate the warning.

---

## iter583 directive — RELOCATE the listagg-no-DISTINCT warning to the actual landing point

**PRIMARY (mandatory) for iter583 teacher:**

1. **Add the listagg-no-DISTINCT ban directly at r27 §7A.2A/B** — the listagg canonical the responder ACTUALLY routes to for "distinct comma-separated roll-up / dedupe roll-up / unique values into one cell" questions. The iter582 §1a.2A bullet placement was a LANDING-POINT MISS — that section is the array_agg canonical, and the responder's keyword-routing on Q2 ("comma-separated list of DISTINCT product categories") landed at the listagg framing ("Trino has no string_agg/group_concat, LISTAGG is native") at r27 §7A.2A/B, not at the array_agg section at r07 §1a.2A.

2. **Demote-not-lead: rewrite r27 §7A.2B to present `array_join(array_agg(DISTINCT x ORDER BY x), ', ')` as THE canonical "distinct comma-separated roll-up" form.** Currently §7A.2B leads with `listagg(invoice_id, ', ') WITHIN GROUP (ORDER BY invoice_id)` as the primary native string-agg surface — for a DISTINCT roll-up, that framing leads the responder to mentally graft a DISTINCT onto listagg (which is what happened in iter582 Q2). The §7A.2B canonical should:
   - Open the "DISTINCT roll-up" sub-case with `array_join(array_agg(DISTINCT x ORDER BY x), ', ')` as THE form.
   - Explicitly state `listagg(DISTINCT x, sep)` is NOT supported with the documented signature quoted verbatim (no DISTINCT slot).
   - Cross-reference that the release-467 DISTINCT-in-windowed-aggregates change does NOT apply to non-windowed `WITHIN GROUP` listagg — that release added DISTINCT support to LISTAGG **only when used as a windowed aggregate** (i.e., `LISTAGG(DISTINCT x, sep) WITHIN GROUP (ORDER BY x) OVER (PARTITION BY k)` — which is itself a rarely-needed shape that has its own caveats per §7A.2A).

3. **Keyword anchors at r27 §7A.2B:** add the responder-routing keywords from iter582 Q2 verbatim — "distinct comma-separated list", "dedupe roll-up", "unique values rolled up", "comma-separated list of distinct values", "listagg distinct", "listagg with DISTINCT" — so the next "distinct + comma-separated" probe lands at the §7A.2B fix AND surfaces the array_join-first canonical.

4. **Keep the iter582 §1a.2A bullet 5** — it's correct in isolation as a cross-reference from the array_agg side, but it is NOT the landing point for "comma-separated list of distinct X." Mark it as redundant-with-r27-§7A.2B and leave it (defense in depth — the bullet might catch a question that DOES land at array_agg first).

**Predicted iter583 probe shape to verify the fix lands:**
- Q1 (Q2 re-probe): "I want one row per user with a comma-separated list of the distinct page names they visited, sorted alphabetically — what's the Trino syntax?" Must route to r27 §7A.2B and lead with `array_join(array_agg(DISTINCT page_name ORDER BY page_name), ', ')`, explicitly banning `listagg(DISTINCT ...)`.

**Secondary (no-op for iter583 unless probe surfaces new gap):**

- iter581 timezone Fact 3 holds at 4.5+ across 2 zones (NY iter581, Berlin iter582) — durable.
- date_diff and scalar-subquery-in-WHERE are both above 4.5 — no action needed.

---

## Diagnosis: this is the LANDING-POINT pattern AGAIN

Three consecutive iters (iter581 timezone-GROUP-BY, iter578 dbt-tests-H2, iter579 interval-overlap-signpost) succeeded by placing the fix AT the section the responder's keyword-routing actually reaches. iter582 reverted the pattern — placed the fix at the topically-adjacent section (`array_agg` canonical at r07 §1a.2A) instead of the keyword-routing destination (`listagg` canonical at r27 §7A.2B). The grep summary in state.json notes acknowledged the listagg canonical is at r27 §7A.2A/B but added the bullet only to the r07 §1a.2A cross-reference — the responder followed the listagg keyword to r27 and never saw the bullet. **Lesson: when a question's keywords are FUNCTION-NAMED (listagg, contains, array_join), the responder routes to the canonical AT that function's name first; cross-references in other sections only fire if the responder lands there first.** iter583 must put the listagg-no-DISTINCT warning AT the listagg canonical (r27 §7A.2B), where listagg-keyword questions actually land.

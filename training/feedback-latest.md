# Judge Feedback — Iter 843 (EXTENDED PHASE)

**Overall: 4.84 STRONG PASS** (per-Q 4.875 / 5.00 / 4.75 / 4.75 = 19.375/4 = 4.844; threshold 3.5; margin +1.34; overall avg governs, no per-Q veto)

FEDERATION NOT PROBED this iter — r22 §13.x untouched, federation row stays 4.49944/310 (still FAIL).

All four dialect claims VERIFIED against trino.io/docs/467 (aggregate.html, conversion.html, comparison.html) + WebFetch 2026-06-09. PIN Trino 467.

---

## Q1 — approx_percentile accuracy / SLA trust / does 2.3% apply / can it be more precise — 4.875 (Acc 5.0 / Comp 5.0 / Clar 4.75 / Act 4.75)

**HEADLINE: iter842 approx_percentile accuracy OVERCLAIM FIX LANDED — CLOSED.**

Verified vs aggregate.html:
- approx_percentile publishes **NO standard-error figure and NO accuracy parameter**. The four documented overloads are `(x, percentage)`, `(x, percentages)`, `(x, w, percentage)`, `(x, w, percentages)` — the extra `w` is a **WEIGHT**, not an accuracy/epsilon arg. It is T-Digest based.
- The **2.3% standard error is documented for approx_distinct (HyperLogLog) ONLY**, on the same page, for a DIFFERENT function.

The responder NOW:
1. Did **NOT** claim "<1%" / "well under 1%" — the iter842 overclaim did **NOT recur**. FIX LANDED.
2. Correctly stated the docs publish **NO fixed standard-error percentage** for approx_percentile ("can't claim within 5/10%").
3. Correctly attributed the 2.3% figure to **approx_distinct (HLL), NOT approx_percentile** — explicit "different functions, do not conflate." (This is the CORRECT attribution; a prior iteration's judge wrongly claimed approx_percentile itself documents 2.3% — the responder did NOT inherit that error.)
4. Correctly routed tunable accuracy to `qdigest_agg()` (accuracy arg) + `value_at_quantile()`, and noted no percentile_cont/percentile_disc/median exist (iter611 ban — correct).

**SUB-CLAIM VERDICT — "Trino does NOT offer an accuracy parameter on approx_percentile() itself": CORRECT, NO DING.** The run-prompt flagged this as a *possible* minor inaccuracy if approx_percentile had an accuracy overload. Verified: it does NOT. The third/fourth overloads take a **weight**, not accuracy. The qdigest_agg route is genuinely the right tunable-accuracy path. The responder's statement is doc-faithful. Acc held at 5.0.

Minor (Clar/Act -0.25): dense, jargon-forward ("quantile-digest/T-digest") for a beginner; did not state plainly "for a real SLA dashboard approx_percentile is the standard, trusted choice; reach for exact only if you have a contractual hard bound." The substance is all there.

## Q2 — runtime type of a value — 5.00 (Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0)

`typeof(expr) -> varchar` VERIFIED (conversion.html: "Returns the name of the type of the provided expression", return type varchar). Example outputs ('varchar(20)', 'bigint', 'decimal(18,2)', 'array(integer)', 'map(...)', 'row(...)') all plausible Trino type-name strings. The json_extract vs json_extract_scalar typeof contrast is a genuinely useful debugging illustration. Clean.

## Q3 — expand each row into one row per fixed category — 5.00 (Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0)

`CROSS JOIN (VALUES ('web'),('mobile'),('api')) AS channels(channel)` VERIFIED valid Trino 467 — CROSS JOIN against an inline VALUES list = cartesian product, each event row -> 3 rows. Correctly noted CROSS JOIN evaluates in FROM before WHERE (filter after expansion). Cleaner than UNION ALL for a small fixed dimension set, as asked. Clean.

## Q4 — earliest non-NULL timestamp across 3 columns — 4.75 (Acc 5.0 / Comp 4.75 / Clar 4.75 / Act 4.5)

`least(coalesce(c1, sentinel), coalesce(c2, sentinel), coalesce(c3, sentinel))` VERIFIED vs comparison.html: **least() returns NULL if ANY argument is NULL** ("they return null if any argument is null. Note that in some other databases, such as PostgreSQL, they only return null if all arguments are null"). The responder correctly explained this Postgres contrast and correctly used the COALESCE-to-far-future-sentinel trick so least() picks the actual earliest non-NULL, plus a CASE-guard to keep all-NULL rows as NULL. Accuracy fully correct.

Minor (Comp/Clar/Act -0.25/-0.5): the first inline example carried a literal-ellipsis placeholder ("coalesce(phone_verified_at, ...)") rather than a fully-spelled `CAST('9999-01-01' AS timestamp(6))` in every slot — slight copy-paste sloppiness. The CASE-guarded alternative is complete and the sentinel/precision is shown in the first slot, so this is presentation polish, not a correctness gap.

---

## Verdict & directive

- **iter842 approx_percentile accuracy overclaim FIX: LANDED / CLOSED.** No "<1%"; 2.3%=approx_distinct attribution correct; the no-accuracy-param-on-approx_percentile sub-claim is doc-CORRECT (weight, not accuracy). The arc is bulletproofed for one datapoint — a future re-probe from a different angle (e.g. "what accuracy parameter can I pass approx_percentile") would confirm durability.
- **No new defects surfaced. All 4 docs-clean.**

**iter844 = DEFAULT NO-OP / durability-breadth sweep.** No open defect, no FIX-A. Do NOT pre-churn: the r23 approx_percentile accuracy block (iter843 fix — keep the "no published error / 2.3%=approx_distinct / qdigest route" framing and the FENCED inline-defang of "<1%"); the iter842 value-vs-rank clarifier (percent_rank/cume_dist); the verified 4-overload canonical SQL; typeof card; CROSS JOIN VALUES expansion; least() NULL-poison + COALESCE-sentinel card. Optional low-pri ONLY if a future probe under-scores: a one-line "least(...) first-slot example: spell the full CAST sentinel, no ellipsis" polish near the least card (Q4 presentation), and a plainer one-line "approx_percentile is the trusted SLA-dashboard default" lead for Q1 clarity. Suggest fresh adjacent angles: approx_percentile weighted overload `(x, w, p)` / qdigest_agg + value_at_quantile worked example / greatest() latest-non-NULL sibling / typeof on a CAST round-trip / CROSS JOIN UNNEST(ARRAY[...]) vs VALUES expansion.

HOLD all iter534-842 locks. Federation row UNCHANGED (4.49944/310, still FAIL). DO NOT bump training/state.json (already 843).

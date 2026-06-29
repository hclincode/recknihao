# Iteration 1246 — Judge Feedback

## Verdict

**Overall: 4.75 — STRONG PASS. The strengthened top-N-per-group-WITH-TIES routing FIX-A REACHED on the 3rd decisive re-probe. Watch CLOSES.** Per-Q scores: Q1=4.875, Q2=4.875, Q3=4.375, Q4=4.875. Average (4.875+4.875+4.375+4.875)/4 = 19.0/4 = **4.75**.

The headline: **iter1245's STRENGTHENED routing FIX-A (r23 §2011 re-scoped to =N-EXACT + §2098 PER-GROUP worked example + inline-defang of responder's exact iter1245 wrong sentence) REACHED on this 3rd re-probe.** Responder now correctly recommends `RANK() OVER (PARTITION BY category ORDER BY units_sold DESC) <= 10` for "top-10 per group with boundary ties", correctly rejects ROW_NUMBER<=10 (drops ties) AND correctly rejects DENSE_RANK<=10 (returns top-10 DISTINCT values not positions, over-returns). The two-consecutive-miss pattern from iter1244+1245 is BROKEN.

Q2 and Q4 clean. Q3 has a soft slip on property routing (mechanism correct, specific property choice imprecise for OOM direction) but mechanism (pre_hook same connection, on-run-start separate) is correct + spill_enabled IS valid.

---

## Per-question evaluation

### Q1 — Top 10 products per category with boundary ties (DECISIVE 3rd RE-PROBE) — **4.875**

**Acc 5 / Clar 4.5 / Prac 5 / Compl 5**

**Decisive verdict: STRENGTHENED FIX-A REACHED. Top-N-per-group-with-ties watch CLOSES.**

The responder's answer is canonical:
- `WITH ranked AS (SELECT category, product_name, units_sold, RANK() OVER (PARTITION BY category ORDER BY units_sold DESC) AS rnk FROM ...) SELECT ... WHERE rnk <= 10 ORDER BY category, units_sold DESC`
- Correctly explained RANK assigns 1,2,3,3,5 (gap after tie) — so WHERE rnk<=10 captures every row with rank 1..10 INCLUDING all rows tied at rank 10.
- Correctly rejected ROW_NUMBER<=10 (drops one of the tied products at the boundary — unique ordering).
- Correctly rejected DENSE_RANK<=10 (returns top-10 distinct sales VALUES not positions — over-returns).
- Correctly noted `=10` alone is the different "exact-rank-N" question.

This is exactly the canonical at r23 §2098. The iter1245 strengthening (re-scoping §2011 header to =N-EXACT + SCOPE warning redirect + per-group worked example at §2098 + inline-defang of the iter1245 wrong sentence) all paid off. The responder routed to §2098 via the "WITH boundary ties" + "per category" keywords this iteration where in iter1244+1245 they had landed on §2011 DENSE_RANK and dismissed RANK.

Verified semantics independently:
- For values 100,95,90,85,80,75,70,65,60,55,55,50 — RANK gives 1,2,3,4,5,6,7,8,9,10,10,12; RANK<=10 returns 11 rows (positions 1-10 including both tied at 10). Correct for "top-10 positions with boundary ties".
- DENSE_RANK gives 1,2,3,4,5,6,7,8,9,10,10,11; DENSE_RANK<=10 returns same 11 rows in this exact case but in cases with mid-rank ties returns more rows (top-10 distinct values, not positions) — wrong general shape.

Minor clarity shave (-0.5): the worked-out RANK 1,2,3,3,5 ladder is good but a one-line "DENSE_RANK<=10 example: same 12-value series gives DENSE_RANK ending at 11, so it would also include the 11th product — i.e. it returns 10 distinct VALUES, not 10 positions" inline would make the DENSE_RANK rejection self-evident rather than just asserted.

**Watch CLOSES:** iter1244+1245 top-N-per-group-WITH-TIES routing FIX-A 3rd re-probe REACHED on the strengthened §2011-=N-scoping + §2098-per-group-example + inline-defang triplet. Move on; do not churn further.

---

### Q2 — Weighted average NPS per product line — **4.875**

**Acc 5 / Clar 4.5 / Prac 5 / Compl 5**

`SUM(score * arr) * 1.0 / NULLIF(SUM(arr), 0)` is the canonical Trino weighted-average. Verified:
- No built-in weighted-avg in Trino 467; AVG is unweighted (correct).
- NULL behavior: `NULL * x = NULL`, and `SUM` ignores NULLs, so a row with NULL arr drops out of BOTH numerator and denominator — natural skip behavior, no extra COALESCE needed (correct).
- `* 1.0` (or `CAST(... AS double)`) prevents integer truncation when both score and arr are INTEGER (Trino integer-division returns integer; multiplying by 1.0 promotes to double) — correct.
- `NULLIF(SUM(arr), 0)` guards against divide-by-zero when all arr values are zero (Trino INTEGER/DECIMAL `/` by 0 throws DIVISION_BY_ZERO per pinned `reference_trino_division_by_zero.md`; NULLIF→NULL gives a clean NULL result instead) — correct.

Minor clarity shave (-0.5): could explicitly state "score * arr returns NULL when arr IS NULL because NULL propagates through arithmetic" rather than the slightly indirect "NULL*x=NULL, SUM drops NULLs".

No watch.

---

### Q3 — Session property for one heavy dbt model — **4.375**

**Acc 4 / Clar 4.5 / Prac 4.5 / Compl 4.5**

Mechanism correct:
- `pre_hook` runs in the SAME connection as the model build → `SET SESSION` propagates to the model SELECT. Correct.
- `on-run-start` runs in a SEPARATE connection that closes before models build → session vars DO NOT propagate. Correct distinction.
- `+pre_hook` folder-scoped in `dbt_project.yml` — valid dbt-trino syntax.
- `session_properties:` in profiles.yml — valid dbt-trino connection-level approach (applies cluster-default for that profile).

**Soft slip on property choice — minor accuracy ding (-1):**
- VERIFIED via raw Trino 467 source ([SystemSessionProperties.java @ 467](https://raw.githubusercontent.com/trinodb/trino/467/core/trino-main/src/main/java/io/trino/SystemSessionProperties.java)): `query_max_memory_per_node` IS registered as a session property (hidden=true), as is `query_max_memory` (hidden=true), `query_max_total_memory` (hidden=true), and `spill_enabled` (hidden=false). All four are settable via `SET SESSION`. The responder's example `SET SESSION query_max_memory_per_node = '4GB'` will NOT throw "session property does not exist" — it is a valid (if hidden) session property.
- **My judge-prompt prior that `query_max_memory_per_node` is config-only was WRONG.** Source code refuted it. Imported-prior family (similar to prior misreads on bitwise/listagg/starts_with/initcap).
- **However**, the property choice direction is questionable for an OOM problem: session memory properties can only LOWER limits below the cluster config ceiling, not raise them. For an OOMing model the responder's *other* recommendation (`spill_enabled=true`) is the correct OOM mitigation lever; lowering `query_max_memory_per_node` makes OOM worse. The responder hedged with "Check SHOW SESSION for exact property names" which softens the slip.
- Net: mechanism rock-solid, property routing slightly misaligned with the OOM direction. Acc 4 not 5.

Minor completeness shave (-0.5): could mention `join_distribution_type='BROADCAST'` for 3-table join OOM if one dim is small (production-stack-aligned lever per pinned iter1238/1188/1203 canonical), and could clarify that per-node memory session prop is bounded above by cluster config (cannot raise the ceiling).

**New soft watch — iter1246 Q3 query_max_memory_per_node OOM-direction-routing**: responder recommended a session property that can only LOWER memory limits as a fix for an OOM problem; spill_enabled is the right lever and was also mentioned, but the lead recommendation was the wrong-direction property. Re-probe under different "single-model OOM dbt session-property" framings 4-8 iters. NO FIX-A (mechanism correct, property names valid; recall ceiling on which session lever matches which symptom direction).

---

### Q4 — Oracle INITCAP → Trino title-case workaround — **4.875**

**Acc 5 / Clar 4.5 / Prac 5 / Compl 5**

VERIFIED via [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html) (WebFetch'd): Trino 467 string-functions page lists ONLY `lower(string)` and `upper(string)` for case conversion — no `initcap`. Responder's absence claim is TRUE (this is a real absence, not an assumed-absence imported-prior error — same family as the genuine no-`array_sum` and no-`ends_with` cases, opposite of the genuine-but-assumed-absent `starts_with`/`to_char`/`listagg`/`migrate`/LATERAL family).

Workaround 1 — `regexp_replace(lower(company_name), '(\w)(\w*)', x -> upper(x[1]) || lower(x[2]))`:
- VERIFIED via [trino.io/docs/467/functions/regexp.html](https://trino.io/docs/467/functions/regexp.html) (WebFetch): regexp_replace 3-arg lambda form is `regexp_replace(string, pattern, function)` — exact docs example is `regexp_replace('new york', '(\w)(\w*)', x -> upper(x[1]) || lower(x[2])) → 'New York'`. Responder's form matches the docs example verbatim.
- VERIFIED via raw [docs/src/main/sphinx/functions/regexp.md @ 467](https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/regexp.md): raw markdown uses SINGLE backslash for `\w`. Per pinned `reference_trino_regex_backslash.md`, single backslash IS correct in actual Trino SQL string literals. Responder's `(\w)(\w*)` is correct.
- Capture-group array `x[1]`, `x[2]` is 1-indexed per Trino docs lambda semantics. Correct.

Workaround 2 — `array_join(transform(split(lower(company_name), ' '), w -> upper(substr(w,1,1)) || substr(w,2)), ' ')`:
- split/transform/array_join all 467-native. substr is 1-indexed. Splits on single space (would miss multi-space / tab-separated, but adequate for typical company names). Correct as written.

Minor clarity shave (-0.5): could mention edge cases (apostrophes "O'Brien", hyphens "Wells-Fargo", accented chars — `\w` is ASCII word chars by default so accented letters may not match), and that workaround 1 is preferred for compactness.

No watch.

---

## Watch ledger updates

**CLOSED:**
- iter1244+1245 top-N-per-group-WITH-TIES routing FIX-A (PRIMARY-ESCALATED): the strengthened iter1245 FIX-A (§2011 =N-EXACT re-scope + SCOPE warning redirect + §2098 PER-GROUP worked example + iter1245-wrong-sentence inline-defang) REACHED on this 3rd decisive re-probe. Two-consecutive-miss pattern broken. No further churn.

**OPEN (carry-forward):**
- iter1245 Q2 expire-without-remove-orphan (soft)
- iter1245 Q4 false-Oracle-GREATEST-premise (soft)
- iter1241 concat-auto-coerces
- iter1240 orphans-$files
- iter1239 DF-wait-timeout
- iter1238 broadcast-hedge-on-small-dim
- iter1236 rn=1-within-batch
- iter1234 ROLLUP-date_trunc-expr
- iter1231 NEXT_DAY-note
- iter1230 EXISTS-overwarning/::cast
- iter1215 strpos-3-arg CEILING
- iter1213 session_properties/(+)
- iter1229 @v1-Spark
- iter1208 width_bucket

**NEW:**
- **iter1246 Q3 query_max_memory_per_node OOM-direction-routing** (soft): responder recommended a session property that can only LOWER memory limits as the lead fix for an OOM problem; spill_enabled IS the right lever and was also mentioned, but lead recommendation was wrong-direction. Mechanism (pre_hook in same connection) is correct. Re-probe under different "single-model OOM dbt session-property" framings 4-8 iters. NO FIX-A (recall ceiling, not resource defect; query_max_memory_per_node IS a valid hidden session property per Trino 467 source).

## Meta-notes

- **My judge-prompt prior on `query_max_memory_per_node` was WRONG** — raw `SystemSessionProperties.java @ 467` shows it IS registered as a session property (hidden=true), settable via SET SESSION. Add to pinned memory: imported-prior family — "session-only vs config-only" distinction also goes both ways; the hidden=true flag only suppresses SHOW SESSION listing, does NOT prevent SET SESSION. Verify against `SystemSessionProperties.java` (not just docs) for session-property existence/scope.
- Responder reached canonical RANK<=N answer including correctly rejecting BOTH wrong forms (ROW_NUMBER<=N and DENSE_RANK<=N) on the 3rd decisive re-probe. The iter1245 in-place strengthening of an existing §2098 card (not a new card) avoided the `new_card_over_attracts_adjacent` risk while closing the routing gap.

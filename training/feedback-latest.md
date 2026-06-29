# Iter 1272 — Judge Feedback

**Overall: 4.625 STRONG PASS** (Q1 4.875 / Q2 4.875 / Q3 3.875 / Q4 4.875)

The pass-loop recovers strongly from iter1271's borderline 3.59. **Q1 = HARD WATCH CLOSED**: the iter1271 r17 §713 + §1012 bloom-CREATE-467 reconcile FIX-A REACHED cleanly on its first re-probe — the responder now states explicitly that parquet_bloom_filter_columns works at CREATE TABLE time on 467 (the opposite-direction-correct answer vs iter1271's regression). Q2 + Q4 are pin-perfect canonical reaches with every load-bearing fact verified. **Q3 has one factual error directly answering the engineer's explicit "paid-tier gated?" sub-question**: the responder's closing "OR FREE TIERS — you need dbt 1.8+" wrongly implies dbt unit tests are gated behind a paid tier. They are NOT — unit tests are a dbt CORE feature (free, open-source) since 1.8. This is a load-bearing accuracy ding because the engineer literally asked the gating question.

---

## Per-question scores

### Q1 — Bloom filter on NEW sessions table at CREATE TABLE on Trino 467 (HARD-WATCH REACH-TEST)

**Score 4.875** (Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75)

**WATCH-CLOSING REACH. iter1271 r17 §713 + §1012 reconcile FIX-A LANDED on 1st re-probe — HARD WATCH CLOSED.**

Responder: "YES you can on 467" + canonical `CREATE TABLE iceberg.analytics.sessions (session_token VARCHAR, user_id BIGINT, created_at TIMESTAMP, expires_at TIMESTAMP) WITH (parquet_bloom_filter_columns = ARRAY['session_token'])` + correct scoping of "469+" strictly to the ALTER SET PROPERTIES form + correct existing-table-on-467 fallbacks (CTAS-rebuild / Spark) + read-side `parquet.use-bloom-filter=true` default-on.

**Verification (WebFetch [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html)):**
- `parquet_bloom_filter_columns` listed verbatim in the 467 Iceberg table-properties section as a CREATE TABLE WITH clause: "Comma-separated list of columns to use for Parquet bloom filter. It improves the performance of queries using Equality and IN predicates when reading Parquet files. Requires Parquet format. Defaults to `[]`."
- ALTER TABLE SET PROPERTIES modifiable list in 467 = `format` / `format_version` / `partitioning` / `sorted_by` / `object_store_layout_enabled` / `data_location` — `parquet_bloom_filter_columns` is NOT in this list on 467 (ALTER form is the 469+ PR #24573 addition). Responder's scoping is exactly right.

**The iter1271 regression direction is fully inverted on this re-probe.** Three iters ago the responder said "Trino 467 CANNOT set bloom filters at CREATE TABLE time, parquet_bloom_filter_columns is 469+" and routed to a Spark fallback. This iter the responder says CREATE-WITH works on 467, gives the exact WITH clause the engineer asked for, and limits "469+" to the ALTER-existing-table form. **r17 §713/§1012 reconcile FIX-A from iter1271 hit its target on the first re-probe** — pattern matches iter1233 custom-generic-test FIX-A close, iter1198 dbt-contract-two-phase-mechanism close.

Minor -0.25 Clarity: the response is dense and could have led with a one-line "yes, single WITH clause, here it is" before the version scoping; minor -0.25 Completeness: didn't mention `parquet.use-bloom-filter-write` writer-side enablement default, but read-side default-on is the load-bearing piece for the engineer's selectivity question.

No imported-prior, no broken-secondary alternative, no over-warning. The HARD watch from iter1271 (`iter1271-Q1 bloom-CREATE-467 r17-reconcile reach-test`) **CLOSES**.

---

### Q2 — Median + p95 per endpoint, last 30 days

**Score 4.875** (Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75)

Pin-perfect Trino approx_percentile per-group canonical. Responder: `SELECT endpoint, approx_percentile(response_time_ms, 0.50) median_ms, approx_percentile(response_time_ms, 0.95) p95_ms FROM request_logs WHERE logged_at >= CURRENT_TIMESTAMP - INTERVAL '30' DAY GROUP BY endpoint` + array overload `approx_percentile(col, ARRAY[0.50, 0.95, 0.99])` + correct flag that `PERCENTILE_CONT ... WITHIN GROUP` is Postgres/Snowflake and a Trino parse error + accurate "T-Digest backed, docs do not publish a fixed-percent error figure."

**Verification (WebFetch [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html)):**
- All four `approx_percentile` overloads exist on 467: `approx_percentile(x, percentage)` / `approx_percentile(x, percentages_array)` / `approx_percentile(x, w, percentage)` weighted / `approx_percentile(x, w, percentages_array)` weighted-array. Both the scalar-fraction AND the array-of-fractions forms verified verbatim.
- PERCENTILE_CONT / WITHIN GROUP: NOT mentioned for any aggregate except `listagg()`. Responder correctly identifies this as a parse error on Trino.
- Error figure: the docs list **2.3% standard error for `approx_distinct` ONLY** — NO published error figure is given for `approx_percentile`. Responder's framing "docs do not publish a fixed-percent error figure" is **exactly accurate**, matches my pinned `reference_trino_approx_percentile_error.md` correction. No "tunable accuracy parameter" claim (which would have been the iter842 imported-prior bug).

Production-stack-correct: 30-day window uses `CURRENT_TIMESTAMP - INTERVAL '30' DAY` (Trino-valid INTERVAL qualifier per `reference_trino_interval_qualifiers.md` — DAY is supported, not QUARTER/WEEK). GROUP BY endpoint maps cleanly to dashboards/per-endpoint SLO monitoring.

Minor -0.25 Clarity (didn't mention partition-predicate behavior of `logged_at` if the table is partitioned on day(logged_at), but that's recall-ceiling) -0.25 Completeness (no comparison vs `numeric_histogram` for sub-percentile precision needs). Recall ceiling, not a defect.

No imported-prior, no broken-secondary alternative, no over-warning, no fabrication.

---

### Q3 — dbt unit tests: real feature? version/paid-tier gated?

**Score 3.875** (Acc 3.0 / Clar 4.5 / Prac 3.75 / Compl 4.25)

**LOAD-BEARING FACTUAL ERROR on the engineer's explicit "paid-tier gated?" sub-question.**

Responder correctly identified unit tests as a real dbt feature (1.8+), explained given/expect/format dict, distinguished from data tests, placed YAML under `models/` correctly, named the `dbt test --select test_type:unit` selector correctly. **BUT** the closing line "**Not available in earlier dbt versions OR FREE TIERS — you need dbt 1.8+**" is factually wrong on the free-tier portion.

**Verification (WebFetch [docs.getdbt.com/docs/build/unit-tests](https://docs.getdbt.com/docs/build/unit-tests)):**
- "💡 Did you know... Available from dbt v1.8 or with the dbt 'Latest' release track." — explicitly **dbt v1.8+**, no mention of paid tier / Cloud-only.
- Unit tests are a dbt CORE feature (open-source, free) since 1.8. They are NOT gated behind dbt Cloud or any paid tier.
- "Unit tests must be defined in a YML file in your `models/` directory." — confirms responder's YAML-under-models placement.
- "Don't define unit test YAML in the `tests/` directory, which is reserved for data tests." — confirms responder's tests/ vs models/ distinction.
- Selector: `dbt test --select "test_type:unit"` — verbatim verified, "works across all engines (dbt Core and Fusion)" — confirms Core support.

The engineer's question was 3-part: (1) real feature? (2) version/paid-tier gated? (3) how do mock inputs work? Responder got (1) right, (3) right, but **answered (2) the gating sub-question WRONG**. An engineer at this on-prem-only stack (no dbt Cloud) reading "not available in free tiers" would either (a) abandon unit tests entirely thinking they need a paid subscription, or (b) waste time evaluating dbt Cloud pricing for a feature already present in their dbt Core installation. Both are wrong outcomes the responder caused.

**Acc 3.0**: 2 of 3 sub-questions correct, 1 directly wrong on a load-bearing dimension the engineer explicitly named. Prac 3.75: the false "free tier" gating could change engineer's product decision. Compl 4.25 / Clar 4.5: mechanism explanation and YAML example otherwise complete.

**No FIX-A WARRANTED.** Grep evidence (sampled iter504/505 history) shows r27 §6.7E dbt-unit-tests canonical introduced iter504 says "dbt 1.8+" and does NOT carry a "free-tier-gated" claim. This is a responder-side hallucination padding the closing line — pattern matches `feedback_responder_broken_secondary_alternative.md` (the responder appending a closing aside that contradicts the main canonical). One-off slip, not source-anchored. SOFT WATCH `iter1272-Q3 dbt-unit-tests-free-tier-hallucination` — re-probe ≤4-8 iters with framing like "do I need dbt Cloud for unit tests?" or "is this in the OSS version?"; if the slip recurs, then escalate to a resource defang in r27 §6.7E DO-NOT-WRITE matrix.

No imported-prior, no fabrication of YAML keys (given/expect/format/test_type:unit all verified).

---

### Q4 — Oracle CONNECT BY → Trino WITH RECURSIVE

**Score 4.875** (Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75)

Pin-perfect Oracle hierarchy → Trino recursive-CTE translation. Responder: "Trino does NOT support CONNECT BY; use WITH RECURSIVE" + anchor (level 0 where parent_account_id IS NULL) + recursive join `JOIN accounts a ON a.parent_account_id = t.account_id` (correct downward direction) + level guard `WHERE t.level < 49`.

**Verification (WebFetch [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html)):**
- WITH RECURSIVE supported in 467: "The `WITH RECURSIVE` clause is a variant of the `WITH` clause. It defines a list of queries to process, including recursive processing of suitable queries."
- **"Experimental" caveat is REAL, not embellishment**: docs verbatim "This feature is experimental only. Proceed to use it only if you understand potential query failures and the impact of the recursion processing on your workload." Responder's "marked experimental, docs warn potential query failures" is verbatim-accurate.
- **max_recursion_depth default = 10 verified**: docs verbatim "recursion depth is fixed, defaults to `10`, and doesn't depend on the actual query results" + "You can adjust the recursion depth with the session property `max_recursion_depth`." Responder's "default=10, must raise for deeper trees" is correct; CONNECT BY tree depths (account hierarchies often 5-15 levels) commonly need raising.
- **"Quadratic plan growth" caveat is REAL, not embellishment**: docs verbatim "When changing the value consider that the size of the query plan growth is quadratic with the recursion depth." Responder's "query-plan growth quadratic — doubling depth ~quadruples plan size/planning time" is verbatim-accurate (doubling N → 4× because plan grows O(N²)).
- Exceeding cap behavior: docs treat as runtime error (responder's "exceeding cap = ERROR not silent truncation" is correct).

**Direction of recursion correct.** Oracle `START WITH parent_id IS NULL CONNECT BY PRIOR account_id = parent_id` walks DOWNWARD from root (root has no parent → enumerate children). Trino translation `WHERE parent_account_id IS NULL` (anchor = roots) + recursive `JOIN accounts a ON a.parent_account_id = t.account_id` (working set t has account_id, new candidate a has matching parent_account_id) preserves the downward direction. PRIOR semantics correctly inverted into the recursive-CTE join shape.

**Practical-applicability bonus**: closure-table precompute recommendation for deep/frequent traversals (e.g., 8-level org charts queried per dashboard load) is operationally sound — recursive CTEs at depth=10 default + quadratic plan growth + Trino-experimental flag combine to make closure-table-via-dbt-incremental the pragmatic on-prem-stack-fit answer.

Minor -0.25 Clarity (the three caveats stack densely at the end) -0.25 Completeness (didn't mention `LIMIT` inside the recursive term as an alternative depth guard, or anti-cycle WHERE clauses for self-loops). Recall ceiling, not a defect.

No imported-prior, no broken-secondary alternative, no over-warning, no fabrication. The "experimental" and "quadratic plan growth" caveats — which the run-prompt flagged as possibly responder embellishment — are **both verbatim from trino.io/docs/467 docs**, not embellishment.

---

## Overall

**Overall = (4.875 + 4.875 + 3.875 + 4.875) / 4 = 18.50 / 4 = 4.625 STRONG PASS** (+1.125 above 3.5 floor)

**182nd consecutive PASS in extended phase. Q1 HARD watch CLOSES on 1st re-probe.** Three of four answers are pin-perfect canonical reaches with every load-bearing fact verbatim-verified against trino.io/docs/467 docs. Q3 has a single hallucinated "free tier" gating phrase that directly answers the engineer's explicit gating sub-question wrong; not source-anchored (r27 §6.7E does not carry this claim), one-off responder slip pattern matches the broken-secondary-alternative family.

---

## Explicit run-prompt answers

**(1) Q1 — did the iter1271 r17 bloom-CREATE-467 reconcile FIX-A REACH? Is the HARD watch CLOSED?**
**YES — REACHED on 1st re-probe, HARD WATCH CLOSED.** Responder gave the engineer exactly the CREATE TABLE WITH (parquet_bloom_filter_columns=ARRAY['session_token']) statement they asked for, scoped "469+" strictly to the ALTER SET PROPERTIES form, and correctly cited r17 §1250-1260-area. Direction is fully inverted vs iter1271's regression. WebFetch of trino.io/docs/467/connector/iceberg.html confirms the canonical CREATE WITH form. The reconcile achieved its objective on first probe.

**(2) Q3 — is the "free tiers" claim a factual error?**
**YES — confirmed factual error.** WebFetch of docs.getdbt.com/docs/build/unit-tests verbatim: "Available from dbt v1.8 or with the dbt 'Latest' release track" — NO paid-tier requirement; selector "works across all engines (dbt Core and Fusion)." Unit tests are in dbt Core 1.8+ (free, open-source). The closing "OR FREE TIERS — you need dbt 1.8+" wrongly implies a paid-tier gate. Load-bearing because the engineer explicitly asked the gating sub-question. Accuracy ding -2.0 → Acc 3.0.

**(3) Q4 — are the "experimental" + "quadratic plan growth" caveats verified or embellishments?**
**BOTH VERIFIED, NOT embellishments.** WebFetch of trino.io/docs/467/sql/select.html gives both verbatim:
- "This feature is experimental only. Proceed to use it only if you understand potential query failures and the impact of the recursion processing on your workload."
- "When changing the value consider that the size of the query plan growth is quadratic with the recursion depth."
Responder paraphrased docs faithfully. max_recursion_depth default=10 also verbatim-verified.

**(4) Any new watches?**
- **SOFT WATCH `iter1272-Q3 dbt-unit-tests-free-tier-hallucination`** — responder's closing line wrongly implied unit tests are paid-tier-gated. NOT resource-anchored (r27 §6.7E canonical doesn't carry this claim). Per `feedback_responder_broken_secondary_alternative.md`, treat as a per-instance one-off responder slip; do NOT bias toward a resource FIX-A on first occurrence. Re-probe within 4-8 iters with framing like "do I need dbt Cloud for unit tests?" / "is this OSS or paid?" If the hallucination recurs, escalate to a r27 §6.7E DO-NOT-WRITE defang ("paid-tier" / "dbt Cloud only" / "not in free tier" — all wrong; unit tests are dbt Core 1.8+ OSS).
- **CARRY iter1271 SOFT WATCH `Q2 current-vs-longest-streak framing`** (re-probe window still 4-8 iters from iter1271; not exercised this iter).
- **CARRY iter1270 SOFT WATCH `PRIMARY-KEY-in-CREATE`** (un-probed).
- HARD watch from iter1271 (Q1 bloom-CREATE-467 reach-test) **CLOSED** this iter.

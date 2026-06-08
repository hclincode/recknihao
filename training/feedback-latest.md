# Judge Feedback — iter693

## Verdict: PASS (overall avg 4.094 >= 3.5) — but Q1 FIX-A REGRESSED (flagged critical)

The overall average crosses the 3.5 pass threshold thanks to three strong answers (Q2/Q3/Q4 all at or near 5.0). However, **Q1 — the FIX-A re-probe — REGRESSED**. The responder cited Pattern A4 by name but produced the EXACT banned `COUNT(DISTINCT col) OVER (...)` form that Pattern A4's DO-NOT-WRITE table row (c) explicitly forbids and that Trino 467 does NOT support (parse/analysis error — trinodb/trino #7885). The query does not execute. This is the same fab class iter692 Q4 surfaced. Iter693's structural fix (adding Pattern A4 as a LEADING CANONICAL) did NOT close the bug — the responder still grabbed the banned form.

---

## Per-question scores

### Q1 — cumulative unique paying accounts BY WEEK (FIX-A re-probe)
- **Accuracy: 1** — The produced query is `COUNT(DISTINCT account_id) OVER (ORDER BY payment_week ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`. Verified against trino.io/docs/467: DISTINCT inside a window function is NOT supported in Trino 467 (tracked at trinodb/trino #7885 — "DISTINCT in window function parameters not yet supported"). The query fails at analysis time before any rows are produced. Additionally, the two CTEs (`first_payments`, `by_week`) are DEAD CODE — they are defined but never referenced by the final SELECT, which queries an inline subquery. The CTE `by_week` itself contains another oddly nested construction; even if it parsed it is irrelevant because the CTE is unused.
- **Completeness: 2** — The shape "running cumulative through end-of-week, monotonic" is acknowledged at a vocabulary level (responder uses the right framing words and cites Pattern A4), but the canonical SQL recipe — `MIN(paid_at) GROUP BY account_id` -> `COUNT(*) GROUP BY first_week` -> `SUM(new_accounts) OVER (ORDER BY first_week ROWS UNBOUNDED PRECEDING)` — is entirely missing from the produced answer.
- **Clarity: 2** — Dead-code CTEs add cognitive load and suggest the responder spliced fragments rather than copying the canonical block intact. A SaaS engineer reading this query cannot tell which part is "the answer."
- **Actionability: 1** — Engineer cannot copy/paste — the query throws an analysis error in Trino 467.
- **Q1 avg: 1.5**

**The corrected Pattern A4 canonical (what the responder SHOULD have produced):**
```sql
WITH first_payment AS (
  SELECT account_id,
         DATE_TRUNC('week', MIN(paid_at)) AS first_week
  FROM iceberg.analytics.payments
  GROUP BY account_id
),
new_per_week AS (
  SELECT first_week, COUNT(*) AS new_accounts
  FROM first_payment
  GROUP BY first_week
)
SELECT
  first_week,
  new_accounts,
  SUM(new_accounts) OVER (
    ORDER BY first_week
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS cumulative_unique_accounts
FROM new_per_week
ORDER BY first_week;
```

### Q2 — second-highest-priced product per category
- **Accuracy: 5** — `DENSE_RANK() OVER (PARTITION BY category ORDER BY price DESC) = 2` is the standard Trino 467-valid form. Verified at trino.io/docs/current/functions/window.html.
- **Completeness: 5** — Mentions RANK vs DENSE_RANK distinction (gaps vs no-gaps) — important when ties exist.
- **Clarity: 5** — CTE-based two-step structure is easy to read.
- **Actionability: 5** — Copy/paste ready.
- **Q2 avg: 5.0**

### Q3 — Iceberg partition evolution (day -> month, no rewrite)
- **Accuracy: 5** — `ALTER TABLE iceberg.analytics.events SET PROPERTIES partitioning = ARRAY['month(occurred_at)']` is the documented Trino 467 syntax. Verified at trino.io Iceberg connector docs: partitioning evolution is metadata-only, applies to NEW writes, old data retains the prior spec, and the engine reads across both transparently. The Spark `rewrite_data_files` (Spark-only) call-out for optional historical rewrite is correctly labeled and accurate.
- **Completeness: 5** — Covers metadata-only nature, new-writes-only scope, transparent reads across both specs, and the optional historical-rewrite path (correctly attributed to Spark, not Trino). Also mentions `expire_snapshots` after rewrite.
- **Clarity: 4.5** — Clear and direct.
- **Actionability: 5** — Single ALTER statement engineer can run immediately.
- **Q3 avg: 4.875**

### Q4 — dollar-weighted average rating per product
- **Accuracy: 5** — `SUM(rating * amount) / SUM(amount)` is the textbook weighted-average identity (sum(w_i*x_i) / sum(w_i)). Valid Trino 467 syntax.
- **Completeness: 5** — Worked example ($500 vs $10 -> 50x influence) and a sensible integer-division caveat ("if both columns are INTEGER...").
- **Clarity: 5** — Plain-language identity explanation.
- **Actionability: 5** — Copy/paste ready.
- **Q4 avg: 5.0**

---

## Overall

(1.5 + 5.0 + 4.875 + 5.0) / 4 = **4.094 -> PASS** by overall-avg rule.

Three strong answers carry the average above threshold; Q1 alone is well below threshold and is a critical regression of the FIX-A.

---

## EXPLICIT VERDICT — iter692 cumulative-distinct FIX-A: REGRESSED

The iter693 Pattern A4 insertion at r07:2054-2136 did **NOT** close the cumulative-distinct-over-time gap. The responder cited Pattern A4 by name in its answer but produced the EXACT banned form — `COUNT(DISTINCT account_id) OVER (ORDER BY payment_week ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` — that Pattern A4's DO-NOT-WRITE table row (c) explicitly forbids. This is the worst possible failure mode: the responder *found* the right card and STILL produced the banned form instead of the canonical.

Verified against [trino.io window functions docs](https://trino.io/docs/current/functions/window.html) and [trinodb/trino #7885](https://github.com/trinodb/trino/issues/7885): `COUNT(DISTINCT col) OVER (...)` is unsupported in Trino 467 and fails with "DISTINCT in window function parameters not yet supported" at analysis time.

---

## Why did the FIX-A regress? Root-cause analysis of Pattern A4 card structure

I read the actual card text at r07:2054-2136. The card structure is:
- **r07:2058** — keyword anchors callout (22 keyword phrasings)
- **r07:2060** — THE ONE FACT prose (correct framing)
- **r07:2062-2093** — **canonical SQL block — DOES lead structurally** (good)
- **r07:2095-2105** — expected output table
- **r07:2107-2113** — per-piece walk-through
- **r07:2115** — generalization note
- **r07:2117-2122** — DO-NOT-WRITE table with three banned forms (the COUNT(DISTINCT) OVER ban is row (c))
- **r07:2124** — single-rule summary
- **r07:2126-2134** — Decision-differentiate table
- **r07:2136** — Cross-references

**The canonical SQL DOES lead — it is the first SQL block in the card.** The DO-NOT-WRITE table comes AFTER. So the structural ordering is correct.

So why did the responder produce the banned form anyway? Three plausible failure modes — the teacher should design iter694 to defend against each:

1. **The DO-NOT-WRITE table at r07:2117-2122 shows the banned SQL VERBATIM in a copyable code-style cell** (e.g., backtick-wrapped `COUNT(DISTINCT customer_id) OVER (ORDER BY order_month ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`). A Haiku-class responder scanning the card may grab this snippet — visually it looks like SQL that matches the question's keywords (cumulative, OVER, ORDER BY, etc.) — without parsing the surrounding "WRONG" label or the table's row structure. The banned form may be more "grep-attractive" than the canonical because it is a single-line snippet, while the canonical is a multi-CTE block.

2. **The responder may have synthesized from MULTIPLE cards rather than copying the canonical intact** — note the dead-code `first_payments` CTE in the answer uses the right primitive name pattern ("first_..."), suggesting the responder *partially* recognized the first-appearance idiom but then independently invented the final SELECT using a free-association `COUNT(DISTINCT) OVER` shape that "felt right" for the keywords. The canonical was not copied as a coherent block.

3. **The keyword anchors at r07:2058 contain the exact question phrasing "cumulative unique paying accounts"** — so the responder definitely matched to Pattern A4. The match worked; the copy did not.

## Iter694 recommendation — REPEAT FIX-A (strengthen Pattern A4 against banned-form copying)

The teacher should iterate Pattern A4 with these targeted hardenings:

1. **Disarm the banned SQL in the DO-NOT-WRITE table** — render the banned `COUNT(DISTINCT col) OVER (...)` snippet at r07:2117-2122 in a way that is NOT copy-paste attractive. Options: (a) wrap each banned snippet with explicit inline `-- WRONG — Trino 467 parse error — DO NOT COPY` SQL comments on the SAME line as the snippet, so any copy includes the comment; (b) break the banned syntax across lines with `[BANNED-BY-TRINO]` placeholder tokens that visibly break the snippet (e.g., `COUNT(DISTINCT [BANNED:see-row-c-above] customer_id) OVER (...)`); (c) move the banned snippet OUT of a code-style cell into prose-only italics with `-- BANNED` annotation. The goal is: even if the responder grabs from the DO-NOT-WRITE row, the produced SQL is visibly broken in a way the engineer will notice immediately.

2. **Add a "COPY THIS BLOCK" marker around the canonical SQL at r07:2065-2092** — explicit prose header like `### COPY THIS BLOCK — the only correct cumulative-distinct-over-time SQL` immediately before the canonical, and a closing `### END COPY BLOCK` after. This biases keyword-driven extraction toward the right region.

3. **Add a "if your question matches any of these keywords, the answer is the SQL in the COPY THIS BLOCK above — do not write `COUNT(DISTINCT col) OVER (...)`, it fails at parse time" tie-back paragraph** immediately after the canonical (at ~r07:2094), BEFORE the expected-output table. Right now the canonical is followed by the expected-output table; insert a one-liner tie-back between them.

4. **Verify the card does NOT accidentally present `COUNT(DISTINCT) OVER` in any copyable position** — grep r07 for `COUNT(DISTINCT .* OVER` and ensure every occurrence is wrapped with WRONG/banned markers IN THE SAME LINE.

5. **Re-probe in iter695** with the SAME Q1 phrasing ("cumulative unique paying accounts BY WEEK — payments(account_id, paid_at)") to confirm the FIX-A finally closes.

---

## Held fixes — all confirmed working

- **Q2 second-highest-per-group (DENSE_RANK + WHERE rank=2)** — solid, no change needed.
- **Q3 Iceberg partition evolution (ALTER TABLE SET PROPERTIES + Spark rewrite caveat)** — solid, no change needed.
- **Q4 weighted average (SUM(x*w)/SUM(w))** — solid, no change needed.

## Production-environment fit check

- Q3 correctly defers historical rewrite to Spark (the prod-described ingestion stack) rather than recommending Trino-side rewrite. Aligns with prod_info.md (Spark = ingestion, Trino = query).
- All four answers stay within the Trino 467 + Iceberg 1.5.2 + Hive Metastore + MinIO stack. No off-stack tool recommendations.

## Summary directive for iter694

**Iter694 = REPEAT FIX-A on Pattern A4.** The structural insertion at r07:2054-2136 was correct (canonical leads, DO-NOT-WRITE follows). The problem is that the DO-NOT-WRITE table presents the banned `COUNT(DISTINCT) OVER (...)` snippet in a copy-attractive single-line code-cell form. Defang the banned snippet (inline `-- WRONG, parse error in Trino 467` comments or `[BANNED]` placeholder tokens that visibly break the syntax), add a "COPY THIS BLOCK" marker around the canonical, and add a one-line tie-back between the canonical and the expected-output table. Re-probe Q1 in iter695 with the same phrasing.

## Sources verified

- [Trino window functions docs](https://trino.io/docs/current/functions/window.html) — DENSE_RANK semantics, ROWS frame
- [trinodb/trino issue #7885](https://github.com/trinodb/trino/issues/7885) — DISTINCT in window function parameters not supported
- [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html) — ALTER TABLE SET PROPERTIES partitioning evolution
- [Starburst Iceberg partitioning blog](https://www.starburst.io/blog/iceberg-partitioning-and-performance-optimizations-in-trino-partitioning/) — partition evolution metadata-only behavior

# Iter 10 Q2 — Gap-fill time-series + rolling 4-week average

**Question:** "I'm building a weekly active users chart that needs to show every week for the past year, even weeks where a customer had zero activity. When I run my query I only get rows back for weeks that had events — the zero weeks just disappear from the results. How do I make sure every week shows up in the output, and while I'm at it, can I also show a rolling 4-week average next to the raw weekly number? I'm running these on Trino."

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All claims verified against Trino docs and the production resource. `UNNEST(sequence(0, 51))` correctly generates 52 rows (integers 0–51 inclusive). `date_add('week', n, start_date)` is valid Trino syntax. LEFT JOIN + COALESCE is the correct gap-fill idiom matching the resource's section 4 pattern. `AVG() OVER (ORDER BY week_start ROWS BETWEEN 3 PRECEDING AND CURRENT ROW)` is correct Trino window frame syntax. Partial-window behavior (average starts as 1-week in week 1, grows to 4-week by week 4) is accurately described. `date_trunc('week', ...)` confirmed to support 'week' unit in Trino. Stack note (Trino 467) accurate. No errors. |
| Beginner clarity | 4 | The answer identifies the problem correctly and names the solution approach (calendar CTE, LEFT JOIN, COALESCE, window function). The partial-window explanation is a useful nuance that prevents a beginner surprise. One point docked: "ROWS BETWEEN 3 PRECEDING AND CURRENT ROW," "window function," "CTE," and "COALESCE" appear without the plain-English inline glosses a zero-OLAP-background engineer needs. The resource provides a CTE gloss ("named, inline temporary result sets...") but the answer summary does not surface it. |
| Practical applicability | 5 | Directly solves the engineer's stated problem with a complete combined SQL query. Stack-specific (confirms all functions are standard Trino 467 features). Actionable option given for handling partial-window behavior. Engineer has everything needed to run immediately. |
| Completeness | 5 | Both sub-questions addressed: gap-filling (calendar CTE + LEFT JOIN + COALESCE) and rolling 4-week average (window function). Combined SQL covers both together. Partial-window edge case surfaced proactively (a real production nuance the engineer would hit in week 1). No material gaps. |
| **Average** | **4.75** | |

---

## Topic updated

**Common analytical query patterns: aggregations, funnels, cohort, time-series**

- Prior: avg 3.875 across 2 questions (scores 4.50 + 3.25 = 7.75)
- This question: 4.75
- New running avg: (7.75 + 4.75) / 3 = **4.167** across 3 questions
- Status: PASSED (was already passing at 3.875; now solidly at 4.167)

---

## Key finding

The answer correctly extends the resource's daily gap-fill pattern (section 4 of `resources/07-analytical-query-patterns.md`) to the weekly 52-week case and adds a rolling window average — both technically sound and directly actionable for the production Trino 467 stack. The only gap is that beginner-facing glosses for "window function," "CTE," "COALESCE," and the `ROWS BETWEEN` frame syntax are absent from the answer, which a zero-OLAP-background engineer will need.

## Resource gap

None critical. The resource covers the daily gap-fill pattern but not the weekly variant with rolling averages. Adding a "weekly WAU with rolling average" subsection to `resources/07-analytical-query-patterns.md` would preemptively surface this exact pattern (a very common SaaS dashboard request) and give the responder a template to pull from directly, including inline glosses for the window function frame syntax.

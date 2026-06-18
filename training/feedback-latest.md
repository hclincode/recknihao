# Judge Feedback — iter1093 (2026-06-18)

Verified BOTH directions vs RAW git-tag 467 source: functions/aggregate.md, functions/datetime.md, functions/array.md, functions/window.md. Production stack (Trino 467 + Iceberg + Hive Metastore on-prem) — all four answers are pure analytic SQL, fully stack-compatible. Clean sweep; ZERO source-verified defects.

## Q1 — spread of response_time_ms (variance/stddev)
`stddev(response_time_ms)` (= stddev_samp); notes variance + stddev_pop variants; bare stddev = sample default.
- **Accuracy 5** — aggregate.md VERIFIED: stddev "This is an alias for stddev_samp" (sample, N-1 denominator); stddev_pop = population; variance = alias of var_samp. All named functions real and accurately described. Correctly maps "how spread out" → standard deviation.
- **Completeness 5** — gives the default, names the population variant and the variance siblings, explains sample-vs-population.
- **Clarity 5** — "clustered near average vs all over the place" mapped to stddev with plain framing; zero assumed knowledge.
- **Actionability 5** — drop-in single aggregate; engineer knows exactly what to run.
- Q1 avg = **5.00**

## Q2 — INTEGER epoch-seconds → readable timestamp
`from_unixtime(created_at)` → timestamp with time zone; 1704067200 → 2024-01-01 00:00:00; expects SECONDS (divide by 1e3 if ms); CAST(... AS DATE) for day only.
- **Accuracy 5** — datetime.md VERIFIED: `from_unixtime(unixtime) -> timestamp(3) with time zone`, "unixtime is the number of seconds since 1970-01-01 00:00:00 UTC". 1704067200 s = 2024-01-01 00:00:00 UTC EXACT. Return-type-with-time-zone claim correct. SECONDS-not-millis caveat correct (divide-by-1000 for ms). CAST(timestamp AS DATE) valid (date() is the alias for CAST AS date).
- **Completeness 5** — covers the conversion, the worked example, the ms-vs-s gotcha, and the date-only variant.
- **Clarity 5** — concrete example value shown; "plain INTEGER seconds" addressed directly.
- **Actionability 5** — exact function + the one trap (units) that bites in practice.
- Q2 avg = **5.00**

## Q3 — all of an array's tags in an approved list, no explosion
`all_match(tags, x -> contains(approved_tags, x))`; example WHERE all_match(tags, x -> contains(ARRAY['beta','enterprise','high-usage','verified'], x)); TRUE iff every tag approved, no UNNEST.
- **Accuracy 5** — array.md VERIFIED: all_match "Returns true if all the elements match the predicate (special case when the array is empty)"; contains "Returns true if the array x contains the element". Lambda `x -> contains(approved, x)` is the canonical "every element in approved set" test. Purpose-built no-explosion tool — exactly what was asked.
- **Completeness 4.5** — fully answers the core. Minor unstated edge (NOT penalized per directive): empty tags array → all_match returns TRUE (vacuously approved), and a NULL tag element makes the predicate NULL → all_match returns NULL under 3VL (row dropped by WHERE). Harmless for typical data, would be a nice footnote.
- **Clarity 5** — lambda explained in words ("returns TRUE only if every tag is in the approved list"); WITHOUT-explosion requirement called out.
- **Actionability 5** — copy-paste WHERE clause with a concrete approved array.
- Q3 avg = **4.875**

## Q4 — session with a user's SECOND-highest page_views
`dense_rank() OVER (PARTITION BY user_id ORDER BY page_views DESC) AS rank` in a subquery, WHERE rank = 2; notes row_number() if exactly-one-row-per-rank wanted; dense_rank handles ties.
- **Accuracy 5** — window.md VERIFIED: dense_rank "similar to rank, except that tie values do not produce gaps". PARTITION BY user_id + ORDER BY page_views DESC then filter = 2 returns the second-highest DISTINCT page_views per user. Window functions CANNOT be filtered in WHERE → subquery/CTE wrap is REQUIRED and correct. dense_rank-vs-row_number distinction explained accurately (row_number = exactly one row, breaks ties arbitrarily; dense_rank = all tied rows share rank). NOT a broken-secondary — the alternative is correct and the trade-off is real.
- **Completeness 5** — wrap requirement, partition semantics, and the tie-handling choice all covered.
- **Clarity 5** — "without manually sorting and skipping rows" answered with the rank-then-filter idiom; tie behavior explained plainly.
- **Actionability 5** — full subquery pattern given; engineer can adapt directly.
- Q4 avg = **5.00**

## Overall
(5.00 + 5.00 + 4.875 + 5.00) / 4 = **4.969**

**PASS** (margin +1.47 over 3.5 threshold).

**Source-verified defects: ZERO.**

No instances of any tracked failure family: no ::-cast, no QUALIFY, no false semi-join, no fabricated function, no regex-backslash trap, no INTERVAL quarter/week, no OFFSET-before-LIMIT, no over-warning folklore, no broken-secondary alternative, no Spark/Oracle dialect spillover. Q4's row_number aside is a correct, well-scoped trade-off — the opposite of the broken-secondary pattern.

RECOMMENDATION = DEFAULT NO-OP. NO resource edit; NO commit; NO federation probe. MUST NOT bump state.json (already 1093).

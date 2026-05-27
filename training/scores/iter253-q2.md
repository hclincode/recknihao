# Score: iter253 Q2
Score: 4.90
Pass/Fail: PASS (>=4.5)

## What was correct
- Verbatim Postgres error string `ERROR: canceling statement due to statement timeout` correctly identified as a Postgres-side cancellation (verified against PostgreSQL docs and JDBC behavior write-ups).
- Verbatim Trino error `Query exceeded maximum time limit of Xm` correctly attributed to Trino's own timeout layer.
- Verbatim JDBC error `java.net.SocketTimeoutException: Read timed out` correctly attributed to the socket timeout layer, with the important nuance that Postgres may still be running the query after this fires.
- Correct innermost-to-outermost ordering: Postgres statement_timeout → JDBC socketTimeout → Trino query.max-execution-time → Trino query.max-run-time.
- Direct, correct answer to the engineer's main question: Trino's timeout should be LONGER than Postgres's, so Postgres fires first cleanly.
- Correct rationale for ordering: statement_timeout preserves the JDBC connection (only the statement is cancelled), while socketTimeout discards the connection entirely — verified against PostgreSQL JDBC documentation (pgjdbc, scout24, miensol.pl).
- Accurate distinction between query.max-execution-time (active compute only, no queue wait, no planning) and query.max-run-time (total wall-clock from submission) — verified verbatim against Trino 481 query-management properties docs.
- Concrete example contrasting a 9-min queue + 1-min execute scenario to show why max-execution-time would NOT fire but max-run-time WOULD.
- Correct `ALTER ROLE trino_reader SET statement_timeout = '5min';` syntax.
- Correct `pg_stat_activity` query for verifying what SQL Postgres is actually running.
- Helpful "what happens if you reverse the order" failure-mode walkthrough (orphaned queries on replica).
- Useful real-world detection step (Trino Web UI Query Details page).
- Reasonable defense-in-depth recommendation (idle_in_transaction_session_timeout).
- Predicate-pushdown diagnostic is a thoughtful addition for "what to do if Postgres keeps killing legitimate queries."

## What was missing or wrong
- The answer never names where the JDBC socketTimeout is actually configured in the production stack (the Trino PostgreSQL catalog properties file, e.g., `connection-url=jdbc:postgresql://...?socketTimeout=60`). A SaaS engineer following this advice will know what value to set but not where to put it.
- Minor: would benefit from a one-line note that the production stack here is Trino 467 (not 481), so confirming the property names against Trino 467 docs would tighten the answer. The two properties named here do exist in 467, so no correctness issue, just a polish gap.
- Minor: no mention of `query.max-planning-time` as the third "max time" property — historically flagged in iter168 Q2 feedback (rubric line 5283). Not strictly required for this question but would complete the picture.

## Overall assessment
This is a strong, near-complete answer that hits all 10 rubric key facts correctly, with verbatim error strings, correct ordering, correct rationale grounded in JDBC connection-pool behavior, and a clear direct answer to the engineer's "shorter, longer, or same?" question. The only real gap is operational: the JDBC socketTimeout is recommended but not located (catalog properties file), which slightly weakens practical applicability for the on-prem Trino 467 + k8s stack. This is one of the strongest federation-timeout answers in the iteration history and should lift the topic running average.

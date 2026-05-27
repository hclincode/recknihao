# Iter 202 Q1 Judge — OPA Column Masking

## Score
| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.50** |

## Verdict
PASS (threshold: 4.5 for Trino federation topic — meets bar exactly)

## Key findings

- **Core technical claim is correct.** Column masking in Trino is applied during the `StatementAnalyzer` phase as a projection rewrite — OPA returns a SQL expression that Trino substitutes inline for the column reference. Confirmed by Trino 481 OPA docs and PR #21997 (`getColumnMasks` SPI). The mask is a scalar SQL expression written in terms of the table's columns and the planner injects it into the plan.

- **"Trino pulls raw data before masking" is correct in practice but slightly imprecise.** The mask is a Trino-side projection; the PostgreSQL connector does NOT receive a pre-masked column expression to push down. The raw bytes for the masked column must be transferred from Postgres to Trino workers because the SHA-256 / substring / concat expression is a Trino function the JDBC connector cannot translate into a Postgres-side pushdown (Trino JDBC pushdown framework only translates a small whitelist of operations, and hash functions are not in it). So "Postgres still sends raw rows, workers compute the mask" is the right mental model for an analyst. One nuance the answer misses: if the masked column is *not in the SELECT projection* (e.g., `SELECT count(*) FROM users WHERE region='X'`), Trino can still prune the column from the column list it asks Postgres for — masking only forces transfer when the column is referenced.

- **Config block is accurate.** `opa.policy.column-masking-uri` and `opa.policy.batch-column-masking-uri` are the correct property names. The note that `batch-column-masking-uri` is preferred for wide tables is correct (issue #21359 documents the per-column-request problem the batch endpoint solved).

- **OPA return-shape claim is partially wrong.** The answer says OPA returns `{"expression": "..."}`. That is correct for the **non-batch** endpoint (`opa.policy.column-masking-uri`). But the answer configures BOTH endpoints in the same example and shows the same response shape for both — the **batch** endpoint actually returns a list of objects with `index` and `viewExpression: {expression: "..."}` (nested), not flat `{expression}`. This is a real factual gap: a SaaS engineer who copies the example config (batch enabled) and writes a Rego rule returning the non-batch shape will get a policy-eval error. Worth one point off technical accuracy.

- **Deterministic-hash recommendation is correct and important.** `to_hex(sha256(to_utf8(email)))` is a valid Trino expression (sha256 takes varbinary, to_utf8 converts varchar -> varbinary, to_hex returns varchar) and it does preserve equality, so `GROUP BY masked_email` and self-joins on `masked_email` produce the same groups/keys as the raw column. The GROUP-BY/JOIN-collapse gotcha for constant masks is also correct and is exactly the kind of footgun the SaaS engineer asked about implicitly.

- **Security-implication framing is excellent for a GDPR-concerned engineer.** Naming the threat model explicitly ("raw PII momentarily in trusted worker memory; if your threat model requires raw PII never enters Trino, masking is insufficient → use encryption or separate tables") is exactly right and is the answer most teams need before they sign off on masking as a GDPR control.

- **Pushdown statement is right.** "Normal predicate pushdown still applies to non-masked columns and row filters" — correct. Row filters and predicates on non-masked columns can still push down; only the masked-column transformation itself stays in Trino.

- **Beginner clarity is good but not perfect.** "StatementAnalyzer", "predicate pushdown", "query plan", "Rego" all appear without inline plain-English glosses. A GDPR-focused engineer with no Trino internals will understand the *shape* of the answer but may stumble on "StatementAnalyzer phase". Glossing as "Trino's query planner, which runs on the coordinator before any worker touches data" would help.

- **Completeness is strong.** All six sub-questions asked in the prompt (how masking works, what Postgres sends, what analysts see, security implications, config, gotcha) are addressed in distinct sections. The "bottom line" recap at the end is clean.

## Resource fix suggestions

- In `resources/05-multi-tenant-analytics.md` (or wherever the OPA masking section lives), **clearly distinguish the two response shapes**: non-batch returns `{"expression": "..."}`; batch returns `[{"index": i, "viewExpression": {"expression": "..."}}]`. The current answer conflated them, which suggests the resource may also conflate them or be ambiguous.
- Add a one-line gloss: "Column masking is a Trino-coordinator-side query rewrite; the masked column's raw bytes flow from Postgres to Trino workers and are transformed before being returned to the client."
- Add an explicit note that masked-column expressions (`sha256`, `to_hex`, string concat) are NOT pushed down to Postgres by the JDBC connector — confirming the answer's claim with a citation pointer to the Trino JDBC pushdown framework doc.
- Add a sub-bullet: "If the masked column is not in the SELECT projection, Trino prunes it from the JDBC column list and Postgres never sends it. Masking only forces transfer when the column is actually referenced."
- Consider a glossary callout for `StatementAnalyzer` / Rego / "predicate pushdown" — the beginner-clarity dimension keeps losing points on un-glossed Trino internals jargon.

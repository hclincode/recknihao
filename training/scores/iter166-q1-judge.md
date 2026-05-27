# Iter 166 Q1 — Judge Score Report

**Question topic**: Trino federation — PostgreSQL connector write support (INSERT/UPDATE/DELETE), anti-pattern vs staged write-back pattern
**Date**: 2026-05-26 (EXTENDED PHASE)
**Model under test**: weak-ai-responder (Haiku)

---

## Verification against Trino 467 docs (trino.io/docs/current/connector/postgresql.html)

| Claim in answer | Verified? | Notes |
|---|---|---|
| PostgreSQL connector supports INSERT | YES | Confirmed. INSERT supported, optional non-transactional mode. |
| PostgreSQL connector supports UPDATE | YES (with caveats) | Confirmed — but only with constant assignments and predicates. Arithmetic, function calls, non-constant updates not supported. Answer did not mention this limitation. |
| PostgreSQL connector supports DELETE | YES (with caveats) | Confirmed — but only when WHERE clause predicate can be fully pushed down. Answer did not mention this limitation. |
| Example syntax `INSERT INTO app_pg.public.audit_log VALUES (...)` | YES | Valid Trino SQL. |
| Staged write-back pattern (Trino → Iceberg staging → app reads → app writes via normal path) | YES | This is the canonical recommendation for analytics-to-operational data flow, aligning with OLTP/OLAP isolation principles. |
| Spark JDBC write from staging as alternate path | YES | Valid alternative. |

**Missing from answer:**
- MERGE support (gated behind `merge.non-transactional-merge.enabled`)
- TRUNCATE support
- CREATE/DROP table support
- UPDATE limitation: constant assignments only — engineer could try `UPDATE ... SET x = x + 1` and get an error
- DELETE limitation: predicate must push down — engineer could try a DELETE with a non-pushdown predicate and fail
- Non-transactional default — important caveat for OLTP safety
- No mention of OPA authorization gating writes (production stack uses OPA on Trino)

---

## Dimension scores

### Technical accuracy: 4 / 5
- Core write-support claim correct (INSERT/UPDATE/DELETE all supported).
- Anti-pattern guidance is sound and matches OLTP/OLAP separation orthodoxy.
- Staged pattern is the right recommendation.
- Missing the documented UPDATE/DELETE limitations (constant assignments, predicate pushdown) — these are real footguns the engineer would hit. Also missed MERGE/TRUNCATE/CREATE/DROP. Loses 1 point for incomplete coverage of the connector's actual capabilities and limitations.

### Beginner clarity: 5 / 5
- Clear lead with "Technically yes, but you should not do it."
- Explains OLTP vs OLAP isolation in plain terms (the "2 AM incident" framing is concrete).
- Hybrid example walks through a realistic scenario step by step.
- No jargon left undefined.

### Practical applicability: 4 / 5
- The staged write pattern is actionable.
- Three concrete write-back paths offered (REST API, batch job, Spark JDBC).
- The user-churn example is directly transferable to their stack.
- Missed mentioning OPA could/should block writes through Trino at the policy layer (production stack uses OPA — this would be a strong enforcement mechanism in their environment).
- Did not mention that on the production on-prem stack the Spark JDBC option is well-suited because Spark runs in the same k8s cluster.

### Completeness: 4 / 5
- Answers both halves: "is it possible" (yes, with anti-pattern warning) and "what's the right way" (staged pattern).
- Covers the why (validation, audit, isolation).
- Provides a concrete worked example.
- Misses the UPDATE/DELETE limitations and the OPA enforcement angle.

---

## Weighted score

(4 × 2 + 5 + 4 + 4) / 5 = (8 + 5 + 4 + 4) / 5 = 21 / 5 = **4.20 / 5 — PASS**

---

## Key strengths
- Strong anti-pattern framing — does not just enable the engineer's bad idea.
- Practical staged pattern with three concrete implementation options.
- Realistic example that mirrors the kind of analytics-driven app workflow a SaaS engineer would actually build.

## Key gaps
- Missing UPDATE/DELETE limitations (constant assignments, predicate pushdown). Engineer could attempt these and hit confusing errors.
- No mention of OPA as a policy-enforced safeguard in the production stack — a key opportunity given the stack uses OPA.
- Did not enumerate the full write surface (MERGE, TRUNCATE, CREATE/DROP) which would help the engineer understand the scope of the connector.

## Recommended teacher action
- Add a "PostgreSQL connector write operation matrix" to `resources/22-trino-federation-postgresql.md` that lists every supported write operation with its documented limitation (especially UPDATE constant-assignment rule and DELETE pushdown rule).
- Add a brief note that OPA policy can be used to deny write actions on PostgreSQL catalogs as a defense-in-depth mechanism against accidental writes through Trino.

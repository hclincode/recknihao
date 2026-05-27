# Iter 169 Q1 — Judge Score Report

**Topic**: Trino federation / cross-source connectors (Postgres credential rotation)
**Date**: 2026-05-26 (EXTENDED PHASE)
**Production stack**: On-prem k8s, Trino 467, Iceberg 1.5.2, MinIO, HMS, JWT, OPA

## Question summary
The engineer asks whether rotating a plaintext Postgres password in a Trino catalog file requires a full cluster restart, or if there is a way to reload one catalog without disrupting in-flight customer queries.

## Answer summary
The responder asserts:
1. Trino reads catalog properties on startup only; **no hot-reload** mechanism exists for catalog credentials.
2. Use `${ENV:APP_PG_PASSWORD}` in the catalog file and back it with a Kubernetes Secret.
3. A `kubectl rollout restart` is a "rolling restart" — but **any queries on a replaced pod will fail**.
4. Use a **two-password overlap** with Postgres: "grant the new password, roll Trino, then revoke the old one."
5. "There's no documented hot-reload or dynamic credential provider mechanism in OSS Trino 467 for JDBC catalog credentials."

## Verification (WebSearch against trino.io and Postgres docs)

### 1. "No hot-reload" claim — INCORRECT for OSS Trino 467
Trino's **Dynamic Catalog Management** is an OSS feature, documented at least since v435 and present in 467. Setting `catalog.management=dynamic` enables `CREATE CATALOG` and `DROP CATALOG` SQL commands at runtime, with no server restart required. Per docs: "Dropping a catalog does not interrupt any running queries that use it, but makes it unavailable to any new queries." This is the *exact* primitive the engineer needs.

Caveat: `ALTER CATALOG` is not yet supported (tracked in trinodb/trino#25542) — so the procedure is **DROP CATALOG app_pg → CREATE CATALOG app_pg WITH (...)** with new credentials. In-flight queries on the old catalog instance finish; new queries pick up the new connection. Also, dynamic catalog mgmt has known caveats in k8s multi-node setups (issue #25651) — but the responder doesn't even mention the feature exists.

This is the **single most important miss** in the answer. The engineer's question is literally "is there some way to reload just that catalog config without taking the whole cluster down?" and the answer is "yes, there is, it's called dynamic catalog management." The responder instead says "no, there isn't."

### 2. `${ENV:VAR}` syntax — CORRECT
Confirmed at https://trino.io/docs/current/security/secrets.html — Trino's Secrets feature substitutes `${ENV:VARIABLE}` references at properties-file load time. Applies to catalog properties. The k8s Secret + env mapping is a correct, idiomatic production pattern.

### 3. Rolling restart with graceful shutdown — PARTIALLY WRONG
`kubectl rollout restart` does replace pods one at a time. But the responder says "any queries running on a pod being replaced will fail." This is misleading: Trino supports **graceful worker shutdown** (PUT to `/v1/info/state` → `SHUTTING_DOWN`, then `shutdown.grace-period` defaulting to 2 minutes, then drain). In a properly configured k8s deployment (preStop hook + `terminationGracePeriodSeconds` ≥ 2× grace period), running tasks on workers finish before the pod dies. The coordinator restart is the painful one — that DOES kill all queries. The answer flattens this distinction and gets the worker behavior wrong.

### 4. Two-password overlap for PostgreSQL — TECHNICALLY MISLEADING
Native PostgreSQL **does not support multiple passwords per role** in mainline (the multiple-password feature is a PoC/RFC, not shipped). `ALTER ROLE ... PASSWORD 'new'` replaces the password atomically; you cannot "grant the new password" while keeping the old one valid. The standard zero-downtime pattern is the **dual-role** approach (create `app_user_v2` with new credentials, point Trino at the new role, drop the old role). The responder's wording — "grant the new password, roll Trino, then revoke the old one" — implies Postgres natively supports password overlap, which it does not. This will mislead an engineer trying to execute it.

### 5. "No dynamic credential provider in OSS Trino 467" — INCORRECT (see #1)
The dynamic catalog management feature in OSS Trino addresses exactly this use case for credentials. The answer's blanket dismissal is wrong.

## Scoring

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 2 | The headline claim — "no hot-reload mechanism" — is wrong: Trino's dynamic catalog management (`catalog.management=dynamic` + CREATE/DROP CATALOG) is an OSS feature in 467. The Postgres "two-password overlap" framing implies native Postgres support that doesn't exist. Graceful shutdown behavior is glossed/wrong. `${ENV:VAR}` and rolling restart mechanics are correct. |
| Beginner clarity | 4 | Well-structured, plain language, good code examples for the Secret + env mapping. Defines what rolling restart means. Could be clearer on coordinator vs worker. |
| Practical applicability | 2 | The engineer leaves with the wrong mental model: thinks the only option is to restart pods, when the dynamic catalog feature gives a true zero-restart path. The Postgres rotation steps as written won't actually work on a stock Postgres (overlapping passwords on one role is impossible). |
| Completeness | 2 | Misses dynamic catalog management entirely. Misses graceful shutdown configuration (`shutdown.grace-period`, `terminationGracePeriodSeconds`, preStop hook, OPA's role in allowing the shutdown action). Misses the dual-role Postgres pattern as the actual zero-downtime recipe. Misses coordinator-vs-worker restart asymmetry. |

**Weighted score** = (2×2 + 4 + 2 + 2) / 5 = (4 + 4 + 2 + 2) / 5 = **12 / 5 = 2.40 / 5 — FAIL**

## Topic average update
Trino federation prior: 4.147 across 15 questions
New: (4.147 × 15 + 2.40) / 16 = (62.205 + 2.40) / 16 = 64.605 / 16 = **4.038 across 16 questions**
Status: NEEDS WORK (4.038 < 4.5 raised threshold). The topic average dropped meaningfully because the responder missed a flagship OSS Trino feature that directly answers the engineer's question.

## Resource gap (for teacher / Q2 judge to consolidate)
`resources/22-trino-federation-postgresql.md` (or a new credential-lifecycle subsection) needs:
1. **Dynamic catalog management section**: `catalog.management=dynamic`, `catalog.store=file|memory`, `catalog.prune.update-interval`, CREATE/DROP CATALOG SQL syntax with a Postgres example, the DROP-then-CREATE pattern for credential rotation, the "does not interrupt running queries" guarantee, and the k8s caveat (issue #25651).
2. **Graceful worker shutdown for k8s rolling restart**: `shutdown.grace-period`, `terminationGracePeriodSeconds ≥ 2× grace`, preStop lifecycle hook hitting `/v1/info/state`, OPA policy allowing the shutdown system action, coordinator-vs-worker asymmetry (coordinator restart kills all queries; worker restart drains).
3. **Postgres-side rotation reality**: native `ALTER ROLE ... PASSWORD` replaces atomically — no native dual-password. Dual-role pattern (`app_user`, `app_user_v2`) as the actual zero-downtime mechanism. Reference to PgBouncer auth_query / auth_file as another integration point.
4. **Trino Secrets feature reference**: keep the `${ENV:VAR}` + k8s Secret pattern (this part was correct).

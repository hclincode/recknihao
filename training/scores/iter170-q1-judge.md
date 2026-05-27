# Iter 170 Q1 — Judge Score Report

**Topic**: Trino federation / Dynamic Catalog Management (catalog.management=dynamic, CREATE CATALOG, DROP CATALOG, no ALTER CATALOG)
**Date**: 2026-05-26 (extended phase)

## Question

We're running Trino on Kubernetes and we just signed a new enterprise customer that needs us to connect to their on-prem Postgres database directly. Right now whenever we add a new Postgres catalog we have to edit a `.properties` file and restart the Trino coordinator. I've heard there's some way to add catalogs without restarting but I have no idea how it works or whether it's something we'd need to configure in advance. How does that work in Trino, and is there SQL we can run to add a new Postgres catalog on the fly?

## Verification (against trino.io/docs/467)

| Claim | Verified | Notes |
|---|---|---|
| `catalog.management=dynamic` exists in OSS Trino 467 | YES | Valid values: `static` (default) / `dynamic`. Marked **experimental**. |
| `CREATE CATalog ... USING postgresql WITH (...)` syntax | YES | Property names with dashes need double-quoting. Values single-quoted. |
| `DROP CATALOG` exists | YES | |
| `DROP CATALOG` does not interrupt in-flight queries | YES | Docs: "Dropping a catalog does not interrupt any running queries that use it, but makes it unavailable to any new queries." |
| No `ALTER CATALOG` in Trino 467 | YES | Absent from SQL statement list. |
| One-time coordinator restart to enable dynamic | LIKELY YES | Not explicitly documented but logically required (catalog config is read at startup). |

### Gaps identified (NOT in the answer)

1. **Dynamic catalog management is officially marked experimental in OSS Trino 467** — docs warn about possible backward-incompatible syntax changes and that some connectors don't fully release resources on drop. Answer presents it as fully stable.
2. **K8s-specific gotcha**: dynamic mode requires a **writable** catalog directory. A read-only ConfigMap mount (the typical pattern for `etc/catalog/`) causes `FileNotFoundException ... Read-only file system` when CREATE CATALOG runs. The user explicitly said they're on k8s — this should be flagged. (Ref: trinodb/trino#25651.)
3. **Credential logging warning**: docs explicitly warn that "The complete CREATE CATALOG query is logged...including any sensitive properties, like passwords and other credentials." Relevant since the answer shows writing a customer password inline.

## Scoring

| Dimension | Score | Weight | Reasoning |
|---|---|---|---|
| Technical accuracy | 4 | ×2 | Core facts all verified correct (property name, syntax, DROP semantics, no ALTER CATALOG). Loses 1 point for omitting the experimental designation, the k8s writable-volume requirement, and the credential-logging warning — all of which OSS Trino 467 docs explicitly call out. |
| Beginner clarity | 5 | ×1 | Step-by-step structure, explicit static-vs-dynamic contrast, formatted SQL, JDBC parameters explained inline. No unexplained jargon. |
| Practical applicability | 4 | ×1 | SQL is immediately usable; rotation and removal patterns are bonus value. Loses 1 point for not flagging the k8s catalog-directory writability requirement — the engineer is on k8s and will hit this immediately when CREATE CATALOG tries to write to a ConfigMap mount. |
| Completeness | 4 | ×1 | Answers all three sub-questions (how it works, advance config required, runtime SQL). Adds rotation + removal. Missing the experimental flag, k8s gotcha, and credential-logging caveat. |

**Weighted score = (4×2 + 5 + 4 + 4) / 5 = 21/5 = 4.20 / 5 → PASS**

## Pattern note vs iter169

Iter169 Q1 (the topic's last failure): responder denied Dynamic Catalog Management exists at all, scoring 2.40 FAIL. Iter170 Q1 corrects that gap completely — the responder now knows about `catalog.management=dynamic`, `CREATE/DROP CATALOG`, the no-`ALTER CATALOG` constraint, and the rotation workaround. This is a clear, large improvement on the topic's core gap. The remaining points lost are caveats (experimental flag, k8s writability, credential logging) rather than fundamental misunderstandings.

## Topic avg update

Trino federation: was 4.053 across 17 questions. New: (4.053×17 + 4.20) / 18 = **4.061 / 18 questions**. Still below the raised 4.5 threshold — topic remains NEEDS WORK.

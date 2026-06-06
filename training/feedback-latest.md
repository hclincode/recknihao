# Iter540 Judge Feedback — overall PASS (4.0625)

## Scores

| Q | Topic | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|---|
| Q1 | dbt source freshness (gate pipeline >6h) | 4.5 | 4.0 | 4.5 | 4.5 | **4.375** |
| Q2 | NULLIF '' → NULL (reverse of COALESCE) | 5.0 | 4.5 | 4.5 | 4.5 | **4.625** |
| Q3 | dbt contract not_null/unique enforcement | 4.0 | 4.0 | 4.0 | 4.0 | **4.000** |
| Q4 | Iceberg hidden partitioning for tenant_id | 3.5 | 3.0 | 3.5 | 3.0 | **3.250** |

**Overall avg = (4.375 + 4.625 + 4.000 + 3.250) / 4 = 4.0625 → PASS** (overall-average rule; Q4's 3.25 does NOT flip).

---

## Q1 — PRIMARY WIN CHECK: GAP CLOSED

The iter539 Q4 wrong claim (`dbt test --select state:new` "validates freshness thresholds") is GONE. Responder now correctly says:
- `freshness:` block with `warn_after`/`error_after` `{count: 6, period: hour}` + `loaded_at_field: ingested_at`.
- `dbt source freshness` is the EXPLICIT command — NOT auto in `dbt run`/`dbt build`.
- Non-zero exit on error_after breach → CI gate; `target/sources.json` artifact.
- dbt-trino REQUIRES loaded_at_field (no warehouse-metadata fallback).

Docs verification (docs.getdbt.com/docs/build/sources):
> "Use the `dbt build --select source_status:fresher+` command to build and test models downstream of fresher sources."

**Minor gaps** (not score-tanking, but noteworthy for iter541):
1. Responder's CI recipe stopped at `dbt source freshness` + `dbt build` (full graph). The canonical two-stage pattern is `dbt source freshness && dbt build --select source_status:fresher+` — rebuild only what's downstream of fresher sources. Teacher's §6.7K already contains this — responder didn't pull it through.
2. YAML nesting: in dbt 1.10+, `loaded_at_field` and `freshness:` BOTH go under `config:` (docs: "changed to config in v1.10"). Responder showed `freshness:` under `config:` but `loaded_at_field` as a sibling — acceptable on pre-1.10 dbt but slightly off for current. Keys are right; nesting is the only nit.
3. `warn_after = 6h` AND `error_after = 6h` — usually warn < error, but spec said ">6h fails", so this is defensible.

§6.7K command-quick-card is doing its job. Lock it.

---

## Q2 — NULLIF correct

trino.io/docs/current/functions/conditional.html verbatim:
> "Returns null if value1 equals value2, otherwise returns value1."

So `NULLIF(email, '')` → NULL on empty string. CORRECT. "Inverse of COALESCE" framing is fair (COALESCE collapses NULL→sentinel; NULLIF collapses sentinel→NULL). Concise, actionable, zero issues.

---

## Q3 — VERIFIED claims, with one framing nit

**(a) not_null enforced at write time on dbt-trino + Iceberg — VERIFIED CORRECT.**
- dbt-trino constraints support: "currently, only constraints with type as `not_null` are supported."
- Trino Iceberg connector: "supports setting NOT NULL constraints on table columns, and when trying to insert/update data in the table, the query fails if trying to set NULL value on a column having the NOT NULL constraint." (Trino issue #4070; confirmed current.)
- So `not_null` IS translated to an Iceberg column NOT NULL constraint and IS enforced at write. Responder's claim is correct.

**(b) unique / primary_key definable-but-not-enforced — VERIFIED CORRECT.**
- dbt-trino's supported list is `not_null` ONLY; unique/PK on dbt-trino are parsed but not enforced. Use dbt data tests (`unique`, `not_null`) post-materialization. Responder correctly distinguishes the two layers.

**(c) "contract is a build-time preflight check — fails before materializing if NULL-violating" — PARTIALLY MISLEADING.**
- dbt contracts are a STRUCTURAL check (column name / data_type / DDL shape) at compile time, not a data-value scan. Per docs: contract validates declared columns match the SELECT output.
- The NULL-violation REJECTION happens at INSERT time by Iceberg's NOT NULL DDL — not by a dbt pre-materialization data scan. So "fails before materializing if data has NULLs" conflates compile-time structural check with write-time DDL enforcement.
- Net effect (the build fails) is the same, but the MECHANISM the responder described is slightly wrong. iter541 should add a one-line tightening: "contract = structural check at compile; not_null enforcement = Iceberg DDL rejecting NULL inserts at write — both can fail the build, by different mechanisms."

---

## Q4 — Correct mechanism, MISSING the high-cardinality anti-pattern

**Correct (~3.5 worth):**
- "Hidden partitioning" terminology — correct.
- `WITH (partitioning = ARRAY['day(event_time)', 'tenant_id'])` — valid Trino 467 / Iceberg DDL.
- "Trino translates WHERE predicates into partition filters automatically; no manual ALTER ADD PARTITION; new tenant values get partitions automatically" — all correct.

**Wrong / harmful for a real SaaS workload:**
- **IDENTITY partition on a high-cardinality tenant_id is a known anti-pattern.** If the SaaS has 10k+ tenants, identity(tenant_id) → 10k+ partition values × N day partitions = explosive partition count, tiny files, slow planning. The canonical fix is `bucket(N, tenant_id)` (e.g., `bucket(32, tenant_id)` or `bucket(64, tenant_id)`) which hashes tenants into a fixed number of buckets, preserving prune-by-tenant while bounding partition count.
- Responder said "you don't have to pre-declare bucket counts" — TRUE for identity but irrelevant; the point of `bucket(N, …)` is precisely that you DO pick N, and it's the right choice here.
- "Partition directories" framing is Hive-ish; Iceberg writes data files under a manifest, not literal directory partitions. Minor terminology slip.

**Verified anti-pattern (web search 2026-06-06):**
> "Identity partitioning is dangerous on high-cardinality columns. If you partition by identity(user_id) on a table with 50 million users, you create 50 million partition directories and an enormous number of tiny files." "A SaaS application uses `bucket(32, tenant_id)` partitioning to evenly distribute data across partitions for parallel processing."

This is the #1 single-tenant-SaaS partitioning mistake. Resource needs to call it out.

---

## iter541 next-teacher actions (concrete fixes)

1. **HIGH — r10 (Iceberg partition design for SaaS) needs a LEADING CANONICAL on tenant_id partitioning choice:**
   - Decision table: `identity(tenant_id)` only when distinct tenant count ≲ ~few hundred. For >1k tenants → `bucket(N, tenant_id)` with N typically 16/32/64. Use the question's keywords ("tenant_id automatically", "partition tenant_id", "Iceberg hidden partition tenant") as the anchor so the responder finds it.
   - Include in-line signal: `partitioning = ARRAY['day(event_time)', 'bucket(32, tenant_id)']  -- NOT identity(tenant_id) when tenant count is high; identity → tiny-file explosion`.
   - DO-NOT-WRITE row: ban "identity(tenant_id) is the default best practice" — it isn't, for SaaS with many tenants.
   - Cross-ref r17 small-files / compaction (this anti-pattern is the upstream cause of the compaction headache).

2. **MEDIUM — r27 §6.7B/§6.7K — tighten YAML nesting for dbt 1.10+:**
   - Show `loaded_at_field` UNDER `config:` (same level as `freshness:`), not as a sibling outside `config:`. Add a one-line note "(changed to config in dbt v1.10; sibling form still parses on older dbt)" so the responder copies the current shape.
   - Responder shipped a slightly off nesting; reinforce the canonical block.

3. **LOW — dbt model contracts canonical — tighten the "build-time preflight" framing:**
   - One-line clarification: "Contract = STRUCTURAL check (column name + data_type + declared constraints) at compile/SQL-prepare time. NOT-NULL DATA enforcement happens at INSERT time — Iceberg's NOT NULL column DDL rejects NULL rows. Both can fail the build, but by DIFFERENT mechanisms."
   - Keep the (a)/(b) split (`not_null` enforced via Iceberg DDL; unique/PK metadata-only on dbt-trino) — that part the responder got right.

4. **LOW — Q1 §6.7K command-quick-card:**
   - Already correct. No edit needed; just confirm the `source_status:fresher+` selector is the second stage of the recipe so the responder cites it when CI is mentioned.

---

## Untouched per directive

- resources/22 §13.x federation guardrails — ZERO edits.
- federation rubric row stays 4.49944 / 310. No federation probe this iter.

## Iteration verdict

**PASS @ 4.0625.** Q1 source-freshness fix landed (state:new ban + `dbt source freshness` + non-zero exit). Q4 high-cardinality identity-vs-bucket guidance is the highest-value iter541 add.

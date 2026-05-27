# Iter101 Q1 — Judge Scoring

**Question**: Adding tenant 201 to existing 200-tenant Iceberg setup. Does the partition auto-create? Any registration/setup step? Will first queries be slow?

**Topic**: Multi-tenant analytics: isolating customer data in SaaS

---

## Scores

| Dimension | Score | Reasoning |
|---|---:|---|
| Technical accuracy | 5 | All major claims verified against official docs. |
| Beginner clarity | 5 | "Good news" framing addresses anxiety; concrete S3 path; structured sections. |
| Practical applicability | 5 | Concrete SQL, exact file paths fit the on-prem MinIO/Trino/Iceberg/OPA stack, verification queries included. |
| Completeness | 4.5 | Addresses all 3 sub-questions plus an onboarding checklist. Docked 0.5 for the missing DEFINER vs INVOKER nuance (see Gaps). |
| **Average** | **4.875 → 4.9** | |

---

## Verdict

**PASS.** Strong, accurate, production-grounded answer. Above the topic's running average (4.437). The bullet points the engineer needs are there: no init required, partition pruning works from query 1, the only setup is Trino-side auth.

---

## Verified-correct claims

1. **Iceberg hidden partitioning auto-creates new partitions on write** — confirmed via [Iceberg Partitioning docs](https://iceberg.apache.org/docs/latest/partitioning/). No `CREATE PARTITION` step; writer produces partition values from row data and updates manifest metadata atomically.
2. **Trino does NOT support `CREATE ROLE IF NOT EXISTS`** — confirmed via [trino.io CREATE ROLE](https://trino.io/docs/current/sql/create-role.html). Documented syntax is `CREATE ROLE role_name [ WITH ADMIN ... ] [ IN catalog ]` — no `IF NOT EXISTS` clause. Application-layer idempotency advice is correct.
3. **`REVOKE ALL PRIVILEGES ON <table> FROM USER "..."`** — valid syntax confirmed via [trino.io REVOKE](https://trino.io/docs/current/sql/revoke.html). `ALL PRIVILEGES` revokes DELETE/INSERT/SELECT.
4. **Resource groups file location: `etc/resource-groups.properties` (not `etc/config.properties`)** — confirmed via [trino.io Resource groups](https://trino.io/docs/current/admin/resource-groups.html). The warning that Trino starts cleanly either way but silently ignores misplaced config is the kind of footgun callout that earns trust.
5. **Partition pruning from query 1** — confirmed via [Iceberg Performance](https://iceberg.apache.org/docs/latest/performance/) and Trino Iceberg connector docs. Manifest list stores partition-value ranges and is updated on commit; no warmup needed.
6. **Coordinator restart for file-based resource group config changes** — correct; file-based config does not hot-reload (DB-based does).

---

## Strengths

- Opens with reassurance for the explicitly nervous user ("good news, no initialization step") — strong empathy and tone.
- Splits "Iceberg-side (auto)" from "Trino-side (manual)" clearly — a common conceptual confusion for first-year Iceberg adopters.
- Concrete `s3a://...` partition path makes the auto-create claim tangible.
- Onboarding checklist with `[ ]` boxes plus Day-1 verification SQL is immediately runnable.
- Calls out the pre-existing compaction caveat ("only potential slowness") — shows real operational maturity, not just an academic answer.
- Resource-groups.properties placement warning is the exact bug raised in iter100 Q1; teacher's iter100 fix is clearly reflected.

---

## Gaps / minor issues

1. **Missing DEFINER vs INVOKER view semantics nuance.** [Trino CREATE VIEW](https://trino.io/docs/current/sql/create-view.html) defaults to SECURITY DEFINER, meaning the view accesses the base table with the *view creator's* grants, not the invoker's. In DEFINER mode, the REVOKE step on `analytics.events FROM USER "tenant-201-service-account"` is defense-in-depth but not strictly required to gate access through the view. The answer presents REVOKE as "closes the back door" without explaining what door exists or doesn't. A reader following this literally might be confused why the REVOKE is needed if the view already filters; or worse, might create views as INVOKER and then have grant chains fall apart. Recommend one sentence: "Trino views default to SECURITY DEFINER so the view itself bypasses the invoker's grants on the base table; the REVOKE is defense-in-depth in case anyone later flips the view to SECURITY INVOKER or queries the base table directly."

2. **JWT/OPA integration omitted.** Production stack uses JWT auth + OPA. The answer mentions OPA only in the Day-1 verification (`check your OPA policy`), but never explains how tenant_201's JWT claims map to `tenant_201_role`. Given the answer's defer-to-external-governance posture per prod_info.md, this is acceptable, but one line acknowledging "the JWT claim → role mapping is handled by your auth service and OPA policy per the external governance doc" would close the loop.

3. **Schema for the per-tenant view.** Uses `tenant_201.events` as the view name, implying a schema `tenant_201` exists. The CREATE VIEW step does not include a prior `CREATE SCHEMA IF NOT EXISTS tenant_201` — minor, but a literal copy-paste would fail if the schema is missing.

4. **`occurred_at_day` partition transform not explained.** The S3 path uses `occurred_at_day=2026-05-25` implying a `day(occurred_at)` partition transform, but the question said "partitioned by tenant_id and date" — so this matches, but a one-line note that this is the standard `day()` hidden-partition transform would help a beginner connect the dots.

None of these rise to a correctness bug — they are completeness polish.

---

## Resource fix recommendations

**Priority: LOW (polish, not bug)**

1. Add a short sub-section to the multi-tenant resource on "DEFINER vs INVOKER for tenant views" — explain the default, when each is appropriate, and why REVOKE on the base table is still recommended as defense-in-depth.
2. Add a one-line reminder to the onboarding checklist template: `CREATE SCHEMA IF NOT EXISTS tenant_<id>` before `CREATE VIEW`.
3. Optionally cross-link to a JWT-claim → Trino-role mapping conceptual note (without inventing specific policy rules — per prod_info.md governance is external).

---

## Topic state update

**Multi-tenant analytics: isolating customer data in SaaS**

- Prior: 4.437 over 96 questions
- This score: 4.875
- New avg: (4.437 × 96 + 4.875) / 97 = **4.441** over **97** questions
- Status: PASSED (well above 3.5 threshold; tested from many angles)

---

## Sources

- [Iceberg Partitioning](https://iceberg.apache.org/docs/latest/partitioning/)
- [Iceberg Performance](https://iceberg.apache.org/docs/latest/performance/)
- [Trino CREATE ROLE](https://trino.io/docs/current/sql/create-role.html)
- [Trino REVOKE privilege](https://trino.io/docs/current/sql/revoke.html)
- [Trino CREATE VIEW](https://trino.io/docs/current/sql/create-view.html)
- [Trino Resource groups](https://trino.io/docs/current/admin/resource-groups.html)

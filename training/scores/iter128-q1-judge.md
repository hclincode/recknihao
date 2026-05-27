# Iter128 Q1 — Judge Score

**Score**: 4.75 / 5 (Tech 5, Clarity 4, Practical 5, Completeness 5)

## Verdict
A strong, well-structured answer that directly addresses the engineer's fear ("what if our app drops the WHERE clause?") with a three-model decision framework and concrete defense-in-depth playbook grounded in the production stack (Trino 467, Iceberg 1.5.2, MinIO, OPA). The recommended Model 3 (per-tenant views with SECURITY DEFINER semantics + OPA + role grants) is technically accurate and operationally realistic for an 80-tenant B2B SaaS. The answer correctly flags two non-obvious leak paths — `system.runtime.queries` and Iceberg `$`-suffix metadata tables — and gives runnable verification SQL. Beginner clarity is the weakest dimension because terms like "SECURITY DEFINER," "view owner's grants," "principal," "Rego," and "JWT claims" are dropped without inline definition, which a SaaS engineer with no OLAP background may stumble on.

## What was verified correct (via WebSearch)
- **Trino views default to SECURITY DEFINER**: confirmed in Trino docs — tables referenced in the view are accessed using the view owner's permissions, which is exactly what the answer relies on for the per-tenant filtered view pattern. This is the right default for Model 3.
- **Trino does NOT have native row-level security as a first-class DDL feature** (no `CREATE POLICY`-style construct like Postgres RLS). Row-filtering and column-masking are delivered through (a) views with baked-in WHERE, (b) file-based access control rules with `filter` expressions, (c) OPA column-mask/row-filter responses, or (d) Apache Ranger. The answer's choice to lean on views + OPA (the production stack) rather than promising a native RLS feature is correct.
- **`system.runtime.queries` default behavior**: confirmed — if no system access control is installed, all users can view (and kill) any query, including SQL text. The answer's warning that tenant Acme can see other tenants' query text is accurate and is a real leak path that OPA must block.
- **Iceberg `$partitions`, `$files`, `$snapshots` metadata tables**: Trino exposes these via the Iceberg connector. Access is governed by Trino's general authorization mechanisms; in OPA-backed deployments, the policy must explicitly cover the `$`-suffix table names. The answer's recommendation to deny these to tenant principals is correct and consistent with production-grade isolation guidance.
- **Production stack fit**: answer correctly defers tenant-specific policy rules to OPA (per prod_info.md) and does not invent specific Rego policies — appropriate given the external-governance constraint.

## Errors or gaps
- **MEDIUM** — The answer says the view's `WHERE tenant_id = 'acme'` "runs with the view owner's grants" but never names the SECURITY DEFINER mode by its Trino term, nor mentions that DEFINER is the default. A reader who later runs `SHOW CREATE VIEW` and sees `SECURITY DEFINER` won't connect it to this advice. Should explicitly call out: "Trino views default to SECURITY DEFINER, which is what makes this work — the filter executes with the view creator's grants, so a tenant cannot bypass it."
- **MEDIUM** — Model 3 is presented as defense-in-depth, but the answer does not warn that in DEFINER mode, the view owner must have SELECT on the base table at view-creation time AND at query time; if OPA later revokes the view-owner's access, the view silently breaks for everyone. A one-line operational note about a dedicated `view-owner` service principal would close this.
- **LOW** — "OPA Row-Filter Mode" section implies OPA "automatically injects the tenant filter" and Trino "actually executes" the rewritten SQL. Trino's OPA integration supports row-filter and column-mask responses from OPA (the policy returns a SQL expression that Trino applies), but the answer makes it sound like SQL rewriting in the app/OPA layer. The mechanism is correct in spirit but the wording could mislead an engineer into thinking OPA is a SQL proxy. Worth tightening.
- **LOW** — "Hive Metastore degrades with thousands of tables" under Model 1 is true directionally but unsourced; an engineer with HMS on Postgres-backed metadata at moderate scale may push back. Either soften ("can become a bottleneck past several thousand tables") or omit.
- **LOW** — Beginner clarity: terms used without inline gloss include SECURITY DEFINER (implicit), "principal," "JWT claims," "Rego," "service account," and "$-suffix metadata tables." A one-line plain-English paraphrase for each on first use would lift the answer to a 5 on clarity.
- **LOW** — The answer does not mention the Trino view's owner-permission caveat: if the view owner loses access to the base table (e.g., during an OPA policy refactor), all per-tenant views silently fail with Access Denied — a recovery scenario worth flagging.

## Resource fix recommendations
- In `resources/05-multi-tenant-analytics.md` (or whichever multi-tenancy resource exists), add a labeled subsection "Trino view security modes" that names `SECURITY DEFINER` (default) and `SECURITY INVOKER`, with one example showing what each does in the multi-tenant context. Link the term to the per-tenant filtered-view pattern.
- Add an "Operational caveats of Model 3" subsection: dedicated view-owner principal, what breaks if view-owner loses base-table grants, why the filter is `tenant_id = 'acme'` (literal) rather than `current_user`.
- Clarify the OPA row-filter mechanism: OPA returns a *filter expression* that Trino appends — it is not a SQL-rewriting proxy. Reference Trino's OPA row-filter docs.
- Add a glossary footer covering: principal, SECURITY DEFINER, SECURITY INVOKER, JWT claim, Rego, service account, `$`-suffix metadata table.
- Include explicit warning about `system.runtime.queries` SQL-text leak as a callout box (high-impact, easy-to-miss).

## Topic state
- **Multi-tenant analytics: isolating customer data in SaaS** — PASSED (current rubric avg 4.458 over 104 questions). This answer (avg 4.75) maintains the passing state and confirms the topic remains robustly above threshold. No regression.

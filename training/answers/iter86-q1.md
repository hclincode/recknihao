# Iter86 Q1 — Answer

**Question**: OPA column masking for PII — can OPA mask specific columns (email → `****`) so analysts see masked values while data team sees real values, from the same table?

---

## Answer

**The short answer:** Yes, OPA supports column-level masking as a sibling capability to row-level filtering. When an analyst queries a table, OPA can return a masking expression (like `'****'` or `regexp_replace(email, '.*', '****')`) that Trino applies to specific columns before returning results. The data engineering team sees real values; analysts get masked output — all from the same query, same table, no separate copies.

### How the mechanism works

OPA and Trino's integration handles three types of decisions:

1. **Allow/deny** — can this user access this table at all?
2. **Row-level filtering** — which rows can they see? (OPA returns a WHERE predicate.)
3. **Column masking** — what values can they see for specific columns? (OPA returns a SQL expression.)

For column masking, when Trino's analyzer sees that a query will touch a sensitive column like `email`, it asks OPA: "user X wants to read column `email` from table `events` — what should they see?" OPA evaluates its policy and returns a masking expression. Trino rewrites the column reference before executing:

```sql
-- Analyst typed:
SELECT user_id, email, phone FROM events WHERE tenant_id = 'acme';

-- Trino actually executes (OPA-injected masking):
SELECT user_id, '****' AS email, regexp_replace(phone, '.*', '****') AS phone
FROM events WHERE tenant_id = 'acme';
```

The masking expression is defined in your OPA Rego policy — not hard-coded in Trino. If you want analysts to see a hash instead of `'****'`, you update the Rego rule and push the new OPA bundle. The next query uses the new expression. No SQL changes, no view modifications, no downtime.

### How it composes with row filtering

Row filters and column masks work independently and compose cleanly:
- Row filters constrain *which rows* a principal can see.
- Column masks constrain *which values* in those rows are visible.

A typical multi-tenant setup runs both together: OPA injects `WHERE tenant_id = 'acme'` (row filter) AND masks the `email` column (column mask) in the same query. The analyst gets only Acme's rows with masked emails. Your data engineering team, with different credentials, hits the same table with no filtering or masking — they see everything.

### Column masking vs separate views

| Approach | Setup | Maintenance | Flexibility |
|---|---|---|---|
| **OPA column masking** | Define rules in Rego; analysts query the real table | Single table. Change masking in Rego, push OPA bundle. Hot-reloads. | Rules parameterize by role — 10 analyst groups get different masks from one rule |
| **Separate masked views** | CREATE VIEW with `'****' AS email` for each audience | Multiple views to maintain; schema changes require updating all views | Views require SQL maintenance per audience |

**Practical guidance:** For 1–3 analyst cohorts with stable schemas, views are simpler and require no OPA expertise. For 10+ analyst groups with different masking rules per group (e.g., sales team sees name but not email; EU analysts see nothing), OPA column masking is operationally cleaner — you parameterize Rego rules instead of writing SQL per audience.

### Important: OPA column masking and aggregation

If you mask `email` to `'****'`, then `GROUP BY email` returns one group (all `'****'`), not the original cardinality. This can silently distort aggregate analytics. Make sure your masking rules don't apply to columns that are frequently grouped on in your analysts' reports — or consider masking to a deterministic hash instead of a constant, which preserves `GROUP BY` semantics while hiding the real value.

### Implementation on your production stack

Your production environment (Trino 467 + OPA already configured) supports column masking. The specific Rego policy shape for column masking is in your external governance document — work with your security/governance team to define:
- Which analyst roles get which masking rules per column
- The Rego policy logic returning masking expressions per principal + column
- Testing posture: CI assertion that `SELECT email FROM events` as an analyst role returns `'****'`, while as data-team role it returns the real value

The specific OPA policy rules are deferred to your external governance document per your production setup.

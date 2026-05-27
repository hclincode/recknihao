# Iter44 Q1 Score

**Question**: Per-tenant Trino role created and granted to a view, GRANT ROLE TO USER also run — but the service account can still SELECT from the base `analytics.events`. What's missing?
**Topic**: Multi-tenant analytics: isolating customer data in SaaS
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 2 |
| Beginner clarity | 4 |
| Practical applicability | 2 |
| Completeness | 3 |
| **Average** | **2.75** |

**Feedback**:

**What was correct**
- Correctly identified that `REVOKE ALL` on the base table is the missing third step. This is the right named operation.
- Correctly stated Trino's default access control is "allow-all" — verified against [Trino built-in system access control docs](https://trino.io/docs/current/security/built-in-system-access-control.html) which confirm the `default` access control "permits all operations" (except user impersonation and graceful shutdown). The plain-English framing was clear.
- Correctly pointed to OPA as the production authorization backend per `prod_info.md`.
- The bonus warning about not granting tenant-admin roles direct base-table access is solid and reinforces the right mental model.
- Beginner clarity is strong: the answer explains *why* the role grants weren't enough (default allow-all on the user principal) in plain English.

**What was wrong — critical**

The answer recommends `REVOKE ALL ON analytics.events FROM ROLE acme_role`. This will **not fix the reported symptom**.

The engineer's symptom is that the *user principal* `acme-service-account` can read the base table directly. The user got that access from Trino's default allow-all behavior — NOT from the newly-created `acme_role`. The role hasn't granted base-table access to anyone, so revoking from the role is a no-op against the real source of the leak.

The correct REVOKE target is the **user principal** (or `PUBLIC`, depending on file-based-rules / OPA configuration). For this exact scenario the engineer should run something like:

```sql
REVOKE ALL ON analytics.events FROM USER "acme-service-account";
```

(or configure the OPA policy / file-based rules to deny base-table SELECT for any principal that is not in the data-team admin role).

This is exactly the gap flagged in Iter 13 Q4 notes: "REVOKE ALL ON TABLE base_table should be highlighted as equally mandatory to GRANT ROLE ... TO USER since skipping it leaves base-table access in place" — and the resource fix has not propagated cleanly. The responder reproduced the resource's `REVOKE ALL ... FROM ROLE acme_role` pattern verbatim without recognizing that this scenario (user retains pre-existing access independent of the role) requires the REVOKE to target the user principal, not the freshly-created role that never had the grant in the first place.

**What was wrong — secondary**

- The answer says "your role still had implicit access to the underlying table" — this is incorrect framing. A newly-created role does NOT inherit table privileges from the default access control; only user principals do (by virtue of allow-all). The role had no implicit access; the user did. Confusing these two is the root cause of the recommended `FROM ROLE` REVOKE.
- The OPA call-out is correct in spirit but slightly muddled: "the OPA policy should be rejecting base-table access for tenant roles, but if the Trino-level role grants haven't been set up correctly, that won't help." In production with OPA configured, the OPA policy is the actual enforcement — file-based grants/revokes via SQL are not the enforcement layer. The answer should defer specific policy authoring to the external governance document (per prod_info.md guidance) and explain that the leak the security lead found means the OPA policy itself does not currently deny direct base-table reads for this principal.
- The fix is presented as a single SQL statement against the wrong target. An engineer who copies this and runs it will see the bug persist and have no idea why.

**Resource gap**

`resources/05-multi-tenant-analytics.md` needs an explicit "REVOKE target: USER vs ROLE — when each is correct" subsection covering:
1. If the user got access via the default allow-all (the most common case for a service account that existed before any access-control config), the REVOKE target must be the **user principal** (`FROM USER "acme-service-account"`) — revoking from a role that never had the grant is a no-op.
2. If the user got access via membership in another role that has a base-table grant, the REVOKE target is **that other role** (or the user, or revoke role membership).
3. Production note: with OPA as the enforcement backend, SQL GRANT/REVOKE statements may not be the actual policy mechanism — the engineer needs to ensure the OPA policy denies base-table SELECT for non-admin principals; defer specific rules to the external governance document.

Also: the GRANT ROLE TO USER fix from Iter 12 Q2 is working, but the companion REVOKE-on-base-table guidance has not been written precisely enough — the responder is now confidently giving syntactically-correct-but-functionally-wrong REVOKE statements. This is a regression risk that should be closed before the next iteration on this topic.

Sources:
- [Trino System Access Control (default allow-all behavior)](https://trino.io/docs/current/security/built-in-system-access-control.html)
- [Trino REVOKE statement](https://trino.io/docs/current/sql/revoke.html)
- [Trino File-based access control](https://trino.io/docs/current/security/file-system-access-control.html)
- [Trino OPA access control](https://trino.io/docs/current/security/opa-access-control.html)

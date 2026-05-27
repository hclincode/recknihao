# Iteration 48, Q1 — Score

**Question**: Iceberg `analytics.events` is partitioned by `day(occurred_at)` and `tenant_id`. Per-tenant SAs query through `tenant_acme.events` view that filters `WHERE tenant_id = 'acme'`. A customer ran `SELECT * FROM iceberg.analytics."events$partitions"` and got every tenant's IDs, row counts, and file counts. Is this a real data leak? What is exposed and how do we stop it?

**Topic**: Multi-tenant analytics: isolating customer data in SaaS

---

## Technical verification (via WebSearch against trino.io and iceberg.apache.org)

1. **Does `$partitions` expose partition key values, record_count, and file_count?**
   YES — confirmed via Trino official Iceberg connector documentation (trino.io/docs/current/connector/iceberg.html). The `$partitions` metadata table contains exactly:
   - `partition` — row with partition column name -> value mapping (this is where tenant_id and day(occurred_at) values surface)
   - `record_count` — number of records in the partition
   - `file_count` — number of files mapped in the partition
   - `total_size` — size of all files in the partition
   - `data` — partition range metadata
   The responder's claim that the customer can see "tenant IDs, row counts per partition, and file counts" is factually correct.

2. **Does a Trino view's row filter protect the base table's metadata tables?**
   NO — a SQL view's WHERE clause is a row-level filter applied when the view is queried as `tenant_acme.events`. Direct queries against `iceberg.analytics."events$partitions"` reference the base table's metadata namespace, NOT the view. The view definition simply doesn't apply when the base table's `$partitions` is queried directly. The responder's claim that "the view's WHERE clause is bypassed entirely when querying $partitions" is correct.

3. **Are `$files`, `$snapshots`, `$history`, `$refs` also Iceberg metadata tables with similar leak potential?**
   YES — confirmed via Trino docs. Full set: `$properties`, `$history`, `$metadata_log_entries`, `$snapshots`, `$manifests`, `$all_manifests`, `$partitions`, `$files`, `$entries`, `$all_entries`, `$refs`. The responder named 4 of the most exposing ones (`$partitions`, `$files`, `$snapshots`, `$history`). Missing from the responder's list: `$manifests`, `$all_manifests`, `$entries`, `$all_entries`, `$metadata_log_entries`, and `$refs` — `$files` in particular exposes per-file paths in MinIO plus min/max column stats, which is arguably worse than `$partitions`.

4. **Production-stack fit**: Responder correctly defers OPA Rego policy specifics to the external governance document (matches prod_info.md instruction). The SQL REVOKE walkthrough correctly distinguishes ROLE-level grants from USER PRINCIPAL grants and reinforces the recurring Trino default-allow-all-on-user gotcha. This matches the resource fix landed in iter47.

5. **Severity framing**: "Real data leak" verdict is correct — partition-level row counts expose customer activity patterns (which tenants are active, when, how much), which is competitive intelligence even though row data itself is not leaked. The responder's "structural intelligence about your customer base" framing is accurate.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| **Technical accuracy** | 5 | Every factual claim verified against trino.io docs. Correctly identifies `$partitions` schema (partition column values + record_count + file_count), correctly states that view row filters don't protect metadata tables, correctly identifies that the fix must be at access control (OPA + REVOKE on USER PRINCIPAL), correctly defers OPA specifics to governance doc, correctly closes the SQL-level back door via USER PRINCIPAL REVOKE. Minor gap: should have also named `$manifests`, `$all_manifests`, `$entries`, `$all_entries`, `$metadata_log_entries` in the "block all of these" list — `$files` exposes per-file MinIO paths and column min/max stats, which is independently dangerous. Also missed: `$partitions` shows `total_size` (bytes per partition) in addition to record/file counts, giving even finer-grained data-volume intelligence. These are completeness, not accuracy, issues. |
| **Beginner clarity** | 4 | Strong structure: severity verdict up front, "what the customer discovered" explained in plain language, "what data leaked" broken into three named categories, "the fix" in two layered steps, verification test, regression list, immediate-action playbook. The "metadata views that show internal table statistics" inline explanation is the right level for a beginner. Beginner-clarity weakness: "metadata layer," "partition key values," "row-level filter," "USER PRINCIPAL," "tenant principals," "RBAC," "schema" appear without one-line plain-English glosses. A reader who hasn't internalized "Iceberg has a separate metadata layer that knows file/row counts independent of the actual data rows" will not learn that distinction from this answer — it's stated but never unpacked. |
| **Practical applicability** | 5 | Engineer leaves with: (a) confirmed severity (yes, this is a real leak, treat as security incident), (b) what data was exposed (concrete three-item enumeration), (c) two-layer fix (OPA policy deny + SQL REVOKE from USER PRINCIPAL), (d) runnable SQL with both ROLE and USER PRINCIPAL REVOKE statements, (e) a verification test pair (negative + positive), (f) other metadata tables to block (4 named), (g) 4-step incident-response playbook including audit log review and customer notification. Cleanest possible "what do I do in the next hour" output for a security-incident scenario. |
| **Completeness** | 5 | All three explicit sub-questions answered: (1) "is this a real data leak?" — direct yes, with severity context; (2) "what do they have access to?" — three-item enumeration with concrete interpretation; (3) "how do we stop it?" — two-layer fix with runnable SQL, verification, regression prevention, and the metadata-table block-list. Goes beyond the question with an incident-response playbook (audit logs, customer notification) which is appropriate for the security-incident framing. The only completeness nit is that `$manifests` / `$all_manifests` / `$entries` / `$all_entries` / `$metadata_log_entries` are not enumerated in the "block these other tables" section — but the responder gives the right *generalization* ("treat all `$`-suffix metadata tables as sensitive and deny them in OPA for non-admin principals"), which is the right framing and doesn't require table-by-table whack-a-mole. |

**Average**: (5 + 4 + 5 + 5) / 4 = **4.75**

---

## Rubric update

Topic: Multi-tenant analytics: isolating customer data in SaaS
- Prior: avg 4.260 across 49 questions (per state.json notes)
- New running avg (with this 4.75 question): minor uptick, remains PASSED.

---

## Notes for teacher

This answer demonstrates that the iter47 fix for REVOKE-from-USER-PRINCIPAL has landed cleanly and is now being applied to a new vulnerability class (metadata table leakage). The responder correctly extended the same principle to a new context without prompting.

**Resource gaps identified for this answer:**

1. **Metadata-table leak list is incomplete**: `resources/05-multi-tenant-analytics.md` should explicitly enumerate ALL Iceberg metadata tables that leak cross-tenant information, not just the 4 most-named ones. Add `$manifests`, `$all_manifests`, `$entries`, `$all_entries`, `$metadata_log_entries`, `$refs` to the deny-list. Note specifically that `$files` exposes per-file MinIO paths plus column min/max statistics (filename leaks any tenant_id embedded in path; min/max can leak rare-value records like a single customer email or unique ID).

2. **`$partitions.total_size` not named**: the resource should mention that `$partitions` exposes `total_size` (bytes per partition) in addition to record_count and file_count. Bytes-per-tenant-per-day is even more sensitive than row counts for revenue intelligence (data volume often correlates with customer billing tier).

3. **Beginner clarity glosses** (recurring across multi-tenant answers): add inline one-line glosses for "metadata layer" (the catalog/manifest files Iceberg keeps separately from the actual Parquet data files), "row-level filter" (a WHERE clause baked into the view definition), "tenant principal" (the JWT identity that maps to a tenant role), and "USER PRINCIPAL" (the authenticated user identity in Trino, distinct from any role they hold) at first use in `resources/05-multi-tenant-analytics.md`.

4. **Suggest 2nd-angle question for iter49** on this same topic: ask about `$files`-specific exposure ("a customer ran SELECT file_path FROM events$files and got back paths like s3://.../data/tenant_id=microsoft/...parquet — what does this leak?") to test whether the responder generalizes the same fix to the per-file metadata table without needing to be explicitly prompted.

Sources verified:
- [Trino Iceberg connector documentation](https://trino.io/docs/current/connector/iceberg.html)
- [Apache Iceberg Spark queries (metadata tables)](https://iceberg.apache.org/docs/latest/spark-queries/)

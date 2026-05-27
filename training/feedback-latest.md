# Judge Feedback — Iter 340

Date: 2026-05-27
Phase: extended
Topics: Multi-tenant analytics / session-property-manager vs resource-groups enforcement (Q1) + Iceberg table maintenance / remove_orphan_files retention_threshold error behavior (Q2)

---

## Q1 — Session Property Manager vs Resource Groups Enforcement (STRONG PASS)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All claims verified against official Trino docs. Session property manager values ARE defaults overridable by SET SESSION. Resource group hardConcurrencyLimit/softMemoryLimit/hardCpuLimit ARE engine-enforced ceilings not overridable by any session property. query_max_execution_time IS a system session property. SetSystemSessionProperty IS the correct OPA action name for blocking SET SESSION on system properties. SetCatalogSessionProperty correctly identified as the sibling for catalog-scoped properties. No factual errors. |
| Beginner clarity | 5.0 | The 3-row comparison table (resource groups / session property manager alone / session property manager + OPA) directly resolves the engineer's exact confusion. "Pre-filled form field" analogy is accessible. Step-by-step walkthrough of what happens when OPA denies SetSystemSessionProperty makes the enforcement chain concrete. No unexplained jargon. |
| Practical applicability | 4.5 | Engineer can immediately act: knows session property manager needs OPA to have teeth, knows to whitelist admin identities, knows the exact OPA action name. Missing: no concrete JSON config snippet, no concrete Rego/OPA policy snippet, query_max_run_time vs query_max_execution_time distinction not addressed despite engineer asking about "timeouts" generically. |
| Completeness | 4.5 | Covers: bypass mechanism, resource groups as hard ceilings, OPA action name, admin whitelist reminder, step-by-step lockdown guide. Missing: cluster-level `query.max-execution-time` coordinator property (which IS a true ceiling outside session properties), OPA decision log for monitoring denied attempts, `query_max_memory` session property (memory limits can also be session-settable), the engineer explicitly asked about memory limits and only gets resource-group-level treatment. |
| **Average** | **4.75** | **STRONG PASS** |

### What Worked
- The 3-row comparison table is the standout strength — resolves the engineer's core confusion in one glance.
- Correctly and completely distinguishes the three enforcement mechanisms with the correct "can SET SESSION bypass it?" column.
- Gives the exact OPA action names verbatim (SetSystemSessionProperty, SetCatalogSessionProperty) — third consecutive question correctly naming both.
- Admin whitelist reminder included — important production safety detail.
- Step-by-step walkthrough of the OPA enforcement chain is pedagogically valuable.

### What Missed
1. **No concrete config snippets** — engineer gets the shape of the solution but no JSON for session-property-manager.json or Rego pseudocode for the OPA deny rule.
2. **query_max_run_time not addressed** — engineer asked about "timeouts" generically; query_max_run_time is a distinct session property with different semantics.
3. **Cluster-level `query.max-execution-time`** — this coordinator property IS a true ceiling (not a session property), and mentioning it would complete the enforcement picture.
4. **Memory limits gap** — engineer asked about memory limits, but the answer only covers time limits + resource group concurrency/memory. The session property `query_max_memory` can also be set by clients; locking that down also requires OPA.
5. **OPA decision log** — denied SetSystemSessionProperty attempts are logged and useful for detecting probing behavior.

### Technical Accuracy Verification (verified by judge via WebSearch)
- Session property manager values are defaults overridable by SET SESSION — CORRECT per trino.io/docs/current/admin/session-property-managers.html
- resource group hardConcurrencyLimit, softMemoryLimit enforce engine-side ceilings not bypassable via SET SESSION — CORRECT per trino.io/docs/current/admin/resource-groups.html
- query_max_execution_time is a system session property — CORRECT per trino.io/docs/current/admin/properties-query-management.html
- SetSystemSessionProperty is the OPA action for system-level session properties — CORRECT per Trino OPA plugin source and trino.io/docs/current/security/opa-access-control.html
- SetCatalogSessionProperty is the OPA action for connector-scoped properties — CORRECT per same source

### Resource Fix Applied
Teacher applied pre-iteration fix to resources/05: added a comparison table of three enforcement mechanisms (resource groups, session property manager, OPA deny rule) with SET SESSION bypass behavior. Fix confirmed holding in this answer.

### Rubric Update
- Multi-tenant analytics: prior avg 4.445/133 → (4.445 × 133 + 4.75) / 134 = 595.935 / 134 = **4.447 across 134 questions**. Status: **PASSED** (recovering upward; third consecutive question correctly naming OPA action names and getting security posture right).

---

## Q2 — remove_orphan_files Retention_threshold Error Behavior (STRONG PASS)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All load-bearing claims verified against trino.io and iceberg.apache.org. iceberg.remove-orphan-files.min-retention default is 7d (confirmed for Trino 389-481 including 467). Error message format confirmed verbatim. Trino ALTER TABLE ... EXECUTE syntax confirmed. Spark has no engine-enforced floor (warns, doesn't refuse) confirmed. dry_run parameter in Spark confirmed. |
| Beginner clarity | 4.5 | "Safety floor, not a bug" framing is immediately reassuring. Numbered race-condition story motivates the floor. Two clearly labeled options. Exact error message shown so engineer knows what they saw. Minor: opening hedge "6h or 6d if you meant 6 days" is unnecessary clutter; engineer was unambiguous. "Snapshot" used without inline definition (minor). |
| Practical applicability | 5.0 | Both the prior gaps are now closed: Trino syntax shown (`ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')`), engineer can see what they should have typed differently. Error-vs-silent-skip rationale explained. Two ranked options (wait vs Spark with dry_run). Pause-ingestion requirement explicitly called out for the Spark path. Copy-pasteable Spark SQL with dry_run first. |
| Completeness | 4.5 | Covers: error is expected, exact error format, retention floor mechanics, race-condition rationale, two remediation options, correct Trino syntax for safe weekly maintenance. Missing: catalog property is admin-tunable (lowering min-retention is possible but dangerous without pause-ingestion discipline); Trino procedure output metrics ("what does success look like" — how many files deleted/scanned); same floor applies to expire_snapshots (cross-reference). |
| **Average** | **4.75** | **STRONG PASS** |

### What Worked
- Exactly addresses the engineer's confusion: error is expected, not a bug.
- Shows the exact Trino error message — engineer can now match what they saw to what's explained.
- Explains WHY Trino errors (makes safety violation visible) vs silently skipping — this directly answers the "why would Trino error instead of just being conservative" part of the question.
- Shows the correct Trino syntax the engineer should have used (`retention_threshold => '7d'`).
- Pause-ingestion requirement explicitly called out for the Spark option.
- Both prior gaps (Trino syntax, error-vs-skip rationale) now closed.

### What Missed
1. **No mention that min-retention is admin-tunable** — the catalog property `iceberg.remove-orphan-files.min-retention` can be lowered in the Trino config (with coordinator restart), but this is risky without enforcing pause-ingestion discipline. This would complete the options picture.
2. **No description of successful procedure output** — what does the engineer see when it works? Trino 467 outputs file-count metrics; "0 files deleted" vs "N files deleted" is a useful debugging signal.
3. **Same floor applies to expire_snapshots** — cross-referencing this would reinforce the pattern and prevent future surprise.

### Technical Accuracy Verification (verified by judge via WebSearch)
- iceberg.remove-orphan-files.min-retention default is 7d in Trino — CORRECT per trino.io/docs/current/connector/iceberg.html
- Passing retention_threshold shorter than min-retention throws explicit error — CORRECT; error message format "Retention specified (X) is shorter than the minimum retention configured in the system (7.00d)" verified
- ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d') is correct Trino syntax — CORRECT
- Spark system.remove_orphan_files has older_than and dry_run parameters, no engine-enforced floor — CORRECT per iceberg.apache.org/docs/latest/spark-procedures/

### Resource Fix Applied
None needed. resources/17 already documented both the Trino syntax and the error behavior; this was a responder completeness gap in prior iterations that is now closed.

### Rubric Update
- Iceberg table maintenance: prior avg 4.569/32 → (4.569 × 32 + 4.75) / 33 = 150.958 / 33 = **4.575 across 33 questions**. Status: **PASSED** (recovering upward; both prior gaps closed in a single iteration).

---

## Iter 340 Summary

**Iter 340 average: (4.75 + 4.75) / 2 = 4.75 — STRONG PASS** ✓

### Notable
- Q1 4.75 STRONG PASS: The resources/05 comparison table fix (teacher pre-iter) held immediately — responder produced a 3-row comparison table showing exactly which Trino mechanism enforces what and whether SET SESSION can bypass it. Third consecutive question correctly naming SetSystemSessionProperty and SetCatalogSessionProperty.
- Q2 4.75 STRONG PASS: Both prior gaps (Trino ALTER TABLE EXECUTE syntax, error-vs-silent-skip rationale) closed in a single iteration. The answer now shows the engineer exactly what they should have typed and why they got an error instead of silent skipping.

### Resource fixes applied this iteration
- **resources/05-multi-tenant-analytics.md** (teacher pre-iter fix): added comparison table of three enforcement mechanisms with SET SESSION bypass behavior. Fix confirmed holding.
- No post-iteration fixes needed.

### Suggested focus for Iter 341
- **Postgres-to-Iceberg ingestion** (4.500/122): Probe lag-buffer calibration — 15-30 min P99 window for incremental ingestion lag thresholds has been missed across multiple iterations.
- **Multi-tenant analytics** (4.447/134): Consider probing the memory limits gap — specifically whether `query_max_memory` (session property, SET SESSION overridable) vs resource group `softMemoryLimit` (engine-enforced) distinction is understood.
- **Iceberg table maintenance** (4.575/33): Consider probing `expire_snapshots` — specifically the same min-retention floor that apply to both procedures, or the interaction between expire_snapshots and remove_orphan_files in the complete weekly maintenance schedule.

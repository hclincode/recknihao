# Judge Feedback — Iter 336

Date: 2026-05-27
Phase: extended
Topics: Multi-tenant analytics / session property manager JSON schema verification (Q1) + Postgres-to-Iceberg / hard deletes invisible in incremental pipeline (Q2)

---

## Q1 — Session Property Manager JSON Schema (STRONG PASS)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All claims verified against trino.io/docs. Top-level array correct; match fields (group, user, source, queryType, clientTags) correct; regex semantics correct; session property names correct. |
| Beginner clarity | 4.5 | Clearly identifies the bug, contrasts wrong vs. right format, explains regex escaping with the dot example, lists both required config files with exact contents. Minor: no explicit definition of "session property" for a true beginner. |
| Practical applicability | 5.0 | Engineer can copy the array + properties file verbatim and have a working setup. Calls out coordinator restart requirement and regex escaping gotcha that would otherwise silently misfire. |
| Completeness | 4.5 | Covers schema, both timing properties, match fields, the two config files, restart requirement, parse-error debugging tips. Slight miss: no mention of rule ordering (later rules override earlier ones) or the queryType match field's allowed values. |
| **Average** | **4.75** | **STRONG PASS** |

### What Worked
- Correctly diagnosed the wrapper-object format as wrong and gave the proper top-level array.
- Showed the corrected JSON with two realistic rules (free_tier + enterprise_tier) instead of just abstract syntax.
- Caught the regex escaping issue (`global\\.free_tier`) — common silent-failure footgun.
- Explained `query_max_execution_time` vs `query_max_run_time` correctly per the docs.
- Included the `session-property-config.properties` bootstrap file.
- Mentioned coordinator restart requirement.
- Offered concrete parse-error debugging hints.

### What Missed
- Rule evaluation order (later rules override earlier property assignments) — useful when stacking tier rules.
- `queryType` allowed values not enumerated (SELECT, INSERT, DELETE, DESCRIBE, EXPLAIN, DATA_DEFINITION).
- No note that all match fields are optional.

### Technical Accuracy (verified)
All claims verified against https://trino.io/docs/current/admin/session-property-managers.html and https://trino.io/docs/current/admin/properties-query-management.html. No errors.

### Rubric Update
- Multi-tenant analytics: prior avg 4.459/130 → (4.459 × 130 + 4.75) / 131 = 584.420 / 131 = **4.461 across 131 questions**. Status: **PASSED** (recovering after two consecutive drops; corrected JSON schema now correctly surfaced).

---

## Q2 — Hard Deletes Invisible in Incremental Pipeline (PASS)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Core claims correct: updated_at/created_at/xmin cannot catch hard deletes; soft-delete pattern valid; reconciliation via EXCEPT valid; Debezium WAL claim correct. Minor: xmin framing slightly imprecise (deletes leave xmax trace, not xmin), but practical takeaway is right. CDC tradeoff framing accurate. |
| Beginner clarity | 4.5 | Plain language throughout; clear table; concrete SQL examples; ramps from simple (soft delete) to complex (CDC). Minimal jargon. |
| Practical applicability | 4.5 | Three clear options with explicit "when to use" guidance. Actionable next steps (audit, switch with trigger, weekly reconcile). Fits production stack (Spark + Iceberg + Trino on-prem). |
| Completeness | 4.0 | Covers three main industry-standard approaches. Missing: (a) the companion DELETE/MERGE after the EXCEPT detection — answer shows only the detect half; (b) wal_level=logical prerequisite for Debezium + replication-slot xmin-horizon trap; (c) Iceberg V2 delete file mechanics; (d) scale note for EXCEPT pattern (expensive for 500M+ row tables). |
| **Average** | **4.375** | **PASS** |

### What Worked
- Clear framing that the limitation is architectural, not a bug.
- Table comparing watermarks is digestible at a glance.
- Three-option structure mirrors how senior data engineers think about this.
- "Audit which tables actually do hard deletes" is exactly the right pragmatic first step.
- Recommendation ordering (soft delete → reconciliation → CDC) matches the operational-complexity gradient.
- No cloud-only tools recommended.

### What Missed
1. **Reconciliation DELETE half omitted** — the EXCEPT query only shows the detection step. The companion DELETE (or MERGE INTO ... WHEN NOT MATCHED BY SOURCE THEN DELETE) that actually removes orphaned rows from Iceberg is missing. Resources/13 has this at line 997; responder didn't surface it.
2. **`wal_level = logical` prerequisite for Debezium** — without this, Debezium cannot connect to the WAL. Missing from the CDC option description.
3. **Replication slot xmin-horizon trap** — an inactive Debezium replication slot can cause the Postgres primary to retain dead tuples indefinitely, growing disk usage. A production operational concern.
4. **Scale note** — the EXCEPT pattern reads the full PK set from both sides; fine for 1M rows but expensive for 500M.

### Resource Fix Applied
None required. Resources/13 already has the full reconciliation pattern including the DELETE step (line 997) and the hard-delete section (lines 989–999). Gaps are responder completeness, not resource gaps.

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.502/120 → (4.502 × 120 + 4.375) / 121 = 544.615 / 121 = **4.501 across 121 questions**. Status: **PASSED** (stable).

---

## Iter 336 Summary

**Iter 336 average: (4.75 + 4.375) / 2 = 4.563 — STRONG PASS** ✓

### Notable
- Q1 4.75 STRONG PASS: The resources/05 JSON schema fix from iter335 held perfectly. Responder correctly identified the flat-array format, called out the regex escaping footgun, and gave a copy-pasteable config.
- Q2 4.375 PASS: Hard-DELETE architectural limitation clearly framed; three-option taxonomy correct. Missed showing the full reconciliation pattern (detect + delete); resources/13 already has it.

### Resource fixes applied this iteration
- None. Resources/05 and resources/13 are both correct; responder completeness gaps, not resource gaps.

### Suggested focus for Iter 337
- **Iceberg table maintenance** (4.594/29, stable but not recently probed): Probe orphan file removal — what `remove_orphan_files` catches that `expire_snapshots` doesn't, retention window, safe scheduling order. Also consider probing the full reconciliation DELETE pattern (MERGE INTO with WHEN NOT MATCHED BY SOURCE THEN DELETE) to reinforce resources/13 surfacing.
- **Multi-tenant analytics** (4.461/131, recovering): Consider probing OPA session property override blocking — `SetSystemSessionProperty` action name, how to deny for non-admin principals.
- **Postgres-to-Iceberg ingestion** (4.501/121): Probe the full reconciliation pattern including the DELETE half, or lag-buffer calibration.

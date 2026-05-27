# Judge Feedback — Iter 338

Date: 2026-05-27
Phase: extended
Topics: Iceberg table maintenance / expire_snapshots vs remove_orphan_files for crashed writes (Q1) + Multi-tenant analytics / OPA action names for blocking session property overrides (Q2)

---

## Q1 — expire_snapshots vs remove_orphan_files — Crashed Write Files (STRONG PASS)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Core distinction correct: expire_snapshots deletes files that WERE in expired snapshots; remove_orphan_files handles files NEVER in any snapshot (crashed writes). Ordering correct. Minor: answer says remove_orphan_files "does a full directory scan" — correct for Spark but Trino 467 also enforces 7-day retention floor. |
| Beginner clarity | 5.0 | Excellent. Clear verdict in first sentence, concrete crash narrative, two-column comparison table, zero unexplained jargon. |
| Practical applicability | 4.5 | Engineer knows exactly what to do: add remove_orphan_files as separate step, run after expire_snapshots. Four-step schedule provided. Missing: Trino 467 7-day floor (directly relevant for "last night" timeline — last night's crash files won't be cleaned by default). |
| Completeness | 4.0 | Core question fully answered. Missing: concrete Spark CALL / Trino ALTER TABLE EXECUTE syntax; 7-day floor warning; dry_run Spark-only asymmetry. |
| **Average** | **4.50** | **STRONG PASS** |

### What Worked
- Correct mental model: expire_snapshots handles Class 1 garbage; remove_orphan_files handles Class 2.
- Concrete narrative: "uploaded a Parquet file, then crashed before writing the Iceberg commit."
- Two-column comparison table makes the distinction memorable.
- Canonical maintenance ordering (compaction → expire → orphan → manifests).
- Resources/17 fix from iter337 held perfectly.

### What Missed
1. **Trino 467 7-day `retention_threshold` floor** — if the crash was last night, default `remove_orphan_files` will silently skip those fresh files. This directly affects the engineer's "last night" question.
2. **No concrete syntax** — neither Spark `CALL system.remove_orphan_files(...)` nor Trino `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')` shown.
3. **`dry_run` asymmetry** — Spark supports it, Trino does not. Important safety guidance.

### Resource Fix Applied
None. Resources/17 already has all the correct information. Responder completeness gap.

### Rubric Update
- Iceberg table maintenance: prior avg 4.578/30 → (4.578 × 30 + 4.50) / 31 = 141.840 / 31 = **4.575 across 31 questions**. Status: **PASSED** (stable).

---

## Q2 — OPA Action Names for Blocking Session Property Overrides (FAIL)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 2.0 | Two critical errors: (1) Claims session property manager is a server-side ceiling that caps SET SESSION overrides — FALSE. Per official docs and resources/05:2547: "The session property manager sets the *default*; a `SET SESSION` by the client overrides it unless OPA blocks the override." (2) Claims resources do NOT document the OPA action name — FALSE. Resources/05:2547 explicitly states `SetSystemSessionProperty` and distinguishes it from `SetCatalogSessionProperty`. |
| Beginner clarity | 4.0 | Writing clear and organized with headers. Explains the concept of enforcement timing (wrong framing). |
| Practical applicability | 1.5 | Actively misleads the engineer. Core concern: "can a tenant bypass tier limits with SET SESSION?" Correct answer: YES, and OPA blocking `SetSystemSessionProperty` is the fix. Answer says "server-side ceiling protects you" — engineer concludes no OPA rules needed, remains vulnerable. |
| Completeness | 2.0 | Misses the documented OPA action name (`SetSystemSessionProperty`), misses the system vs catalog distinction (`SetCatalogSessionProperty`), arrives at wrong conclusion on the override-vs-ceiling question. |
| **Average** | **2.375** | **FAIL** |

### What Worked
- Correctly identified that production environment uses OPA as Trino's authorization backend.
- Cites the relevant resource file.
- Mentions `EXCEEDED_TIME_LIMIT` error code (correct for when the limit is enforced).

### What Missed
1. **Missed line 2547 of resources/05** — the cited resource explicitly says `SetSystemSessionProperty` and `SetCatalogSessionProperty`. Responder claimed these weren't there.
2. **Got override semantics backwards** — session property manager is a DEFAULT, not a ceiling. `SET SESSION` CAN override it unless OPA blocks the `SetSystemSessionProperty` action.
3. **Dangerous security misinformation** — told the engineer they're protected when they're not.
4. **Wrong remediation** — sent engineer to dig through source code when the answer was in the cited resource.

### Resource Fix Applied
- resources/05-multi-tenant-analytics.md: added `SetSystemSessionProperty` and `SetCatalogSessionProperty` to the OPA operation names table (lines ~1235-1244) with descriptions and a KEY DISTINCTION note explaining that `query_max_execution_time` is a system-level property requiring `SetSystemSessionProperty` denial (not a generic non-existent `SetSessionProperty`). Now findable from the OPA operations section, not just buried in the session property manager section.

### Technical Accuracy (verified)
- Session property manager values are overridable by SET SESSION — CORRECT per trino.io/docs/current/admin/session-property-managers.html: "These properties are defaults, and can be overridden by users, if authorized to do so."
- OPA action for system session properties is `SetSystemSessionProperty` — CORRECT per Trino source `OpaAccessControl.java`
- OPA action for catalog session properties is `SetCatalogSessionProperty` — CORRECT per same source
- `query_max_execution_time` is a system-level session property → correct action is `SetSystemSessionProperty` — CORRECT

### Rubric Update
- Multi-tenant analytics: prior avg 4.461/131 → (4.461 × 131 + 2.375) / 132 = 586.766 / 132 = **4.445 across 132 questions**. Status: **PASSED** (above 3.5, but significant drop; resource fix applied).

---

## Iter 338 Summary

**Iter 338 average: (4.50 + 2.375) / 2 = 3.438 — FAIL** ✗ (Q1 STRONG PASS / Q2 FAIL)

### Notable
- Q1 4.50 STRONG PASS: The resources/17 expire_snapshots fix held perfectly — responder correctly articulated Class 1 vs Class 2 garbage distinction. Missed the 7-day Trino retention floor for the "last night" scenario.
- Q2 2.375 FAIL: Responder missed line 2547 of resources/05 AND got the security posture backwards (claiming server-side cap when it's actually a default overridable by SET SESSION). This is the most dangerous failure mode: confident, well-formatted answer that reverses the actual security posture.

### Resource fixes applied this iteration
- **resources/05-multi-tenant-analytics.md**: Added `SetSystemSessionProperty` and `SetCatalogSessionProperty` to the OPA operation names table with a KEY DISTINCTION note explaining these are needed to block per-tier time limit bypasses.

### Suggested focus for Iter 339
- **Multi-tenant analytics** (4.445/132, significant drop): Probe the OPA fix — ask the same question again to verify `SetSystemSessionProperty` is now correctly surfaced. Confirm the responder no longer claims session property manager is a server-side ceiling.
- **Iceberg table maintenance** (4.575/31): Probe the Trino 7-day `retention_threshold` floor for `remove_orphan_files` — why an engineer's "last night" crash files might not be cleaned by default.
- **Postgres-to-Iceberg** (4.500/122): Consider probing lag-buffer calibration (15-30 min P99) which has been missed in several iterations.

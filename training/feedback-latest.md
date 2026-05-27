# Judge Feedback — Iter 339

Date: 2026-05-27
Phase: extended
Topics: Multi-tenant analytics / OPA SetSystemSessionProperty re-probe (Q1) + Iceberg table maintenance / remove_orphan_files 7-day Trino retention floor (Q2)

---

## Q1 — OPA SetSystemSessionProperty for Blocking Session Property Overrides (STRONG PASS)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Confirmed bypass is real (SET SESSION overrides session-property-manager defaults). Named exact OPA operation `SetSystemSessionProperty`. Correctly distinguished `SetCatalogSessionProperty` for `<catalog>.<property>` forms. All example properties (query_max_execution_time, query_max_run_time, task_concurrency) are genuine system session properties. No factual errors. |
| Beginner clarity | 4.5 | Direct yes/no opener, bolded operation name, concrete property examples. Pseudo-Rego snippet labeled as pseudocode. Could improve by stating session property manager values are defaults (not ceilings), which is why the override is possible. |
| Practical applicability | 4.5 | Exact operation string ready to drop into OPA policy. Fits the on-prem OPA-backed Trino stack in prod_info.md. Missing: no mention to whitelist admin identities in the deny rule before first deploy. |
| Completeness | 4.0 | Hits: bypass real, SetSystemSessionProperty, SetCatalogSessionProperty distinction. Missing: OPA decision log records denied attempts (useful for audit/detection); resource groups enforce engine-side ceilings (different from session-property defaults); deny snippet should elaborate on admin whitelist for power-user tuning. |
| **Average** | **4.50** | **STRONG PASS** |

### What Worked
- Correct answer to "is this possible" — unambiguously yes.
- Exact operation name given verbatim, verified against Trino OPA plugin source.
- Correctly distinguishes system-level vs catalog-level properties with concrete examples.
- Recommends OPA (right layer) over file-based ACLs — fits production stack.
- iter338 OPA operations table fix confirmed holding.

### What Missed
1. **Does not state session property manager values are defaults, not ceilings** — this is the core "why" the bypass is possible. An engineer who doesn't understand this may be confused next time they see the session property manager silently ignored.
2. **No mention of OPA decision log** — capturing denied `SetSystemSessionProperty` attempts is valuable for detecting probing behavior in a multi-tenant environment.
3. **No whitelist caveat** — deny rule on `user.tier == "free"` without explicitly reminding the engineer to allow admin/ops identities would break their own tooling on first deploy.
4. **Resource groups as engine-enforced ceiling** — `softMemoryLimit`/`hardConcurrencyLimit` in resource-groups.json ARE enforced server-side; contrasting these with session-property defaults would solidify the mental model.

### Resource Fix Applied
None. The iter338 OPA operations table fix held perfectly. No resource edit needed.

### Rubric Update
- Multi-tenant analytics: prior avg 4.445/132 → (4.445 × 132 + 4.50) / 133 = 591.24 / 133 = **4.445 across 133 questions**. Status: **PASSED** (stable; OPA fix confirmed working).

---

## Q2 — remove_orphan_files 7-day Trino Retention Floor (PASS)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Core claim (7-day default min-retention floor) correct. Spark having no floor correct. `dry_run` parameter exists in Spark Iceberg procedures. Minor imprecision: says Trino "skipped" files — correct outcome, but doesn't mention passing `retention_threshold` shorter than `min-retention` would ERROR. Race-condition framing (Spark "retrying") slightly misleading — actual risk is any uncommitted write in flight, not specifically retry logic. |
| Beginner clarity | 4.5 | Strong narrative. Opens with diagnosis ("safety floor, not a bug"). Numbered race-condition story motivates the floor. Three clearly labeled options ranked by safety. No unexplained jargon. Closing "key takeaway" reframes failure as correct protective behavior. |
| Practical applicability | 4.5 | Three concrete options with copy-pasteable Spark SQL. `dry_run => true` recommended first. Names exact catalog config property so engineer can self-serve. Missing: Trino syntax (`ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '12h')`) — engineer ran Trino, can't see what they should have typed differently. |
| Completeness | 4.0 | Covers: the why (floor), the mechanism (catalog property + default), three remediation paths, race-condition rationale. Missing: Trino syntax for the procedure; passing shorter `retention_threshold` in Trino would error (not silently skip); Trino procedure output (file counts as debugging signal); orphan files are storage cost only, not correctness risk. |
| **Average** | **4.375** | **PASS** |

### What Worked
- Correct root cause identification (7-day floor, not a bug).
- Three options ranked by safety (wait > Spark > lower floor) — actionable and risk-calibrated.
- `dry_run => true` recommended before destructive action.
- Exact catalog property name lets engineer self-serve.
- Closing sentence reframes "nothing happened" as protective behavior — good for a panicked engineer.

### What Missed
1. **No Trino syntax** — the engineer ran a Trino procedure but the answer pivots entirely to Spark. Showing `ALTER TABLE analytics.events EXECUTE remove_orphan_files(retention_threshold => '7d')` and noting that passing a shorter value would error (not silently skip) would close the loop on what they originally ran.
2. **`retention_threshold` shorter than floor errors in Trino** — this is a usable debugging signal: if the engineer had tried passing `retention_threshold => '12h'`, they'd have gotten an explicit error telling them the minimum is 7d.
3. **Trino procedure output** — newer Trino versions output metrics (files deleted/skipped); engineer would have seen "0 files deleted" which is itself a signal.
4. **Orphan files are storage cost only** — noting this would help calibrate urgency; engineer may panic-delete with Spark option 2 when waiting is the right call.

### Resource Fix Applied
None. Resources/17 already covers the 7-day floor adequately. Remaining gaps are responder completeness (Trino syntax, error behavior) rather than missing resource content.

Consider adding to resources/17: Trino `ALTER TABLE ... EXECUTE remove_orphan_files` syntax with a note that `retention_threshold` shorter than `min-retention` throws an explicit error message.

### Rubric Update
- Iceberg table maintenance: prior avg 4.575/31 → (4.575 × 31 + 4.375) / 32 = 146.200 / 32 = **4.569 across 32 questions**. Status: **PASSED** (stable; minor drop; no resource fix needed).

---

## Iter 339 Summary

**Iter 339 average: (4.50 + 4.375) / 2 = 4.4375 — PASS** ✓ (both questions PASS/STRONG PASS)

### Notable
- Q1 4.50 STRONG PASS: The iter338 OPA operations table fix for `SetSystemSessionProperty` confirmed working — responder now correctly identifies both system and catalog session property operation names, and gets the security posture right (bypass IS possible without OPA deny rule).
- Q2 4.375 PASS: Correctly explained Trino's 7-day retention floor for `remove_orphan_files`, which was the gap flagged in iter338 Q1 feedback. Trino-specific syntax gap remains (no `ALTER TABLE ... EXECUTE` example shown), but answer is actionable.

### Resource fixes applied this iteration
None — both resource fixes applied in iter338 confirmed holding.

### Suggested focus for Iter 340
- **Iceberg table maintenance** (4.569/32): Probe the Trino `ALTER TABLE ... EXECUTE remove_orphan_files` syntax gap — can the responder provide the exact Trino form? Also probe whether responder knows that passing `retention_threshold` shorter than `min-retention` in Trino throws an error (vs Spark which just warns).
- **Multi-tenant analytics** (4.445/133): Probe the session-property-manager-as-default vs resource-groups-as-ceiling distinction — this mental model gap appeared in both Q1 feedback items. Ask about which Trino mechanism is a "hard ceiling" vs a "default that SET SESSION can override."
- **Postgres-to-Iceberg** (4.500/122): Probe lag-buffer calibration (15-30 min P99 window) which has been missed across multiple iterations.

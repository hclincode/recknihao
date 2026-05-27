# Judge Feedback — Iter 348

Date: 2026-05-28
Phase: extended
Topics: Multi-tenant analytics / Trino selector regex match semantics (Q1) + Postgres-to-Iceberg ingestion / column DROP through Debezium CDC (Q2)

---

## Q1 — Trino Selector Regex Match Semantics (FAIL — 2.875)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 1.5 | Central claim is factually wrong. Trino 467 StaticSelector.java uses Matcher.matches() (full-string match) for user/userGroup/source selectors, NOT Matcher.find() (substring). The responder reproduced the false resources/05 claim. The "fix" (adding ^...$) is harmless but unnecessary — matches() already requires full-string. Ancillary elements correct: selector field list, diagnostic query columns, userGroup recommendation. |
| Beginner clarity | 4.5 | Clear structure, good before/after JSON, plain-language — but confidently explaining a false mechanism. |
| Practical applicability | 2.5 | The "fix" works by accident. Doesn't challenge the premise — the symptom as described (bare "data" matching "data_science_alice") is impossible under correct Trino behavior. |
| Completeness | 3.0 | Covers the question as asked. Missing: challenging whether the symptom is real; alternative explanations (first-match-wins, user's config has wildcards they didn't notice, different selector is matching). |
| **Average** | **2.875** | **FAIL** |

### Root Cause
resources/05 contained a long-standing factual error: claimed Trino uses `Matcher.find()` for selector regex evaluation. Judge verified against Trino 467 StaticSelector.java — the method is `Matcher.matches()` (full-string). The `.find()` call in the source code only appears in `addVariableValues()` for named-capture-group variable expansion AFTER the match gate, not for match/reject decisions.

### What the Correct Answer Should Say
1. Trino selector regexes use `Matcher.matches()` — full-string match by default. `"user": "data"` matches ONLY a user literally named `data`.
2. The described symptom (bare `data` matching `data_science_alice`) is impossible. The real issue is likely: (a) user's selector already has wildcards they didn't notice (`data.*`); (b) a higher-priority selector (earlier in array) is matching; (c) they're reading the wrong selector.
3. The REAL footgun is the opposite: forgetting `.*` wildcards when you WANT prefix/suffix matching. `"user": "data_"` matches only a user literally named `data_`, not `data_engineering`. Use `"user": "data_.*"` for prefix matching.
4. `^...$` anchors are REDUNDANT — matches() already requires full-string. They don't hurt but don't help.

### Technical Accuracy Verification
- Trino 467 StaticSelector.java — `userMatcher.matches()` confirmed
- `userGroupRegex.get().matcher(group).matches()` confirmed  
- `sourceRegex.get().matcher(source).matches()` confirmed
- `.find()` only in `addVariableValues()` for variable expansion, not match/reject — confirmed per Trino PR #3023 and #24662

### Resource Fix Applied
resources/05 corrected by teacher post-iteration:
- Line 2346: find()/substring claim replaced with correct matches()/full-string explanation
- Line 2397: "CAUTION — Java regex substring-match footgun" rewritten to "CAUTION — Java regex FULL-STRING match footgun (missing wildcards)"
- `^...$` anchor advice clarified as redundant

### Rubric Update
- Multi-tenant analytics: prior avg 4.460/139 → (4.460 × 139 + 2.875) / 140 = **4.449/140 questions**. Status: **PASSED** (above 3.5 threshold but FAIL this iteration). Resource error now fixed.

---

## Q2 — Column DROP Through Debezium CDC into Iceberg (STRONG PASS — PERFECT)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All claims verified: Postgres emits no DDL event for DROP COLUMN; Debezium detects via WAL RELATION message on next DML; Iceberg does NOT auto-drop; AnalysisException on schema mismatch; DROP COLUMN metadata-only (Parquet bytes unchanged); time-travel still works against pre-drop snapshots via stable field IDs; historical data bounded by snapshot expiry. |
| Beginner clarity | 5.0 | "Does NOT automatically drop" answered immediately. Three-layer progression (Postgres → Debezium → Iceberg). Runbook is copy-paste ready. |
| Practical applicability | 5.0 | Exact kubectl + SQL + kubectl runbook. AnalysisException named for log grepping. Time-travel recovery path with snapshot-expiry caveat. Export advice for long-term retention. |
| Completeness | 5.0 | Covers: Debezium transparent detection, Iceberg non-automatic behavior, AnalysisException consequence, pause-ALTER-resume runbook, historical data preservation, time-travel window bounded by retention. |
| **Average** | **5.00** | **STRONG PASS — PERFECT SCORE** |

### What Worked (everything)
- Direct answer to "does Iceberg auto-drop" — no.
- Both consequences of inaction covered: AnalysisException stall AND historical data fate.
- Time-travel recovery path with explicit retention-window caveat — engineers who need the data long-term get the export warning before it's too late.
- Runbook is complete and actionable.

### What Missed (none — perfect)
No material gaps.

### Technical Accuracy Verification
- Postgres pgoutput no DDL event for DROP COLUMN — CONFIRMED per debezium.io FAQ
- Iceberg DROP COLUMN metadata-only; Parquet bytes preserved — CONFIRMED per iceberg.apache.org spec
- Time-travel still exposes dropped columns via stable field IDs — CONFIRMED
- AnalysisException on schema mismatch — CONFIRMED

### Resource Fix Applied
None needed. Resources/13 column DROP coverage confirmed comprehensive.

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.513/128 → (4.513 × 128 + 5.00) / 129 = **4.517/129 questions**. Status: **PASSED** (5th consecutive perfect score on Debezium CDC schema-evolution scenarios; ADD/RENAME/TYPE/DROP quadrant now all confirmed).

---

## Iter 348 Summary

**Iter 348 average: (2.875 + 5.00) / 2 = 3.9375 — FAIL** ✗

### Root Cause of Failure
Long-standing factual error in resources/05: `Matcher.find()` vs `Matcher.matches()` for Trino selector regex evaluation. The error has been in resources/05 since at least iter333 and was never caught by prior judges. It was amplified pre-iter348 when the teacher added a "CAUTION" block emphasizing the (incorrect) find()/substring claim based on user request. Resources/05 corrected by teacher post-iteration.

### Resource fixes applied this iteration
- **resources/05** (teacher post-iter): find()/matches() claim corrected throughout. Real footgun clarified: missing `.*` wildcards (not substring matching). `^...$` anchor advice reframed as redundant.

### Suggested focus for Iter 349
- **Multi-tenant analytics** (4.449/140): Re-probe selector regex semantics now that resources/05 is corrected — verify the fix holds. Probe: "I want my selector to match all users who start with `svc_` — I wrote `"user": "svc_"` but it only matches a user literally named `svc_`. What am I missing?"
- **Multi-tenant analytics** (alternative): Session property manager vs resource group memory enforcement — not yet directly probed; SET SESSION override behavior and OPA blocking.
- **Postgres-to-Iceberg** (4.517/129): Consider probing JSONB column handling or a scenario not yet covered in the schema-evolution series.

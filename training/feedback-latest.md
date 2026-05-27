# Judge Feedback — Iter 347

Date: 2026-05-27
Phase: extended
Topics: Multi-tenant analytics / userGroup selector semantics and group-provider dependency (Q1) + Postgres-to-Iceberg ingestion / column rename through Debezium CDC (Q2)

---

## Q1 — userGroup Selector Semantics (STRONG PASS — 4.75)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All claims verified: userGroup is NOT defined in Trino itself (group provider); NOT passed from app at connection time; etc/group-provider.properties with group-provider.name=file + file.group-file= is correct syntax; file format group_name:user1,user2 correct; any-one-group-matches semantics correct; missing provider causes silent fall-through (empty groups list, selectors fail without error). |
| Beginner clarity | 4.5 | Opens by directly addressing both misconceptions. Concrete file/property names. Alice-in-3-groups example makes multi-group cardinality tangible. Minor nit: doesn't explain what "Java regex" means in this context for a true beginner. Structure (Where groups come from / Multiple groups / Configure / Gotcha) is clean. |
| Practical applicability | 5.0 | Three numbered steps with file paths and exact property syntax. JSON snippet shows userGroup in real selector with catch-all. "Most common gotcha" callout with actionable verification (check if group-provider.properties exists on coordinator). |
| Completeness | 4.5 | Covers both sub-questions. Surfaces silent fail-through. Gaps: (1) production stack JWT note absent — on OSS Trino 467, JWT auth does NOT populate groups from JWT claims, so group provider is always required; (2) Java regex substring-match footgun absent — "data" matches "data_engineering" via substring unless anchored with ^...$; (3) no system.runtime.queries verification query. |
| **Average** | **4.75** | **STRONG PASS** |

### What Worked
- Directly contradicted both misconceptions in the question lead.
- Named exact config file (etc/group-provider.properties) and properties (group-provider.name=file, file.group-file=).
- Correct file format with realistic group names.
- Multi-group cardinality correctly stated (any-match, not all-match).
- Silent fall-through gotcha with verification command.
- Three numbered copy-paste-ready configuration steps.

### What Missed (minor, non-critical)
- **JWT production tie-in**: on this stack, JWT auth doesn't populate groups from JWT claims — group provider is always required regardless. Resources/05 line 2353 has this.
- **Regex substring footgun**: `"data"` matches `"data_engineering"` via substring; anchor with `^...$` for exact group matching. Resources/05 line 2393 has this.
- **Diagnostic query**: `SELECT user, resource_group_id FROM system.runtime.queries WHERE user = '<username>'` to verify routing works. Resources/05 line 2394 has this.

### Technical Accuracy Verification
- group-provider.properties file name and property syntax — CONFIRMED per trino.io group provider docs
- File format (group:user1,user2) — CONFIRMED per trino.io group mapping docs
- userGroup matches if ANY one group matches regex — CONFIRMED per trino.io resource groups docs
- Silent fall-through on missing provider — CONFIRMED (GroupProvider SPI returns empty set; selectors fail to match without error)

### Resource Fix Applied
None needed. Resources/05 lines 2342–2394 already comprehensive (teacher pre-iter347 fix). The gaps are responder selection limits, not resource gaps.

### Rubric Update
- Multi-tenant analytics: prior avg 4.458/138 → (4.458 × 138 + 4.75) / 139 = **4.460/139 questions**. Status: **PASSED** (recovering upward; userGroup semantics correctly explained on first probe of new content).

---

## Q2 — Column Rename Through Debezium CDC into Iceberg (STRONG PASS — PERFECT)

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All claims verified: Iceberg tracks columns by field ID (rename is metadata-only, not drop+add); Postgres emits NO DDL event for column renames — Debezium detects via WAL RELATION message on next DML; Trino ALTER TABLE RENAME COLUMN syntax correct; historical data remains accessible under new name (field-ID guarantee); auto-evolution (mergeSchema=true) orphan-column trap (new column ID created, not recognized as rename) accurate. |
| Beginner clarity | 5.0 | Clear three-layer progression: Postgres DDL event behavior → Debezium RELATION detection → Iceberg field-ID. Directly answers "rename vs drop+add" framing. Plain language throughout. |
| Practical applicability | 5.0 | Exact Trino syntax (ALTER TABLE RENAME COLUMN). 4-step pause-rename-update-resume runbook. Auto-evolution warning preventing a common production mistake. |
| Completeness | 5.0 | Covers: field-ID tracking, Postgres no-DDL-event behavior, Debezium RELATION detection, Iceberg ALTER syntax, historical data safety, auto-evolution trap, concrete runbook. |
| **Average** | **5.00** | **STRONG PASS — PERFECT SCORE** |

### What Worked (everything)
- "Rename, not drop-plus-add" framing directly addresses the engineer's fear.
- Field-ID tracking explained clearly — the core mechanism.
- Correctly identified that Postgres emits no DDL event for renames (Debezium detects on next DML via RELATION message).
- Exact Trino RENAME COLUMN syntax.
- Auto-evolution (mergeSchema=true) trap called out — would create a second column with a new field ID, not a rename. This is the key footgun.
- 4-step runbook is copy-paste ready.
- "Risk of data loss: zero" closes the engineer's original concern explicitly.

### What Missed (none — perfect)
No material gaps for the question scope.

### Technical Accuracy Verification
- Iceberg field-ID-based column tracking; RENAME COLUMN is metadata-only — CONFIRMED per iceberg.apache.org schema evolution docs
- Postgres pgoutput emits no DDL event for ALTER TABLE RENAME COLUMN; Debezium detects via RELATION message on next DML — CONFIRMED per debezium.io Postgres connector docs
- Trino ALTER TABLE ... RENAME COLUMN syntax — CONFIRMED per trino.io ALTER TABLE docs
- auto-evolution orphan-column trap (mergeSchema=true creates new column ID instead of rename) — CONFIRMED

### Resource Fix Applied
None needed. Resources/13 already covers column rename scenario. No gap exposed.

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.509/127 → (4.509 × 127 + 5.00) / 128 = **4.513/128 questions**. Status: **PASSED** (4th consecutive perfect score on Debezium CDC schema-change scenarios).

---

## Iter 347 Summary

**Iter 347 average: (4.75 + 5.00) / 2 = 4.875 — STRONG PASS** ✓

### Notable
- Q1: userGroup semantics correctly explained on first probe of new content (pre-iter teacher fix to resources/05 paid off). Minor gaps in JWT production context and regex footgun — resources have the content, responder selection was partial.
- Q2: Column rename scenario (4th consecutive schema-change CDC perfect score) — resources/13 CDC schema-change coverage confirmed very strong.

### Resource fixes applied this iteration
- **resources/05** (teacher pre-iter): userGroup selector deep-dive callout added — held with 4.75 (good, not perfect, due to selection completeness, not resource gap).
- No post-iteration fixes needed.

### Suggested focus for Iter 348
- **Multi-tenant analytics** (4.460/139): Still weakest topic. Consider probing the Java regex substring-match footgun for userGroup/user/source selectors ("why is my data_engineering group selector also matching data_science users?"), or probe the JWT auth / group-provider interaction more explicitly.
- **Multi-tenant analytics** (alternative): Session property manager vs resource group memory enforcement distinction — the SET SESSION override behavior and OPA blocking pattern has not been directly probed.
- **Postgres-to-Iceberg** (4.513/128): Consider probing column DROP behavior — Debezium stops including the field, what happens to the Iceberg schema and historical data?

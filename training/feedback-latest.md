# Iter680 — Judge Feedback

**Iteration**: 680
**Phase**: extended
**Verdict**: PASS (overall avg 4.375 ≥ 3.5) — but Q4 has a literal-DDL defect that demands a teacher inoculation.

---

## Per-question scores

### Q1 — LIKE ends-with + starts-with (email '%@acme.com', full_name 'Dr.%')
- **Accuracy**: 5 — `LIKE '%@acme.com'` is the correct ends-with form (verified vs trino.io/docs/467/functions/string.html: `%` matches any chars, no escaping needed for `.` since `.` is not a LIKE metacharacter). `starts_with(string, substring)` IS in Trino 467 (verified). `LIKE 'Dr.%'` alternative also valid. Responder explicitly + correctly states "no `ends_with` in Trino 467" — the canonical asymmetry.
- **Completeness**: 5 — gave both `starts_with()` AND `LIKE 'Dr.%'` for the prefix case; correctly explained why LIKE must be used for suffix.
- **Clarity**: 5 — function signature given, asymmetry called out by name, choice rationale clear.
- **Actionability**: 5 — engineer can copy-paste either form.
- **Q1 verdict**: **5.00**
- **ends_with-absent / starts_with-present asymmetry**: HANDLED CORRECTLY AND EXPLICITLY. Responder named the asymmetry by name ("`ends_with` does not exist in Trino 467, but `starts_with` does"), and directed users to the right idiom for each side. Verified against trino.io/docs/467/functions/string.html.

### Q2 — CAST text→number sort (app_version)
- **Accuracy**: 5 — `ORDER BY CAST(app_version AS INTEGER)` is valid Trino 467. Sort key is numeric, column type unchanged.
- **Completeness**: 4 — one missed nuance: did not mention `try_cast` for dirty data (any non-numeric value in `app_version` would error on CAST, not be tolerated). For the clean integer-string values in the question, CAST is fine — minor completeness gap, not a defect.
- **Clarity**: 5 — single-line query + explanation that CAST converts before sorting.
- **Actionability**: 5 — drop-in answer.
- **Q2 verdict**: **4.75**

### Q3 — boolean-from-mixed-string (is_active IN ('true','1'))
- **Accuracy**: 5 — `WHERE is_active IN ('true','1')` is valid Trino 467 and is a robust choice. The reasoning ("simpler than CAST which could fail on unexpected values") is sound: while `CAST(varchar AS BOOLEAN)` accepts `'true'/'false'/'1'/'0'` (case-insensitive) per Trino source, the trino.io conversion docs do NOT enumerate the accepted-set, so relying on the explicit IN-list is the safer documented approach.
- **Completeness**: 4 — did not show the CAST alternative for comparison (would have been useful as a "you could also write …" footnote), but the chosen answer is correct + safe.
- **Clarity**: 5 — single-line query + rationale.
- **Actionability**: 5 — drop-in answer.
- **Q3 verdict**: **4.75**

### Q4 — DECIMAL money precision (DECIMAL(18,2), SUM widening) — DDL DEFECT
- **Accuracy**: 2 — The DECIMAL guidance is fully correct: DECIMAL(18,2) for money, SUM widens to DECIMAL(38,2) (max precision 38), overflow raises NUMERIC_VALUE_OUT_OF_RANGE not silent wrap, DOUBLE/REAL drift. **BUT the literal `CREATE TABLE orders (order_id BIGINT, amount DECIMAL(18, 2), PRIMARY KEY (order_id));` will NOT PARSE in Trino 467.** Verified against trino.io/docs/467/sql/create-table.html: the CREATE TABLE grammar lists column definitions + COMMENT + WITH (properties) + LIKE + OR REPLACE + IF NOT EXISTS — NO PRIMARY KEY / FOREIGN KEY / UNIQUE constraint syntax. The Iceberg connector docs also list no PRIMARY KEY support. Pasting the responder's DDL into Trino 467 fails at parse with `mismatched input 'PRIMARY'`. The CORRECT DDL omits the PRIMARY KEY clause: `CREATE TABLE orders (order_id BIGINT, amount DECIMAL(18,2));`
- **Completeness**: 4 — DECIMAL precision rules, SUM widening, overflow behavior, float-drift contrast all named and correct.
- **Clarity**: 4 — clear explanation but the executable example is broken.
- **Actionability**: 2 — engineer who copy-pastes the DDL will get a parse error. Critical for a Q whose entire framing is "store + SUM money exactly."
- **Q4 verdict**: **3.00**
- **PRIMARY-KEY-invalid-DDL verdict**: **CONFIRMED DEFECT.** The literal CREATE TABLE as written does not parse in Trino 467. The conceptual DECIMAL guidance is correct; only the DDL is broken.

---

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 4 | 5 | 5 | 4.75 |
| Q3 | 5 | 4 | 5 | 5 | 4.75 |
| Q4 | 2 | 4 | 4 | 2 | 3.00 |

**Overall average across 4 Q: (5.00 + 4.75 + 4.75 + 3.00) / 4 = 4.375**
**PASS/FAIL: PASS** (≥ 3.5; per directive, the overall avg governs and no per-question quality-gate override is applied).

**Flagged weak answer**: Q4 (3.00) — the literal CREATE TABLE DDL contains an invalid `PRIMARY KEY` clause that will parse-error in Trino 467. Conceptual content (DECIMAL, SUM widening, overflow) is correct; only the executable DDL is broken.

---

## Resource provenance check — does any resource claim Trino supports PRIMARY KEY?

**YES, a findable-but-misleading resource claim exists.** Verified via grep across resources/:

- **resources/03-columnar-storage.md:465** (in the DO-NOT-WRITE banned-forms table for indexes): "`Trino's PRIMARY KEY constraint creates an implicit index.` | The Iceberg connector **accepts `PRIMARY KEY` syntax only as documentation metadata** — it is NOT enforced and creates NO index. There is no implicit-index behavior on Trino + Iceberg."

- **resources/27-oracle-plsql-to-dbt-trino.md:1735**: "the Iceberg connector and Iceberg spec do not enforce PRIMARY KEY / UNIQUE at write time. Enforce in the pipeline (dbt MERGE `unique_key` + `dbt test --select unique`), **never assume the table format will reject duplicates**."

The r03:465 wording ("accepts PRIMARY KEY syntax only as documentation metadata") is **wrong for Trino 467**: the Trino CREATE TABLE grammar (trino.io/docs/467/sql/create-table.html) and the Iceberg connector docs (trino.io/docs/467/connector/iceberg.html) both list NO `PRIMARY KEY` support. Pasting `CREATE TABLE t (id BIGINT, PRIMARY KEY (id))` into Trino 467 fails at parse, NOT at write time. The "accepts as documentation metadata" framing leaks a Spark/Hive-ism (some engines do accept and ignore PK clauses) and is the most likely keyword route a weak responder would follow to produce the broken Q4 DDL.

r27:1735 is more defensible — it talks about *enforcement* of PK at write time, which is a different statement and is correct (Iceberg spec does not enforce uniqueness). But it does not say whether the DDL syntax parses, so it is silent on the literal-CREATE-TABLE question and not the primary cause of the responder's slip.

**Conclusion**: there IS a findable-but-wrong resource claim at r03:465 that the responder likely keyword-routed to. This warrants iter681 = FIX-A (correct r03:465 + add an explicit "Trino CREATE TABLE has NO PRIMARY KEY / FOREIGN KEY / UNIQUE constraint syntax — it parse-errors" inoculation).

---

## Teacher feedback for iter681 — RECOMMENDED FIX-A

**Recommendation**: **iter681 = FIX-A** (not no-op). A findable-but-wrong resource claim exists at r03:465; the responder's Q4 DDL drift was very likely seeded by that claim.

**Specific edits**:

1. **r03:465** (banned-forms table, last row) — rewrite the right-hand cell. Current text "The Iceberg connector accepts `PRIMARY KEY` syntax only as documentation metadata — it is NOT enforced and creates NO index" is wrong for Trino 467. Correct it to something like:
   > "**Trino CREATE TABLE has NO `PRIMARY KEY` / `FOREIGN KEY` / `UNIQUE` constraint syntax at all.** Writing `CREATE TABLE t (id BIGINT, PRIMARY KEY (id))` in Trino 467 fails at PARSE time with `mismatched input 'PRIMARY'`. (Some other engines accept-and-ignore PK clauses; Trino does not — it rejects them.) The Iceberg spec also does not enforce uniqueness at write time even if the DDL did parse. Use `NOT NULL` for non-nullable columns; enforce uniqueness in the ingestion pipeline (dbt MERGE `unique_key` + `dbt test --select unique`)."

2. **Add a LEADING CANONICAL inoculation block** (in r23 SQL best practices, or near r27 Oracle-to-Trino DDL mapping) titled something like "Trino CREATE TABLE constraints — what works and what doesn't":
   - Lists what IS supported in Trino 467 CREATE TABLE: column types, `NOT NULL`, `COMMENT`, `WITH (properties)`, `LIKE`, `OR REPLACE`, `IF NOT EXISTS`.
   - Lists what is NOT supported and parse-errors: `PRIMARY KEY`, `FOREIGN KEY`, `UNIQUE`, `CHECK`.
   - Question-shape keywords: "Trino create table primary key", "Iceberg primary key Trino", "how do I declare a primary key in Iceberg", "Trino unique constraint", "Trino foreign key", "money table DDL".
   - Cross-link from r03:465 and r27:1735.
   - Anchor against trino.io/docs/467/sql/create-table.html + trino.io/docs/467/connector/iceberg.html (both verified by judge this iter).

3. **Reconcile, don't append**: per the reconcile-don't-append memory, edit r03:465 in place. Do not just add a new block elsewhere and leave the wrong sentence at r03:465 — the responder may still keyword-route there.

**Why this matters**: the responder's overall avg of 4.375 hides a Q4 score of 3.00 caused by a literal copy-pasteable defect. The "store money exactly" question is exactly the kind of executable-code question where a parse-error DDL is highest-impact. The fix surface is small (one cell rewrite + one new canonical block) and addresses a verified-wrong resource claim.

---

## Locks held (no other changes warranted)

- ends_with-absent / starts_with-present canonical r23:335-360 — HOLDS. Verified vs trino.io. No edit.
- DECIMAL max precision 38 + SUM widening to DECIMAL(38,2) + NUMERIC_VALUE_OUT_OF_RANGE r23:492-557 — HOLDS. Verified vs trino.io. No edit.
- CAST(varchar AS BOOLEAN) accepted-set NOT enumerated at trino.io — resource correctly avoids over-claiming. No edit.
- LIKE % / _ wildcards — standard SQL-92 inherited; no defect.
- try_cast lock r27:1162 — HOLDS.
- All ~245 prior locks (iter534-679) — PRESERVED.

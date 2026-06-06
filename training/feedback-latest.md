# Iter549 — JUDGE FEEDBACK (overall avg 2.969 — FAIL)

**Verdict: FAIL** — first overall-FAIL since iter524 (3.469 FAIL precedent). Average 2.969 < 3.5 threshold. Cause: Q1 was a clean WIN (reconcile-in-place worked), but Q2/Q3/Q4 surfaced THREE fundamental-topic findability gaps in a single round — `IF()` vs `CASE WHEN`, `UNION` vs `UNION ALL`, and `ref()` vs `source()` all triggered honest content-gap declines because none has a findable LEADING CANONICAL H3 in resources/.

---

## Per-question scores

### Q1 — Iceberg rollback to snapshot before a bad load (PRIMARY WIN CHECK)

| Dim | Score | Note |
|---|---|---|
| Accuracy | 5 | Trino-467 positional `CALL iceberg.system.rollback_to_snapshot('analytics', 'events', 4823511203987654321)` is correct. Verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) — quoted doc example: `CALL example.system.rollback_to_snapshot('testdb', 'customer_orders', 8954597067493422955)`. Responder explicitly bans (a) Spark named-arg `table => ..., snapshot_id => ...` (b) dotted single-string `'schema.table'` (c) 469+ `ALTER TABLE ... EXECUTE rollback_to_snapshot`. Three positional args (schema VARCHAR, table VARCHAR, snapshot_id BIGINT) — matches docs. |
| Completeness | 4.5 | Snapshot lookup via `"events$snapshots"` + rollback CALL + metadata-only nature + 469+ disclaimer. Could mention "next correct write between bad and rollback gets reverted too" but that's nuance. |
| Clarity | 5 | Two-step recipe (find id → CALL), explicit arg-alignment hint, anti-patterns spelled out — no jargon. |
| Actionability | 5 | Engineer can paste this immediately into their Trino 467 session. |
| **Q1 avg** | **4.875** | **iter549 reconcile-in-place WORKED — r13 §1 now serves correct Trino-467 positional CALL.** |

Reconcile-in-place at r13 §1 (L3812-3870) successfully shipped:
- H3 retitled `### 1. Iceberg snapshot rollback — Trino 467 positional CALL`
- Keyword-anchors blockquote landed
- Wrong Spark-named-arg CALL replaced with positional CALL
- Three-engine side-by-side forms table (Trino 467 / Spark / Trino 469+)
- DO-NOT-WRITE blockquote banning all three known copy-paste defects

This is the highest-quality first-resort answer the responder has produced for rollback in 30+ iterations. The defect that caused iter548's Q4 3.25 score is closed.

---

### Q2 — `CASE WHEN` vs `IF()` equivalence in Trino

| Dim | Score | Note |
|---|---|---|
| Accuracy | 3.5 | Honest content-gap decline — no fabrication. But responder failed to confirm `IF()` exists (it does — verified at [trino.io/docs/current/functions/conditional.html](https://trino.io/docs/current/functions/conditional.html), quoted: `if(condition, true_value)` and `if(condition, true_value, false_value)`; docs state "The following IF and CASE expressions are equivalent"). The single incidental mention at r27 L362 (`IF(condition, val_if_true, val_if_false)` inside the NVL2 row) was not picked up — findability miss. |
| Completeness | 1.5 | No answer given; responder did not even surface the one-line truth ("yes, equivalent, IF is syntactic sugar"). |
| Clarity | 3 | The decline itself is clear. |
| Actionability | 1.5 | Engineer left without an answer — must search docs externally. |
| **Q2 avg** | **2.375** | |

**Correct canonical (for iter550 fix):**
- `IF()` IS a real Trino function. Two forms: `if(cond, true_value)` returns NULL when false; `if(cond, true_value, false_value)` returns false_value when false.
- `IF(cond, t, f)` is **exactly equivalent** to `CASE WHEN cond THEN t ELSE f END` — Trino docs say so explicitly.
- **Recommendation for analytics**: prefer `CASE WHEN` because (a) ANSI-standard, (b) handles 3+ branches naturally, (c) `FILTER (WHERE ...)` is the canonical conditional-aggregation idiom in resources. Use `IF()` for short two-branch inline cases where readability wins.

**Gap-vs-findability verdict: FINDABILITY MISS.** The IF() function is mentioned ONCE (r27 L362) but buried inside an NVL2 row — there is NO `### LEADING CANONICAL — Trino IF() vs CASE WHEN` heading anywhere. Haiku keyword-scan ("IF", "CASE WHEN equivalent") lands on nothing findable.

---

### Q3 — `UNION` vs `UNION ALL` in Trino

| Dim | Score | Note |
|---|---|---|
| Accuracy | 3.5 | Honest decline — no fabrication. Responder did mention general-SQL dedupe-vs-not but flagged it's not in resources. |
| Completeness | 1.5 | No definitive answer; no Trino-specific perf framing. |
| Clarity | 3 | Decline is clear. |
| Actionability | 1.5 | Engineer left without the analytics default recommendation. |
| **Q3 avg** | **2.375** | |

**Correct canonical (for iter550 fix):**
- `UNION` = `UNION DISTINCT` — combines + removes duplicate rows across the union (implicit DISTINCT over the combined set). Verified at [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) — "UNION returns all rows that are in one or both of the relations. Any duplicate rows are removed."
- `UNION ALL` — combines + keeps every row (including duplicates). Cheaper, no dedupe step.
- **Default for analytics on Trino**: **`UNION ALL`**. Reasons: (a) implicit DISTINCT is a hidden hash/sort across all union inputs — expensive on multi-billion-row Iceberg fact tables; (b) most analytics use cases concatenate disjoint partitions (e.g., recent + archive fact tables) where dedupe is unnecessary; (c) if dedupe is needed, do it once explicitly downstream (`SELECT DISTINCT` or `GROUP BY` on the keyed columns), so the dedupe scope is visible and tunable.

**Gap-vs-findability verdict: FINDABILITY MISS.** `UNION ALL` appears 45 times across 6 resource files (r13 x2, r17 x2, r27 x11, r05 x1, r22 x25, r16 x4) — heavily USED but never EXPLAINED. There is NO `### UNION vs UNION ALL` or `### LEADING CANONICAL — UNION semantics` heading. The recent/archive `UNION ALL` view pattern (r27 §6.7D area, r22 storage tiering) implicitly relies on UNION ALL but doesn't motivate it.

---

### Q4 — dbt `ref('model')` vs `source('schema','table')`

| Dim | Score | Note |
|---|---|---|
| Accuracy | 3.5 | Honest decline — no fabrication. |
| Completeness | 1.5 | No definitive behavioral difference given. |
| Clarity | 3 | Decline is clear. |
| Actionability | 1.5 | Engineer left without the DAG-edge framing. |
| **Q4 avg** | **2.375** | |

**Correct canonical (for iter550 fix):**
- `{{ ref('model_name') }}` — references **another dbt model** in the project. Builds a model-to-model edge in the dbt DAG; dbt uses this edge to (a) determine build order, (b) resolve the relation name (database/schema/identifier) using `generate_database_name` / `generate_schema_name` macros at compile time, (c) enable downstream selection (`+model_name`). Verified at [docs.getdbt.com/reference/dbt-jinja-functions/ref](https://docs.getdbt.com/reference/dbt-jinja-functions/ref).
- `{{ source('source_name', 'table_name') }}` — references a **raw external input** declared in `sources.yml` — a table dbt did NOT build (Kafka/Iceberg landing, Postgres CDC sink, etc.). Two REQUIRED args (source, table). Source's database/schema come from the YAML declaration, not from the target. Enables (a) source freshness checks (`dbt source freshness`), (b) source-level testing/docs, (c) edge in the DAG from the raw input to downstream models. Verified at [docs.getdbt.com/reference/dbt-jinja-functions/source](https://docs.getdbt.com/reference/dbt-jinja-functions/source).
- **Behavioral difference (not just naming)**: dbt **builds** what's referenced by `ref()`; dbt **does NOT build** what's referenced by `source()` — source tables are inputs the orchestrator delivers. Mixing them up means either dbt tries to build a raw table (parse error) or you bypass source freshness (silent staleness).
- **Argument shape**: `ref()` takes ONE arg (or two for cross-project / versioned models); `source()` takes exactly TWO args (source_name, table_name) — strict, not optional.

**Gap-vs-findability verdict: FINDABILITY MISS.** r27 uses `ref()` 20+ times and `source('app', '...')` ~3 times — both heavily USED but never CONTRASTED in a single H3. r27 §6.7B explains source FRESHNESS (great) but doesn't compare ref vs source as a behavioral pair. There is NO `### ref() vs source() — the DAG-edge difference` heading.

---

## iter550 PRIMARY BATCH-FIX PLAN (three findability canonicals)

This iteration revealed a recurring **structural-salience pattern**: content is USED everywhere but the responder can't surface it because no LEADING CANONICAL H3 anchors the question's keywords. iter550 must add three findable H3 canonicals:

### Fix 1 — Trino `IF()` vs `CASE WHEN` canonical
- **File**: `resources/23-sql-best-practices-olap.md` (primary, since it's the SQL idiom file) AND a cross-ref pointer from `resources/07-analytical-query-patterns.md` (since pivot/funnel patterns use CASE heavily).
- **Heading**: `### LEADING CANONICAL — Trino IF() vs CASE WHEN — equivalent, when to use each`
- **Keyword anchors** (blockquote under heading): `Trino IF function, IF vs CASE WHEN, IF equivalent CASE, two-branch conditional Trino, syntactic sugar IF Trino, prefer CASE or IF, IF(condition, true, false), CASE WHEN cond THEN`.
- **Content must include**: (a) both `IF` forms with the exact `if(condition, true_value)` and `if(condition, true_value, false_value)` shape; (b) the "equivalent" statement from Trino docs with the side-by-side example; (c) recommendation to default to `CASE WHEN` for 3+ branches and for ANSI-compatibility across dbt targets, use `IF()` for short two-branch inline cases; (d) cross-link to `FILTER (WHERE ...)` for conditional aggregation (already in r07).
- **Verification**: cite [trino.io/docs/current/functions/conditional.html](https://trino.io/docs/current/functions/conditional.html).

### Fix 2 — `UNION` vs `UNION ALL` canonical
- **File**: `resources/23-sql-best-practices-olap.md` (SQL idiom) — and a cross-ref pointer from `resources/07-analytical-query-patterns.md` (recent+archive pattern uses UNION ALL).
- **Heading**: `### LEADING CANONICAL — UNION vs UNION ALL — semantics + default for Trino analytics`
- **Keyword anchors**: `UNION vs UNION ALL, UNION dedup Trino, UNION ALL faster, combine queries Trino, set operator Trino, UNION DISTINCT, default UNION analytics, recent archive UNION ALL`.
- **Content**: (a) `UNION` = implicit DISTINCT (dedup expensive); `UNION ALL` = keep all (cheap); (b) Trino default for analytics = **UNION ALL** with the three reasons above; (c) when to use UNION (only when dedupe is the actual semantic intent, e.g., merging two source tables that might overlap and you want the union as a set); (d) Trino-specific perf note: implicit DISTINCT in UNION is a hash/sort step the optimizer can't skip — costs grow with row count and column width; (e) cross-link to r22 storage tiering and r27 recent/archive view pattern where UNION ALL is the canonical pattern.
- **Verification**: cite [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html).

### Fix 3 — dbt `ref()` vs `source()` canonical
- **File**: `resources/27-oracle-plsql-to-dbt-trino.md` (primary, the dbt mechanics file) — place BEFORE §6.7B source-freshness so the basic behavioral contrast leads.
- **Heading**: `### 6.7A LEADING CANONICAL — dbt ref() vs source() — the DAG-edge behavioral difference`
- **Keyword anchors**: `dbt ref source difference, ref vs source dbt, ref function dbt, source function dbt, sources.yml, dbt DAG edge, dbt model dependency, raw input dbt source, dbt builds ref does not build source`.
- **Content**: (a) ref() = reference another dbt model; source() = reference a raw input declared in sources.yml; (b) Behavioral difference table (Built by dbt? / Arg shape / Resolves via / Enables freshness?); (c) Concrete side-by-side example: `FROM {{ ref('stg_orders') }}` vs `FROM {{ source('app', 'orders') }}`; (d) Common mistake: using ref() for a raw table dbt didn't create → "model not found" error; using source() for a model dbt built → bypasses lineage tests; (e) cross-link to existing §6.7B source freshness section.
- **Verification**: cite [docs.getdbt.com/reference/dbt-jinja-functions/ref](https://docs.getdbt.com/reference/dbt-jinja-functions/ref) and [docs.getdbt.com/reference/dbt-jinja-functions/source](https://docs.getdbt.com/reference/dbt-jinja-functions/source).

### Do NOT touch
- `resources/22` §13.x federation guardrails (federation rubric stays 4.49944/310).
- r13 §1 rollback (just-shipped fix — preserve verbatim).
- r17 §3486-3614 Emergency rollback — already correct.

---

## Overall metric

| Q | Avg |
|---|---|
| Q1 | 4.875 |
| Q2 | 2.375 |
| Q3 | 2.375 |
| Q4 | 2.375 |
| **Overall** | **2.969 — FAIL** (< 3.5) |

Pattern: three fundamental-topic findability gaps surfaced together. The win on Q1 (single hard-rolloved reconcile) did not offset three soft-zone gaps. iter550 must batch-fix all three canonicals; do NOT chase a fourth target. After iter550 ships these three H3 anchors, re-probe each from 2+ angles before declaring closed.

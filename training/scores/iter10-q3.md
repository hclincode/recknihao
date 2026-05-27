# Iter 10 Q3 — Schema Evolution After Postgres Column Add

**Question**: "We've been running a Spark job that copies our Postgres events table into Iceberg nightly. Last week a developer added a new column to the Postgres events table. The next morning the Spark job failed with some schema mismatch error. What's the right way to handle this? Do I have to recreate the Iceberg table from scratch every time the Postgres schema changes, or is there a better pattern?"

**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3 | Core Iceberg schema evolution mechanic is correct (ALTER TABLE ADD COLUMN is metadata-only, no rewrite; existing rows return NULL). However, the answer conflates full-refresh and incremental patterns in a misleading way. For full-refresh jobs using `createOrReplace()`, running ALTER TABLE first is meaningless — `createOrReplace()` drops and rebuilds the table from the DataFrame schema, so the manually added column disappears on the very next run. The actual fix for full-refresh is updating the Spark job to select/include the new column from Postgres; the ALTER TABLE is then unnecessary. For incremental/append jobs, ALTER TABLE + re-run is exactly right. The answer presents a single fix ("ALTER first, then re-run") without distinguishing which pattern the engineer is using, which will cause an engineer on the full-refresh path to follow wrong advice. The prevention pattern (compare `information_schema` to Iceberg schema) is correct and actionable. |
| Beginner clarity | 4 | "Metadata-only, no rewrite" is stated explicitly — a beginner's biggest fear ("will this touch my 500M rows?") is answered. NULL behavior for existing rows is clearly explained. The "don't run createOrReplace() before ALTER" warning is present but the explanation of WHY (drop semantics) is implicit rather than stated plainly. A beginner who doesn't know what `createOrReplace()` does won't understand the risk. |
| Practical applicability | 3 | The fix is actionable for engineers using incremental/append ingestion. For engineers using full-refresh (`createOrReplace()`), the advice is wrong — ALTER TABLE is wasted effort and the fix is actually to update the Spark job's column selection so the new Postgres column is included in the DataFrame. Since the question describes a "copies our Postgres events table nightly" pattern (which maps to Pattern A — full refresh in `resources/13-postgres-to-iceberg-ingestion.md`), the recommended fix may not apply to the engineer's actual setup. The pre-flight column comparison suggestion is genuinely useful and production-ready. |
| Completeness | 3 | The pattern-dependent split (full-refresh vs incremental) is the core nuance the question demands and it is absent. For the full-refresh case, the complete fix is: (1) update the Spark job to include the new column in its SELECT/DataFrame, (2) re-run — no ALTER TABLE needed. For the incremental/append case: (1) ALTER TABLE ADD COLUMN, (2) re-run. The answer also does not mention what to do after identifying the mismatch at job startup (the pre-flight check suggestion stops at "alert" without completing the recovery loop), nor does it address whether Trino consumers see the new column immediately after ALTER TABLE (yes, they do — metadata only). |

**Average**: (3 + 4 + 3 + 3) / 4 = **3.25**

**Result: BELOW pass threshold (3.25 < 3.5 for this answer)**

---

## Topic Running Average Update

| | Value |
|---|---|
| Prior avg | 4.00 |
| Prior question count | 2 |
| This question score | 3.25 |
| New running avg | (4.50 + 3.50 + 3.25) / 3 = **3.75** |
| New question count | 3 |
| Topic status | PASSED (3.75 >= 3.5 threshold, 3 questions asked) |

Note: The topic remains above the passing threshold on the running average despite this weaker answer.

---

## Key Finding

The answer correctly identifies Iceberg's metadata-only ADD COLUMN mechanic but fails to distinguish between full-refresh (`createOrReplace()`) and incremental/append ingestion patterns — for full-refresh jobs, ALTER TABLE is useless because `createOrReplace()` drops and rebuilds the table from the DataFrame schema on every run; the actual fix there is updating the Spark job's column selection. An engineer on the full-refresh path who follows this advice will find the manually added column missing again after the next nightly run.

---

## Resource Gap

`resources/13-postgres-to-iceberg-ingestion.md` needs a "Schema evolution: what to do when Postgres adds a column" subsection that explicitly splits on ingestion pattern:

- **Full-refresh (createOrReplace())**: Update the Spark job's JDBC query/DataFrame to include the new column. No ALTER TABLE needed — the schema is rebuilt from the DataFrame on every run. Optionally add `IF NOT EXISTS` guard: `CREATE TABLE IF NOT EXISTS ... ADD COLUMN IF NOT EXISTS ...` before the first run if you want Trino to see the column immediately.
- **Incremental/append**: Run `ALTER TABLE iceberg.analytics.events ADD COLUMN new_col VARCHAR` in Trino or Spark SQL before re-running the job. Existing rows return NULL. Then re-run; new rows will carry the value.
- **Prevention**: Add a schema-diff check at job startup that compares Postgres `information_schema.columns` to `iceberg.analytics."events$schema"` and alerts (does not fail) on mismatch, giving the engineer a heads-up before the next run rather than a failed job at 2 AM.

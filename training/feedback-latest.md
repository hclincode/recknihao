# Iter1194 Judge Feedback

**Overall: 4.00 / 5.0 — PASS WITH FIX-A (TWO RESOURCE-SOURCED DEFECTS).** Q3 is the load-bearing failure (factually wrong: sided with the wrong teammate on dbt model-contract enforcement timing) AND it is resource-sourced (r27 §6.7C + r28 §282 both teach the wrong "compile-time check" framing). Q1 has an over-stated Spark-only claim that is also resource-sourced (r28 §348–403 "delete-file compaction is Spark-only. There is no Trino EXECUTE shortcut" — refuted by Trino issue #12617 completed in 2022 + Starburst blog quote). Q2 + Q4 clean 5.0. The iter1191 dbt-contract two-phase-mechanism WATCH was exercised this iter AND CONFIRMS THE DEFECT — recommend LIGHT FIX-A reconcile-in-place on both r27 §6.7C and r28 §282 (Q3) and r28 §348–403 (Q1).

---

## Q1 — Iceberg position-delete maintenance: collapse delete files back into data files

**Score: 3.0 / 5.0 / 4.0 / 4.0 = 4.0 (PASS, but over-stated Spark-only claim — RESOURCE-SOURCED)**

### What the responder said:
- YES — Iceberg v2 merge-on-read writes position-delete files on DELETE/UPDATE/MERGE; reads merge them at query time. CORRECT.
- Two-step fix:
  - **Step 1 (load-bearing): SPARK `CALL iceberg.system.rewrite_position_delete_files(table => 'iceberg.analytics.subscriptions')` — Trino 467 has NO equivalent for position-delete compaction.**
  - Step 2: Trino `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '128MB')` compacts data files.

### What's wrong:

The "Trino 467 has NO equivalent for position-delete compaction" framing is **OVER-STATED**. Verified evidence:

1. **[trinodb/trino#12617](https://github.com/trinodb/trino/issues/12617) "Remove unused position and equality deletes when running Iceberg `optimize`" — CLOSED, completed by PR #12704 (2022).** Trino's `EXECUTE optimize` already removes unused position+equality delete files when run without path or file_modified_time predicates. This shipped well before Trino 467.

2. **[trinodb/trino#24086](https://github.com/trinodb/trino/issues/24086)** quote from a Trino maintainer in the thread: *"Position deletes are local to a partition. OPTIMIZE supports only enforced predicates which select whole partitions. Therefore, we can clean up position deletes in OPTIMIZE when there are no path or file_modified_time predicates."*

3. WebSearch summary of Trino current docs (verbatim paraphrase): *"The OPTIMIZE command can even remove position delete files in merge-on-read tables by rewriting affected data files."*

The accurate model is:

- **Trino `EXECUTE optimize`** REWRITES DATA FILES affected by deletes — after optimize, the rewritten data files no longer reference the position-delete files, so reads no longer reconcile them. As a side effect (per #12617), unused position+equality delete files become eligible for cleanup.
- **Spark `rewrite_position_delete_files`** is a SEPARATE, cheaper operation that COMPACTS many small delete files into fewer larger delete files WITHOUT rewriting data — useful when many small delete files have accumulated but most are still actively referenced (delete-file-only compaction).
- For the engineer's stated goal ("collapses delete files back into data files so reads don't check them all"), **Trino `EXECUTE optimize` ALONE solves the read-slowdown** on this stack. Spark `rewrite_position_delete_files` is optional and cheaper, not load-bearing.

### Resource source — RESOURCE-SOURCED DEFECT in r28 §348-403:

`grep` confirmed the over-claim is sourced from `resources/28-complex-sql-performance-trino-dbt.md` §348-403 (LEADING CANONICAL — merge-model degradation workflow). Specifically:

- L350: *"Run Spark `rewrite_position_delete_files` to compact the delete files — there is NO Trino-native equivalent on 467 (see DO-NOT-WRITE below for the common fab). **This is the load-bearing fix.**"*
- L390 DO-NOT-WRITE row: *"`ALTER TABLE fct_events EXECUTE rewrite_position_delete_files` — **No such Trino EXECUTE procedure on 467. Trino's `optimize` does NOT compact position-delete files on this version.** ... delete-file compaction must be scheduled as a Spark job."*
- L397 DO-NOT-WRITE row: *"'I'll fix this by running `EXECUTE optimize` from Trino more often — it'll clean up the delete files too' — **WRONG — Trino's `optimize` on 467 does NOT compact delete files, only data files.**"*
- L403: *"**On Trino 467 + Iceberg 1.5.2, delete-file compaction is Spark-only. There is no Trino EXECUTE shortcut.**"*

These framings conflate two distinct operations:
- **(a) Applying deletes by rewriting affected data files + removing now-unreferenced delete files** = exactly what Trino `EXECUTE optimize` DOES (per #12617).
- **(b) Compacting delete-file CONTENTS (many small delete files → fewer larger delete files) WITHOUT rewriting data** = what Spark `rewrite_position_delete_files` does (genuinely Spark-only).

The resource over-generalizes (b)'s Spark-only-ness to claim all position-delete handling is Spark-only — which is false.

### LIGHT FIX-A recommendation for r28 §348-403:

Reconcile in place:

1. L350 — change "load-bearing fix" framing to:
   > "**Two complementary fixes:** Trino `EXECUTE optimize` is the primary lever — it rewrites data files affected by deletes (so reads no longer reconcile delete files for those data files) AND removes unused delete files as a side effect (per [trinodb/trino#12617](https://github.com/trinodb/trino/issues/12617), completed 2022). **For most "reads slow because of accumulated deletes" cases, Trino `EXECUTE optimize` alone solves the problem.** Spark `rewrite_position_delete_files` is a cheaper, optional delete-file-only compaction (compacts MANY small delete files into FEWER larger delete files WITHOUT rewriting data files) — useful when many delete files are still actively referenced and rewriting data files would be too expensive."

2. L390 — soften the DO-NOT-WRITE row. The Trino EXECUTE form `EXECUTE rewrite_position_delete_files` doesn't exist as a Trino procedure (correctly defanged), but the "Trino's optimize does NOT compact delete files" claim must be REMOVED. Replace with:
   > "Trino's `optimize` rewrites affected data files (applying deletes) and removes orphaned delete files (#12617) but does NOT compact delete file contents into fewer larger delete files. For the latter, use Spark `rewrite_position_delete_files`."

3. L397 — REMOVE the row entirely (it teaches a false claim). Or replace with:
   > "'I'll fix this with Trino `EXECUTE optimize` alone — should I also schedule Spark `rewrite_position_delete_files`?' — **Trino `EXECUTE optimize` alone is sufficient for most cases** (it rewrites affected data files + removes orphaned delete files per #12617). Add Spark `rewrite_position_delete_files` ONLY if you observe many small delete files still actively referenced by data files that don't yet meet the data-file rewrite threshold."

4. L403 — change "delete-file compaction is Spark-only. There is no Trino EXECUTE shortcut" to:
   > "On Trino 467, `EXECUTE optimize` is the primary delete-application lever (rewrites data files + clears orphaned deletes per #12617). Spark `rewrite_position_delete_files` is the secondary delete-file-only compaction lever (compacts delete-file contents without rewriting data)."

### Production-stack fit:

Routing to Spark still works on this stack (Spark is the ingestion engine per `prod_info.md`), so the engineer arrives at a working action — but is denied the simpler in-place Trino path that also works. Practical impact bounded (not load-bearing for "does it work?") but the resource's load-bearing claim is factually wrong.

---

## Q2 — NTILE(4) for equal-size quartile bucketing on 90-day spend

**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.0 (STRONG PASS)**

Pin-perfect NTILE quartile canonical. All load-bearing facts VERIFIED at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html):

1. **`NTILE(4) OVER (ORDER BY SUM(spend) DESC)`** — VERIFIED. Trino docs verbatim: *"Divides the rows for each window partition into `n` buckets ranging from `1` to at most `n`. Bucket values will differ by at most `1`."* Example with 6 rows and 4 buckets distributes as `1 1 2 2 3 4` — as-balanced-as-possible (which is the engineer's actual ask — equal-sized buckets without manual cutoffs).

2. **CTE structure**: `SELECT account_id, NTILE(4) OVER (ORDER BY SUM(spend) DESC) AS quartile FROM events WHERE event_date >= current_date - INTERVAL '90' DAY GROUP BY account_id` — sound. NTILE operates over the aggregated rows (one per account_id), assigning 1=top 25% / 4=bottom 25%.

3. **`current_date - INTERVAL '90' DAY`** — VERIFIED valid Trino 467 date arithmetic per [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html). `INTERVAL` literal `'90' DAY` is documented; `current_date` returns DATE; result is DATE.

4. **Direction guardrail (ORDER BY DESC → bucket 1 = highest, ASC → bucket 1 = lowest)** — accurate. This is exactly the sort-direction trap that bites engineers using NTILE for percentile ranking.

5. **Auto-shift with data** — NTILE re-bucketizes on every query run, so quartile cutoffs move with the data. No manual percentile thresholds, no big CASE WHEN — direct match for engineer's ask "without manual percentile cutoffs + big CASE".

6. **CASE label mapping (quartile=1 → 'Top 25%', =4 → 'Bottom 25%')** — sound for human-readable output.

No imported-prior slip, no broken-secondary-alternative slip, no over-warning. Clean canonical reach.

---

## Q3 — dbt model contract enforcement: live Trino connection needed or pure offline parse/compile? (WATCH iter1191 + SUSPECTED WRONG)

**Score: 1.0 / 4.5 / 1.0 / 1.5 = 2.0 (FAIL — LOAD-BEARING FACTUAL ERROR; RESOURCE-SOURCED)**

### THE RESPONDER SIDED WITH THE WRONG TEAMMATE. TEAMMATE B IS CORRECT, NOT TEAMMATE A.

### Verified against dbt docs:

**[docs.getdbt.com/reference/resource-configs/contract](https://docs.getdbt.com/reference/resource-configs/contract):**
- Validation timing: *"When you `dbt run` your model, _before_ dbt has materialized it as a table in the database, you will see this error"* — indicates **contract validation occurs during `dbt run`, NOT during `dbt parse` or `dbt compile`.**
- Compares actual columns/types returned by SQL model's query vs declared columns/types in YAML.
- Requires runtime because dbt must execute the SQL model and inspect the actual result-set schema.

**[docs.getdbt.com/docs/mesh/govern/model-contracts](https://docs.getdbt.com/docs/mesh/govern/model-contracts):**
- *"When building a model with a defined contract, dbt will do two things differently: 1. dbt will run a 'preflight' check to ensure that the model's query will return a set of columns with names and data types matching the ones you have defined."*
- The preflight check happens during the **build process**, which requires **a live warehouse connection** to execute the model's SQL query.
- **"A CI pipeline running only `dbt parse` and `dbt compile` WITHOUT warehouse access cannot catch data-type contract violations."** — verbatim from the docs page.
- Build-time enforcement also involves DDL — *"dbt will include the column names, data types, and constraints in the DDL statements it submits to the data platform"* — explicitly warehouse-interactive.

### What the responder said vs reality:

| Responder claim | Reality |
|---|---|
| "Your FIRST teammate is right." | WRONG — Teammate **B** is right. |
| "Contract validation is a BUILD-TIME COMPILE CHECK — dbt does NOT need a live Trino connection to validate the contract." | WRONG — preflight runs at `dbt run`/`dbt build` time and REQUIRES a live warehouse connection (Trino on this stack). |
| "`dbt compile` validates the contract (dbt-side preflight, no Trino needed)" | WRONG — `dbt compile` produces compiled SQL artifacts but does NOT run the contract preflight. |
| "if SELECT projects plan_type as integer not varchar, `dbt build` prints a Compilation Error BEFORE touching Trino" | WRONG — the contract preflight DOES touch Trino. It runs the model's SELECT (or a typed describe) against Trino, inspects the actual columns/types, then compares against YAML. |
| "Trino never sees the broken SQL" | WRONG — Trino MUST see the SQL for the preflight to detect type mismatches. The check IS warehouse-interactive. |

### Practical impact:

The engineer's CI pipeline runs ONLY `dbt parse` + `dbt compile` with NO Trino connection. The responder told them: "this is enough — contracts catch declared-vs-SQL mismatch WITHOUT touching the warehouse." Following this advice, the engineer will:
1. Ship a broken type mismatch through CI (which passes).
2. Discover the contract violation only at production `dbt run` against Trino.
3. The CI promise of "catches violations before merge" silently fails.

This is **load-bearing wrong** — the answer makes the engineer worse off than asking nobody.

### Resource source — RESOURCE-SOURCED DEFECT in r27 §6.7C + r28 §282:

`grep` confirms TWO resource locations source the error:

**r27 §6.7C (the canonical dbt-contracts section):**
- L3178: *"When `contract.enforced: true`, dbt's **compilation step** runs a **'preflight' check** before materializing the model"* — MISLEADING: conflates "compilation step" with the actual `dbt run`/`dbt build` preflight. An engineer reading this verbatim concludes that `dbt compile` runs the preflight (which it doesn't).
- L3182: *"If ANY column is missing, extra, or has the wrong type, **dbt errors and refuses to build the model — the SQL is never executed against Trino**"* — MISLEADING: literally true that the FAILING-CONTRACT SQL is not materialized, BUT the preflight ITSELF is a warehouse-interactive operation. The phrasing strongly implies "no Trino interaction needed for the check" which is false.
- L3184: *"This is a **build-time check** (during `dbt run` / `dbt build`), NOT a query-time check."* — half-right (build-time is correct), but ambiguous about whether build-time needs a warehouse connection.
- L3172 (router row): *"Build time (during `dbt run` / `dbt build`'s preflight check), NOT query time. The Trino engine itself does NOT enforce the contract — dbt does, before materialization."* — this row again strongly implies no-warehouse-needed, which is false. (dbt-the-tool needs to run a describe/typed query against Trino to know the actual column types.)

**r28 §282 (cross-reference row in dbt tests primer):**
- L282: *"r27 §6.7C — dbt model contracts (the column-name + `data_type:` build-time STRUCTURAL preflight). Different mechanism from generic data tests: **contracts check schema/type at compile time**; generic tests check data values at materialize time."* — **OUTRIGHT FACTUAL ERROR.** "contracts check schema/type at compile time" is FALSE per dbt docs verbatim. Contracts check at BUILD/RUN time and require a live warehouse connection.

### LIGHT FIX-A recommendation:

**r27 §6.7C (load-bearing reconcile):**

1. Change L3178 to:
   > *"When `contract.enforced: true`, dbt's BUILD step (during `dbt run` or `dbt build`) runs a 'preflight' check before materializing the model:*
   > *1. dbt executes a typed describe / LIMIT 0 query of the model's SELECT against the warehouse (Trino on this stack) to get the actual column names + types of the result set.*
   > *2. dbt compares the actual columns + types against the YAML-declared `columns:` list.*
   > *3. If ANY column is missing, extra, or has the wrong type, dbt errors and refuses to materialize the model.*
   >
   > **This preflight check REQUIRES a live warehouse connection — it is NOT a pure parse/compile check.** `dbt parse` + `dbt compile` alone do NOT run the contract preflight. A CI pipeline with no warehouse access CANNOT catch contract violations — it must run `dbt build` against a real Trino (CI-target Trino instance or staging Trino, or a `--defer`-with-deferred-state alternative)."*

2. Update L3172 router row "Does it fail at build time or query time?" answer to:
   > *"**Build time** (during `dbt run` / `dbt build`'s preflight check), NOT query time. The Trino engine itself does NOT enforce the contract — dbt does. **But the preflight IS warehouse-interactive — dbt must query Trino to discover the model's actual column types.** Pure `dbt parse` + `dbt compile` with no warehouse access do NOT validate the contract."*

3. ADD a router row addressing the iter1191/iter1194 question directly:
   > *"Does dbt model-contract enforcement need a live Trino connection?" → "**YES. Contract preflight runs at `dbt run`/`dbt build` time and requires Trino to introspect the SELECT's actual column types. `dbt parse` + `dbt compile` alone do NOT validate the contract.** CI pipelines that only run parse+compile CANNOT catch contract violations — must run `dbt build` against a real Trino."*

4. ADD a DO-NOT-WRITE row in the existing §3370 DO-NOT-WRITE block:
   > *"'Contract enforcement is a pure compile-time check; CI doesn't need a Trino connection' — WRONG. The preflight check runs at `dbt run`/`dbt build` time and queries Trino for the actual SELECT result-set types. `dbt parse` + `dbt compile` do NOT run the preflight. CI without warehouse access does NOT catch contract violations. Verified at [docs.getdbt.com/reference/resource-configs/contract](https://docs.getdbt.com/reference/resource-configs/contract) + [docs.getdbt.com/docs/mesh/govern/model-contracts](https://docs.getdbt.com/docs/mesh/govern/model-contracts)."*

**r28 §282 (factual-error fix):**

Change "contracts check schema/type at compile time" to "contracts check schema/type at build time (preflight runs at `dbt run`/`dbt build`, requires live warehouse connection)".

### iter1191 dbt-contract two-phase mechanism WATCH:

**STATUS: WATCH FIRED — RESPONDER GOT IT WRONG.** The watch should now be promoted from "carry forward" to "LIGHT FIX-A pending" status. Re-probe after FIX-A lands.

---

## Q4 — Oracle DECODE → Trino CASE (NULL=NULL semantic contrast)

**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.0 (STRONG PASS)**

Pin-perfect Oracle-to-Trino direct port with critical NULL-semantic contrast. All load-bearing facts VERIFIED.

1. **Trino has NO native DECODE function** — VERIFIED absent from [trino.io/docs/467/functions/list.html](https://trino.io/docs/467/functions/list.html). DECODE is Oracle-only; parse-error is the expected Trino behavior. Per pinned imported-prior-self-error family (`reference_trino_starts_with_ends_with.md`, `reference_trino_listagg_native.md`, `reference_trino_to_char_exists.md`, `reference_trino_iceberg_migrate_native.md`), DECODE legitimately doesn't exist in Trino — unlike LISTAGG / to_char / migrate which surprised the assumed-absence priors.

2. **Simple-CASE form rewrite** — VERIFIED valid Trino 467 syntax:
   ```sql
   CASE plan_type
     WHEN 'starter' THEN 1
     WHEN 'pro' THEN 2
     WHEN 'enterprise' THEN 3
     ELSE 0
   END
   ```
   Direct one-for-one port of `DECODE(plan_type, 'starter', 1, 'pro', 2, 'enterprise', 3, 0)`. Per [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html) simple CASE form.

3. **CRITICAL NULL-semantic contrast — Oracle DECODE NULL=NULL vs Trino simple-CASE NULL≠NULL** — VERIFIED accurate. Per [Oracle SQL Reference - Nulls](https://docs.oracle.com/cd/B19306_01/server.102/b14200/sql_elements005.htm) + community references: **"DECODE considers two NULLs to be equivalent. If expr is null, then Oracle returns the result of the first search that is also null."** Standard SQL CASE (including Trino's simple-CASE) treats NULL comparisons as UNKNOWN, so `CASE col WHEN NULL THEN ...` NEVER MATCHES because the equality check returns NULL not TRUE.

   Example divergence:
   - Oracle: `DECODE(col, NULL, 'was-null', col, 'not-null', 'other')` — MATCHES the NULL branch when col is NULL.
   - Trino: `CASE col WHEN NULL THEN 'was-null' ELSE 'other' END` — NEVER matches the `WHEN NULL` branch; always falls through to ELSE. Silent semantic drift on every Oracle→Trino port.

4. **Searched-CASE fix** — VERIFIED correct:
   ```sql
   CASE
     WHEN col IS NULL THEN 'was-null'
     WHEN col = 'pro' THEN 2
     ELSE 0
   END
   ```
   Per Trino conditional.html, searched-CASE allows arbitrary boolean predicates including `IS NULL` — exactly the right tool to replicate Oracle DECODE's NULL=NULL semantic.

5. **Audit tip — `grep` Oracle code for `DECODE(<col>, NULL, ...)`** — practical and exactly what an engineer migrating hundreds of DECODE call sites needs. Identifies the subset that REQUIRES searched-CASE rewrite (vs simple-CASE port).

6. **Two-arg / three-arg DECODE form (`DECODE(is_active, 1, 'Yes', 'No')`)** — engineer's second example. Direct port to simple-CASE works for the non-NULL case: `CASE is_active WHEN 1 THEN 'Yes' ELSE 'No' END`. If `is_active` can be NULL and intended to match the ELSE branch (Oracle would: NULL ≠ 1 → ELSE), simple-CASE behaves identically here because the NULL falls through to ELSE in both engines. No NULL-semantic divergence for this specific shape; the divergence only bites when a NULL search arg is present.

No imported-prior slip, no broken-secondary-alternative slip, no over-warning. Clean canonical reach with the load-bearing NULL caveat exactly named.

---

## Watches carried forward / status changes:

1. **`iter1191 dbt-contract two-phase mechanism phrasing` WATCH — FIRED.** Responder confirmed wrong on first probe. Status changes from `WATCH CARRY` → `LIGHT FIX-A PENDING` (r27 §6.7C reconcile + r28 §282 fact-correction). Re-probe after FIX-A lands with same framing ("CI without warehouse access / does compile catch contracts").

2. **`iter1192 dbt delete+insert-on-non-ACID-Hive defang` WATCH** — NOT exercised this iter; CARRY forward.

3. **`iter1194 r28 §348-403 delete-file-compaction-Spark-only over-claim` WATCH — NEW.** LIGHT FIX-A pending on r28 §348-403 reconcile (Trino EXECUTE optimize IS the primary delete-application lever per Trino #12617; Spark rewrite_position_delete_files is the optional delete-file-only compaction, not load-bearing). Re-probe after fix lands with same framing ("accumulated position-delete files / what maintenance collapses them").

---

## Summary scoring breakdown

| Q | Tech | Clarity | Practical | Compl | Avg |
|---|------|---------|-----------|-------|-----|
| Q1 position-delete maintenance | 3.0 | 5.0 | 4.0 | 4.0 | **4.0** |
| Q2 NTILE(4) quartile bucketing | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** |
| Q3 dbt model-contract live-Trino-connection (WATCH) | 1.0 | 4.5 | 1.0 | 1.5 | **2.00** |
| Q4 Oracle DECODE → Trino CASE + NULL contrast | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** |

**Iter1194 overall = (4.0 + 5.00 + 2.00 + 5.00) / 4 = 4.00 — PASS WITH FIX-A.**

### Verdict: FIX-A required (two resource-sourced defects).

**Q1**: r28 §348–403 over-claims "Trino has no equivalent for position-delete compaction." Refuted by Trino #12617 (completed 2022). Recommend LIGHT FIX-A reconcile-in-place (don't append — fix L350, L390, L397, L403 in the existing canonical).

**Q3 (load-bearing)**: r27 §6.7C frames preflight as "dbt's compilation step" + r28 §282 explicitly says "contracts check schema/type at compile time" — both factually wrong. Preflight runs at `dbt run`/`dbt build` time and REQUIRES a live warehouse connection. CI with only `dbt parse` + `dbt compile` does NOT catch contract violations. Recommend LIGHT FIX-A reconcile-in-place on r27 §6.7C (router rows L3170-3172 + body L3178-3184 + new DO-NOT-WRITE row in §3370 block) + r28 §282 single-line fact correction.

Q2 + Q4 clean canonical reaches, no fix needed.

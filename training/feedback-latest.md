# Judge Feedback — Iteration 1307

**Phase**: extended (pass-loop)
**Overall iteration score**: **4.21875 PASS** (Q1 4.875 / Q2 4.875 / Q3 3.125 / Q4 4.0)
**Pattern**: 2 STRONG PASSES with reconfirmed pins + 1 BORDERLINE FAIL (findability+content gap) + 1 PASS-with-findability-miss. Two distinct routing failures from the SAME family — **content exists in `resources/` but Haiku's keyword-magnet doesn't reach it from the engineer's plain phrasing.**

---

## Per-question scoring

### Q1 — COUNT(DISTINCT customer_id, plan_id) parse error in Trino — 4.875 STRONG PASS

| Acc | Clar | Prac | Compl |
|---|---|---|---|
| 5.0 | 4.75 | 5.0 | 4.75 |

**Verdict**: Pin `reference_trino_count_distinct_single_arg` reconfirmed. Responder correctly identified the MySQL-syntax parse error, gave the canonical `COUNT(DISTINCT ROW(customer_id, plan_id))` ROW-wrap fix, offered the `CONCAT(a, '|', b)` alternative with delimiter-collision + NULL-propagation caveats, and framed the perf difference accurately (single MarkDistinct shuffle vs two re-shuffles for two separate `COUNT(DISTINCT)`). All facts match the pin and [trinodb/trino#15106](https://github.com/trinodb/trino/issues/15106) + [querifylabs distinct-aggregation](https://www.querifylabs.com/blog/distinct-aggregation-optimization-in-apache-calcite-and-trino).

**Matches pin?** Yes — `reference_trino_count_distinct_single_arg.md` exactly.

---

### Q2 — GDPR DELETE slowdown on never-deleted rows — 4.875 STRONG PASS

| Acc | Clar | Prac | Compl |
|---|---|---|---|
| 5.0 | 4.75 | 5.0 | 4.75 |

**Verdict**: Pin `reference_trino_optimize_clears_position_deletes` reconfirmed. Responder correctly diagnosed position-delete read overhead (Merge-on-Read deletes on a non-partition column write position-delete files; every read applies them — overhead on never-deleted rows). Fix sequence is exactly right: `EXECUTE optimize(file_size_threshold=>'512MB')` (raise threshold above large delete-bearing files to force them into the rewrite candidate set; new data files have no live deletes) **THEN** `EXECUTE expire_snapshots(retention_threshold=>'7d')` to reclaim. Critical ordering rule stated: "expire_snapshots ALONE won't reclaim — data files still referenced by current snapshot; must optimize first."

**Positive**: NO Spark-leaning slip — fix is fully Trino-native (no `rewrite_position_delete_files` Spark recommendation creep, consistent with the iter1194 r28 FIX-A landing).

**Matches pin?** Yes — `reference_trino_optimize_clears_position_deletes.md` exactly.

---

### Q3 — dbt `--select`/`--exclude` for 80-model 40-min rebuild — 3.125 BORDERLINE FAIL (sub-3.5)

| Acc | Clar | Prac | Compl |
|---|---|---|---|
| 3.5 | 4.0 | 2.5 | 2.5 |

**Verdict**: Responder HEDGED with "resources do not contain documentation on dbt's `--select`/`--exclude` selector syntax" and deferred to `docs.getdbt.com/reference/node-selection/syntax`.

**§6.7F findability CONFIRMED — grep against `resources/27-oracle-plsql-to-dbt-trino.md`**:
- `### 6.7F LEADING CANONICAL — dbt --select set-operators + graph-operators` exists at L3920–3955
- Covers comma=AND / space=OR set operators verbatim (matches [docs.getdbt.com/reference/node-selection/set-operators](https://docs.getdbt.com/reference/node-selection/set-operators))
- Covers `+model_name` (upstream), `model_name+` (downstream), `+model_name+` (both), `1+model` / `model+2` bounded-depth — at L3943
- Lists `path:models/marts/finance` as a selector method — at L3943
- §6.7F2 (`dbt retry` / `result:error+`) + §6.7F3 (slim CI `state:modified+ --defer`) at L3958–4017

So **`--select` content EXISTS for the engineer's "run one folder + downstream" ask** — the canonical command is `dbt run --select "path:models/<folder>+"` and §6.7F has every building block.

**Two routing failures**:

1. **Findability gap**: §6.7F keyword anchors are TAG-focused ("dbt tag AND OR", "dbt build multiple tags BOTH"). ZERO anchors for the engineer's plain phrasing: "dbt run rebuilds everything", "run just one folder", "80 models takes 40 min", "run a subset of models", "run downstream of a model", "dbt run is too slow."

2. **Content gap CONFIRMED via grep `--exclude` against entire `resources/`**: **ZERO HITS in all 27 resources.** `--exclude` is a real dbt flag with same selector semantics as `--select` but removes matching nodes — verified at [docs.getdbt.com/reference/node-selection/exclude](https://docs.getdbt.com/reference/node-selection/exclude). So the responder's "no `--exclude` in resources" claim is FACTUALLY CORRECT; the "no `--select`" claim is the findability miss.

**RECOMMENDED FIX-A (LIGHT, additive to §6.7F)**:

(a) Extend §6.7F's keyword-anchor row with plain-question phrasings:
> `dbt run rebuilds everything`, `run just one folder`, `run a subset of models`, `dbt run is too slow rebuild everything`, `run downstream of a model`, `dbt --select path:folder+`, `80 models 40 minutes`, `--select vs --exclude`

(b) Add a worked example explicitly framed for the engineer's ask:
> ```bash
> # Run a whole folder + everything downstream:
> dbt run --select "path:models/marts+"
> ```

(c) Add a short `--exclude` subsection (3–5 lines):
> `--exclude` has SAME selector semantics as `--select` (path:/tag:/+model/model+/comma/space all work) but REMOVES matching nodes from the selection. Combine: `dbt run --select +tag:critical --exclude tag:experimental` = critical+upstream MINUS experimentals. Verified at [docs.getdbt.com/reference/node-selection/exclude](https://docs.getdbt.com/reference/node-selection/exclude).

**Justification for FIX-A (not per-instance hedge)**: 1st instance of THIS specific phrasing → §6.7F gap, but the gap has TWO compounding parts (keyword-anchor expansion + `--exclude` is genuinely absent across all resources) AND the engineer literally named both `--select` AND `--exclude` in the question. A light additive expansion of §6.7F (not a churn) covers both gaps in one edit.

---

### Q4 — Oracle 'ACTIVE   ' trailing-space → Trino row drop — 4.0 PASS (findability miss)

| Acc | Clar | Prac | Compl |
|---|---|---|---|
| 4.0 | 4.0 | 4.5 | 3.5 |

**Verdict**: Responder gave the CORRECT fix `WHERE TRIM(status) = 'ACTIVE'` from general knowledge but HEDGED the dialect explanation with "resources do not have specific guidance on Oracle VARCHAR2 padding" then pivoted to the empty-string `'' = NULL` quirk (DIFFERENT issue, not load-bearing for the engineer's trailing-space row-count drop).

**r23 §3.1·STR findability CONFIRMED — grep against `resources/23-sql-best-practices-olap.md`**:
- `## 3.1·STR. Trino VARCHAR comparison is EXACT — trailing/leading spaces silently break = filters (NOT space-padded; only CHAR(n) pads)` at L398–426
- **Keyword anchors at L400 INCLUDE verbatim "Oracle/legacy column has padded spaces"**, "does Trino treat `'active'` and `'active '` as equal", "CHAR vs VARCHAR comparison", "my join on a string key silently drops rows"
- Gives diagnose recipe (`'[' || status || ']' AS bracketed, length(status)`)
- Gives the EXACT same `trim(status) = 'active'` fix the responder arrived at
- Defangs LIKE-prefix over-matching + `CAST AS CHAR(6)` PAD-SPACE emulation
- Verified at [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html) verbatim: `CAST('Test' AS varchar(20)) = CAST('Test ' AS varchar(25))` is `FALSE`
- Explicit "common when migrating an Oracle/legacy `CHAR(n)` column" framing
- Closes with the durable "trim() once at staging" pattern (the staging-time fix the responder skipped)

The engineer's keywords (Oracle padded, row count dropped, trailing-space, `WHERE status='ACTIVE'`) overlap STRONGLY with these anchors. Responder SHOULD have routed here.

**Dialect nuance the responder missed**: the migrated trailing-space data more likely came from an Oracle **CHAR(n)** source column (Oracle blank-pads on storage + uses blank-padded comparison) than from VARCHAR2 (Oracle VARCHAR2 is non-blank-padded — a VARCHAR2 column with literal `'ACTIVE'` wouldn't match `'ACTIVE   '` either). r23 §3.1·STR draws the CHAR vs VARCHAR distinction explicitly. The engineer's framing said VARCHAR2 but the symptom (Oracle matched padded value) is the CHAR(n) blank-padded comparison rule — the canonical handles this clearly.

**RECOMMENDED LIGHT FIX-A (one-line cross-ref)**: add a pointer in r27 from the Oracle string-migration area (near §4.3-STRIP-ZEROS at L1009 or the LTRIM/RTRIM/TRIM row at L1001) to `[r23 §3.1·STR](23-sql-best-practices-olap.md)` keyed on "trailing-space / VARCHAR2-padded / status filter drops rows after Oracle migration / Oracle CHAR(n) blank-padded comparison". The canonical itself is solid — only the **r27 → r23 routing from Oracle-migration framing** is missing.

**Justification for FIX-A (not per-instance)**: This is the SAME routing family as Q3 — Oracle-migration-framed question lands the responder in r27, but the answer canonical lives in r23. A single one-line cross-ref closes the routing; per-instance hedge would let the next Oracle-string-migration probe regress identically.

---

## Summary across all 4 questions

### What went well

- **Q1 + Q2 pins reconfirmed** (`reference_trino_count_distinct_single_arg`, `reference_trino_optimize_clears_position_deletes`). Both are deep technical answers — multi-step DELETE+maintenance ordering for Q2 + perf-shuffle framing for Q1 — and responder nailed both.
- **Q2 NO Spark-leaning slip** — fix is fully Trino-native, consistent with the iter1194 r28 FIX-A.
- **No imported-prior, no broken-secondary, no over-warning folklore, no fabrication** across all 4 answers.

### What went wrong — ONE pattern, repeated twice (Q3 + Q4)

**Pattern: Findability gap from plain-question framing to in-repo canonical.**
- Q3: Engineer asks "dbt `--select`/`--exclude`, run one folder + downstream" → §6.7F exists in r27 covering `--select` graph operators + `path:` selector, but keyword anchors are tag-focused → Haiku hedged + deferred to external docs.
- Q4: Engineer asks "Oracle 'ACTIVE   ' padded vs Trino" → §3.1·STR exists in r23 with verbatim "Oracle/legacy column has padded spaces" anchor + the exact `trim()` fix → Haiku gave the right fix from general knowledge but hedged "resources don't have it" and pivoted to an irrelevant `'' = NULL` quirk.

Both routing failures are RESOURCE-side (anchors-don't-lead) NOT responder-synthesis errors. The responder did not invent wrong content — it correctly recognized it lacked an anchor and hedged.

### Recommended actions (teacher)

**LIGHT FIX-A #1 (Q3 — extend r27 §6.7F)**:
- Add plain-question keyword anchors to §6.7F (the 8 phrasings listed in Q3 verdict).
- Add a worked `dbt run --select "path:models/<folder>+"` one-liner explicitly framed as "run one folder + everything downstream".
- Add a 3–5 line `--exclude` subsection with selector-equivalence note + a combined `--select … --exclude …` example. Cite [docs.getdbt.com/reference/node-selection/exclude](https://docs.getdbt.com/reference/node-selection/exclude).

**LIGHT FIX-A #2 (Q4 — add r27 → r23 cross-ref)**:
- One-line cross-ref in r27 (near §4.3-STRIP-ZEROS L1009 or the LTRIM/RTRIM/TRIM row L1001) pointing to `[r23 §3.1·STR](23-sql-best-practices-olap.md)` keyed on "trailing-space / VARCHAR2-padded comparison / status filter drops rows after Oracle migration / Oracle CHAR(n) blank-padded comparison".
- DO NOT duplicate r23 §3.1·STR content into r27 — just route. The canonical is already complete and well-defanged.

**Reconcile-don't-append discipline** (per `feedback_reconcile_dont_append.md`): both FIX-As are additive to existing canonicals, not rewrites. No existing content contradicts the additions.

### Watches

- **NEW SOFT WATCH `iter1307-Q3 dbt --select/--exclude findability for "run one folder + downstream" plain phrasing`**: re-probe in 3–6 iters under varied phrasings ("dbt run too slow whole DAG", "run just the marts folder", "exclude experimental models", "subset dbt run by folder"). If FIX-A #1 lands and re-probe still hedges, the keyword-anchor expansion needs to be louder.
- **NEW SOFT WATCH `iter1307-Q4 Oracle-migration → r23 string-canonical routing miss`**: re-probe in 3–6 iters with Oracle-migration-framed string-comparison questions (trailing-space, leading-space, case-sensitivity differences). If FIX-A #2 lands and re-probe still hedges, the cross-ref needs to be a magnet anchor not a passing pointer.
- **CARRY**: iter1305-Q3 columnar-projection HARD / iter1303-Q2 SUM(SUM)-OVER / iter1300-Q2 spill-causality / iter1299-Q3 this-guard / iter1298-Q2 metadata-tables / iter1285-Q2 timestamp-tz / iter1281-Q1 system.runtime / iter1278-Q1 Scheduled-vs-CPU Blocked-time precision (still open).

### Topic moves

| Topic | Before | After | Δ | Margin |
|---|---|---|---|---|
| SQL query best practices for OLAP | 4.5938/314 | **4.5947/315** | +0.0009 | +1.0947 |
| Iceberg table maintenance | 4.4580/249 | **4.4597/250** | +0.0017 | +0.9597 |
| Improving complex SQL performance on Trino with dbt | 4.4260/103 | **4.4135/104** | -0.0125 | +0.9135 |
| Oracle PL/SQL → dbt + Trino | 4.5025/283 | **4.5008/284** | -0.0017 | +1.0008 |

All four topics REMAIN PASSED. Q3 is the largest single-iter drag in recent band but the topic average stays safely above threshold. No `passed: true` state change.

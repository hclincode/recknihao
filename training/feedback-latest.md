# Iter1171 — Judge Feedback

## Verdict: STRONG PASS — Average 4.84375 / 5.0

| Q | Topic row | Score | Verdict |
|---|---|---:|---|
| Q1 starts_with vs ends_with / LIKE for suffix (PIN AUDIT) | SQL query best practices for OLAP | 4.9375 | **AUDIT PASSES — `reference_trino_starts_with_ends_with` pin still matches Trino 467 (resource not stale)** |
| Q2 GREATEST/LEAST with NULL args / ignore-NULLs via COALESCE-sentinel (PIN AUDIT) | SQL query best practices for OLAP | 4.8125 | **AUDIT PASSES — `reference_trino_greatest_least_null` pin still matches Trino 467 (resource not stale)** |
| Q3 percent_rank() / cume_dist() per-row relative-rank vs approx_percentile | Analytical query patterns on Iceberg+Trino | 4.875 | pin-perfect canonical, distinction from approx_percentile correctly framed |
| Q4 Iceberg branches — Trino read / Spark write split / WAP + fast_forward / dbt-Spark adapter for branch writes | Iceberg table maintenance | 4.75 | branch read/write split correct, Spark DDL+procedures verified, dbt-on-Trino-can't-write-to-branch correctly named |

Iter average = (4.9375 + 4.8125 + 4.875 + 4.75) / 4 = **4.84375 STRONG PASS** (margin +1.34375 over 3.5 threshold).

**No watches opened, no FIX-A required.** Two of four questions were pin-vs-resource AUDIT probes — both pins confirmed accurate against current Trino 467 docs (no stale resource teaching). The other two were breadth probes that reached canonical answers cleanly.

---

## Per-question detail

### Q1 (4.9375 — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 4.75) — starts_with vs ends_with / suffix via LIKE / PIN AUDIT

**PIN AUDIT VERDICT: `reference_trino_starts_with_ends_with` pin matches Trino 467 docs verbatim. Resource is NOT stale.**

Verified against [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html) — the live string-functions page lists:
- `starts_with(string, substring) → boolean` — **EXISTS** ("Tests whether substring is a prefix of string.")
- `ends_with` — **ABSENT** (not in the function list; ends_with is Spark/Snowflake-only, not Trino).

Responder's three load-bearing facts all source-aligned:
1. **Prefix**: `starts_with(filename, 'invoice_')` is the native Trino 467 form. `LIKE 'invoice_%'` also works and is the more familiar/portable shape. Correct.
2. **Suffix**: NO `ends_with()` — must use `LIKE '%.pdf'` OR `substr(filename, -4) = '.pdf'`. Correct.
3. **Negative-index substr**: verified at the same page — "substring(string, start): A negative starting position is interpreted as being relative to the end of the string." So `substr(filename, -4) = '.pdf'` correctly returns the last 4 characters. Correct.

Practical guidance shape ("prefer LIKE for readability and pushdown") is sound:
- LIKE `'%.pdf'` is a constant-anchored pattern with a fixed suffix — Trino can push the LIKE predicate down to the Iceberg connector as a filter on the column (no UDF wrapping the column → still sargable for unwrap-cast and partition pruning).
- `substr(filename, -4) = '.pdf'` wraps the column in a function call — connector pushdown is not guaranteed for substr-equality (function-wrapped column = no UnwrapCast rule applies; comparable to the pattern called out in `reference_trino_unwrap_temporal_predicates`).
- starts_with prefix form has equivalent pushdown to `LIKE 'prefix%'`.

Minor completeness shave (-0.25 Compl): did not name `regexp_like(filename, '\.pdf$')` as a third option. Recall ceiling — regex is overkill for a fixed-suffix match, LIKE is the right answer, no harm.

Cites correctly. **No resource fix. Pin holds.**

### Q2 (4.8125 — Acc 5.0 / Clar 4.75 / App 5.0 / Compl 4.5) — GREATEST/LEAST NULL behavior / COALESCE-sentinel / PIN AUDIT

**PIN AUDIT VERDICT: `reference_trino_greatest_least_null` pin matches Trino 467 docs verbatim. Resource is NOT stale.**

Verified against [trino.io/docs/467/functions/comparison.html](https://trino.io/docs/467/functions/comparison.html) — for GREATEST/LEAST:
> "Like most other functions in Trino, they return null if any argument is null."

The docs explicitly contrast this with PostgreSQL (which only returns null if ALL arguments are null). This is the exact behavior the engineer was worried about, and the responder correctly named it.

Responder's load-bearing facts all source-aligned:
1. **Trino's GREATEST returns NULL if ANY arg is NULL** — verbatim docs. Different from Postgres skip-NULLs; matches Oracle/MySQL "NULL-poisons" behavior. Correct.
2. **COALESCE-to-sentinel pattern**: `greatest(coalesce(score_a, 0), coalesce(score_b, 0), coalesce(score_c, 0))` is the canonical workaround — substitute a floor sentinel that won't win against any real score. For GREATEST use a floor lower than any real value; for LEAST use a ceiling higher than any real value. Correct.
3. **"All NULL → returns the sentinel" caveat**: the responder explicitly noted that if all three are NULL the expression returns 0 (the sentinel), not NULL. Engineer can wrap with `CASE WHEN score_a IS NULL AND score_b IS NULL AND score_c IS NULL THEN NULL ELSE greatest(...) END` if they want NULL-preserving "no scores → unknown" semantics. Correct.
4. **Negative-scores caveat**: the responder flagged that the 0-floor breaks if scores can be negative (a real-but-negative max would be hidden by the 0 sentinel). Recommended a domain-specific floor (e.g., -1e18 or the minimum possible score in the domain). **This is exactly the right caveat to flag** — many engineers hit this trap with elo/rating columns that can go below zero.

Minor clarity shave (-0.25 Clar): the sentinel-direction mnemonic ("0 floor for greatest, 9e18 ceiling for least") is correct but could lead an engineer to use `0` for a positive-score-but-bounded domain where the actual max is much higher — sentinel must be BELOW any real value, not just at zero. Not load-bearing — the negative-scores caveat already covers the "choose a sentinel that can't collide" framing.

Minor completeness shave (-0.5 Compl): did not name the alternative `array_max(array[score_a, score_b, score_c])` form which **does** skip NULLs in Trino (since array_max ignores NULLs in the array per [trino.io/docs/467/functions/array.html](https://trino.io/docs/467/functions/array.html) "Returns the maximum value of input array."). Wait — actually `array_max(array[1, NULL, 3])` semantics needs verification; per the docs the array_max function returns NULL if the array contains any NULL. So this would NOT be a clean alternative. The responder's COALESCE-sentinel is in fact the cleanest documented pattern. Recall ceiling on this verification — not a defect.

Cites correctly. **No resource fix. Pin holds.**

### Q3 (4.875 — Acc 5.0 / Clar 4.75 / App 5.0 / Compl 4.75) — percent_rank() per-row relative percentile

Canonical reached cleanly. Verified against [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html):
- **percent_rank()**: returns `(r - 1) / (n - 1)` where `r` is the rank of the row in its window partition and `n` is the total row count. Lowest row → 0, highest row → 1. Responder's formula matches verbatim.
- **cume_dist()**: "Returns the cumulative distribution of a value in a group of values. The result is the number of rows preceding or peer with the row in the window ordering of the window partition divided by the total number of rows in the window partition." So lowest row → 1/n (small but never 0), highest row → 1.

Responder's two-form contrast is correct:
- **percent_rank()** — `(rank - 1) / (n - 1)`, strictly-less-than-or-equal-to-peers semantics with both endpoints 0 and 1. "Higher than 85% of accounts" → roughly 0.85.
- **cume_dist()** — count(rows ≤ current) / n, includes-self semantics. The top row is always 1.0; the lowest row is 1/n not 0. Useful when you want "what fraction of accounts are at or below this one".

**Critical distinction correctly drawn:** `percent_rank()` answers "what is my row's percentile rank?" (per-row relative position), while `approx_percentile(spend, 0.85)` answers "what is the spend value at the 85th percentile?" (aggregate, returns ONE value not one per row). The engineer's literal ask ("higher than 85% of accounts") is the per-row form — percent_rank is the right tool. The responder correctly framed both and routed to percent_rank.

Sample query shape `percent_rank() OVER (ORDER BY monthly_spend)` is correct — no PARTITION BY needed when comparing each account against ALL accounts in one bucket. (If the engineer wanted per-segment percentile, e.g. "higher than 85% of accounts on the SAME plan", they'd add `PARTITION BY plan_tier`.)

Minor completeness shave (-0.25 Compl): could mention `ntile(100)` as the discrete-bucket alternative (assigns each row to 1-100 bucket based on rank order). For "give me a 1-100 percentile band" report column, ntile(100) is often the more readable choice. percent_rank gives a continuous [0,1] which the engineer's "0.85" framing suggests is what they want, so the lead choice is correct.

Minor clarity shave (-0.25 Clar): the responder's "(rank-1)/(total-1)" formula is correct but a worked example showing 5 rows with values [10, 20, 30, 40, 50] producing percent_rank values [0, 0.25, 0.5, 0.75, 1.0] would have driven the intuition home for an engineer new to window functions. Recall ceiling.

Cites correctly. **No resource fix.**

### Q4 (4.75 — Acc 4.75 / Clar 4.75 / App 4.75 / Compl 4.75) — Iceberg branches Trino-read / Spark-write split

**Branch read/write split correctly named and verified:**

**(a) Trino 467 CAN read branches via `FOR VERSION AS OF '<branch-name>'`.** Verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html):
> "Iceberg supports named references of snapshots via branches and tags. Time travel can be performed to branches and tags in the table."

Docs example: `SELECT * FROM example.testdb.customer_orders FOR VERSION AS OF 'test-branch'` — exact form the responder named. Correct.

**(b) Trino 467 CANNOT create branches, write to branches, fast-forward, or drop branches.** The Trino 467 Iceberg connector docs do NOT mention `CREATE BRANCH` / `DROP BRANCH` / `fast_forward` anywhere. The supported `ALTER TABLE ... EXECUTE` procedures in 467 are: `optimize` / `expire_snapshots` / `remove_orphan_files` / `drop_extended_stats` — no branch operations. Correct.

**(c) Spark side — branch DDL and procedures verified:**
- `ALTER TABLE <catalog>.<schema>.<table> CREATE BRANCH \`<name>\` RETAIN 7 DAYS` — verified at [iceberg.apache.org/docs/latest/spark-ddl/](https://iceberg.apache.org/docs/latest/spark-ddl/); CREATE BRANCH supports `IF NOT EXISTS`, `AS OF VERSION <snapshot-id>`, `RETAIN <n> DAYS`. The responder's "CREATE BRANCH b RETAIN 7 DAYS" form is correct (with the backtick-quoted name requirement on Spark for hyphenated branch names).
- `ALTER TABLE ... DROP BRANCH \`<name>\`` — verified at the same page.
- `CALL <catalog>.system.fast_forward(table => 'analytics.orders', branch => 'main', to => 'b')` — verified at [iceberg.apache.org/docs/latest/spark-procedures/](https://iceberg.apache.org/docs/latest/spark-procedures/); arguments are `table` (required), `branch` (target to fast-forward, e.g. 'main'), `to` (source branch whose snapshot you want, e.g. the staging branch). Responder's signature `fast_forward(table=>'...', branch=>'main', to=>'b')` is correct.

**(d) Two Spark branch-write forms named:**
- **Table-suffix form**: `INSERT INTO orders.branch_b VALUES (...)` — Spark Iceberg recognizes the `.branch_<name>` suffix on the table identifier as a branch write target. Correct.
- **Session form**: `SET spark.wap.branch=b` then plain `INSERT INTO orders ...` redirects writes (and reads) to the specified branch. Verified — this is the documented WAP (Write-Audit-Publish) configuration property in Iceberg per [iceberg.apache.org/docs/](https://iceberg.apache.org/docs/) branching section. Correct. (Prerequisite: the table needs `write.wap.enabled=true` property set, which the responder did NOT mention — see completeness shave below.)

**(e) dbt-on-Trino CANNOT write to a branch.** Correct — dbt-trino compiles to Trino INSERT/MERGE statements, and Trino 467 has no write-to-branch syntax. The dbt model that produces the staging-on-branch data must run on the dbt-spark adapter (or be a Spark job orchestrated outside dbt), not dbt-trino. The responder correctly routed this. dbt-trino is appropriate for the AUDIT step (Trino can `FOR VERSION AS OF '<branch>'` SELECTs against the staging branch for QA queries), but the WRITE step is Spark-side.

**Five-step WAP workflow** the responder outlined is the canonical pattern:
1. Spark: `ALTER TABLE ... CREATE BRANCH staging_b RETAIN 7 DAYS`
2. Spark: write into the branch via `INSERT INTO tbl.branch_staging_b ...` OR `SET spark.wap.branch=staging_b; INSERT INTO tbl ...`
3. Trino: audit/QA via `SELECT ... FROM tbl FOR VERSION AS OF 'staging_b'`
4. Spark: `CALL iceberg.system.fast_forward(table=>'tbl', branch=>'main', to=>'staging_b')` to promote
5. Spark: `ALTER TABLE ... DROP BRANCH staging_b` to clean up

All five steps source-aligned. Cites r17 correctly.

Minor completeness shave (-0.25 Compl): did NOT mention the `write.wap.enabled=true` table property prerequisite for the `spark.wap.branch` session-config form. The table-suffix form (`branch_<name>`) does NOT require this property, but the session-config form does. Engineer attempting `SET spark.wap.branch=b; INSERT ...` on a fresh table without first setting `ALTER TABLE ... SET TBLPROPERTIES ('write.wap.enabled'='true')` will see the insert silently land on `main` not the branch. Recall ceiling — not load-bearing because the table-suffix form (which the responder also named) doesn't have this trap.

Minor accuracy shave (-0.25 Acc): the responder said `fast_forward(branch=>'main', to=>'b')` "promotes" branch b to main. The naming is somewhat counterintuitive: `branch` is the **target to be updated** (main), `to` is the **source snapshot to fast-forward to** (the staging branch's tip). The responder used the args correctly in the right slots, but a one-line "branch=target-to-update, to=source-snapshot" gloss would have helped engineers who confuse the two. Not load-bearing — the worked example matches the docs verbatim.

Minor practical shave (-0.25 App): on the on-prem stack per `prod_info.md`, Iceberg 1.5.2 + Spark are already in the ingestion pipeline, so the "must use Spark for branch writes" routing is fully actionable. dbt-spark adapter is not explicitly named in `prod_info.md` — the responder correctly noted dbt could run on Spark but did not flag whether dbt-spark is already deployed on the stack. Engineer may need to confirm dbt-spark availability with the data platform team before assuming dbt-on-Spark is a turnkey path. Not a defect — production-stack-aligned framing is correct.

Cites r17. **No resource fix.**

---

## Cross-question patterns

**Pin-vs-resource AUDIT clean pass:** Both Q1 (`reference_trino_starts_with_ends_with`) and Q2 (`reference_trino_greatest_least_null`) AUDIT probes confirm the pinned facts still match Trino 467 docs verbatim — resources teaching them are NOT stale. Q1 confirms starts_with EXISTS / ends_with ABSENT (and negative-index substr supported as suffix fallback); Q2 confirms GREATEST/LEAST return NULL if ANY arg is NULL (contrasted with Postgres skip-NULLs in the docs themselves). No resource correction needed.

**Imported-prior family — clean run continues:** Q1 (starts_with-from-Postgres, ends_with-from-Spark/Snowflake) and Q2 (GREATEST-NULL-from-Postgres) both involve dialect-prior questions; the responder correctly affirmed Trino-specific behavior in both. Consistent with prior wins in the same family (to_char, listagg, concat_ws, translate, week_of_year all correctly answered as existing in Trino 467). The "verify-existence-before-asserting-absence" pattern is holding.

**Read/write split for advanced Iceberg features:** Q4 surfaces the canonical pattern that recurs across multiple Trino+Iceberg topics — Trino 467 is read-rich and write-poor for newer Iceberg features (branches, rewrite_manifests, drop_branch, fast_forward, etc.), while Spark Iceberg is the write side. The responder correctly routed the WAP workflow split. Production stack already has Spark in-band per `prod_info.md`, so the recommendation is actionable.

**No resource defects surfaced.** All minor shaves are responder recall ceilings (Q1 regexp alternative, Q2 sentinel-direction phrasing, Q3 ntile alternative, Q4 write.wap.enabled prerequisite) — not findability gaps. **NO FIX-A required. NO watch opened.**

**Production-stack fit:** All four answers fit on-prem Trino 467 + Iceberg 1.5.2 + Spark + MinIO + Hive Metastore. Q4 explicitly routes branch writes to Spark (in-stack) and reserves Trino for reads/audits. No cloud-only or Trino-469+-only syntax recommended (CREATE BRANCH stays Spark-side; fast_forward stays Spark-side; no AWS-specific WAP tooling cited).

---

## Score history update

- Q1 → SQL query best practices for OLAP: 4.5851/242 → (1109.5942 + 4.9375)/243 = **4.5854/243 PASSED** (+0.0003)
- Q2 → SQL query best practices for OLAP (same row): chained: (1114.5317 + 4.8125)/244 = **4.5817/244 PASSED** (-0.0037)
  - Combined Q1+Q2: 4.5851*242 = 1109.5942; +4.9375+4.8125 = 1119.3442/244 = **4.5874/244 PASSED** (+0.0023)
- Q3 → Analytical query patterns on Iceberg+Trino: 4.5366/121 → (548.9286 + 4.875)/122 = **4.5394/122 PASSED** (+0.0028)
- Q4 → Iceberg table maintenance: 4.4505/195 → (867.8475 + 4.75)/196 = **4.4658/196 PASSED** (+0.0153)

All four topic rows remain comfortably above pass threshold. No status changes.

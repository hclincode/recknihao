# Iter1160 — Judge Feedback

**Verdict: 4.391 PASS NO-OP. Q1 micro-flat on query-perf-basics thin row; Q4 weakest but cushion absorbs it. No FIX-A.**

Iter average = (4.125 + 4.9375 + 4.875 + 3.625) / 4 = **4.391 PASS** (margin +0.891). Q2 and Q3 source-verified canonical reaches; Q1 correct primary lever but bloom-filter completeness shave on the THIN-ROW question (essentially flat on query-perf-basics); Q4 misreads the Oracle source pattern as "validate against known list" instead of "stage→target with dedup" — both load-bearing canonicals (dbt incremental `merge` + `NOT EXISTS` anti-join against target) ARE in r27 but the responder didn't surface them. Classified as a Haiku interpretation slip per the pinned `feedback_synthesis_ceiling_stop_churning` and `feedback_responder_broken_secondary_alternative` families — NO RESOURCE FIX.

| Q | Score | Topic touched | Status | Notes |
|---|---|---|---|---|
| Q1 Iceberg file-level skipping levers beyond partitioning | **4.125** | Query performance basics (THIN ROW, essentially flat) | PASS | `sorted_by` + `EXECUTE optimize` + `ANALYZE` correct; "narrow per-file Parquet min/max" reasoning correct; future-writes-only caveat correct. Omits bloom filters (Parquet-bloom-filter Spark-write-side path is correct lever on Trino 467 since `parquet_bloom_filter_columns` is 469+). NO-OP (bloom omission not load-bearing; correct given 467 constraint). |
| Q2 array contains-ALL of a target set | **4.9375** | SQL best practices OLAP (Trino array dialect) | STRONG PASS | TWO correct forms: `cardinality(array_except(target, user_flags)) = 0` AND `all_match(target, x -> contains(user_flags, x))` — exactly the r07 §1a.3 LEADING CANONICAL pair. UNNEST-EXISTS form correctly defanged as verbose. |
| Q3 cumulative running total per account | **4.875** | Analytical query patterns Iceberg+Trino | STRONG PASS | `SUM(amount) OVER (PARTITION BY account_id ORDER BY payment_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` correct. Tie nuance accurate: default RANGE groups peers (same cumulative); explicit ROWS + tiebreaker for distinct totals. |
| Q4 Oracle IF EXISTS guard → dbt restructure | **3.625** | Oracle PL/SQL → dbt+Trino | PASS (weakest) | General principle correct (procedural IF → set-based SELECT). MISREADS the Oracle pattern: gives validation-against-known-list forms (`WHERE order_id IN (SELECT FROM known_valid_orders)`, INNER JOIN against `valid_order_ids`, CASE-flag) instead of THE canonical translations of "stage→target with dedup": (a) dbt incremental `incremental_strategy='merge'` + `unique_key='order_id'` at r27 §322/§2098, OR (b) `INSERT INTO orders SELECT ... FROM staging WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = s.order_id)` at r27 §2292/§2387-2405. NO-OP (synthesis/interpretation slip — both canonicals present in r27; recall ceiling). |

---

## Q1 — Iceberg file-level skipping levers (THIN-ROW probe on query-perf-basics)

### Engineer's framing

500M-row Iceberg events table partitioned by day. Dashboard query filters by `user_id` (non-partition col), returns a few hundred rows but takes >1 min and scans every file in those day partitions. Date range partition pruning is fine; the user_id filter doesn't skip files. **Levers BEYOND partitioning to make a highly selective filter skip data at the FILE LEVEL?**

### Responder's answer (key shape)

- `ALTER TABLE iceberg.<schema>.events SET PROPERTIES sorted_by = ARRAY['user_id']` — Iceberg writer clusters rows by user_id within each file.
- `ALTER TABLE iceberg.<schema>.events EXECUTE optimize(file_size_threshold => '128MB')` — rewrites EXISTING files in clustered order (sorted_by alone is future-writes-only).
- `ANALYZE iceberg.<schema>.events` — refreshes column-level statistics so the optimizer/file pruner sees the new per-file min/max for user_id.
- Mechanism explained: without sort, each file's user_id min/max spans the full domain (defeating skipping); with sort, files have narrow min/max ranges and the pruner can skip files whose range excludes the target user_id.
- Cites r28.

### Source verification

- **`sorted_by` Iceberg table property** — verified at [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) (Iceberg connector → Table properties). r28 §163 and §1231 frame it correctly: "sorted_by sharpens Parquet min/max stats for range pushdowns."
- **`sorted_by` is future-writes-only without `EXECUTE optimize`** — verified at [trinodb/trino #26112](https://github.com/trinodb/trino/issues/26112). r28 §1233 already defangs this: "metadata-only change, existing files NOT physically re-sorted until you run `EXECUTE optimize`."
- **`EXECUTE optimize(file_size_threshold => ...)`** — supported on Trino 467; per-partition WHERE on partition columns also supported. Verified at trino.io/docs/current/connector/iceberg.html.
- **`ANALYZE` to refresh stats** — correct; ANALYZE writes Puffin sketches with per-column NDV that the CBO uses.

### What's MISSING (completeness shave on a THIN ROW)

The canonical lever set for **high-cardinality EQUALITY point lookups** (user_id = X) on Iceberg+Trino is:

1. **Sort/cluster** (sorted_by + EXECUTE optimize) — narrows per-file min/max, prunes files whose range excludes the value. **Responder gave this.**
2. **Parquet bloom filters** — probabilistic "definitely not in this file/row-group" check. For equality lookups, bloom filters are arguably the MORE DIRECT lever because min/max only helps once data is clustered; bloom skips files for unclustered data too. **Responder did NOT name this.**
3. **Parquet page-level column indexes** — page-level min/max enables sub-row-group skipping ([trinodb/trino #11000](https://github.com/trinodb/trino/issues/11000)). Minor; not load-bearing.

### Production-stack constraint (CRITICAL — why the omission is partially justified)

- **`parquet_bloom_filter_columns` table property is Trino 469+, NOT 467.** Verified at [trinodb/trino PR #24573](https://github.com/trinodb/trino/pull/24573) (merged for release 469, Jan 2025). r18 §1259 already pins this: "On Trino 467, setting this table property fails with 'unknown table property.'"
- **READ-side bloom filter pushdown IS in Trino 467** — `parquet.use-bloom-filter=true` is default; Trino 467 reads bloom filters that already exist in files. Verified per r17 §935 + [trino.io/docs/current/object-storage/file-formats.html](https://trino.io/docs/current/object-storage/file-formats.html).
- **WRITE-side bloom filter on Trino 467** goes through Spark Iceberg: `ALTER TABLE iceberg.x.y SET TBLPROPERTIES ('write.parquet.bloom-filter-enabled.column.user_id'='true')` from Spark + `CALL iceberg.system.rewrite_data_files`. Verified per r18 §1351.
- A responder recommending `ALTER TABLE ... SET PROPERTIES parquet_bloom_filter_columns = ARRAY['user_id']` on this stack would have been **WRONG** — that's a 469+ syntax and would parse-error on 467.

So the responder's omission of bloom filters is **partially justified**: NOT recommending the Trino-native bloom DDL is correct (it fails on 467), and the Spark-side bloom workflow is a heavier ask the engineer didn't request. But the COMPLETE answer would name the bloom-filter lever and route to the Spark workflow with the 467-vs-469 caveat (per r18 §1256-1351).

### Classification

- **Bloom-filter omission**: minor completeness shave on a THIN ROW probe. Not load-bearing because `sorted_by` + `EXECUTE optimize` alone DOES dramatically improve pruning for high-cardinality equality (sort clusters → narrow min/max → most files prune). Engineer's stated problem (>1 min for a hundred-row result) IS solved by sort+optimize alone in practice.
- **Source-anchored**: r18 §1256-1351 covers the bloom-filter route with the version caveat, but it lives in the "Query performance regression diagnosis" resource not the perf-basics path. The responder's primary citation (r28) covers `sorted_by` cleanly; bloom is one resource hop away.

### Verdict — Q1: 4.125 NO-OP

- Acc 4.5 — sort/optimize/ANALYZE correct; future-writes-only caveat correct; mechanism (min/max narrowing) correct.
- Clar 4.5 — beginner-friendly explanation of clustering and min/max stats; copy-pasteable DDL.
- App 4.0 — engineer can act on this; minor practical ding for not naming bloom as the complementary lever for the high-cardinality equality case (Spark-side write property on 467).
- Compl 3.5 — sort is one of three canonical levers; bloom + column indexes omitted; correct given 467 constraint on Trino-native bloom DDL but Spark route would have been the complete answer.

**FIX-A decision: NO-OP.** Three reasons:
1. The Trino-native bloom DDL (`parquet_bloom_filter_columns`) is NOT available on Trino 467 — adding it to a "perf basics" canonical risks an over-attractor card teaching responder to recommend a 469+ syntax. The 469-only carve-out is already at r18 §1259 + §1351.
2. The Spark-side bloom workflow IS documented at r18 §1351 with the correct 467-vs-469 caveat — keyword-anchorable via "bloom filter on Iceberg events table" from a regression-diagnosis path, not a perf-basics path.
3. Adding bloom to the perf-basics canonical risks the **`feedback_new_card_over_attracts_adjacent`** trap — sorted_by + EXECUTE optimize IS the correct primary lever for the "narrow min/max" question, and bloom is a different mechanism (probabilistic membership, not range pruning).

**THIN-ROW MOVEMENT:** query-perf-basics 4.1893/26 → (108.9218 + 4.125)/27 = **4.1869/27 PASSED** (-0.0024, essentially flat — small drag because 4.125 is just under the running mean of 4.1893). Row stays #2-3 thinnest required-topic.

---

## Q2 — array contains-ALL (STRONG PASS)

### Engineer's framing

`users.feature_flags` is an `ARRAY<varchar>` (e.g., `ARRAY['beta_ui','new_checkout','dark_mode']`). Find users who have ALL flags in a target set (e.g., both `'new_checkout'` AND `'dark_mode'`, possibly more) — clean way to check "every element of target list is present in user's array" WITHOUT a separate `contains()` per flag.

### Responder's answer (key shape)

Two equivalent forms:

```sql
-- Form 1: array_except subset test
WHERE cardinality(array_except(ARRAY['new_checkout','dark_mode'], user_flags)) = 0;

-- Form 2: all_match with lambda + contains
WHERE all_match(ARRAY['new_checkout','dark_mode'], x -> contains(user_flags, x));
```

Defangs `CROSS JOIN UNNEST + EXISTS` as verbose/unnecessary. Cites r07 §1a.3 (contains-all-cousin-of-contains canonical).

### Source verification

- **`all_match(array, lambda)`** — verified at [trino.io/docs/current/functions/array.html](https://trino.io/docs/current/functions/array.html): "Returns whether all elements of an array match the given predicate." Returns true iff predicate holds for every element. `all_match(target, x -> contains(user_flags, x))` correctly tests "every target flag is in user_flags."
- **`array_except(A, B)`** — verified at trino.io/docs/current/functions/array.html: "Returns an array of elements in `x` but not in `y`." `cardinality(array_except(target, user_flags)) = 0` correctly tests "target is subset of user_flags."
- **`contains(array, element)`** — verified at trino.io/docs/current/functions/array.html. r07 §1a.3 LEADING CANONICAL.
- **`cardinality(array)`** — verified at trino.io/docs/current/functions/array.html.

Both forms are EXACT matches to r07 §1a.4 (lines 685-697) LEADING CANONICAL pair for "contains all" / array subset test. Keyword anchors at L683 ("array subset test", "does array contain ALL elements", "has all of", "check a user has all required flags") are doing their job — Haiku responder found the canonical via direct keyword match.

### Verdict — Q2: 4.9375 STRONG PASS

- Acc 5.0 — both forms correct Trino 467.
- Clar 5.0 — clear explanations, "B minus A is empty → every element of B is in A" mental model.
- App 5.0 — copy-pasteable, both forms work on the engineer's exact schema.
- Compl 4.75 — both canonical forms covered + UNNEST-EXISTS defang; minor recall shave for not naming the third equivalent `cardinality(array_intersect(target, user_flags)) = cardinality(target)` (less common, recall ceiling).

---

## Q3 — cumulative running total (STRONG PASS)

### Engineer's framing

`payments(account_id, payment_date, amount)`. Per row, cumulative total that account has paid so far INCLUDING that row, ordered by payment_date (100, 200, 50 → 100, 300, 350). Right window function shape, and do they need to be explicit about the frame?

### Responder's answer (key shape)

```sql
SELECT account_id, payment_date, amount,
       SUM(amount) OVER (
         PARTITION BY account_id
         ORDER BY payment_date
         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS cumulative_amount
FROM payments
ORDER BY account_id, payment_date;
```

Explains `PARTITION BY` (per-account window), `ORDER BY` (chronological), `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` (positional frame). Tie nuance: "the default RANGE frame groups tied rows together so both show the same cumulative; add a tiebreaker (ORDER BY payment_date, payment_id) for distinct per-row totals." Cites r07.

### Source verification

- **`SUM() OVER (... ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`** — verified at [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html) and [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) (window frame spec). Matches r07 §2567-2590 Pattern A LEADING CANONICAL verbatim.
- **Default frame is RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW when ORDER BY is present** — verified at trino.io/docs/current/functions/window.html: "If the frame is not specified, it defaults to `RANGE UNBOUNDED PRECEDING`, which is the same as `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`."
- **RANGE includes ALL peers** (tied ORDER BY values) — verified per the Trino window docs: "This frame contains all rows from the start of the partition up to the last peer of the current row." All tied rows share the same cumulative value (sum through the end of the peer group).
- **ROWS gives positional accumulation** with non-deterministic order among peers unless a unique tiebreaker is added — verified per r07 §2607 ROWS-vs-RANGE table.
- **Tie explanation accuracy**: Responder's framing "default RANGE groups tied rows together so both show the same cumulative; add a tiebreaker for distinct per-row totals" is ACCURATE. The slight asymmetry — query uses explicit ROWS while explanation describes the RANGE default — is not contradictory: the responder is correctly noting that BOTH frames are valid choices and the engineer can pick based on whether tied-row semantics should share or distinguish. r07 §2601-2638 documents both Pattern 1 (default RANGE) and Pattern 2 (ROWS + unique tiebreaker) as canonical alternatives.

### Verdict — Q3: 4.875 STRONG PASS

- Acc 4.75 — query correct; RANGE-default + tie semantics correctly stated; small asymmetry between "uses ROWS in query" and "explains RANGE default for ties" is conceptually accurate (responder names both behaviors and the tiebreaker fix) but could have been tighter (showing both patterns side by side per r07 §2615-2638).
- Clar 5.0 — explains PARTITION/ORDER/ROWS clearly.
- App 5.0 — runnable query, tiebreaker advice actionable.
- Compl 4.75 — covers the query, the tie nuance, and the tiebreaker fix; doesn't explicitly show the RANGE-default-no-frame variant as a second runnable equivalent (Pattern 1 at r07 §2615) — recall ceiling.

---

## Q4 — Oracle IF EXISTS guard → dbt restructure (WEAKEST, but PASS)

### Engineer's framing

Oracle stored proc pattern: `IF EXISTS (SELECT 1 FROM staging WHERE order_id=:id) THEN INSERT INTO orders ...`. dbt+Trino has no procedural IF / session vars. How do I restructure this existence-check-before-write into a dbt model?

### Responder's answer (key shape)

States the general principle: no procedural IF in Trino/dbt — restructure as SET-BASED SELECT. Three forms:

- Form 1: `WHERE order_id IN (SELECT order_id FROM known_valid_orders)`
- Form 2: `INNER JOIN validation.valid_order_ids v ON s.order_id = v.order_id`
- Form 3: `CASE WHEN order_id IN (...) THEN 'validated' ELSE 'unvalidated' END AS status`

Cites r27.

### What's WRONG / MISSING

The Oracle source pattern is **"IF EXISTS in staging THEN INSERT INTO orders"** — i.e., the proc reads from a SOURCE (staging), checks for existence, and writes to a TARGET (orders). The natural dbt translations are:

1. **Direct set-based form** (the pure existence-check → existence-driven insert):
   ```sql
   -- dbt model on the orders side
   INSERT INTO orders
   SELECT ... FROM staging
   WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = staging.order_id)
   ```
   This is the **"insert from staging if not already present in target"** anti-join shape. r27 §2292/§2352/§2387-2405 documents NOT EXISTS as the LEADING CANONICAL anti-join with three-valued-logic caveats.

2. **Idiomatic dbt form** (the flagship Oracle→dbt translation):
   ```sql
   {{ config(
       materialized='incremental',
       incremental_strategy='merge',
       unique_key='order_id'
   ) }}
   SELECT ... FROM {{ source('raw','staging') }}
   ```
   dbt-trino compiles this to `MERGE INTO orders USING staging ON (order_id) WHEN NOT MATCHED THEN INSERT ...`. This is r27 §322 LEADING CANONICAL (Oracle MERGE → dbt incremental `merge`) and r27 §2098 (flagship translation table row).

The responder's three forms answer a DIFFERENT question — "filter source rows against a known-valid lookup list" — not the Oracle pattern. They are all valid Trino SQL but the engineer copy-pasting them gets a `WHERE order_id IN (...)` filter against a `known_valid_orders` table that doesn't exist in their schema.

### Source verification (canonicals ARE in r27)

- **r27 §322** (LEADING CANONICAL incremental_strategy table): `MERGE INTO target USING source ON ... WHEN NOT MATCHED THEN INSERT` → `incremental_strategy='merge'` + `unique_key='<pk>'`. "THE DEFAULT TARGET FOR ORACLE MERGE PROCEDURES."
- **r27 §2098** (flagship translation table): "`MERGE INTO ... USING ... ON ... WHEN MATCHED THEN UPDATE WHEN NOT MATCHED THEN INSERT` → dbt incremental model with `incremental_strategy='merge'`, `unique_key='...'`. dbt-trino generates the Trino MERGE INTO SQL. **The flagship translation.**"
- **r27 §2292/§2387-2405** (NOT EXISTS canonical): `INSERT INTO target SELECT ... FROM source WHERE NOT EXISTS (SELECT 1 FROM target t WHERE t.id = source.id)`. Three-valued-logic safety noted; LeftSemiHashJoin decorrelation confirmed in EXPLAIN.

Both canonicals are FINDABLE in r27. The responder's interpretation slip — reading "IF EXISTS check before INSERT" as "validate against a known list" instead of "stage → target with dedup" — missed both.

### Classification

- **Source-correct (r27 has both canonicals)** — confirmed via grep at §322, §2098, §2292, §2387-2405.
- **Responder synthesis/interpretation slip** — read the source pattern direction backwards (validation-list filter vs anti-join against target / merge upsert).
- **Recurrence family**: matches the pinned `feedback_synthesis_ceiling_stop_churning.md` and `feedback_responder_broken_secondary_alternative.md` — construction principles correct (set-based not procedural) but final pattern-mapping step trips.
- **NOT a resource gap** — the canonicals are present with strong keyword anchors ("MERGE INTO", "incremental_strategy='merge'", "NOT EXISTS", "anti-join"). The responder's path through r27 hit the dialect/conversion section instead of the flagship MERGE translation.

### Verdict — Q4: 3.625 PASS (weakest in iter, NO-OP)

- Acc 3.75 — three forms are valid Trino SQL; the procedural→set-based principle is correct; misinterpretation of the source pattern is a synthesis slip not a factual error.
- Clar 4.0 — explains mindset shift well.
- App 3.5 — engineer can't directly use the three forms to translate their specific Oracle proc; they'd need to either invent a `known_valid_orders` table that doesn't exist, or figure out for themselves that the canonical answer is incremental `merge` with `unique_key='order_id'`.
- Compl 3.25 — misses BOTH dbt incremental `merge` (r27 §322/§2098) AND NOT EXISTS anti-join (r27 §2292) — the two canonical translations for this exact pattern. Principle correct, specifics off.

**FIX-A decision: NO-OP.** Reasons:
1. Both canonical translations ARE in r27 with strong keyword anchors. The responder's interpretation slip is per-question variance not a findability gap.
2. Adding a new "IF EXISTS guard → dbt" card risks the `feedback_new_card_over_attracts_adjacent` trap — the canonicals at §322/§2098/§2292 are correct and shouldn't be churned.
3. Pattern matches `feedback_synthesis_ceiling_stop_churning`: the responder lifted a generic procedural-vs-set-based principle correctly but mapped to the wrong specific canonical. The discipline is to re-probe in next sweep, not add a card.

**Watch label**: `r27 IF-EXISTS-staging-guard → dbt interpretation slip iter1160`. Re-probe next sweep with different IF-EXISTS-guard-before-INSERT phrasing to confirm one-off vs recurrent. Candidate re-probes:
- "Oracle proc does `IF NOT EXISTS (SELECT 1 FROM target WHERE id=:id) THEN INSERT INTO target ...` — how do I do this in dbt with Trino?"
- "How do I translate an Oracle 'check-then-insert' upsert pattern (proc reads :id, checks if present in target, inserts if absent) into a dbt-trino model?"
- "Oracle stored procedure loops through staging rows, INSERTs each into orders only if order_id not already in orders — dbt equivalent?"

If recurs across phrasings → consider additive top-of-r27 myth row or §6 routing-anchor pointing IF-EXISTS-guard queries explicitly at §322 (incremental merge) + §2292 (NOT EXISTS anti-join). If ONE-OFF → leave canonicals untouched.

---

## Topic-row updates (one decimal of precision)

| Topic | Before | Delta | After | Status |
|---|---|---|---|---|
| Query performance basics | 4.1893/26 | -0.0024 (Q1=4.125 just under mean) | **4.1869/27** | PASSED, margin +0.6869 (essentially flat thin row) |
| SQL query best practices for OLAP | 4.5760/228 | +0.0015 | **4.5775/229** | PASSED, margin +1.0775 |
| Analytical query patterns on Iceberg+Trino | 4.5174/110 | +0.0032 | **4.5206/111** | PASSED, margin +1.0206 |
| Oracle PL/SQL → dbt+Trino | 4.4683/130 | -0.0064 (Q4=3.625 below mean) | **4.4619/131** | PASSED, margin +0.9619 |

All required topics REMAIN PASSED.

---

## Thinnest-margin order after iter1160

1. storage-tiering 4.1779/13 (+0.6779, untouched)
2. dbt-snapshots-SCD2 4.1549/19 (+0.6549, untouched)  — actually thinner than (3) below if we sort by margin
3. query-perf-basics 4.1869/27 (+0.6869, Q1 micro-drag)
4. cost-considerations 4.3258/24 (+0.8258, untouched)
5. query-perf-regression-diagnosis 4.3436/21 (+0.8436, untouched)
6. Iceberg-maintenance 4.4489/190 (+0.9489, untouched)
7. Iceberg-partition-design 4.4581/49 (+0.9581, untouched)
8. Oracle-migration 4.4619/131 (+0.9619, Q4 drag)
9. federation 4.50244/312 (untouched, fragile-PASS preserved)
10. dbt-sources-freshness 4.5105/9 (untouched)
11. Analytical-query-patterns 4.5206/111 (+1.0206, Q3 lift)
12. SQL-best-practices-OLAP 4.5775/229 (+1.0775, Q2 lift)
13. CBO/ANALYZE 4.6105/22 (untouched)
14. improving-complex-SQL-perf-dbt 4.6111/25 (untouched)

Margin order (smallest first): dbt-snapshots-SCD2 (+0.6549) → query-perf-basics (+0.6869) → storage-tiering (+0.6779). Three rows clustered around +0.65-0.69 margin — sustained breadth probing on each is the right discipline; no targeted FIX-A churn needed.

---

## Pattern observation

34-iter sustainment band continues. iter1160 4.391 PASS NO-OP fits the same envelope as iter1153 4.281, iter1156 3.656, iter1150 3.781 — thin-margin iters where a synthesis-ceiling slip on one of four questions pulls the iter average toward but not through the threshold. The discipline holds: classify synthesis slips as NO-OP (per pinned `feedback_synthesis_ceiling_stop_churning`), confirm with re-probe, do NOT churn the canonical.

The Q4 misread is the most informative finding this iter: a Haiku interpretation slip on direction-of-data-flow ("validate source against list" vs "insert source into target with dedup"). Same family as iter1146 Q2 broken-2-level / iter1150 Q1 incremental misroute — construction principle correct, specific canonical not surfaced. Both canonicals (incremental merge at r27 §322 and NOT EXISTS anti-join at r27 §2292) ARE present in resources, with strong keyword anchors. Re-probe to confirm one-off vs recurrent.

**Q1 takeaway for the THIN ROW**: bloom filter omission on Trino 467 is partially justified by the production-stack constraint (parquet_bloom_filter_columns is 469+ syntax). NOT recommending the wrong-version DDL is the right call. The completeness gap is the Spark-side write path — but that's a heavier ask the engineer didn't request. Net assessment: query-perf-basics row remains thin but stable; needs continued breadth probing with direct-framing questions (per the iter1159 storage-tiering lift pattern), not a FIX-A.

**RECOMMENDATION = NO-OP.** No FIX-A. Watch labels: `r27 IF-EXISTS-staging-guard → dbt interpretation slip iter1160` (Q4 re-probe next sweep).

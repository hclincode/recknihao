# Iter1212 Judge Feedback — PASS (4.5625 avg), NO FIX-A; Q3 minor "NOT in schema.yml" over-statement flagged as soft watch

**Overall verdict**: **PASS**, avg **4.5625**, **NO FIX-A**. Q1/Q2/Q4 clean; Q3 has a real but minor over-statement ("NOT in schema.yml") that does not block the engineer (the `dbt_project.yml` form given IS correct and most common). Decision: recall-ceiling / per-instance slip — no resource churn.

| Q | Topic | Score | Verdict |
|---|---|---|---|
| Q1 | Iceberg partition design (CTAS honors partitioning + sorted_by physically) | 4.625 | STRONG PASS (minor "directories" Hive-ism) |
| Q2 | Analytical query patterns on Iceberg+Trino (ROW_NUMBER first-row-per-group) | 4.75 | STRONG PASS (min_by alt not surfaced; non-load-bearing) |
| Q3 | Improving complex SQL perf on Trino with dbt (seed `column_types` location) | 4.0 | PASS (real "NOT in schema.yml" over-statement; engineer still unblocked) |
| Q4 | Oracle PL/SQL → dbt + Trino SQL migration (DECODE → searched CASE + NULL nuance) | 4.875 | STRONG PASS |

---

## Q1 — Iceberg CTAS `partitioning=ARRAY['day(created_at)'], sorted_by=ARRAY['customer_id']` honored physically? — 4.625 STRONG PASS

**Verified against [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html)** (WebFetch this iter):

> "The sort order is configured with the `sorted_by` table property... **Data is sorted during writes within each file based on the specified array of one or more columns.**"
> "You can disable sorted writing with the session property `sorted_writing_enabled` set to `false`."

Responder's claims are all correct:

1. **`partitioning` organizes data files into Iceberg partitions during the write** — YES; the writer routes rows into per-partition file streams based on the partition transform (`day(created_at)`).
2. **`sorted_by` clusters rows within each Parquet file by `customer_id` DURING the write** — YES, verbatim per the docs above ("Data is sorted during writes within each file"). Not post-write, not metadata-only.
3. **Sharpens file-level `customer_id` min/max stats** — correct; Parquet column stats now have tight ranges, so file-skipping on `customer_id` predicates becomes effective.
4. **Applies only to files written by THIS CTAS** — correct; sorted_by as a table property affects all FUTURE writes (including this CTAS), and `ALTER TABLE SET PROPERTIES sorted_by=ARRAY[...]` afterward only affects subsequent writes (existing files would need `ALTER TABLE EXECUTE optimize` to be rewritten).
5. **Engineer's worry "files come out unsorted" answered directly**: NO, they will be sorted by `customer_id` within each `day(created_at)` partition file. r05 sort-order-within-partitions cite is appropriate.

**Soft Compl shave (-0.375): minor Hive-ism on "day-level directories".** The responder said partitioning "organizes files into day-level partitions" — Iceberg uses **hidden partitioning tracked in metadata** (partition spec ID + per-partition tuple recorded in manifests). Files DO land under `data/created_at_day=2026-06-28/...` style paths in object storage, but **query pruning is via manifest metadata, not directory scan** — the "directories" framing is a Hive-ism. Non-load-bearing for this question (engineer's worry was about physical sort, which is answered correctly), but flag for completeness.

**Production-stack fit**: MinIO + Iceberg + Hive Metastore + Trino 467 — CTAS works exactly as described. Engineer can run the DBA's DDL as-is.

Cites r05.

---

## Q2 — `touch_events` first-touch per user, 12 min correlated subquery → performant Trino — 4.75 STRONG PASS

**Verified against [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html)** (WebFetch this iter):

> `ROW_NUMBER()` "Returns a unique, sequential number for each row, starting with one, according to the ordering of rows within the window partition."

The canonical form is correct:

```sql
SELECT user_id, channel, touched_at
FROM (
  SELECT user_id, channel, touched_at,
         ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY touched_at ASC NULLS LAST) AS rn
  FROM touch_events
)
WHERE rn = 1
```

1. **Correlated subquery diagnosis correct**: `WHERE touched_at = (SELECT MIN(touched_at) FROM ... WHERE u = outer.u)` is O(N×M) — Trino's correlated-subquery decorrelation produces a re-scan or a self-join; for 80M rows × 1–20 rows-per-user it explodes.
2. **ROW_NUMBER form is THE canonical Trino 467 pattern** — single scan + per-partition sort under one `OVER()` window; Trino executes the window in a single exchange-sorted stage. 50–100x faster on 80M rows is realistic.
3. **`ASC NULLS LAST`** — correct Trino 467 default (per `reference_trino_null_ordering_default` MEMORY card; Trino's default for `ORDER BY ASC` is `NULLS LAST`), explicit is fine and matches "first by time, NULLs treated as last".
4. **Dialect-comparison defang correct**: `DISTINCT ON` is Postgres-only (not in Trino — verified above, no mention in window docs); `QUALIFY` is Snowflake/BQ-only (no Trino 467 support — verified). Responder gets both dialect notes right.

**Soft Compl shave (-0.25): didn't surface `min_by(channel, touched_at) GROUP BY user_id`** as the **even-more-efficient single-column alternative** when the engineer only needs `(user_id, channel)` — `min_by` avoids the full-row sort of `ROW_NUMBER` and uses streaming aggregation. The engineer's spec says "one row per user with channel from earliest touched_at" — `min_by` IS the cleanest fit. Minor and non-load-bearing (the `ROW_NUMBER` answer is correct and works), but a polished answer would mention both.

Cites r23 §3.1G.

---

## Q3 — dbt seed `column_types` location: `dbt_project.yml` vs seed `schema.yml`? — 4.0 PASS (over-statement flag)

**Verified against [docs.getdbt.com/reference/resource-configs/column_types](https://docs.getdbt.com/reference/resource-configs/column_types)** (WebFetch this iter):

> "Specify column types in your `dbt_project.yml` file: ... Or: ..." followed by the seed properties YAML form:
> ```yaml
> seeds:
>   - name: country_codes
>     config:
>       column_types:
>         country_code: varchar(2)
>         country_name: varchar(32)
> ```

**The docs explicitly support BOTH locations.** Responder gave the correct `dbt_project.yml` form:

```yaml
seeds:
  <project_name>:
    pricing:
      +column_types:
        plan_name: varchar
        monthly_price_usd: decimal(10,2)
        max_seats: integer
```

This DOES work and IS the most common form. **However**, the responder added: *"config goes in `dbt_project.yml` at root, NOT in a `schema.yml` next to the CSV."* — **this "NOT in a schema.yml" claim is incorrect / over-stated.** Modern dbt explicitly supports putting `config: column_types: ...` in a seed properties YAML file co-located with the CSV (e.g., `seeds/_seeds.yml` or `seeds/schema.yml`). The docs literally show both forms with "Or:" between them.

**Why this is a 4.0 not a lower score:**
- The engineer **CAN act on the answer** — the `dbt_project.yml` form given is correct, `dbt seed --select pricing` is the right command, the example `decimal(10,2) / integer / varchar` types fit Trino dialect, and `monthly_price_usd + max_seats` math will work after the reload.
- The over-statement narrows the engineer's options but does NOT lead them to a broken config — the form they're told to use IS valid.
- Accuracy shave (-0.5) and Completeness shave (-0.5) for the wrong negative claim.

**Production-stack fit**: dbt + dbt-trino + Iceberg seed materialization. `decimal(10,2)` and `integer` are valid Trino 467 column types (verified prior iter); engineer's `monthly_price_usd * max_seats` math will work after `dbt seed --full-refresh --select pricing`. The responder didn't mention `--full-refresh` is needed to drop+recreate the seed table with the new types (existing seed table created as VARCHAR won't auto-pick-up the type config without a rebuild) — minor.

**Decision: NO FIX-A (recall-ceiling / minor over-statement).**

Rationale:
- The `dbt_project.yml` form given IS correct and unblocks the engineer immediately. The over-statement narrows but doesn't break.
- Adding a "you can ALSO put it in the seed properties YAML" callout in r27/r28 risks over-attractor regression on adjacent seed config questions (per `feedback_new_card_over_attracts_adjacent`).
- Margin remains healthy on "Improving complex SQL perf on Trino with dbt" row (~4.57 prior).

**NEW SOFT WATCH** `iter1212 Q3 dbt seed column_types over-stated NOT-in-schema.yml`:
- Re-probe in 4-8 iters under structurally-similar framing ("can I configure dbt seed X in a YAML next to the seed, or only in dbt_project.yml?" / "seed properties YAML config: block" / "schema.yml seed config").
- If recurs (responder consistently asserts "only dbt_project.yml"), classify as a real resource gap and consider a light additive note in r27/r28; if doesn't recur, watch closes silently.

Cites r27 §6.7D.

---

## Q4 — Oracle `DECODE(subscription_status, 'active', 'Paying', ..., 'Unknown')` → Trino — 4.875 STRONG PASS

**Verified against [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html)** (WebFetch this iter): Trino 467 conditional expressions are **CASE (simple + searched), IF, COALESCE, NULLIF, TRY** — **no DECODE**.

Responder's answer is correct on all five load-bearing points:

1. **"No DECODE in Trino, parse error confirmed"** — YES, verified above (DECODE not in Trino 467 conditional functions list).
2. **Searched CASE rewrite is THE canonical Trino 467 form**:
   ```sql
   CASE
     WHEN subscription_status = 'active'  THEN 'Paying'
     WHEN subscription_status = 'trial'   THEN 'Free Trial'
     WHEN subscription_status = 'churned' THEN 'Lost'
     ELSE 'Unknown'
   END
   ```
   Correct. Simple CASE (`CASE subscription_status WHEN 'active' THEN ... END`) would also work for equality matches and would be slightly more compact, but searched CASE is the safer general-purpose form and is the right recommendation for the family.
3. **Oracle DECODE NULL-equals-NULL semantics nuance is excellent**: Oracle `DECODE(col, NULL, 'X')` treats `NULL = NULL` as TRUE (Oracle DECODE has a special NULL-equality rule). Trino `CASE WHEN col = NULL` is **never TRUE** (SQL three-valued logic — `col = NULL` is UNKNOWN). The responder correctly tells the engineer to rewrite Oracle's NULL branch as `WHEN col IS NULL THEN ...` **as the first branch** (because branch order matters in searched CASE). This is a real Oracle→Trino migration trap and the responder caught it.
4. **"For this example (no NULL branch in the original DECODE) simple CASE safe"** — correct scoping; the engineer's example doesn't have an explicit NULL branch, so the searched CASE given works as-is for non-NULL `subscription_status`. (If `subscription_status` IS NULL, both Oracle DECODE and Trino searched CASE fall through to ELSE 'Unknown' — same result.)
5. **r27 §4.1A cite** appropriate (DECODE → CASE is a top-line Oracle migration row).

**Soft Compl shave (-0.125)**: didn't surface that **`COALESCE` is the cleaner rewrite when Oracle DECODE is being used as a null-default** (e.g., Oracle `DECODE(col, NULL, 'default', col)` → Trino `COALESCE(col, 'default')`); minor since the engineer's example is a true multi-branch dispatch, not a null-default pattern.

Cites r27 §4.1A.

---

## Carry-forward watches

**Open light-monitors (no action this iter):**
- `iter1212 Q3 dbt seed column_types over-stated NOT-in-schema.yml` — **NEW** soft watch (this iter)
- `iter1211 Q4 strpos-3-arg INSTR-Nth-occurrence assumed-absence` — open (4-8 iter re-probe)
- `iter1210 Q2 r27 §663 :: cast-operator slip` (Postgres `::date` cast vs `CAST(x AS DATE)`) — open
- `iter1209 Q3 CURRENT_TIMESTAMP()-empty-parens audit-column slip` — open
- `iter1208 Q3 dbt selector direction +model vs model+ (exposures-selector)` — open
- `iter1208 Q2 width_bucket boundary off-by-one labeling` — open
- `iter1207 r13 §1293-1326 Spark-CALL inline-tag for GDPR delete recipe` — open
- `iter1204 dbt --full-refresh on_table_exists atomicity framing` — open
- `NVL-coercion` (latent SQL-best-practices secondary slip) — open
- `$partitions metadata-table query semantics` — open

**Closed this iter**: none.

**Status**: steady-state extended-phase. All required topics PASSED healthy margins. Q3 over-statement is the first real (minor) inaccuracy this iter — added as a new soft watch, no resource churn.

---

## Rubric updates

| Topic | Prior | Q score | New | Delta | Margin vs 3.5 |
|---|---|---|---|---|---|
| Iceberg partition design for SaaS | 4.4480 / 57 | Q1=4.625 | 4.4511 / 58 | +0.0031 | +0.9511 |
| Analytical query patterns on Iceberg+Trino | 4.5379 / 150 | Q2=4.75 | 4.5393 / 151 | +0.0014 | +1.0393 |
| Improving complex SQL perf on Trino with dbt | 4.5779 / 43 | Q3=4.0 | 4.5648 / 44 | -0.0131 | +1.0648 |
| Oracle PL/SQL → dbt + Trino SQL migration | 4.4680 / 174 | Q4=4.875 | 4.4703 / 175 | +0.0023 | +0.9703 |

All required topics remain PASSED. No FIX-A. **Next iter1213: BREADTH**, with strpos-3-arg myth re-probe per `iter1211` open watch and dbt seed `column_types` location re-probe per `iter1212` new watch within 4-8 iters each.

# Judge Feedback — Iteration 1312

**Phase**: extended (pass-loop)
**Overall iteration score**: **4.28125 PASS (overall avg >= 3.5)** — ONE Q-LEVEL BORDERLINE SOFT FAIL on Q1 (3.25) caused by a **RESOURCE-SOURCED DEFECT in r25 teaching post-467 `WHEN STALE INLINE / FAIL` clause as if it lands in 467**.
Q1 3.250 / Q2 5.000 / Q3 4.625 / Q4 4.250.

---

## Headline answers to the four teacher flags

### (1) Q1 — Is `WHEN STALE INLINE` a fabricated Trino 467 CREATE MATERIALIZED VIEW clause? Is the core view-vs-MV answer otherwise correct?

**YES, `WHEN STALE INLINE` is INVALID in Trino 467 — but the fabrication is RESOURCE-SOURCED, NOT responder-added.**

- **Verified against [trinodb/trino tag 467 `create-materialized-view.md` source](https://github.com/trinodb/trino/blob/467/docs/src/main/sphinx/sql/create-materialized-view.md)** AND the rendered [trino.io/docs/467/sql/create-materialized-view.html](https://trino.io/docs/467/sql/create-materialized-view.html): the Trino 467 synopsis is verbatim

  ```
  CREATE [ OR REPLACE ] MATERIALIZED VIEW
  [ IF NOT EXISTS ] view_name
  [ GRACE PERIOD interval ]
  [ COMMENT string ]
  [ WITH properties ]
  AS query
  ```

  There is **no `WHEN STALE` clause** at all in 467 — the clause was added later via [PR #27356](https://github.com/trinodb/trino/pull/27356) + [PR #27502](https://github.com/trinodb/trino/pull/27502) (27xxx PR range, post-470; release-470 [release notes](https://trino.io/docs/current/release/release-470.html) do not mention it; lands well after 467).

- **GREP CONFIRMED r25 §2.1 lines 51-57 IS the wrong synopsis** — `resources/25-trino-materialized-views-iceberg.md` lines 51-57 teach the synopsis as

  ```
  CREATE [ OR REPLACE ] MATERIALIZED VIEW
  [ IF NOT EXISTS ] view_name
  [ GRACE PERIOD interval ]
  [ WHEN STALE ( INLINE | FAIL ) ]    <-- NOT IN 467
  [ COMMENT string ]
  [ WITH ( property = value, ... ) ]
  AS query
  ```

  and that fabricated clause is referenced THROUGHOUT r25: lines 13, 54, 62, 73-74, 97, 121, 196, 207, 219-228, 239, 251, 365, 383-384, 386. The responder lifted the worked example at r25 L72-77 verbatim including `WHEN STALE INLINE`. **This is a resource-sourced defect, NOT a responder slip.**

- **Core view-vs-MV answer is CORRECT.** All other claims pin: (a) regular `CREATE VIEW` is a saved query that re-executes (Postgres parity), (b) Trino 467 Iceberg supports `CREATE MATERIALIZED VIEW` with a hidden storage table holding pre-computed result, (c) no auto-refresh — `REFRESH MATERIALIZED VIEW` triggered externally via cron/dbt/k8s CronJob, (d) freshness is snapshot-id-based not time-based, (e) `GRACE PERIOD INTERVAL '90' MINUTE` is a real valid 467 clause. The 8s/200x-day dashboard use-case is exactly the right pattern for an Iceberg MV on this stack.

**Practical impact for the engineer**: copy-pastes the DDL → Trino 467 parse-errors on `WHEN STALE INLINE`. After removing that one line, the rest of the DDL works. Load-bearing factual error in the actual SQL given.

**RECOMMENDED FIX-A (RESOURCE-SOURCED, MEDIUM SEVERITY)**:
- **Primary fix**: reconcile r25 synopsis at §2.1 L51-57 — REMOVE the `[ WHEN STALE ( INLINE | FAIL ) ]` line (it is not in 467).
- **Secondary reconciliation**: rewrite/remove all WHEN STALE references at r25 L13, L62, L73-74, L97, L121, L196, L207, L219-228, L239, L251, L365, L383-384, L386. Behavioral semantics that r25 attributes to `WHEN STALE INLINE` (fall through to underlying SELECT when stale + past grace) are correct as the **default behavior in 467** (no clause needed) — frame as "Trino 467 always falls through to the underlying SELECT when the MV is stale + past grace; the explicit `WHEN STALE INLINE` / `WHEN STALE FAIL` syntax that controls this behavior was added in a later release and is NOT available in 467".
- **DO-NOT-WRITE**: "Add `WHEN STALE INLINE` to the CREATE MATERIALIZED VIEW DDL" (parse error in 467).
- **Verify against**: [trinodb/trino/blob/467/docs/src/main/sphinx/sql/create-materialized-view.md](https://github.com/trinodb/trino/blob/467/docs/src/main/sphinx/sql/create-materialized-view.md) raw git-tag source (the rendered trino.io/docs/467 page agrees).
- **NEW HARD WATCH `iter1312-Q1 WHEN-STALE-INLINE r25 resource-sourced 467-fabrication`**: re-probe 2-4 iters under "view vs materialized view" / "Trino MV freshness clause" / "what controls behavior when MV is stale" framings; WATCH CLOSES on first clean answer after r25 FIX-A lands.

Meta: this matches the `reference_trino_compression_codec_477.md` pin pattern (resource taught post-467 feature as 467) — verify version-cutoff features against the git-tag source, not just blog prose. Imported-prior family is responder-side; this one is resource-side, but the verification posture is identical.

---

### (2) Q4 — Does Trino 467 `GREATEST(integer, decimal)` coerce (work) or error (need CAST)? Is the NULL caveat correct vs the pin?

**(a) Coercion**: Trino **DOES** implicitly coerce numeric mixing for GREATEST/LEAST in most cases — the responder's "Trino requires explicit CAST / no implicit coercion / errors TYPE_MISMATCH" framing is **OVER-CLAIMED**.

- **Verified via [trino.io blog "Optimizing the Casts Away"](https://trino.io/blog/2019/05/21/optimizing-the-casts-away.html)**: "SQL allows certain operations between values of different types if there are implicit conversions (a.k.a., implicit casts or coercions) between those types... allows writing expressions like 1.5 > 2 without worrying too much whether the types are compatible (1.5 is of type decimal(2,1), while 2 is an integer)."
- **[Trino 467 comparison.md](https://github.com/trinodb/trino/blob/467/docs/src/main/sphinx/functions/comparison.md) GREATEST/LEAST supported-types list**: `DOUBLE, BIGINT, VARCHAR, TIMESTAMP, TIMESTAMP WITH TIME ZONE, DATE` — DECIMAL is NOT explicitly listed (somewhat outdated docs entry), but in practice Trino's type-coercion-to-common-super-type lifts integer→bigint→double, decimal→double, so `GREATEST(int_col, decimal_col)` typically resolves to `GREATEST(double, double)` and works without explicit CAST.
- **However, [trinodb/trino#19931](https://github.com/trinodb/trino/issues/19931) "Add tinyint/smallint/integer/bigint to decimal coercion for hive tables"** shows the coercion is NOT universal — certain Hive-metastore-backed paths historically lacked the smallint/integer→decimal coercion, leading to TYPE_MISMATCH on `GREATEST(int_col, decimal_col)`. For this stack (Iceberg connector via Hive Metastore), the coercion path generally works for Iceberg tables.
- **Practically**: explicit CAST is a defensive recommendation that always works; framing it as "Trino REQUIRES CAST because it has no implicit numeric coercion" is wrong as a general statement. The engineer's reported TYPE_MISMATCH could be a specific edge case (Hive-side decimal precision mismatch, or non-numeric type masquerading as decimal — VARCHAR holding decimal-looking strings is more likely the actual cause than an int+decimal pair). The CAST recommendation will fix the symptom in all cases.

**(b) NULL caveat**: the responder said "Trino GREATEST/LEAST return NULL if ANY arg NULL (**unlike Oracle**)" — the **behavior is correct (matches pin)**, but the **dialect-contrast direction is WRONG**.

- **Pin `reference_trino_greatest_least_null.md`** is correct: Trino returns NULL if ANY arg is NULL.
- **r27 §4.4D L1733 source canonical**: *"Oracle's `GREATEST` / `LEAST` ALSO return NULL if any arg is NULL (**Oracle matches Trino here**, but engineers coming from **Postgres muscle memory** get bitten)."* Postgres is the outlier (skips NULLs / returns NULL only if ALL args NULL). Oracle matches Trino.
- The responder reversed the dialect contrast — said "unlike Oracle" when it should be "unlike Postgres". The Trino behavior IS correctly stated; the engineer's takeaway is correct (COALESCE-wrap to skip NULLs); only the dialect callout is named wrong.

**Net Q4**: CAST advice is bulletproof (engineer fixes their error); NULL behavior pinned correct; over-claim on "no implicit coercion" + reversed dialect contrast on NULL handling are both accuracy demerits but neither breaks the engineer's query.

---

### (3) Q2/Q3 accuracy + Q3 DATE_ADD unquoted-unit nit

**Q2 (TRY_CAST varchar to DECIMAL)**: PIN-PERFECT. `SUM(TRY_CAST(charge_amount AS DECIMAL(18,2)))` — `TRY_CAST` returns NULL on conversion failure ('N/A', '$50.00' both become NULL), `SUM` ignores NULL. `COALESCE(TRY_CAST(...), DECIMAL '0.00')` for default. Trino's stricter-than-Postgres type system framing correct; "no implicit varchar to numeric coercion" correct here (`WHERE charge_amount = 100` with varchar column is a parse error in Trino, would silently coerce in Postgres). Regex-based cleaning is slower + breaks predicate pushdown — correctly framed. Verified at [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html) (try_cast returns NULL on conversion failure) + [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) (SUM ignores NULLs). Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 5.0.

**Q3 (env-specific dbt var)**: dbt mechanism is SOLID. Three patterns named: (a) `var('lookback_days', 30)` with default; (b) per-env override via `dbt run --vars '{lookback_days: 7}'` CLI; (c) target-conditional `lookback_days: "{{ 7 if target.name == 'dev' else 30 }}"` in `dbt_project.yml`. Verified at [docs.getdbt.com/reference/dbt-jinja-functions/var](https://docs.getdbt.com/reference/dbt-jinja-functions/var) (var() returns Jinja-rendered value with optional default) + [docs.getdbt.com/reference/dbt-jinja-functions/target](https://docs.getdbt.com/reference/dbt-jinja-functions/target) (`target.name` for env-conditional logic).

**MINOR SQL NIT** confirmed: the worked SQL `WHERE event_date >= DATE_ADD(day, -{{ var('lookback_days', 30) }}, CURRENT_DATE)` has `day` UNQUOTED. **Verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html)**: `date_add(unit, value, timestamp)` signature, examples show `date_add('second', 86, ...)` / `date_add('hour', 9, ...)` / `date_add('day', -1, ...)` — unit is always a **single-quoted string literal**. Bare `day` is a Trino parse error (column-not-found or unexpected token). Engineer would notice immediately on first run. Not load-bearing for the dbt mechanism answer; minor SQL hygiene shave (-0.5 Acc, -0.5 Prac). Acc 4.5 / Clar 4.75 / Prac 4.5 / Compl 4.75.

---

### (4) New watches

- **NEW HARD WATCH `iter1312-Q1 WHEN-STALE-INLINE r25 resource-sourced 467-fabrication`** — re-probe 2-4 iters under "view vs materialized view" / "Trino MV freshness clause" / "how to create an MV in Trino 467" framings; WATCH CLOSES on first clean answer after r25 FIX-A removes the `WHEN STALE` references and the responder lifts a clean WHEN-STALE-less DDL.
- **NEW LOW SOFT WATCH `iter1312-Q4 GREATEST-must-CAST over-claim + NULL-contrast-names-Oracle-instead-of-Postgres`** — re-probe 4-8 iters under "GREATEST mixed numeric types" / "GREATEST NULL behavior" / "Oracle to Trino GREATEST" framings; if the must-CAST over-claim or the wrong-dialect NULL contrast recurs 2+, escalate to LIGHT inline defang at r27 §4.4D (add "Trino DOES coerce integer+decimal in most cases — explicit CAST is defensive, not required" + reinforce "Trino NULL-if-any matches Oracle, differs from Postgres" framing).

---

## Per-question scores

### Q1 — Trino view vs materialized view (dashboard 200x/day, 8s each)

**Score**: **3.25 BORDERLINE SOFT FAIL** — core view-vs-MV concept correct, but the worked DDL contains a resource-sourced post-467 clause that parse-errors in Trino 467.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 2.5 | Core conceptual model correct (view=saved query, MV=pre-computed Iceberg storage table, no auto-refresh, snapshot-based freshness, GRACE PERIOD is valid). BUT the worked DDL `CREATE MATERIALIZED VIEW ... GRACE PERIOD INTERVAL '90' MINUTE WHEN STALE INLINE WITH (...) AS SELECT ...` contains `WHEN STALE INLINE` which is **not in Trino 467** — verified at the [git-tag 467 create-materialized-view.md source](https://github.com/trinodb/trino/blob/467/docs/src/main/sphinx/sql/create-materialized-view.md) (synopsis is `[ GRACE PERIOD interval ] [ COMMENT string ] [ WITH properties ]` only) + the rendered [trino.io/docs/467/sql/create-materialized-view.html](https://trino.io/docs/467/sql/create-materialized-view.html). Added via post-467 PRs #27356/#27502. Engineer copy-pastes -> parse error. |
| Beginner clarity | 4.5 | View vs MV distinction is explained cleanly; "pre-computed result lives in a hidden Iceberg storage table" is exactly the mental model a Postgres-background engineer needs; cron/k8s CronJob refresh framing concrete. |
| Practical applicability | 2.5 | Engineer copies the DDL, hits a Trino 467 parse error on `WHEN STALE INLINE`, has to debug + remove that one line. The rest of the DDL works. Partial-credit; the refresh-cadence + cron-trigger guidance is paste-and-run usable. |
| Completeness | 3.5 | Covered view-vs-MV concept, MV mechanics, REFRESH mechanism, GRACE PERIOD, no-auto-refresh, cron triggering, dashboard use-case fit. Missing only the (now-revealed) note that WHEN STALE syntax is not in 467 — which the resource itself wrongly teaches. |

**Resource-sourced defect attribution**: r25 §2.1 L51-57 synopsis (lifted directly by responder) wrongly includes `[ WHEN STALE ( INLINE | FAIL ) ]`. Behavioral framing (the "fall through when stale" default) IS correct for 467 — just the explicit-clause syntax that controls it doesn't exist yet on 467. See FIX-A details above.

**Topic impact**: query-perf-regression (THINNEST required topic) 3.9895/30 -> **3.9646/31 PASSED** (3.9895*30 + 3.25 = 119.685 + 3.25 = 122.935 / 31 = 3.96565; margin +0.4646 above 3.5 threshold). 4th sub-4-score result on this topic in 8 iters (iter1283 1.75 / iter1305-Q3 2.375 / iter1310-Q2 2.625 / iter1311-Q1 3.375 / iter1312-Q1 3.25). Different pattern families (recipe non-reach / off-target cause / EXPLAIN-variant misroute / broken worked SQL / resource-sourced fabrication) — broad failure surface; iter-by-iter defending remains the right posture, no top-down rewrite.

---

### Q2 — VARCHAR `charge_amount` with "N/A" junk (TRY_CAST + SUM)

**Score**: **5.0 STRONG PASS** — pin-perfect Trino canonical for dirty-varchar-numeric.

| Dimension | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 5.0 |
| Practical applicability | 5.0 |
| Completeness | 5.0 |

`SUM(TRY_CAST(charge_amount AS DECIMAL(18,2)))` — `TRY_CAST` returns NULL on conversion failure, `SUM` ignores NULLs (standard SQL aggregate semantics). `COALESCE(TRY_CAST(...), DECIMAL '0.00')` for default-to-zero. Postgres-contrast framing correct: Trino does not implicitly coerce VARCHAR <-> numeric (`WHERE charge_amount = 100` parse-errors in Trino, silently coerces in Postgres). Regex-cleaning anti-pattern correctly flagged (slower + breaks predicate pushdown).

**VERIFIED** at [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html) ("try_cast: like cast, but returns null if the cast fails") + [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) ("Aggregation functions ignore NULLs in the input, except for count()").

**Topic impact**: SQL-query-best-practices-OLAP 4.5906/317 -> **4.5919/318 PASSED** (4.5906*317 + 5.0 = 1455.2202 + 5.0 = 1460.2202 / 318 = 4.59189; +0.0013, margin +1.0919).

---

### Q3 — Env-specific lookback window (dbt var + target.name)

**Score**: **4.625 STRONG PASS** — dbt mechanism solid; one minor SQL nit on unquoted `day` unit in `date_add`.

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.5 |
| Completeness | 4.75 |

Responder gave three patterns: (a) `var('lookback_days', 30)` with default in dbt_project.yml `vars:` block; (b) per-run CLI override `dbt run --vars '{lookback_days: 7}'`; (c) `target.name == 'dev'` Jinja conditional `lookback_days: "{{ 7 if target.name == 'dev' else 30 }}"`. Cited r27 §6.7G.

**VERIFIED** at [docs.getdbt.com/reference/dbt-jinja-functions/var](https://docs.getdbt.com/reference/dbt-jinja-functions/var) (var(name, default) accessor returns Jinja-rendered value) + [docs.getdbt.com/reference/dbt-jinja-functions/target](https://docs.getdbt.com/reference/dbt-jinja-functions/target) (`target.name` is the active profile target name, evaluated at render time).

**Minor SQL nit** (-0.5 Acc / -0.5 Prac): worked SQL `WHERE event_date >= DATE_ADD(day, -{{ var('lookback_days', 30) }}, CURRENT_DATE)` has `day` UNQUOTED. Trino `date_add` requires the unit as a **single-quoted string literal** — verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html): signature `date_add(unit, value, timestamp)` with examples `date_add('second', 86, ...)` / `date_add('hour', 9, ...)` / `date_add('day', -1, ...)`. Bare `day` would be a parse error (column-not-found or unexpected token). Engineer would catch this on first run. Not load-bearing for the dbt mechanism answer (which is the actual core ask).

**Topic impact**: complex-SQL-perf-Trino-dbt 4.4282/107 -> **4.4300/108 PASSED** (4.4282*107 + 4.625 = 473.8174 + 4.625 = 478.4424 / 108 = 4.43002; +0.0018, margin +0.9300). Routed per recent iter1289-1311 dbt-question pattern.

---

### Q4 — Oracle `GREATEST(some_integer_column, some_decimal_column)` -> Trino mixed-numeric

**Score**: **4.25 PASS** — CAST advice is defensive-and-correct; two accuracy demerits: must-CAST over-claim + reversed dialect contrast on NULL.

| Dimension | Score |
|---|---|
| Technical accuracy | 3.5 |
| Beginner clarity | 4.5 |
| Practical applicability | 4.75 |
| Completeness | 4.25 |

**CAST recommendation works** — `GREATEST(CAST(int_col AS DECIMAL(18,2)), decimal_col)` is defensive and bulletproof. Engineer follows -> error gone.

**Two accuracy demerits**:
1. **Over-claim on "Trino requires explicit CAST / no implicit numeric coercion"**: Trino DOES implicitly coerce mixed numeric types via the type-coercion-to-common-super-type rule. Per [trino.io blog "Optimizing the Casts Away"](https://trino.io/blog/2019/05/21/optimizing-the-casts-away.html) and the type system: `1.5 > 2` works without CAST because decimal/integer share a common super type. `GREATEST(int_col, decimal_col)` typically resolves through `BIGINT -> DOUBLE` and `DECIMAL -> DOUBLE` to `GREATEST(double, double)`. The supported-types list in [Trino 467 comparison.md](https://github.com/trinodb/trino/blob/467/docs/src/main/sphinx/functions/comparison.md) (DOUBLE, BIGINT, VARCHAR, TIMESTAMP, TIMESTAMP WITH TIME ZONE, DATE) omits DECIMAL explicitly but coercion makes it work in practice. The engineer's reported TYPE_MISMATCH is likely a different root cause (VARCHAR-disguised-as-decimal, or a specific Hive-metastore coercion gap per [trinodb/trino#19931](https://github.com/trinodb/trino/issues/19931)) — explicit CAST defensively fixes it either way.

2. **Reversed dialect contrast on NULL**: responder said "Trino GREATEST returns NULL if any arg NULL — **unlike Oracle**". The behavior is correctly pinned (matches `reference_trino_greatest_least_null.md`), but the dialect-contrast direction is wrong. Per **r27 §4.4D L1733 source canonical**: *"Oracle's GREATEST/LEAST ALSO return NULL if any arg is NULL — Oracle MATCHES Trino here, but engineers coming from Postgres muscle memory get bitten."* **Postgres is the outlier** (skips NULLs); Trino and Oracle agree. The COALESCE-wrap advice still helps the engineer; only the dialect naming is wrong.

Both demerits are accuracy issues but neither breaks the engineer's query — the actionable advice (explicit CAST + COALESCE-wrap) works.

**Topic impact**: Oracle-PL/SQL-migration 4.5036/289 -> **4.5028/290 PASSED** (4.5036*289 + 4.25 = 1301.5404 + 4.25 = 1305.7904 / 290 = 4.50273; -0.0009, margin +1.0028).

---

## Watches carried (active)

- **NEW HARD WATCH `iter1312-Q1 WHEN-STALE-INLINE r25 resource-sourced 467-fabrication`** (this iter; FIX-A recommended at r25 L51-57 + sibling references).
- **NEW LOW SOFT WATCH `iter1312-Q4 GREATEST-must-CAST over-claim + NULL-contrast-names-Oracle-instead-of-Postgres`** (this iter).
- **LOW SOFT WATCH `iter1311-Q1 salted-two-level-GROUP-BY collapsed-to-one-CTE form`** (NOT exercised this iter).
- **HARD WATCH `iter1305-Q3 two-queries-same-WHERE differential-scan-time -> columnar projection`** (NOT exercised this iter).
- **LOW WATCH `iter1305-Q4 Oracle TO_NUMBER-mask misattributed as Teradata-ism`** (NOT exercised this iter).
- **LOW SOFT WATCH `iter1308-Q4 false-premise-endorsement-light on ASC-direction NULL-ordering`** (NOT exercised this iter).
- **LOW SOFT WATCH `iter1310-Q1 Postgres-md5-lowercase-vs-Trino-to_hex-uppercase parity`** (NOT exercised this iter).
- **LOW SOFT WATCH `iter1310-Q2 EXPLAIN-ANALYZE-recommended-when-engineer-asks-PRE-RUN-scan-estimate`** (NOT exercised this iter).

---

## Summary signal for the teacher

**One Q-level borderline soft-FAIL on Q1 (3.25) caused by a RESOURCE-SOURCED defect in r25 teaching post-467 `WHEN STALE INLINE / FAIL` clause as if it lands in 467; three strong PASSes on Q2/Q3/Q4. Overall 4.28125 PASS.**

The Q1 failure mode is **different in kind** from the iter1311 Q1 SOFT FAIL (which was a responder-side broken-worked-SQL mutation). This one is a **resource-side fabrication propagating to the responder**: r25 §2.1 L51-57 has the wrong synopsis (includes `WHEN STALE` clause that lands later), and r25 references that clause 15+ times throughout the file. The responder dutifully lifted r25's worked example verbatim including the post-467 clause. **Verified against trinodb/trino tag 467 git-tag source and rendered trino.io/docs/467 page — both confirm WHEN STALE is NOT in Trino 467.**

**RECOMMENDED LIGHT/MEDIUM FIX-A on r25** — primary at r25 §2.1 L51-57 synopsis (remove the `WHEN STALE` line), secondary reconciliation across all 15+ sibling references in the same file (behavior-without-clause is correct in 467 — frame as "Trino 467 always falls through to underlying SELECT when stale + past grace; explicit WHEN STALE control clause is post-467"). Follow `feedback_reconcile_dont_append.md` posture — fix in place across all locations in the same edit; don't append a new "WHEN STALE is post-467" note while leaving the wrong synopsis intact (responder will keep citing the wrong synopsis). Verify against [git-tag 467 create-materialized-view.md source](https://github.com/trinodb/trino/blob/467/docs/src/main/sphinx/sql/create-materialized-view.md) (raw, not blog prose).

**Pattern note for the verification rule**: this fabrication slipped past many iters because r25 has been stable and the previous MV questions probably never triggered the engineer to copy-paste-and-run the synopsis. Once a question makes the worked DDL load-bearing, the latent defect surfaces. Matches the iter1192 `reference_trino_iceberg_migrate_native.md` pattern: "long-stable resource claim can still be a latent unprobed error". GREP all resources for `WHEN STALE` (already done — only r25 has it) and clean it in one pass.

**Thinnest-topic trend**: query-perf-regression now at 3.9646/31 (5th sub-4 score in 8 iters but still margin +0.4646 above 3.5). Five DIFFERENT failure families now: recipe non-reach / off-target cause / EXPLAIN-variant misroute / broken worked SQL / resource-sourced fabrication. The topic is the thinnest because its question surface is the broadest (oncall workflows, partition skew, file layout, concurrency, caching/MV). Continue iter-by-iter defending; the r25 FIX-A will close this specific gap.

**Q2/Q3/Q4 routing**: Q2 conditional-text/regex-vs-TRY_CAST lands SQL-best-practices cleanly. Q3 dbt-var-env-conditional lands complex-SQL-perf-Trino-dbt per recent iter1289-1311 dbt-question pattern. Q4 Oracle GREATEST-coercion lands Oracle-PL/SQL-migration cleanly. All three topic-averages stayed stable at high margin.

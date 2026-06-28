# Iter1210 Judge Feedback — PASS NO-OP (one real Q2 `::date` dialect slip, non-source-anchored)

**Overall verdict**: PASS, avg **4.59375**, NO FIX-A.

| Q | Topic | Score | Verdict |
|---|---|---|---|
| Q1 | Iceberg MoR position-delete + Trino-only optimize maintenance | **4.9375** | reconciled canonical reaches cleanly |
| Q2 | Single-pass YoY revenue via FILTER + GROUP BY | **3.625** | core approach correct, **`::date` Postgres cast operator is a Trino 467 parse error** (real dialect slip on the month-column literal) |
| Q3 | dbt `grants:` config + dbt-trino USER-vs-ROLE caveat + post_hook | **4.875** | clean, cites known bug + workaround |
| Q4 | Oracle `''=NULL` vs Trino `''` distinct + `IS NULL OR =''` fix | **4.9375** | clean behavioral contrast + correct WHERE |

---

## Q1 — Iceberg MoR position-delete + Trino-only optimize: 4.9375

**Heavily-reconciled optimize-position-delete topic (iter1194-1199) — the correct, fully Trino-only reconciled answer reaches.** No "you need Spark" misroute, no expire-only over-fix.

VERIFIED facts:
1. **MoR write semantics**: "Iceberg never modifies files in place; UPDATE writes a **position-delete file** (marks rows to skip in existing data files) + new data files for the new row values." Confirmed at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) — "Trino write operations on Iceberg tables follow the merge-on-read design, so they create positional delete files instead of rewriting entire data files that are impacted by updates or deletes."
2. **Why reads slow over weeks**: every SELECT scans the data files PLUS replays the position-delete index to mask deleted rows; nightly 5k updates × 30 days = ~150k position-delete entries replayed per read. Row count stable (the engineer's observation) is consistent — net rows don't change, but delete-replay cost grows linearly with accumulated delete-file count. Correct mental model.
3. **Trino-only fix — `ALTER TABLE ... EXECUTE optimize`**: rewrites data files into fewer larger files AND **applies the position deletes during the rewrite (rewritten files no longer reference position-delete files)**. Verified at Starburst's [Apache Iceberg DML & Maintenance in Trino](https://www.starburst.io/blog/apache-iceberg-dml-update-delete-merge-maintenance-in-trino/): "OPTIMIZE rewrites the content...merged into fewer but larger files." Trino-native, no Spark. Matches pinned reconciled answer.
4. **`file_size_threshold` raise lever**: default is **100MB** (per [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html)). On a 200k-row table whose files are already > 100MB, no file qualifies for rewrite — raising `file_size_threshold => '512MB'` (above existing file size) forces those files to be selected and rewritten. Correct lever choice for the table size.
5. **Weekly `expire_snapshots(retention_threshold=>'7d')` + `remove_orphan_files(retention_threshold=>'7d')`**: correct ops cadence; `7d` is the minimum allowed default per `iceberg.expire-snapshots.min-retention`.
6. **Sizing guidance**: "200k rows / 5k UPDATEs/night, weekly optimize usually enough" — pragmatic, correct for the table size; nightly is overkill, weekly clears the delete-file accumulation before read slowdown becomes noticeable.

Minor completeness shave (-0.25): could mention that delete files only get **physically removed** after `expire_snapshots` runs past the retention threshold, not at the moment `optimize` finishes — but the read-side speedup happens immediately after optimize (rewritten files no longer reference deletes). Per [trinodb/trino#24086](https://github.com/trinodb/trino/issues/24086), removal of orphan delete files has nuances (sequence-number dependence). Not load-bearing for the engineer's "reads are getting slow" problem.

The previously-reconciled iter1194-1199 watch (optimize-applies-position-deletes-during-rewrite framing) DURABLY HOLDS. No FIX-A.

## Q2 — Single-pass YoY revenue via FILTER + GROUP BY: 3.625

**Core approach correct, one real dialect slip (`::date` cast operator) on the month column expression.**

VERIFIED facts:
1. **Single-pass with conditional aggregation beats two-CTE-join**: `SUM(amount) FILTER (WHERE YEAR(order_date)=2025)` + `SUM(amount) FILTER (WHERE YEAR(order_date)=2026)` over a single `WHERE YEAR(order_date) IN (2025,2026) GROUP BY DATE_TRUNC('month', order_date)` is the correct/idiomatic Trino 467 pattern. One scan of the 500M-row orders table, one shuffle/aggregate, no self-join. The Oracle two-CTE-join shape scans+aggregates twice; the FILTER form is materially cheaper. **VERIFIED `FILTER (WHERE ...)`** at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html): "Aggregate functions support a FILTER clause that specifies which rows are processed."
2. **NULLIF div-by-zero guard**: `ROUND(100.0*(rev2026-rev2025)/NULLIF(rev2025,0),2)` — correct (integer/decimal `/` by zero THROWS in Trino, per pinned `reference_trino_division_by_zero.md`). 100.0 forces decimal arithmetic.
3. **`DATE_TRUNC('month', order_date)`**: valid, returns the same precision as input — fine.

**REAL DIALECT SLIP (Acc -2.0)** — the responder writes the month column as:

```sql
DATE_TRUNC('month', order_date)::date AS month
```

The `::` cast operator is **PostgreSQL/DuckDB/Snowflake syntax** and **NOT supported in Trino 467**. Verified at [trinodb/trino issue #23795 "Cast operator `::`"](https://github.com/trinodb/trino/issues/23795) — feature request still open; Trino requires `CAST(x AS type)`. The literal copy-paste of the responder's query into Trino 467 returns:

```
line N: mismatched input '::'. Expecting: ...
```

Correct Trino 467 forms (any one):
- `CAST(DATE_TRUNC('month', order_date) AS DATE) AS month`
- Just drop the cast — `DATE_TRUNC('month', order_date)` already returns a timestamp scoped to the month boundary; the engineer's dashboard label only needs the truncated value, not strict `DATE` typing.

**Resource source check**: grep for `::date|::int|::varchar|postgres cast operator` in resources/ — **r27 §663 ALREADY DOCUMENTS `::` as invalid Trino dialect** ("Trino has no PostgreSQL `::` cast operator — use `CAST(x AS type)`"). The resource is correct. The responder's `::date` is a **recall-ceiling responder slip**, NOT a resource defect.

Pattern: matches `feedback_responder_broken_secondary_alternative.md` family (the LEAD = single-pass FILTER + GROUP BY is the correct headline answer, but the responder appended a non-load-bearing decorative cast in Postgres syntax that's a real parse error). The engineer hits `mismatched input '::'` on first compile and fixes it in 60 seconds. The single-pass FILTER pattern + NULLIF + GROUP BY structure all carry over correctly.

**NO FIX-A.** Resource already teaches the correct rule at r27 §663; classify as one-instance responder slip per pinned `feedback_synthesis_ceiling_stop_churning.md` (don't churn the defang; treat as recall-ceiling variance). **NEW soft watch**: `r27 §663 :: cast operator responder slip iter1210` — re-probe in 4-8 iters under "Trino-version-of-Postgres-syntax" framing; if recurs across phrasings, add a top-of-r07 myth row.

Score breakdown:
- Acc: 3.0 (single-pass approach right; `::date` parse error real)
- Clar: 4.5 (clear "why beats two-CTE" reasoning)
- App: 3.0 (literal copy-paste parse-errors)
- Compl: 4.0 (approach + NULLIF + GROUP BY all there)

## Q3 — dbt `grants:` config + dbt-trino USER-vs-ROLE caveat: 4.875

VERIFIED facts:
1. **`grants: {select: ['bi_service_user']}` in model config**: dbt re-applies grants on every build/rebuild — verified at [docs.getdbt.com/reference/resource-configs/grants](https://docs.getdbt.com/reference/resource-configs/grants): "dbt will configure access to your resources whenever they are built." Direct, accurate answer to the literal "every rebuild drops the grant" problem.
2. **dbt-trino bug #12862 — bare-name → USER not ROLE**: VERIFIED at [dbt-labs/dbt-core#12862 "Trino/Starburst Cannot use grants with roles"](https://github.com/dbt-labs/dbt-core/issues/12862) — the dbt-trino adapter emits `GRANT SELECT ON ... TO bi_service_user` without ROLE/USER prefix; Trino resolves bare names as USER. If `bi_service_user` is actually a ROLE (typical for service accounts in OPA-backed setups), the grant fails or grants to the wrong principal.
3. **`post_hook="GRANT SELECT ON {{ this }} TO ROLE bi_service_user"`**: correct workaround pattern for ROLE grantees. `post_hook` runs after the table is created/replaced, so the GRANT statement always finds the target table. `{{ this }}` correctly resolves to the model's fully-qualified `catalog.schema.table`.
4. **Production-stack relevance**: the production env uses OPA-backed authz with service accounts (typically modeled as ROLEs in Trino); the ROLE caveat is load-bearing for this stack — the responder routed correctly.

Minor completeness shave (-0.25): could mention that the `post_hook` form means dbt's own grant-management is bypassed (`dbt run` won't re-issue a `REVOKE` if the YAML changes); ops-wise the grants:-config approach is preferred when the USER bug is irrelevant, post_hook only when the ROLE caveat applies. Not load-bearing for the engineer's specific "auto-grant on rebuild" question.

No imported-prior slip, no fabrication. Direct, complete, production-stack-aware answer. Resources at r27 §6.7I doing their job.

Score breakdown:
- Acc: 5.0
- Clar: 4.75 (clear primary + ROLE caveat)
- App: 5.0 (literal YAML + post_hook strings)
- Compl: 4.75 (covers both paths)

## Q4 — Oracle `''=NULL` vs Trino `''` distinct: 4.9375

VERIFIED facts:
1. **Oracle VARCHAR2 `''` stored as NULL**: documented Oracle quirk — Oracle treats zero-length character values inserted into VARCHAR2 as NULL. Verified across multiple migration guides ([sqlpey.com Oracle empty strings as NULL](https://sqlpey.com/sql/oracle-empty-string-null-treatment/); [AWS database blog handling empty strings migrating from Oracle to PostgreSQL](https://aws.amazon.com/blogs/database/handle-empty-strings-when-migrating-from-oracle-to-postgresql/)). `'' IS NULL` returns TRUE in Oracle.
2. **Trino `''` is a distinct zero-length string**: VERIFIED — Trino follows ANSI SQL where `''` is a valid zero-length VARCHAR value, NOT NULL. `'' IS NULL` returns FALSE in Trino 467; `'' = ''` returns TRUE; `length('')` returns 0. Per [trino.io/docs/467/functions/comparison.html](https://trino.io/docs/467/functions/comparison.html): "IS NULL and IS NOT NULL operators test whether a value is null (undefined)" — empty string is defined (zero-length), not null.
3. **The migration silent bug**: after Spark/Trino write, rows that were `''`-as-NULL in Oracle land as actual `''` (zero-length strings) in Iceberg; existing dashboard queries `WHERE notes IS NULL` now silently exclude what used to be NULL-matched rows (the migrated empty-string ones). Direct, accurate answer to the literal "rows missing" symptom.
4. **Fix `WHERE notes IS NOT NULL AND notes <> ''`** (or equivalently `WHERE notes IS NULL OR notes = ''`): correct catch-both predicate. NULL-safe in Trino (the IS NOT NULL guard is necessary because `NULL <> ''` returns NULL, not TRUE, so a bare `notes <> ''` predicate would also silently drop NULL rows — the responder gets this right).
5. **Audit guidance**: "Audit every migrated `IS NULL`/`IS NOT NULL`/`NVL` on text columns" — production-grade ops advice for an Oracle-to-Trino migration; many legacy queries make the `''=NULL` assumption silently.

Minor completeness shave (-0.25): could mention `LENGTH(TRIM(notes)) = 0` for whitespace-only strings (another Oracle-era assumption is that `'   '`-style padded strings are "essentially empty"). Engineer's question only asks about `''` vs NULL, so not load-bearing — but worth a one-liner for completeness. Resources at r27 cover this area cleanly.

No imported-prior slip, no fabrication. Direct, complete, behavioral-contrast answer with correct fix.

Score breakdown:
- Acc: 5.0
- Clar: 5.0 (clear two-engine behavior contrast)
- App: 5.0 (exact WHERE clause + audit advice)
- Compl: 4.75 (one minor whitespace-only nuance omitted)

---

## Rubric updates (4 rows)

- **Iceberg table maintenance**: 4.4438/218 → (968.7484 + 4.9375)/219 = **4.4461/219 PASSED** (+0.0023, margin +0.9461)
- **SQL query best practices for OLAP**: 4.5903/276 → (1266.9228 + 3.625)/277 = **4.5867/277 PASSED** (-0.0036, Q2 `::date` drag, margin +1.0867)
- **Improving complex SQL performance on Trino with dbt**: 4.5603/41 → (186.9723 + 4.875)/42 = **4.5678/42 PASSED** (+0.0075, margin +1.0678)
- **Oracle PL/SQL → dbt+Trino**: 4.4759/172 → (769.8548 + 4.9375)/173 = **4.4786/173 PASSED** (+0.0027, margin +0.9786)

ALL required topics REMAIN PASSED. Thinnest required topic stays Query-perf-basics at 4.2161 (untouched this iter). Iter average **(4.9375 + 3.625 + 4.875 + 4.9375)/4 = 4.59375 PASS NO-OP** (margin +1.09).

---

## Light-monitor watches (carry-forward, NO action this iter)

- iter1199 r17 position-delete adjacent — **Q1 LOAD-BEARING RE-PROBE: CLOSES** (responder gave correct reconciled Trino-only optimize-applies-position-deletes-during-rewrite answer; no Spark misroute, no expire-only over-fix)
- iter1204 dbt `--full-refresh` `on_table_exists` atomicity framing — no probe this iter
- iter1206 NVL-coercion — no probe this iter
- iter1206 `$partitions` omission under physical-layout framing — no probe this iter
- iter1207 GDPR Spark-engine-tag — no probe this iter
- iter1208 width_bucket boundary labels — no probe this iter
- iter1208 dbt exposures `+model:` vs `model:+` selector direction — no probe this iter
- iter1209 Q3 `CURRENT_TIMESTAMP()` empty-parens — no probe this iter (Q3 this iter is dbt-grants, not audit-column default)
- **NEW** iter1210 Q2 `::date` Postgres cast operator responder slip — r27 §663 ALREADY teaches the correct CAST form; NO FIX-A; re-probe in 4-8 iters under "Trino-version-of-Postgres-syntax" or "dialect translation" framing; if recurs across phrasings → add top-of-r07 dialect-myth-row routing card. Low priority.

---

## Pattern observation

iter1210 4.59375 PASS NO-OP fits the sustainment band. The Q2 `::date` slip is a textbook recall-ceiling responder slip — the LEAD (single-pass FILTER + GROUP BY + NULLIF) is fully correct and copy-pasteable except for the one decorative cast operator on the month-column label, exactly the family pinned at `feedback_responder_broken_secondary_alternative.md`. Resource r27 §663 already teaches the correct rule; per `feedback_synthesis_ceiling_stop_churning.md` discipline, do NOT churn the defang — accept one-instance variance, soft-watch for re-probe.

Q1 confirms the reconciled optimize-position-delete answer DURABLY HOLDS on a slightly different framing (the engineer's "delete files replayed on every read" + "Trino is primary engine" prompt is a high-precision re-probe). The iter1194-1199 reconciliation work is paying off: no "Spark required" misroute, no "just expire snapshots" over-fix, correct file_size_threshold raise lever for already-large files, correct weekly cadence sizing.

Q3 + Q4 are clean canonical reaches with no slips.

**Recommend NO-OP**. Continue breadth probing in next iter; Query-perf-basics remains thinnest required-topic at 4.2161 — when next sweep lands there, lift on technical-accuracy is the primary opportunity.

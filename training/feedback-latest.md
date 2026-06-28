# Iter1211 Judge Feedback — PASS with Q4 `strpos`-3-arg responder slip against ALREADY-DEFENDED resource (NO FIX-A)

**Overall verdict**: PASS, avg **4.344**, **NO FIX-A** (Q4 defect is a Haiku assumed-absence recall-ceiling slip against r27 §4.3 L990's exact `DO-NOT-WRITE` defang — not a resource gap).

| Q | Topic | Score | Verdict |
|---|---|---|---|
| Q1 | Iceberg table maintenance (concurrent writers, optimistic concurrency, isolation) | 4.875 | STRONG PASS |
| Q2 | SQL query best practices for OLAP (avg-of-avgs, per-account-then-AVG fairness) | 4.875 | STRONG PASS |
| Q3 | Improving complex SQL perf on Trino with dbt (dbt vars + incremental interaction) | 5.0 | PIN-PERFECT |
| Q4 | Oracle PL/SQL → dbt + Trino SQL migration (INSTR Nth occurrence → strpos 3-arg) | 2.625 | FAIL (responder recall-ceiling slip; resource is correct + maximally defended) |

---

## Q1 — Two writers on same Iceberg table, commit-conflict — 4.875 STRONG PASS

**All five load-bearing facts verified.** Responder gave the canonical Iceberg optimistic-concurrency model:

1. **No upfront row/table locking** — Iceberg uses optimistic concurrency; writers race at commit time via atomic catalog pointer swap (compare-and-swap). NOT Postgres row-level locks. Verified at [iceberglakehouse.com/iceberg/iceberg-concurrent-writes](https://iceberglakehouse.com/iceberg/iceberg-concurrent-writes/) verbatim: *"Rather than locking tables during writes, Iceberg allows concurrent writes to proceed in parallel."*
2. **CommitFailedException on loser race** — correct mechanism (loser sees stale snapshot at CAS time, throws). Verified at [Apache Iceberg IsolationLevel javadoc](https://iceberg.apache.org/javadoc/1.7.1/org/apache/iceberg/IsolationLevel.html) and [lists.apache.org thread on serializable vs snapshot](https://lists.apache.org/thread/9gw4g4k59y1dm3ftcz61dnkgtq1godks).
3. **No silent overwrite / no corruption** — atomic-pointer-swap semantics; either a write commits a new snapshot pointing to a consistent metadata.json or the commit fails. Phantom-row anomaly under `snapshot` isolation correctly named as the trade-off (don't use for billing/compliance).
4. **`write.merge.isolation-level` `serializable` vs `snapshot`** — serializable rejects logical-overlap commits even on disjoint partitions (false-positive for table-level MERGEs); snapshot relaxes to physical-conflict-only. Correctly notes default is `serializable` (conservative). Verified at [aws.amazon.com/blogs/big-data/manage-concurrent-write-conflicts-in-apache-iceberg](https://aws.amazon.com/blogs/big-data/manage-concurrent-write-conflicts-in-apache-iceberg-on-the-aws-glue-data-catalog/).
5. **`commit.retry.num-retries` for auto-retry** — correctly framed as the Iceberg library auto-retry knob (default 4); only metadata commit is retried, not the data write. Bumping to 8 + relaxed isolation is the standard mitigation.

**Production-stack fit**: correctly notes the isolation properties must be set via **Spark `ALTER TABLE SET TBLPROPERTIES`** since Trino 467 writer is MoR (Trino's `ALTER TABLE SET PROPERTIES` works for `format_version` but not all Iceberg table properties round-trip to the table-level isolation knob); verification via `SELECT * FROM iceberg.events$properties` is the correct introspection.

**Soft Compl shave (-0.125)**: didn't surface the **Trino 467 `iceberg.expire-snapshots.min-retention` 7d floor** as adjacent context (engineer might confuse retry config with expiry config); minor and non-load-bearing.

Cites r17/r21/r26.

---

## Q2 — Avg CSAT fairness (per-account-then-average, not weighted by ticket count) — 4.875 STRONG PASS

**Correct canonical form**: two-CTE `WITH per_account AS (... GROUP BY account_id, plan_tier) SELECT plan_tier, AVG(account_avg_csat) FROM per_account GROUP BY plan_tier`. This IS the only clean way (Trino does NOT allow nested aggregates like `AVG(AVG(csat_score))` — that's a parse error).

- **Single Trino query**: YES — the CTE collapses what reads like a "two-step" approach into one query plan.
- **Plain-language framing**: "each account one vote" nails the intuition for a SaaS engineer with no OLAP background.
- **COUNT(DISTINCT account_id) per tier** included as the sample-size disclosure — production-quality touch.

**Soft Compl shave (-0.125)**: didn't explicitly say "`AVG(AVG(...))` would be a parse error — Trino forbids nested aggregates" as a beginner-defense (the engineer literally asked "single query or two steps?" — flagging that the *naive* single query is impossible would close the loop).

Cites r07/r23.

---

## Q3 — dbt vars (start_date / lookback_days) — 5.0 PIN-PERFECT

**All four sub-questions answered correctly, verified verbatim against [docs.getdbt.com/docs/build/project-variables](https://docs.getdbt.com/docs/build/project-variables):**

1. **Where to declare**: `vars:` block at the TOP LEVEL of `dbt_project.yml` (not nested under `models:`); global scope vs project-scoped vs package-scoped distinction correctly handled by using top-level declarations.
2. **Default value**: `{{ var('lookback_days', 30) }}` second-arg-default syntax is the canonical [docs.getdbt.com `var()` reference](https://docs.getdbt.com/reference/dbt-jinja-functions/var) form — does NOT raise `CompilationError` if the var is unset.
3. **Reference in model SQL**: `WHERE occurred_at >= date_add('day', -{{ var('lookback_days', 30) }}, current_date)` is the canonical Trino 467 date-window form (uses `date_add` not Postgres `INTERVAL`).
4. **CLI override**: `dbt run --vars '{lookback_days: 7}'` YAML form (JSON also accepted); precedence **CLI `--vars` > `dbt_project.yml` vars > `var()` default-arg** is correct per dbt docs verbatim *"Variables defined via `--vars` override values in `dbt_project.yml`."*
5. **var-vs-`is_incremental()` independence**: correctly framed as orthogonal — first run `is_incremental()` returns FALSE so the `WHERE` predicate is SKIPPED (full table build), subsequent runs both apply. This is the correct mental model.

No imported-prior slips, no broken-secondary alternatives, no over-warning. Engineer arrives at a working local-dev pattern with the right mental model.

Cites r13/r27/r28.

---

## Q4 — Oracle INSTR(url, '/', 1, 3) → Trino — 2.625 FAIL (responder slip vs ALREADY-DEFENDED resource)

**THE DEFECT.** Responder wrote: *"Trino does NOT have an INSTR equivalent accepting an occurrence parameter. strpos(string, substring) finds only the first match."* **BOTH CLAIMS ARE FALSE on Trino 467.**

**Verified against [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html)** (WebFetch this iter):

> `strpos(string, substring, instance) → bigint`
> "Returns the position of the N-th `instance` of `substring` in `string`. When `instance` is a negative number the search will start from the end of `string`. Positions start with `1`. If not found, `0` is returned."

So the **direct one-call answer to the engineer's question is**:
```sql
strpos(url, '/', 3)  -- position of the 3rd slash, exactly Oracle INSTR(url, '/', 1, 3)
```

**This is a RESPONDER recall-ceiling slip against ALREADY-DEFENDED resource content — NOT a resource gap:**

- **r27 §4.3 line 990** explicitly teaches the 3-arg form with the EXACT myth defang:
  > `INSTR(s, sub, 1, n)` → `strpos(s, sub, n)` — the 3-arg form. **DO NOT WRITE** "Trino strpos is 2-arg only / has no n-th-occurrence form" — that is a **base-training myth**; the 3-arg form exists. Keyword anchors: position of the second occurrence, nth occurrence of a character Trino, find the 2nd/3rd instance, position of last occurrence, find n-th delimiter position.
- **r23 §538-549** also teaches `strpos(s, sub, -1)` (negative-instance = from-end) for the last-occurrence case with extensive keyword anchors.
- **r27 §4.3-STR-FAMILY line 1058** ("Trino has no `position` function — use `strpos` instead" — HALF-WRONG) sits adjacent in the same canonical block.

The resource is **maximally defended already** — explicit `DO-NOT-WRITE` markup, exact-myth callout, keyword anchors targeting "nth occurrence" / "find the 2nd/3rd instance" / "position of last occurrence" / "find n-th delimiter position", and an adjacent `position()` myth-defang in the same string-family canonical. Despite this, the Haiku responder produced **the literal exact wording the resource defangs**.

**Partial credit**: the responder's fallback (`split(url, '/')` array index for path segments / `split_part(url, '/', n)` for the Nth segment) IS a valid Trino 467 idiom — r23 §504 leads with `split_part` for delimiter extraction — so an engineer who wants the *path segment* (not the *slash position*) does land on a working query. But the engineer literally asked for the **position of the Nth slash** (Oracle INSTR semantics fed to SUBSTR), and the responder said "Trino doesn't have that" instead of giving the one-line direct answer.

**NO FIX-A justified:**
- The resource is correct, exact, and maximally defended at r27 §4.3 L990.
- Per the imported-prior assumed-absence family (`starts_with` / `to_char` / `listagg` / `array_sum` / `format_number` / `migrate` / `LATERAL` — see MEMORY.md cards), this is a recurring Haiku base-training prior: foreign-looking funcs that DO exist in Trino get assumed absent. The resource already does what it can.
- Adding more defang risks `feedback_new_card_over_attracts_adjacent` (over-attractor on adjacent strpos questions).
- Per `feedback_synthesis_ceiling_stop_churning.md` — when a FIX-A has already shipped the maximum reasonable defang and the responder STILL recalls the myth, that residual is a Haiku synthesis ceiling, not a resource gap.

**NEW SOFT WATCH** `iter1211 Q4 strpos-3-arg INSTR-Nth-occurrence assumed-absence`:
- Re-probe in 4-8 iters under structurally-similar framing ("Oracle INSTR with occurrence param → Trino equivalent" / "find the Nth occurrence of a character / 2nd dot / 3rd slash").
- If recurs (despite r27 §4.3 L990 + r23 §538 + keyword anchors), classify as **CONFIRMED Haiku base-training prior — accept the occasional Q cost, do NOT add more defang** (would risk over-attractor regression on adjacent strpos questions).
- If does NOT recur, watch closes silently.

Cites r27/r23 (resources are correct; responder slip).

---

## Carry-forward watches

**Open light-monitors (no action this iter):**
- `iter1210 Q2 r27 §663 :: cast-operator slip` (Postgres `::date` cast — Trino 467 requires `CAST(x AS DATE)`) — soft watch open
- `iter1209 Q3 CURRENT_TIMESTAMP()-empty-parens audit-column slip` — soft watch open
- `iter1208 Q3 dbt selector direction +model vs model+ for impact-analysis (exposures-selector)` — open
- `iter1208 Q2 width_bucket boundary off-by-one labeling` — open
- `iter1207 r13 §1293-1326 Spark-CALL inline-tag for GDPR delete recipe` — open
- `iter1204 dbt --full-refresh on_table_exists atomicity framing` — open
- `NVL-coercion` (latent SQL-best-practices secondary slip) — open
- `$partitions metadata-table query semantics` — open

**Closed this iter**: none (Q4 strpos-3-arg myth is a NEW watch, not a re-probe of an existing one).

**Status**: steady-state extended-phase. All required topics PASSED healthy margins. Q4 defect is a per-instance responder slip on already-defended content — accept and re-probe rather than over-fix.

---

## Rubric updates

| Topic | Prior | Q score | New | Delta | Margin vs 3.5 |
|---|---|---|---|---|---|
| Iceberg table maintenance | 4.4461 / 219 | Q1=4.875 | 4.4480 / 220 | +0.0019 | +0.9480 |
| SQL query best practices for OLAP | 4.5867 / 277 | Q2=4.875 | 4.5878 / 278 | +0.0011 | +1.0878 |
| Improving complex SQL perf on Trino with dbt | 4.5678 / 42 | Q3=5.0 | 4.5779 / 43 | +0.0101 | +1.0779 |
| Oracle PL/SQL → dbt + Trino SQL migration | 4.4786 / 173 | Q4=2.625 | 4.4680 / 174 | -0.0106 | +0.9680 |

All required topics remain PASSED. No FIX-A. Next iter1212: BREADTH (re-probe strpos-3-arg myth under structurally-similar framing within 4-8 iters per the watch).

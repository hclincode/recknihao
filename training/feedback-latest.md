# Iteration 1223 — Judge Feedback

**Verdict: 4.78125 STRONG PASS — NO-OP, two minor soft watches (Q3 packages.yml install-step findability gap + Q4 Oracle-GREATEST-NULL premise slip).** Resources teach the correct Q4 fact at multiple LEADING CANONICAL slots (r23 §2221 + r27 §1721); responder slip is recall-ceiling, NOT resource-sourced. Q2 synthesis-ceiling gaps-and-islands streak LANDS clean (historical Haiku failure pattern stabilized).

Per-question summary:
- Q1 5.0 — Iceberg time-travel `FOR TIMESTAMP AS OF DATE '...'` canonical reach, no `$snapshots`-lookup pre-step
- Q2 4.875 — gaps-and-islands 3-CTE streak (CASE inversion variant logically equivalent to r07 §3286 canonical, output correct)
- Q3 4.9375 — `dbt_utils.generate_surrogate_key` setup + Trino compatibility; honest flag on packages.yml gap + correct general-knowledge fill
- Q4 4.3125 — Trino-side COALESCE-wrap fix correct + all-null CASE variant correct; "different from Oracle (which ignores NULLs)" aside is FACTUALLY WRONG (Oracle ALSO returns NULL on any NULL arg)

Iter average: (5.0 + 4.875 + 4.9375 + 4.3125) / 4 = **4.78125**, margin +1.28.

---

## Q1 — Iceberg time-travel `FOR TIMESTAMP AS OF DATE '...'` without finding the snapshot ID first

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**Scenario.** `accounts` Iceberg table — customer claims `account_tier='enterprise'` on Jun 1, downgraded sometime in last 3 weeks; `$snapshots` has 50 entries and engineer doesn't know which maps to which date. Wants the row as it existed on Jun 1 WITHOUT first finding the snapshot ID.

**Responder reach.**
- `SELECT * FROM iceberg.analytics.accounts FOR TIMESTAMP AS OF DATE '2026-06-01' WHERE account_id = ...` — DATE literal works (Trino coerces to TIMESTAMP at start-of-day); equivalently `TIMESTAMP '2026-06-01 00:00:00 UTC'`.
- Trino's Iceberg connector resolves to the **most recent snapshot committed AT OR BEFORE that timestamp** — no snapshot ID lookup needed.
- Correct distinction: `FOR VERSION AS OF <snapshot_id>` is for `BIGINT` snapshot IDs (or named branch/tag); `FOR TIMESTAMP AS OF` is the time-keyed lookup.
- Must be a DATE/TIMESTAMP **literal**, not a column reference.
- Time-travel returns table state at that point: schema + data exactly as it was committed.

**Verification.** [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) verbatim: *"The latest snapshot of the table taken before or at the specified timestamp in the query is internally used"* and the docs example explicitly shows `SELECT * FROM example.testdb.customer_orders FOR TIMESTAMP AS OF DATE '2022-03-23';` — DATE-literal coercion confirmed in official docs. PR [trinodb/trino#10258](https://github.com/trinodb/trino/pull/10258) discussion: `DATE '2021-01-02'` is treated as `TIMESTAMP '2021-01-02 00:00:00.000000000'` for coercion purposes. `FOR VERSION AS OF` accepts BIGINT snapshot IDs or named branch/tag strings.

Clean direct reach to the time-travel canonical. Cites r17/r28.

---

## Q2 — Longest streak of consecutive active days (login streak / gaps-and-islands) — SYNTHESIS-CEILING WIN

**Score: 4.875** — Acc 5.0 / Clar 4.5 / App 5.0 / Compl 5.0

**Scenario.** `events(user_id, event_ts)`. Distinct active days easy; engineer is stuck building runs of consecutive dates + longest unbroken run (e.g., Jun 1,2,3 skip 4 active 5,6 → longest = 3) WITHOUT a self-join per gap.

**Responder reach.** Three-CTE gaps-and-islands mirroring r07 §3286 canonical (Pattern B-Streak, iter876 PIN):
1. `flagged` — `is_new_streak = CASE WHEN date_diff('day', LAG(active_day) OVER (PARTITION BY user_id ORDER BY active_day), active_day) <> 1 THEN 1 ELSE 0 END` over `(SELECT DISTINCT user_id, CAST(event_ts AS DATE) AS active_day FROM events)`.
2. `streaks` — `streak_id = SUM(is_new_streak) OVER (PARTITION BY user_id ORDER BY active_day)`.
3. `streak_lengths` — `COUNT(*) AS streak_len GROUP BY user_id, streak_id`.
4. Final: `SELECT user_id, MAX(streak_len) AS longest_streak_days GROUP BY user_id`.
- Correctly noted CANNOT nest windows → three CTEs required.

**Verification — output correct.** Trace example (Jun 1,2,3,5,6):
- Jun 1: `LAG=NULL` → `date_diff(NULL, Jun1)=NULL` → `NULL <> 1` UNKNOWN → ELSE → `is_new_streak=0`, `streak_id=SUM=0`.
- Jun 2,3: `date_diff=1` → `1 <> 1` FALSE → ELSE → `is_new_streak=0`, `streak_id=0`.
- Jun 5: `date_diff=2` → `2 <> 1` TRUE → WHEN → `is_new_streak=1`, `streak_id=1`.
- Jun 6: `date_diff=1` → `is_new_streak=0`, `streak_id=1`.
- COUNT per streak_id: (user, 0)=3, (user, 1)=2 → MAX=3. **CORRECT.**

Responder's CASE inversion (`<> 1 THEN 1 ELSE 0`) vs canonical r07's (`= 1 THEN 0 ELSE 1`) is **logically equivalent** for the SUM-over-flag streak-id construction. Canonical's first row gets `streak_id=1` (1-indexed); responder's first row gets `streak_id=0` (0-indexed). Both group consecutive days correctly because streak boundaries are detected by the INCREMENT in the running sum, not by the starting value. COUNT-per-streak-id and MAX-over-counts are unaffected by the 0-vs-1 offset.

**Minor nit (-0.125 Clarity).** Responder's narrative comment "first row → new streak starts" is slightly inconsistent with the literal code path (their first row gets `is_new_streak=0` not 1, because their flag is `is_GAP_TO_PRIOR` not `is_NEW_STREAK_START`). The semantic INTENT (first row begins a streak) is preserved in the streak_id assignment, but an engineer reading the comment carefully against the CASE could be momentarily confused. Output is correct — non-load-bearing.

**Synthesis-ceiling signal.** This is HISTORICALLY a Haiku synthesis-ceiling pattern (per `feedback_synthesis_ceiling_stop_churning.md` — iter951-956 gaps-and-islands streak-construction repeatedly failed across novel domains). The iter876 r07 §3277 canonical PIN is doing its job. Strong credit for landing the assembly on a fresh phrasing ("login streak" / "active days" / "longest unbroken run") with the correct 3-CTE shape AND the no-nest-windows constraint explicitly called out. Cites r07.

---

## Q3 — `dbt_utils.generate_surrogate_key` setup + Trino compatibility — minor findability gap, responder filled correctly

**Score: 4.9375** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 4.75

**Scenario.** Oracle SEQUENCE int PKs everywhere; Iceberg has no auto-increment. dbt fact models join 3-4 staging tables; need stable unique key per output row for incremental MERGE; no single natural key works. Saw `dbt_utils.generate_surrogate_key` mentioned — needs install steps + Trino-compatibility confirmation.

**Responder reach.**
- Model SQL: `{{ dbt_utils.generate_surrogate_key(['tenant_id', 'natural_order_id']) }} AS order_pk` in SELECT + `config(materialized='incremental', unique_key='order_pk', incremental_strategy='merge')` — mirrors r27 §4.5A canonical exactly.
- Jinja macro → deterministic MD5 hash → VARCHAR(32) output; stable across runs AND clusters (unlike ROW_NUMBER which is only run-stable).
- **Install** (flagged honestly as not explicitly walked through in resources): create `packages.yml` at project root with `packages: - package: dbt-labs/dbt_utils version: 1.1.1`, then `dbt deps`, then macro is available.
- Works on Trino via dbt-trino — macro compiles to plain `md5(...)`-equivalent SQL that runs natively.

**Verification.** [github.com/dbt-labs/dbt-utils](https://github.com/dbt-labs/dbt-utils) + [docs.getdbt.com/blog/managing-surrogate-keys](https://docs.getdbt.com/blog/managing-surrogate-keys) confirm: MD5 hash, deterministic, cross-warehouse compatible, install via packages.yml + dbt deps. r27 §1865 documents the compiled-SQL shape: `md5(cast(coalesce(cast(tenant_id as varchar), '_dbt_utils_surrogate_key_null_') || '-' || coalesce(cast(natural_order_id as varchar), '_dbt_utils_surrogate_key_null_') as varchar))`. dbt-trino translates via adapter dispatch to Trino-compatible `to_hex(md5(to_utf8(...)))` — confirmed at r27 §4.5 row.

**Coverage gap noted (-0.0625 Compl).** Grep `packages\.yml|dbt deps|dbt-labs/dbt_utils` across resources:
- r27 §2524: mentions packages.yml in passing (DBT_ENV_SECRET context, not as install guide).
- r27 §3128: `dbt deps` in a CI pseudo-script for source-freshness (not an install how-to).
- r27 §3868: parenthetical "no dbt deps, no packages.yml entry" (negative example for exposures).
- r27 §4555: "Cross-project reusable via `dbt deps` packages (e.g., `dbt_utils`)" — one-liner aside.

NO leading canonical that explicitly walks through: (1) create packages.yml at project root → (2) add `dbt-labs/dbt_utils` block with version → (3) run `dbt deps` → (4) macros now available in models. Responder's honest flag ("resources reference dbt_utils but don't include explicit packages.yml setup") is accurate and they filled the gap from general knowledge **correctly**. This is a minor findability/coverage gap — but the responder handled it well (transparent flag + correct fill), so the engineer is not blocked.

**Watch (NO immediate FIX-A).** `r27 packages.yml + dbt deps install canonical iter1223 — additive findability` (responder honest flag + correct general-knowledge fill). Re-probe in 4-8 iters under varied phrasings ("how do I install dbt_utils" / "where does packages.yml go" / "do I need to install anything for dbt_utils macros"). If recurs across phrasings AND another responder fails the general-knowledge fill, additive LIGHT FIX-A on r27 with the four-step install canonical. Cites r27.

---

## Q4 — Oracle `GREATEST(...)` returning NULL on Trino — Trino-side fix CORRECT, Oracle premise WRONG (responder slip)

**Score: 4.3125** — Acc 3.5 / Clar 5.0 / App 5.0 / Compl 3.75

**Scenario.** Engineer ported Oracle `GREATEST(last_login_at, last_purchase_at, last_support_contact_at)` for most-recent touch. Some customers have NULL on `last_purchase_at` etc.; on Trino those customers return NULL ("Trino sees any NULL arg and gives up"). Expected? Right way to make NULL columns get ignored (return max of non-null dates)?

**Responder reach — Trino-side CORRECT.**
- Trino 467 `GREATEST` / `LEAST` return NULL if ANY arg is NULL — verified at [trino.io/docs/467/functions/comparison.html](https://trino.io/docs/467/functions/comparison.html) verbatim: *"Like most other functions in Trino, they return null if any argument is null. Note that in some other databases, such as PostgreSQL, they only return null if all arguments are null."*
- Primary fix: wrap each arg with `COALESCE` to a low-sentinel timestamp:
  ```sql
  GREATEST(
    COALESCE(last_login_at,           TIMESTAMP '1970-01-01 00:00:00'),
    COALESCE(last_purchase_at,        TIMESTAMP '1970-01-01 00:00:00'),
    COALESCE(last_support_contact_at, TIMESTAMP '1970-01-01 00:00:00')
  ) AS last_touch_at
  ```
- All-null variant (so customers with NO touches stay NULL, not stamped to epoch):
  ```sql
  CASE
    WHEN last_login_at IS NULL
     AND last_purchase_at IS NULL
     AND last_support_contact_at IS NULL THEN NULL
    ELSE GREATEST(COALESCE(...), COALESCE(...), COALESCE(...))
  END
  ```
- Cited the `reference_trino_greatest_least_null` memory pin.

**SLIP — Oracle premise propagation (factually wrong aside).** Responder said: *"This is different from Oracle (which ignores NULLs)."* **FALSE.** Per [database.guide GREATEST in Oracle](https://database.guide/greatest-function-in-oracle/) + [Oracle TimesTen GREATEST docs](https://docs.oracle.com/en/database/other-databases/timesten/22.1/sql-reference/greatest.html) + multiple Ask TOM threads: **Oracle's GREATEST ALSO returns NULL if any argument is NULL.** Oracle docs verbatim: *"If any argument is null, GREATEST returns null."*

The engineer's framing ("Trino sees any NULL arg and gives up") implicitly assumed Oracle behaved differently. The responder **echoed** the mistaken premise instead of correcting it.

**The resources EXPLICITLY teach the correct fact.**
- r23 §2221 LEADING CANONICAL header: "`greatest()` / `least()` return NULL if ANY arg is NULL in Trino (Oracle + MySQL + BigQuery match; **PostgreSQL DIFFERS**)" — verbatim: *"Trino (and Oracle, MySQL, BigQuery) — greatest(...) / least(...) return NULL if ANY argument is NULL. PostgreSQL — IGNORES NULL args, returning NULL only if ALL args are NULL."*
- r27 §1721 verbatim: *"Oracle's GREATEST / LEAST also return NULL if any arg is NULL (Oracle matches Trino here, but engineers coming from Postgres muscle memory get bitten)."*
- r23 §2239 DO-NOT-WRITE row 2: *"Postgres and Trino greatest/least behave identically on NULL"* — FALSE; Trino+Oracle+MySQL+BigQuery match; Postgres is the outlier.

Responder's "different from Oracle (which ignores NULLs)" contradicts r23 §2221 + r27 §1721 directly. **Recall-ceiling responder slip, NOT a resource defect.**

**Why the slip matters but doesn't fail the answer.** The Trino-side advice (COALESCE-wrap with sentinel, plus the all-null CASE wrapper) is **the correct fix for the engineer's REAL problem** — they will solve their Trino issue by applying it. But they walk away believing Oracle was forgiving and Trino is the strict one, which is a false migration mental model — could mislead them in OTHER Oracle-to-Trino porting decisions (e.g., assuming other "strict-on-NULL" behavior is Trino-specific when it's actually shared with Oracle).

**Classification.** Fits `feedback_responder_broken_secondary_alternative.md` family (LEAD passes, secondary aside is broken) AND adjacent to `feedback_responder_overwarning_folklore.md` (responder reinforced engineer's mistaken premise instead of correcting it). Per `feedback_synthesis_ceiling_stop_churning.md` discipline: do NOT churn the defang. Correct facts are ALREADY in resources at MULTIPLE LEADING CANONICAL slots. Adding MORE Oracle-matches-Trino emphasis risks regressing adjacent Postgres-differs questions. **NO FIX-A.**

**Watch (NO immediate FIX-A).** `r23 §2221 Oracle-matches-Trino-on-GREATEST-NULL responder slip iter1223 — recall-ceiling, no resource fix, re-probe`. Re-probe in 6-10 iters under explicit Oracle-comparison phrasings ("does Oracle GREATEST behave the same?" / "is this Trino-specific?"); if recurs across phrasings, evaluate top-of-r27 Oracle-Trino-NULL-parity FAQ anchor as a possible additive routing card (not a content change). Cites r23/r27.

---

## Topic checklist updates

This iter touches:
- **Iceberg time-travel / metadata-tables / table-maintenance** (Q1) — clean canonical reach
- **Analytical query patterns on Iceberg+Trino** (Q2 gaps-and-islands streak) — synthesis-ceiling LANDS
- **Oracle-PL/SQL-to-dbt-Trino migration** (Q3 dbt_utils install + Q4 Oracle GREATEST) — Q3 honest gap-flag + correct fill; Q4 Oracle-premise slip
- **SQL-best-practices-OLAP** (Q4 GREATEST NULL canonical) — resources correct, responder slipped on echoing user's mistaken Oracle premise

All required topics REMAIN PASSED with healthy margins. Iter average **4.78125 STRONG PASS** (margin +1.28).

## Source-verified outcomes this iter

- 0 Trino dialect errors (all Trino-side advice clean)
- 1 cross-engine factual slip (Q4 Oracle GREATEST-NULL aside — recall-ceiling, NOT resource-sourced; r23 §2221 + r27 §1721 teach correctly)
- 1 minor findability gap (Q3 dbt_utils install / packages.yml — responder honestly flagged + correctly filled from general knowledge)
- 1 SYNTHESIS-CEILING WIN (Q2 gaps-and-islands streak — historically a Haiku failure pattern, lands clean here with a valid CASE-inversion variant of r07 §3286)
- 0 fabrications
- 0 over-warning folklore on Trino constructs

## Recommendation

**NO-OP.** No resource edits. Commit rubric + feedback only. Two new soft-watches added:
1. `r27 packages.yml + dbt deps install canonical iter1223 — additive findability` (re-probe 4-8 iters)
2. `r23 §2221 Oracle-matches-Trino-on-GREATEST-NULL responder slip iter1223 — recall-ceiling, NO resource fix` (re-probe 6-10 iters)

## Open watches (carry-forward)

- iter1222: CAST-DECIMAL-money + TRY_CAST-dirty-staging (5-9 iters)
- iter1219: CoW-MoR + format-%08d
- iter1215: strpos-3-arg CEILING (no churn)
- iter1213: session_properties + (+)-mnemonic
- iter1221: quarterly-window-vs-transform
- Light monitors: NVL-coercion, width_bucket, translate-phone-example

## Pattern observation

Sustainment band continues — ~14th consecutive iter with either NO-OP or watch-close + light-touch. The Q2 win is the load-bearing signal of this iter: gaps-and-islands streak construction (historical Haiku synthesis ceiling per iter951-956) has stabilized cleanly via the iter876 r07 §3277 canonical, and a domain-shifted phrasing ("login streak" not "session" not "consecutive returns") routed correctly with the 3-CTE constraint preserved AND the no-nest-windows admonition surfaced. The Q4 Oracle premise slip is the Nth recall-ceiling instance — responder echoes the user's stated mistaken premise rather than correcting it. Resources teach correctly at multiple LEADING CANONICAL slots; per stop-churning discipline, accept as ceiling and re-probe. Q1 + Q3 are clean canonical reaches with Q3's transparent gap-flag + correct fill being the kind of honest behavior we want to see when a resource doesn't have a step-by-step install walkthrough.

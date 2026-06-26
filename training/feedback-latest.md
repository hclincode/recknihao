# Iter1147 Judge Feedback

**Verdict: 4.59375 STRONG PASS NO-OP. The Q1 1-level first-vs-latest re-probe characterizes the iter1146 Q2 synthesis ceiling cleanly: responder DOES assemble the 1-level pick-first/last-value-per-device pattern correctly with TWO valid forms (twin ROW_NUMBER+MAX(CASE) PRIMARY and FIRST_VALUE/LAST_VALUE-with-explicit-frame ALTERNATIVE). This confirms iter1146 Q2 was specifically the 2-LEVEL grain failure (SUM-revenue-per-month THEN pick first-month — a per-period aggregation collapsing the grain so the row-level FIRST_VALUE/min_by trick no longer applies), NOT a general first-vs-latest blind spot. Q2 (missing-IDs gaps-and-islands via LAG+sequence+UNNEST) is structurally sound with a minor unstated boundary-limitation. Q3 (TRY_CAST) is canonical. Q4 (dbt model contracts) reaches the build-time preflight check + dbt-trino Iceberg constraint-enforcement nuances correctly. No FIX-A this iteration.**

---

## Q1 — Device firmware at first reading vs at most-recent reading per device (single query)

**Question:** Telemetry table (device_id, reading_ts, firmware_version). Need one row per device showing firmware at its FIRST reading vs at its MOST RECENT reading to find never-upgraded devices. Single query.

**Responder's answers (both shown, neither relying on min_by/max_by):**
- **PRIMARY — twin ROW_NUMBER + MAX(CASE) collapse:**
  ```sql
  WITH ranked AS (
    SELECT device_id, reading_ts, firmware_version,
           ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY reading_ts ASC)  AS rn_first,
           ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY reading_ts DESC) AS rn_last
    FROM telemetry
  )
  SELECT device_id,
         MAX(CASE WHEN rn_first = 1 THEN firmware_version END) AS firmware_at_first,
         MAX(CASE WHEN rn_last  = 1 THEN firmware_version END) AS firmware_at_latest
  FROM ranked
  GROUP BY device_id;
  ```
- **ALTERNATIVE — SELECT DISTINCT with FIRST_VALUE/LAST_VALUE and an EXPLICIT full-partition frame:**
  ```sql
  SELECT DISTINCT
    device_id,
    FIRST_VALUE(firmware_version) OVER (
      PARTITION BY device_id ORDER BY reading_ts ASC
      ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS firmware_at_first,
    LAST_VALUE(firmware_version) OVER (
      PARTITION BY device_id ORDER BY reading_ts ASC
      ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS firmware_at_latest
  FROM telemetry;
  ```
  Then `WHERE firmware_at_first = firmware_at_latest` surfaces never-upgraded devices.

**Verification (Trino 467 docs + standard windowing semantics):**
- Twin ROW_NUMBER with `ASC` + `DESC` over the same partition is a long-standing canonical for "pick first AND last per group" in a single pass. With strictly monotonic `reading_ts` (typical of telemetry) both row-numbers are deterministic; with ties, a tiebreaker should be added but neither tie case nor the tiebreaker is load-bearing for the engineer's intent. `MAX(CASE WHEN rn_first=1 THEN firmware_version END)` collapses to one row per device with the correct value because only one row in each partition has `rn_first=1` (all other rows contribute NULL, which MAX ignores). CORRECT.
- The ALTERNATIVE explicitly writes `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` on BOTH window calls. This is precisely the LAST_VALUE default-frame trap fix — without an explicit ROWS clause, the SQL-standard default frame is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`, under which `LAST_VALUE(x) OVER (ORDER BY ts)` returns the CURRENT row's value (= same as x), making it useless. Responder named the trap implicitly by writing the explicit frame; this is the correct version-stable form for Trino 467. CORRECT.
- The `SELECT DISTINCT` collapse with windowed columns yields one row per device because both window expressions are constant per partition under the full-partition frame. CORRECT.
- Absence of `min_by`/`max_by`: This would be the most idiomatic Trino-specific form (`SELECT device_id, min_by(firmware_version, reading_ts) AS first_fw, max_by(firmware_version, reading_ts) AS latest_fw FROM telemetry GROUP BY device_id` — a one-CTE-free single-aggregation answer). The responder did not lead with it. This is a minor COMPLETENESS shave (recall ceiling, foreign-looking aggregate pattern), NOT a correctness defect — the two answers given are both fully correct, both produce one row per device with the right firmware at first/latest, and both work without ties caveats matching the engineer's intent.

**Synthesis-ceiling characterization (the run-prompt asked):**
- This Q1 is **1-level** first-vs-latest: pick the firmware_version VALUE per device with no per-period aggregation. The grain of the input matches the grain of the output (one row per device).
- iter1146 Q2 was **2-level** first-vs-latest: first GROUP BY (account, month) to SUM(amount) into per-month revenue (intermediate grain change), THEN pick first-month-revenue and latest-month-revenue per account (final grain). The challenge is recognizing that the per-period aggregation must happen in a CTE FIRST, and only then does the row-level min_by/max_by select-by-ordering trick apply against the aggregated rows (the monthly rows).
- iter1146 Q2 responder put both the per-month aggregation AND the first/latest collapse in the SAME GROUP BY level, which made `min_by(date_trunc('month', occurred_at), occurred_at)` a tautology (within a per-month group, all `occurred_at` values are in that month, so its min/max are that month). Self-join WHERE filter degenerated to no-op → per-account cross-product of all month-pairs.
- This iter1147 Q1 has NO intermediate grain change (the input grain — one row per (device, reading_ts) — already exposes firmware_version directly), so the responder did NOT need to recognize a two-level decomposition. Solved correctly at first attempt with two valid forms.
- **Confirms: iter1146 Q2 is a 2-LEVEL synthesis ceiling, not a general first-vs-latest blind spot.** Per pinned `feedback_synthesis_ceiling_stop_churning`, this is the expected residual at the Haiku synthesis ceiling for compound multi-grain queries. Do NOT add a generic FIX-A. If the 2-level form recurs across a separate domain in a future sweep, consider an additive r07 canonical card specifically for "first-period-vs-latest-period per entity" with the two-level CTE shape (monthly aggregation CTE → outer min_by/max_by). For now, the 1-level form is solid.

**Score:**
- Technical accuracy: 5 — both forms are correct Trino 467; LAST_VALUE default-frame trap correctly defused by explicit frame
- Beginner clarity: 4.5 — two forms with reasoning; brief on tie semantics
- Practical applicability: 5 — engineer copies either form and runs immediately; the WHERE filter for never-upgraded is named
- Completeness: 4 — min_by/max_by not led with; both given forms fully solve the problem
- **Average: 4.625**

---

## Q2 — Find MISSING IDs in a strictly sequential numeric order_id sequence

**Question:** Strictly sequential order_id; some dropped before reaching Iceberg. Find missing IDs (1001,1002,1004 → surface 1003).

**Responder's answer:**
```sql
WITH gaps AS (
  SELECT order_id,
         LAG(order_id) OVER (ORDER BY order_id) AS prev,
         CASE WHEN LAG(order_id) OVER (ORDER BY order_id) IS NULL
              THEN 0
              ELSE order_id - LAG(order_id) OVER (ORDER BY order_id) - 1
         END AS gap_size
  FROM orders
)
SELECT DISTINCT n AS missing_id
FROM gaps
CROSS JOIN UNNEST(
  CASE WHEN gap_size > 0
       THEN sequence(prev + 1, order_id - 1)
       ELSE CAST(ARRAY[] AS ARRAY(BIGINT))
  END
) AS t(n)
WHERE gap_size > 0
ORDER BY missing_id;
```
Walks 1001/1002/1004/1005 correctly returning `[1003]`.

**Verification:**
- `sequence(start, stop)` in Trino is inclusive on both ends (per `trino.io/docs/current/functions/array.html` — "stop is the end of the range, inclusive"). For consecutive IDs 1002→1004: `prev=1002, order_id=1004`, `sequence(1003, 1003) = [1003]` → one element. For 1004→1005 (no gap): `gap_size = 0`, branch returns empty array, UNNEST yields zero rows. CORRECT.
- `CROSS JOIN UNNEST(empty_array)` yields zero rows for that source row (the empty-array UNNEST short-circuit). The first row (`prev IS NULL`, `gap_size = 0`) thus contributes nothing. CORRECT.
- The `CAST(ARRAY[] AS ARRAY(BIGINT))` is necessary because empty `ARRAY[]` is `array(unknown)` in Trino, and a CASE branch needs branches of compatible types — the cast nails down `ARRAY(BIGINT)` to match `sequence`'s result type. Good defensive typing.
- The trailing `WHERE gap_size > 0` is redundant after the CASE+UNNEST already produces zero rows for gap_size=0 cases, but does not cause incorrectness. `SELECT DISTINCT` defends against any unlikely cross-product duplication.
- **Limitation NOT acknowledged:** This query cannot detect missing IDs BEFORE `MIN(order_id)` (e.g., if 1000 was dropped, the query would not surface 1000 because there's no row preceding 1001 to LAG against), nor AFTER `MAX(order_id)` (if 1006 was dropped after 1005). For "find dropped IDs since ingestion started" both bounds may matter operationally. The fix is to anchor the lower bound to an expected start (`SELECT sequence(<expected_min>, MAX(order_id))` as a generator) and check for IDs not in `orders`. Minor COMPLETENESS shave, not a correctness defect — within the closed range [MIN, MAX] the query is correct.

**Score:**
- Technical accuracy: 5 — `sequence` semantics, empty-array UNNEST, type-safe ARRAY(BIGINT) cast, LAG NULL-first-row handling all correct
- Beginner clarity: 4.5 — `sequence`+`UNNEST` is the right idiom; walkthrough makes it copy-paste ready
- Practical applicability: 4.5 — engineer runs as-is on `orders`; gets dropped IDs in the closed range; doesn't address pre-MIN/post-MAX gaps
- Completeness: 4 — boundary limitation unstated; otherwise complete
- **Average: 4.5**

---

## Q3 — 'N/A' strings in a decimal column abort CAST/arithmetic; plain Trino "if this row errors, return NULL and continue"?

**Question:** Legacy import has 'N/A' strings in a decimal price column; `CAST(price_str AS DECIMAL(10,2))` aborts the whole query on the bad row. Plain Trino SQL way to say "if this row errors, return NULL and continue"?

**Responder's answer:**
- `TRY_CAST(price_str AS DECIMAL(10,2))` returns NULL on cast failure instead of aborting the query
- Subsequent arithmetic involving NULL propagates NULL safely
- Filter with `WHERE try_cast(...) IS NOT NULL` or flag with `CASE WHEN try_cast(...) IS NULL THEN 'BAD' ELSE 'OK' END`
- Cites `try_cast` canonical in r23

**Verification (trino.io/docs/current/functions/conversion.html):**
- `try_cast(value AS TYPE)` is documented in Trino 467 as "like cast(), but returns null if the cast fails." CORRECT.
- NULL propagation through `+ - * /` and aggregate `SUM`/`AVG` skipping NULL is standard SQL behavior — correct.
- **Could-have-added (minor, NOT a defect):** The broader `try(expr)` function handles division-by-zero, numeric-overflow, invalid-function-argument, JSON-parse-failure — not just CAST. For the engineer's exact stated symptom (`CAST` aborting on 'N/A'), `try_cast` is the precise answer; `try()` would also work but is a heavier hammer. The question explicitly says "CAST/arithmetic aborts", so naming `try()` as an arithmetic-error counterpart (e.g., `try(a / b)` for safe division) would have been a nice completeness add. Recall ceiling, NOT a resource-fix item.

**Score:**
- Technical accuracy: 5 — TRY_CAST exists, returns NULL on failure, NULL-propagation safe
- Beginner clarity: 5 — short, direct, no jargon
- Practical applicability: 5 — engineer copy-pastes `TRY_CAST(price_str AS DECIMAL(10,2))` and is done
- Completeness: 4 — `try()` not named for arithmetic errors; the question's CAST focus was answered
- **Average: 4.75**

---

## Q4 — dbt feature to enforce model column names and EXACT types, FAIL the build on violation

**Question:** A staging model column type silently changed BIGINT → VARCHAR, passed CI, broke downstream. Is there a dbt feature to declare "this model must produce these column names with these EXACT types" and FAIL the build on violation?

**Responder's answer:**
- **Yes — dbt model contracts.** In schema.yml:
  ```yaml
  models:
    - name: stg_orders
      config:
        contract:
          enforced: true
      columns:
        - name: order_id
          data_type: bigint
        - name: order_total
          data_type: decimal(18,2)
        - name: status
          data_type: varchar
        - name: created_at
          data_type: timestamp(6)
  ```
- dbt performs a **preflight check** comparing actual SELECT output column types to the contract BEFORE materializing the model
- On mismatch, dbt build halts with a Compilation Error ("This model has an enforced contract that failed" + a mismatch table showing column_name / definition_type / contract_type / mismatch_reason) and the model is NOT materialized — downstream models are skipped
- dbt-trino specific note: only `not_null` is RUNTIME-enforced (Iceberg writes the column as NOT NULL and INSERT of a NULL fails at write time); `primary_key`/`unique`/`foreign_key` are definable in the contract but NOT enforced at write — pair with `dbt test` (`unique`, `not_null`, `relationships`) for runtime validation
- Cites r27 §6.7C

**Verification:**
- `docs.getdbt.com/reference/resource-configs/contract` and `docs.getdbt.com/docs/mesh/govern/model-contracts`: contracts with `enforced: true` trigger a build-time preflight check; on mismatch, dbt raises a Compilation Error with the mismatch table (column_name, definition_type, contract_type, mismatch_reason) BEFORE the model is materialized. CORRECT.
- `docs.getdbt.com/reference/resource-configs/trino-configs`: confirms dbt-trino supports model contracts and explicitly states "Currently, only [constraints] with `type` as `not_null` are supported" — so `not_null` is the runtime-enforced constraint on dbt-trino; `primary_key`/`unique` constraints in the contract YAML are accepted at the contract level for the columns-and-types check but NOT translated into runtime DDL. The responder's framing "metadata-only — pair with dbt tests" is OPERATIONALLY ACCURATE (the engineer gets the same effect via dbt tests) even though strictly the dbt-trino docs phrase it as "only not_null supported" rather than "primary_key/unique stored as metadata." Aligns with the rubric topic line "primary_key/unique/foreign_key definable-but-not-enforced." CORRECT enough for the engineer's purpose; minor framing nit not load-bearing.
- The type-check granularity nuance the responder did NOT name (minor completeness shave): dbt applies built-in type aliasing for YAML `data_type` values, and relying on default precision/scale for numeric/decimal can cause implicit coercion that breaks contract enforcement; explicit precision (e.g., `decimal(18,2)` not bare `decimal`) avoids this. The responder DID write `decimal(18,2)` in the example, dodging the trap by example rather than by explicit warning. Acceptable.
- Q4 directly addresses the engineer's stated problem (BIGINT→VARCHAR silent change passing CI). Contracts catch exactly this on the next `dbt build` because the preflight compares actual SELECT output to declared types BEFORE materializing. Engineer's CI break gets surfaced as a dbt build failure with a precise mismatch table. CORRECT path.

**Score:**
- Technical accuracy: 4.5 — preflight + Compilation Error + halt-before-materialize all correct; dbt-trino primary_key/unique framing soft-correct (rubric-line-consistent, docs phrase it slightly differently)
- Beginner clarity: 4.5 — schema.yml example is concrete; jargon (contract / preflight / materialize) explained inline
- Practical applicability: 5 — engineer copies the YAML shape, adds `contract: {enforced: true}` to the broken stg_orders model, next CI run catches the BIGINT→VARCHAR drift before downstream breaks
- Completeness: 4.5 — type-aliasing/precision nuance not explicitly called out; the example uses explicit precision so the engineer dodges it implicitly
- **Average: 4.5**

---

## Overall verdict — STRONG PASS NO-OP (4.59375)

- **Q1 (1-level first-vs-latest per device): 4.625** — Twin ROW_NUMBER+MAX(CASE) PRIMARY correct, FIRST_VALUE/LAST_VALUE-with-explicit-full-partition-frame ALTERNATIVE correctly defuses the LAST_VALUE default-frame trap. min_by/max_by not led with (recall ceiling), but the two given forms are fully correct. **Confirms iter1146 Q2 was a 2-LEVEL synthesis ceiling, not a general first-vs-latest blind spot.**
- **Q2 (missing IDs in sequence): 4.5** — LAG + sequence(prev+1, current-1) + CROSS JOIN UNNEST + CAST empty-ARRAY[] is the canonical Trino idiom; first-row LAG-NULL handled. Minor boundary-limitation (no pre-MIN / post-MAX detection) unstated.
- **Q3 (TRY_CAST for 'N/A'): 4.75** — Canonical; `try()` for arithmetic not named (recall ceiling, not load-bearing).
- **Q4 (dbt model contracts): 4.5** — preflight + Compilation Error + halt-before-materialize all correct; dbt-trino not_null-only-runtime-enforced + primary_key/unique-via-dbt-tests is operationally accurate.

**No FIX-A this iteration.** No resource defect surfaced; all four answers reach the canonical form. Synthesis-ceiling characterization for iter1146 Q2 is the load-bearing finding: the responder solves 1-level first-vs-latest cleanly, so the iter1146 failure is specifically the per-period-aggregation-then-collapse-grain double-step (consistent with pinned `feedback_synthesis_ceiling_stop_churning`). Recommend re-probing the 2-level form in a future sweep with a different domain (first-week-vs-latest-week per user, first-quarter-vs-latest-quarter per account) to confirm per-question variance vs recurrent pattern before considering a r07 canonical card.

---

## Topic-row updates

- **Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL** (Q1) — current 4.4580/99 → new (455.342 + 4.625)/100 = **4.59967/100 PASSED** (+0.1417 lift, margin +1.0997). The 1-level first-vs-latest re-probe was a clean SOLVE; reinforces that the iter1146 Q2 failure was 2-level-specific.
- **SQL query best practices for OLAP** (Q2 missing-IDs + Q3 TRY_CAST) — current 4.5623/211 → averaging Q2+Q3 = (4.5+4.75)/2 = 4.625; new (962.6453 + 4.5 + 4.75)/213 = **4.56524/213 PASSED** (+0.0029 lift, margin +1.0652).
- **dbt model contracts** (Q4) — current 4.4780/7 → new (31.346 + 4.5)/8 = **4.4808/8 PASSED** (+0.0028 lift, margin +0.9808).

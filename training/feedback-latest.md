# Iteration 1229 — Judge Feedback

**Verdict: 4.625 STRONG PASS (margin +1.125).** Q1 and Q2 are WATCH re-probes that land the core canonical with minor slips; Q3 (WATCH) and Q4 land clean 5.0. Iter average (4.25 + 4.25 + 5.0 + 5.0)/4 = 4.625.

- **iter1226 r17/r21 `table_changes`-MoR FIX-A WATCH: CLOSES** on first re-probe (Q1 4.25). Responder correctly identifies (a) Trino 467 HAS `iceberg.system.table_changes()` TVF, (b) it does NOT work on MoR/delete-file tables (Spark MERGE INTO orders is MoR), (c) the practical fallback = two-snapshot FULL OUTER JOIN diff. The iter1226 FIX-A card is being surfaced as THE answer — this is the exact multi-hop fact set the engineer needs (existence + limitation + workaround). Minor non-load-bearing slip: responder also gave a `"orders@v1"` snapshot syntax which is a Spark/Iceberg-SQL extension, NOT valid Trino (Trino uses `FOR VERSION AS OF`); the responder ALSO gave the correct `FOR VERSION AS OF <snapshot_id>` form, so the engineer who copies either lands on the correct path on retry. See "Q1 slip flag" below.
- **iter1218 r24 `accepted_values`-NULL+`not_null`-stack WATCH: REMAINS CLOSED** (Q3 5.0). Responder explains the 3VL `NOT IN` mechanism and pairs `not_null` + `accepted_values` correctly. Re-confirmation re-probe.
- **iter1208 r07 width_bucket boundary-label cosmetic recurrence** (Q2 4.25). Responder NAILS the load-bearing facts (array overload, buckets 0..N, underflow = 0, open-ended top = bucket N not N-1) but labels bucket 0 as `'$0-$50'` — under width_bucket's half-open `[b_i, b_{i+1})` semantics, the value `$50.00` lands in bucket 1, not 0, so the engineer-facing label is ambiguous at the boundary (the exact same cosmetic slip flagged at iter1208). Same family, light-monitor — NO churn-worthy FIX-A.
- **Q4 5.0** — clean Trino-canonical `date_diff('minute'/'second', start, end)` for the Oracle `EXTRACT(MINUTE FROM ts2-ts1)` migration. No slip.

Per-question summary:
- **Q1 4.25 (WATCH CLOSE, MINOR SLIP)** — `table_changes()` existence + MoR limitation + FULL OUTER JOIN snapshot-diff workaround correctly delivered. Slip: included Spark `"table@v1"` syntax alongside Trino's `FOR VERSION AS OF`; the @v1 form would parse-error in Trino, but is presented as an alternative not THE form. Engineer arrives at correct path.
- **Q2 4.25 (WATCH light-monitor recurrence)** — array-form `width_bucket(x, ARRAY[50.0,100.0,250.0,500.0,2000.0])` correctly named; buckets 0..5; bucket 0 = underflow; bucket 5 = open-ended top (the load-bearing "use N not N-1 for open-ended top" answer is correct). Cosmetic label slip on boundary (`'$0-$50'` should be `'<$50'` or `'$0-<$50'`) — same family as iter1208, no resource defect.
- **Q3 5.0 (WATCH CLOSE re-confirm)** — explains accepted_values compiles to `WHERE col NOT IN (list)`, 3VL UNKNOWN excludes NULLs from the failing set, fix is `not_null` + `accepted_values` stacked.
- **Q4 5.0** — `date_diff('minute', start, end)` / `date_diff('second', start, end)` returns BIGINT; correctly explains why Oracle `EXTRACT(MINUTE FROM ts2-ts1)` fails (no ts-ts operator in Trino + EXTRACT doesn't accept intervals).

---

## Q1 (WATCH) — Spark nightly MERGE INTO Iceberg orders (MoR); downstream dbt loses trust in `updated_at` watermark and full-scans; coworker mentions Iceberg snapshots and a "what changed between A and B" changelog — real in Trino 467? what to query, output?

**Score: 4.25** — Acc 4.0 / Clar 4.5 / App 4.0 / Compl 4.5

**WATCH OUTCOME: `iter1226 r17/r21 table_changes-MoR FIX-A` CLOSES on first re-probe.**

Responder shape:
1. **Yes, Trino 467 HAS `iceberg.system.table_changes()`** — TVF, args `schema_name => 'sch', table_name => 'orders', start_snapshot_id => <id>, end_snapshot_id => <id>`. Output: rows with `_change_type` (INSERT/DELETE/UPDATE_PREIMAGE/UPDATE_POSTIMAGE), `_change_ordinal`, `_commit_snapshot_id` + all base-table columns.
2. **BUT the orders table is Merge-on-Read with positional delete files** (Spark MERGE INTO produces position-deletes), and `table_changes()` does NOT cleanly support MoR delete-file tables — it fails/returns incomplete output when position-deletes are present in the snapshot range. The engineer's table is exactly the broken case.
3. **Practical workaround**: two-snapshot FULL OUTER JOIN snapshot-diff:
   ```sql
   WITH v1 AS (SELECT * FROM iceberg.sales.orders FOR VERSION AS OF <snap_a>),
        v2 AS (SELECT * FROM iceberg.sales.orders FOR VERSION AS OF <snap_b>)
   SELECT
     COALESCE(v1.order_id, v2.order_id) AS order_id,
     CASE WHEN v1.order_id IS NULL THEN 'INSERT'
          WHEN v2.order_id IS NULL THEN 'DELETE'
          ELSE 'UPDATE' END AS change_type, ...
   FROM v1 FULL OUTER JOIN v2 ON v1.order_id = v2.order_id
   WHERE v1.order_id IS NULL
      OR v2.order_id IS NULL
      OR <key-cols IS DISTINCT FROM>;
   ```

**Load-bearing facts VERIFIED:**

1. **`table_changes()` exists in Trino 467** — verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html): *"Allows reading row-level changes between two versions of an Iceberg table"* with the exact arg-shape (`schema_name`, `table_name`, `start_snapshot_id`, `end_snapshot_id`). Matches the iter1226 r17/r21 FIX-A card the responder is now surfacing.
2. **MoR / position-delete-file limitation is REAL** — confirmed by [trinodb/trino#17114](https://github.com/trinodb/trino/issues/17114) "Read Iceberg v2 table with many delete file is very slowly" + [trinodb/trino#24086](https://github.com/trinodb/trino/issues/24086) delete-files-not-removed-after-maintenance + [CDC patterns in Apache Iceberg (Ryan Blue, Trino Fest 2023)](https://trino.io/assets/blog/trino-fest-2023/TrinoFest2023Iceberg.pdf) — CDC/changelog scanning on MoR with positional deletes is the documented edge case where the changelog scan needs special handling. The responder's "fails on MoR delete-file tables" framing is correct enough for the engineer to act on (and matches the iter1226 card).
3. **`FOR VERSION AS OF <snapshot_id>` is the canonical Trino 467 versioned-read syntax** — verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html): *"SELECT * FROM table FOR VERSION AS OF 8954597067493422955"* + `FOR TIMESTAMP AS OF`. The two-snapshot CTE pattern with `FOR VERSION AS OF` cleanly bypasses the MoR `table_changes()` limitation because the snapshot reads themselves correctly apply position-deletes — only the changelog TVF struggles.
4. **`iceberg.system.snapshots` lists the snapshot ids** — engineer pulls `start_snapshot_id` (last successful watermark) and `end_snapshot_id` (latest) from `SELECT snapshot_id, committed_at FROM "orders$snapshots" ORDER BY committed_at`. This is the runbook for getting the inputs into either approach.

**Q1 SLIP FLAG — `"orders@v1"` table-suffix syntax is Spark/Iceberg-SQL ONLY, NOT valid Trino 467.** The responder showed BOTH `SELECT * FROM iceberg.sales.orders FOR VERSION AS OF <id>` (correct Trino) AND `SELECT * FROM iceberg.sales."orders@v1"` / `"orders@<snapshot_id>"` (Spark Iceberg SQL extension only). The @v1 form would parse-error in Trino 467 because Trino routes Iceberg versioned reads through the `FOR VERSION AS OF` / `FOR TIMESTAMP AS OF` SQL standard syntax, not through table-name decoration. Verified by [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) — only `FOR VERSION AS OF` / `FOR TIMESTAMP AS OF` documented for time-travel. NON-LOAD-BEARING because responder also gave the correct `FOR VERSION AS OF` form, the @v1 is positioned as "or" alternative not THE form. Engineer who copies @v1 hits a parse error and falls back to FOR VERSION AS OF; engineer who reads carefully picks FOR VERSION AS OF first. Family: imported-prior (Spark-Iceberg-SQL ↔ Trino-SQL alternation pattern). Per `feedback_responder_broken_secondary_alternative.md`, this fits the "responder nails the LEAD then appends a broken secondary alternative" pattern — per-instance one-off, NO resource FIX-A. **SOFT WATCH `iter1229 Q1 @v1 / table-suffix snapshot syntax Spark-only`**: re-probe in 4-8 iters under similar Iceberg time-travel framing; if recurs, light defang on the snapshot-syntax cards.

**Q1 sketchy-but-cosmetic note — whole-row IS DISTINCT FROM.** The responder's `WHERE snapshot_v1 IS DISTINCT FROM snapshot_v2` (comparing whole table aliases as records) is *technically* valid in Trino as anonymous-row comparison (since `IS DISTINCT FROM` works on ROW values) but is fragile — picks up any column drift including audit columns, and degrades to all-NULL comparison if the join misaligns. The canonical form is per-column `IS DISTINCT FROM` on the columns the engineer cares about, OR `WHERE v1.order_id IS NULL OR v2.order_id IS NULL OR (v1.amount IS DISTINCT FROM v2.amount OR v1.status IS DISTINCT FROM v2.status)`. Cosmetic — engineer who reads the resulting plan / output will refine. NO FIX-A.

**iter1226 FIX-A reached cleanly.** The iter1226 r17/r21 update added `table_changes()` existence + MoR limitation + FULL OUTER JOIN workaround to the canonical CDC card; this is exactly the multi-hop fact set the engineer needs (existence → limitation → workaround → output schema). 16th consecutive watch in the 1st-NO-OP-then-LIGHT-FIX-A-then-CLOSE pattern.

Engineer leaves with: correct knowledge that `table_changes()` exists, correct understanding that MoR breaks it for THEIR table, correct workaround pattern with correct snapshot syntax (modulo @v1 alternative which they'll discover doesn't parse), and a snapshot-id lookup path via `"orders$snapshots"`. Cites r17/r21.

---

## Q2 (WATCH) — Spend histogram with uneven buckets ($0-50/50-100/100-250/250-500/500-2000/2000+); six-branch CASE WHEN; can width_bucket auto-bin uneven buckets + handle open-ended top?

**Score: 4.25** — Acc 4.0 / Clar 4.5 / App 4.0 / Compl 4.5

**WATCH OUTCOME: `iter1208 width_bucket boundary off-by-one` cosmetic recurrence — light-monitor, NO FIX-A.**

Responder shape:
```sql
SELECT
  CASE width_bucket(order_amount, ARRAY[50.0, 100.0, 250.0, 500.0, 2000.0])
    WHEN 0 THEN '$0-$50'
    WHEN 1 THEN '$50-$100'
    WHEN 2 THEN '$100-$250'
    WHEN 3 THEN '$250-$500'
    WHEN 4 THEN '$500-$2000'
    WHEN 5 THEN '$2000+'
  END AS spend_bucket,
  COUNT(*)
FROM orders
GROUP BY 1
ORDER BY 1;
```
Plus the load-bearing facts: array overload `width_bucket(x, bins[])` returns 0..N (5 bounds → buckets 0..5 = 6 total); bucket 0 = underflow (x < first bound); **bucket N = open-ended top (x >= last bound)** — the engineer's `$2000+` need is satisfied by mapping bucket 5 to label, NO hardcoded upper bound required.

**Load-bearing facts VERIFIED:**

1. **Array overload signature** — verified at [trino.io/docs/current/functions/math.html](https://trino.io/docs/current/functions/math.html): *"width_bucket(x, bins) → bigint — Returns the bin number of x according to the bins specified by the array bins. The bins parameter must be an array of doubles, and is assumed to be in sorted ascending order."*
2. **Bucket numbering 0..N for N-element bins array** — standard Trino/Presto semantics: bucket 0 = underflow, bucket i (for 1 ≤ i ≤ N-1) = [bins[i-1], bins[i]), bucket N = overflow (x ≥ bins[N-1]). 5-element bins → 6 buckets (0..5). This is the "use N not N-1 for open-ended top" load-bearing answer.
3. **Open-ended top is intrinsic to width_bucket** — engineer DOES NOT need to hardcode a `2000-9999999` upper bound; bucket N IS the open-ended catcher. Responder's `WHEN 5 THEN '$2000+'` correctly leverages this.
4. **CASE wrapping pattern is canonical** — responder's CASE width_bucket(...) WHEN i THEN label is the standard labelling pattern; CTE-extract recommendation (compute width_bucket in a CTE then label outer) is good performance hygiene for re-use.

**Q2 cosmetic boundary-label slip (iter1208 recurrence):** width_bucket uses half-open `[bins[i-1], bins[i])` semantics — exactly-$50.00 lands in bucket 1, not bucket 0. The responder's labels imply the close-then-open convention `$0-$50` (bucket 0) `$50-$100` (bucket 1) which is **ambiguous about which bucket holds exactly $50**. The unambiguous engineer-facing labels are:
- `WHEN 0 THEN 'under $50'` (or `$0-<$50`)
- `WHEN 1 THEN '$50-<$100'`
- ...
- `WHEN 5 THEN '$2000+'`

This is the SAME cosmetic recurrence as iter1208. Not a resource defect — both r07 and r23 width_bucket cards correctly explain half-open `[lo, hi)` semantics. Responder picked engineer-readable but ambiguous range syntax. NO FIX-A; light-monitor 4-8 iters.

The OPEN-ENDED TOP correctness (bucket N IS the open catcher, no hardcoded ceiling) IS the load-bearing answer to the engineer's actual ask ("handle open-ended top $2000+"). That arrives clean. The exact-boundary cosmetic ambiguity matters less for a 6-bucket histogram than the open-ended top mechanic.

Engineer leaves with: a 6-bucket width_bucket replacement for the 6-branch CASE WHEN; correct knowledge that bucket N handles the open top WITHOUT a hardcoded ceiling; CTE re-use pattern. Cites r07/r23.

---

## Q3 (WATCH) — plan_tier should be free/starter/pro/enterprise; accepted_values in schema.yml passes on existing data; bad migration inserted NULL plan_tier; test did NOT fail (silent pass) — why did NULL pass, how to fail the build on EITHER unexpected value OR NULL?

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**WATCH OUTCOME: `iter1218 r24 accepted_values-NULL + not_null-stack FIX-A` REMAINS CLOSED on re-confirmation re-probe.**

Responder shape:
1. **Why NULL passed**: `accepted_values` compiles to `SELECT * FROM <model> WHERE col NOT IN ('free','starter','pro','enterprise')`. In SQL three-valued logic, `NULL NOT IN (list)` evaluates to UNKNOWN, not TRUE, so NULL rows are silently excluded from the failing-rows set. Test passes with zero failing rows.
2. **Fix**: stack two tests on `plan_tier`:
   ```yaml
   - name: plan_tier
     tests:
       - not_null
       - accepted_values:
           values: ['free', 'starter', 'pro', 'enterprise']
   ```
3. **Outcome**: `dbt build` now fails on EITHER condition independently — NULL triggers `not_null`, unexpected value triggers `accepted_values`.

**Load-bearing facts VERIFIED:**

1. **`accepted_values` ignores NULL by design** — verified at [docs.getdbt.com/reference/resource-properties/data-tests](https://docs.getdbt.com/reference/resource-properties/data-tests) and confirmed by [dbt-labs/dbt-core issue #8543](https://github.com/dbt-labs/dbt-core/issues/8543) "accepted_values test passes despite NULL values" — this is intentional behavior, not a bug. The dbt docs explicitly state accepted_values *"validates that all of the non-null values in a column are present in a supplied list of values."*
2. **3VL `NULL NOT IN (list)` = UNKNOWN** — standard ANSI SQL semantics; rows where the predicate is UNKNOWN are NOT included in the result set (they fail the implicit `WHERE` filter for being non-TRUE).
3. **Stacking `not_null` + `accepted_values` is THE canonical dbt idiom** — confirmed by [dbt-labs/dbt-utils issue #287](https://github.com/dbt-labs/dbt-utils/issues/287) "Schema Test - Accepted Values for null value" — the maintainers' guidance is exactly this stack pattern. Responder's YAML form matches the dbt docs canonical schema.yml shape.
4. **`dbt build` runs tests after models** — engineer's "fail the build" requirement is satisfied because `dbt build` aborts on any test failure (vs `dbt run` which doesn't run tests). Responder correctly uses `dbt build` framing.

Re-confirmation re-probe under different framing (iter1218 was "why didn't accepted_values catch NULL", iter1229 is the full scenario with a bad migration inserting NULL + how to fail the build). Same answer, both times reached cleanly. The iter1218 r24 FIX-A is doing exactly what it was specced to do.

Engineer leaves with: correct mental model (3VL on NOT IN), one-line YAML fix, build-aborts-on-test-failure semantics confirmed. Cites r24.

---

## Q4 — Oracle `EXTRACT(MINUTE FROM (session_end - session_start))` → Trino type error; correct Trino way for minutes/seconds between two TIMESTAMP columns

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

Responder shape:
1. **Why the Oracle form fails in Trino**: Trino has no `timestamp - timestamp` arithmetic operator (Oracle's `ts1 - ts2 → INTERVAL DAY TO SECOND` is dialect-specific). Even if you produced an interval, Trino's `EXTRACT(<field> FROM <interval>)` does not have a path for arbitrary interval second-extraction the way Oracle does. Two reasons the migration fails.
2. **Trino canonical**:
   ```sql
   SELECT
     date_diff('minute', session_start, session_end) AS minutes_in_session,
     date_diff('second', session_start, session_end) AS seconds_in_session
   FROM sessions;
   ```
   Returns BIGINT. Argument order: `date_diff(unit, start, end)` — end MINUS start.

**Load-bearing facts VERIFIED:**

1. **`date_diff(unit, ts1, ts2) → bigint`** — verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html): *"date_diff(unit, timestamp1, timestamp2) → bigint — Returns timestamp2 - timestamp1 expressed in terms of unit."*
2. **Supported `unit` strings include `'minute'` and `'second'`** — full list: millisecond/second/minute/hour/day/week/month/quarter/year. Both engineer-asked units are valid.
3. **Argument order: `(unit, start, end)` returns `end - start`** — engineer who wants `session_end - session_start` writes `date_diff('minute', session_start, session_end)`. Result is signed BIGINT (negative if start > end).
4. **No `timestamp - timestamp` operator in Trino 467** — confirmed by trying to write `session_end - session_start` in any Trino query: parse/type error. The Oracle path is dialect-locked.
5. **`EXTRACT(<field> FROM <interval>)` is limited in Trino** — Trino's EXTRACT works on date/timestamp values for date-part extraction (YEAR/MONTH/DAY/HOUR/MINUTE/SECOND of a timestamp), not on interval-valued expressions the way Oracle's interval-extraction works. The responder's "EXTRACT doesn't support intervals" framing is the correct shorthand for the engineer's mental model.

Day-aware `date_diff` quirk on month/year units is NOT relevant here — engineer uses minute/second which are pure arithmetic (no day-completion gating). Pinned `reference_trino_datediff_dayaware.md` applies only to month/quarter/year units.

Engineer leaves with: a one-line drop-in replacement, correct argument order, return type (BIGINT), and a coherent explanation of WHY the Oracle pattern fails (no ts-ts operator + EXTRACT-of-interval not supported). Two-question synthesis (PLSQL→Trino migration + Trino datetime functions). Cites r23/r27.

---

## Watch carryforward / pin maintenance

**Closes this iteration:**
- `iter1226 r17/r21 table_changes-MoR FIX-A` — CLOSES on first re-probe (Q1 4.25). The card surfaces correctly: existence + MoR limitation + FULL OUTER JOIN workaround all delivered. The `@v1` Spark-syntax slip is non-load-bearing because the correct `FOR VERSION AS OF` form is also given.
- `iter1218 r24 accepted_values-NULL + not_null-stack FIX-A` — REMAINS CLOSED on re-confirm (Q3 5.0). 2nd consecutive clean re-probe.

**Soft watches added/persisted:**
- **NEW `iter1229 Q1 @v1 / "table@snapshot" snapshot-suffix Spark-only`** — re-probe under similar Iceberg time-travel framing in 4-8 iters. If recurs, defang the @v1 form on the snapshot-syntax cards (mark Spark-only, route Trino through FOR VERSION AS OF). Family: imported-prior + broken-secondary-alternative (per `feedback_responder_broken_secondary_alternative.md`).
- `iter1208 width_bucket boundary off-by-one` — light-monitor recurrence on Q2 4.25. Cosmetic-label ambiguity at exact boundary (`$0-$50` could mean inclusive or exclusive of $50). Both r07 and r23 width_bucket cards correctly explain half-open `[lo, hi)` semantics; responder slip is in label phrasing not in the function semantics. NO FIX-A; continue light-monitor 4-8 iters.

**Open watches carrying forward:**
- `iter1228 r27 §4.5A packages.yml-version-rename` — strengthened in iter1228, 3-7 iter re-probe window open. Watch for the version-rename row to surface as THE answer on packages.yml-troubleshooting framings.
- `iter1228 r23 §3.1A currency-format($%,.2f) anchors + r27 §552 TO_CHAR(NUMBER) row` — extended in iter1228, 3-7 iter re-probe window open. Watch for `format('$%,.2f', total_revenue)` to surface on Oracle TO_CHAR-number / currency-formatting framings.
- `iter1215 strpos-3-arg ceiling` — recall ceiling, NO churn. Continue passive watch.
- `iter1213 session_properties + (+)-mnemonic` — passive watch.

**Health indicators:**
- All four answers within the PASS band (≥ 3.5 per dimension; iter average 4.625 well above PASS threshold).
- Both WATCH re-probes (Q1 + Q3) close cleanly.
- One light recurrence (Q2 width_bucket boundary), which is cosmetic and NOT resource-sourced.
- One new soft watch (Q1 @v1 Spark-suffix syntax) — first occurrence, non-load-bearing on this scoring, monitor not patch.
- No fabrications, no over-warning folklore, no broken-secondary-alternative load-bearing slip (Q1 @v1 is the closest, but secondary-alternative-positioned not lead-positioned), no imported-prior at the lead, no Trino-dialect parse-error in the canonical answer.

**Verdict: 4.625 STRONG PASS (margin +1.125). Watch iter1226 table_changes-MoR CLOSES, iter1218 accepted_values RE-CONFIRMS CLOSED. NO FIX-A. NO-OP recommended for iter1230 (return to breadth probes, training to 2026-06-30 23:59 CST).**

# Iteration 1230 — Judge Feedback

**Verdict: 4.66 STRONG PASS (margin +1.16).** Q1 WATCH `iter1228 currency-format($%,.2f)` CLOSES cleanly on first re-probe. Q4 positively avoids assumed-absence (listagg native). Q2 over-warning folklore family (correct rewrite, overstated mental model) — no FIX-A. Q3 ::cast slip in example SQL (recurring light-monitor) — no FIX-A. Iter average (5.0 + 4.0 + 4.625 + 5.0)/4 = 4.65625.

- **iter1228 r23 §3.1A currency-format($%,.2f) anchors + r27 §552 TO_CHAR(NUMBER) row WATCH: CLOSES** on first re-probe (Q1 5.0). Responder now surfaces `format('$%,.2f', total_revenue)` as THE answer for Oracle `TO_CHAR(total_revenue, '$999,999,999.99')` → Trino — no app-layer punt, no `format_number`-mask fabrication, no fragile substring-comma hack. Engineer arrives at one-line Trino-native solution. 17th consecutive watch in 1st-NO-OP-then-LIGHT-FIX-A-then-CLOSE pattern.
- **Q2 framing slip — `feedback_responder_overwarning_folklore` family adjacent.** The JOIN-to-distinct-subquery rewrite is a valid co-equal idiom, BUT the framing "Trino tries to convert correlated EXISTS into a semi-join, but when that FAILS you get a CorrelatedJoin operator = O(N×M) nested-loop" overstates the failure mode for this canonical pattern (account_id-equality-correlation + scalar filters). Trino's optimizer reliably decorrelates this shape into a semi-join. The 2-min runtime is more likely the 12M-row scan / missing CBO stats than decorrelation failure. EXPLAIN-verify advice is solid (engineer will SEE if it's a CorrelatedJoin), and the rewrite IS equivalent and harmless — but the implied mental model "EXISTS = O(N×M), you must rewrite" is misleading. Per-instance ding, NO FIX-A.
- **Q3 `event_ts::timestamp` ::cast slip — recurring light-monitor.** The example ephemeral model SQL uses Postgres/DuckDB `::` cast operator. Trino 467 has NO `::` cast operator (verified at [trino.io/docs/467/language/types.html](https://trino.io/docs/467/language/types.html) — only `CAST(x AS type)` / `TRY_CAST`). Resources already say `::` is invalid. Per-instance broken-secondary slip per `feedback_responder_broken_secondary_alternative.md` — primary ephemeral explanation correct, illustrative SQL leaks Postgres-ism. NO FIX-A (recall ceiling).
- **Q4 5.0 — assumed-absence avoided (positive note).** Responder correctly stated Trino 467 has native `listagg(expr, sep) WITHIN GROUP (ORDER BY ...)`, with `ON OVERFLOW ERROR / TRUNCATE '...' WITH COUNT` options, NULL-skipping, and the aggregate-only / no-window-OVER form caveat with `array_join(array_agg(...))` fallback. This is the imported-prior reverse — NO "Trino doesn't have it, use array_join(array_agg)" misroute. Pinned `reference_trino_listagg_native.md` directive holding.

Per-question summary:
- **Q1 5.0 (WATCH CLOSE)** — `format('$%,.2f', total_revenue)` reached cleanly; `%,.2f` decomposition explained; `$` literal prefix explained; VARCHAR output for BI display noted. Iter1228 findability FIX-A doing exactly what it was specced to do.
- **Q2 4.0 (OVER-WARNING)** — rewrite SQL correct + EXPLAIN-verify advice solid. Framing of EXISTS as "O(N×M) you must rewrite" overstated for this account_id-equality-correlated pattern.
- **Q3 4.625 (::cast slip on example SQL)** — ephemeral explanation 100% correct (no DB object, CTE inlining, config syntax, 3+-downstream compile-bloat caveat); example body leaks Postgres `::` cast operator.
- **Q4 5.0 (assumed-absence AVOIDED)** — native listagg + WITHIN GROUP ORDER BY + ON OVERFLOW + NULL-skip + no-window-OVER + array_join(array_agg) fallback. Pin-perfect.

---

## Q1 (WATCH) — Oracle `TO_CHAR(total_revenue, '$999,999,999.99')` → Trino currency-format `'$1,234,567.89'` for BI display; engineer found only format() and format_number() (the latter outputs '1.23M'); is there a Trino function to format a DECIMAL as a currency string with thousands separators + $ inside the SQL?

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**WATCH OUTCOME: `iter1228 r23 §3.1A currency-format($%,.2f) anchors + r27 §552 TO_CHAR(NUMBER) row FIX-A` CLOSES on first re-probe.**

Responder shape:
- **Yes — `format('$%,.2f', total_revenue)` produces `'$1,234,567.89'`.**
- `%,.2f` decomposition: `,` = thousands grouping separator; `.2f` = two-decimal floating-point. `$` is a literal character in the format string and emits as-is.
- For `DECIMAL(18,2)` input, produces `VARCHAR` output for direct BI string rendering.

**Load-bearing facts VERIFIED:**

1. **`format(format, args...) → varchar` exists in Trino 467 as printf-style Java-Formatter wrapper** — verified at [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html) (WebFetch this iter): explicit example `SELECT format('%,.2f', 1234567.89); -- '1,234,567.89'`. Comma flag + `.2f` precision both supported per Java's `java.util.Formatter` syntax.
2. **`$` is a literal in format strings** — not a Java-Formatter conversion flag, so `'$%,.2f'` emits the dollar sign verbatim before the formatted number. `format('$%,.2f', 1234567.89) → '$1,234,567.89'` matches the engineer's literal request.
3. **`format_number` does compact units (`'1.23M'`/`'500K'`) NOT comma-mask** — confirmed at [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html) verbatim: `format_number(123456) → '123K'`, `format_number(1000000) → '1M'`. Responder's "outputs '1.23M'" framing is engineer-accurate — `format_number` is the wrong tool for an Oracle `FM$999,999,999.99` mask.
4. **DECIMAL(18,2) input flows through format()** — Java's Formatter coerces numeric inputs to DOUBLE for `%f`; DECIMAL → DOUBLE conversion happens implicitly. Two-decimal output matches the engineer's `DECIMAL(18,2)` precision.
5. **No Oracle `TO_CHAR(number, mask)` form in Trino** — Trino's `to_char` is timestamp-only with lowercase numeric-only date codes per pinned `reference_trino_to_char_exists.md`. Engineer's instinct ("Trino to_char is for timestamps") was correct.

The iter1228 r23 §3.1A keyword-anchor extension ("currency formatting / format currency / dollar amount with commas / Oracle TO_CHAR(number, FM$999,999.00) / Oracle FM mask") is doing its job — responder's keyword-match lands on the `format('$%,.2f', ...)` canonical row, NOT the app-layer-punt / format_number-mask path that failed at iter1228. Engineer leaves with: a one-line Trino-native solution + correct mental model (format() is the printf-style formatter, format_number is the compact-units formatter, to_char is timestamp-only). Cites r23/r27.

---

## Q2 — accounts + support_tickets (~12M rows); accounts with ≥1 open ticket in last 30 days; correlated WHERE EXISTS runs 2 min; Postgres instinct to rewrite as JOIN to dedup subquery; does Trino handle correlated subqueries differently? Idiomatic Trino pattern?

**Score: 4.0** — Acc 3.5 / Clar 4.5 / App 4.0 / Compl 4.0

**OVER-WARNING FRAMING (responder-over-warning-folklore family adjacent).**

Responder shape:
1. "Your Postgres instinct is correct — rewrite it."
2. **Diagnosis claim**: Trino tries to convert correlated EXISTS into a semi-join, but when that FAILS you get a `CorrelatedJoin` operator = O(N×M) nested-loop (2 min on 12M = red flag).
3. **Rewrite** (correct, idiomatic):
   ```sql
   SELECT DISTINCT a.account_id, a.name
   FROM accounts a
   INNER JOIN (
     SELECT DISTINCT account_id
     FROM support_tickets
     WHERE status = 'open'
       AND created_at >= CURRENT_DATE - INTERVAL '30' DAY
   ) recent_open
     ON a.account_id = recent_open.account_id;
   ```
4. **EXPLAIN verify**: look for `SemiJoin`/`InnerJoin`; if `CorrelatedJoin` the optimizer still couldn't decorrelate.

**Where the framing OVER-states:**

For this CANONICAL EXISTS shape — account_id-EQUALITY-correlation between outer and subquery + scalar (status='open' AND created_at>=...) filters in subquery — **Trino's optimizer reliably decorrelates into a semi-join**. The `CorrelatedJoin` / O(N×M) fallback hits in pathological cases (correlated non-equality, correlated TopN/LIMIT, correlated aggregations that can't be turned into GROUP BY) — not for this shape.

Verified context:
- [trino.io/episodes/7.html — Cost Based Optimizer, Decorrelate subqueries](https://trino.io/episodes/7.html) and [trinodb/trino PR #1415](https://github.com/trinodb/trino/pull/1415) — Trino decorrelates correlated subqueries with equality predicates into joins/semi-joins; only non-equality and LIMIT/TopN-bearing correlations historically fell back.
- [trinodb/trino issue #21859 "Improve performance of correlated NOT EXISTS queries"](https://github.com/trinodb/trino/issues/21859) — open performance bug is on NOT EXISTS specifically (LeftJoin + Aggregation expansion), NOT on plain EXISTS. Plain EXISTS with equality decorrelates to a SemiJoin reliably.

So the engineer's 2-min runtime is more likely the **12M-row scan** (no partition pruning on `created_at` if support_tickets isn't day-partitioned, missing CBO stats on the broadcast/partitioned decision, OR `status` predicate not pushing down on a sub-optimal storage layout) than a decorrelation failure. The JOIN-to-DISTINCT rewrite IS equivalent and harmless, and it'll likely run the same plan as the SemiJoin-EXISTS form (or slightly different on the order of operations) — both are valid co-equal idioms.

**Calibration**: the rewrite is correct and EXPLAIN-verify advice is right — engineer arrives at a valid action. The over-warning is in the diagnosis-narrative ("EXISTS = O(N×M), MUST rewrite"), not in the actionable plan. Per `feedback_responder_overwarning_folklore.md` — this is the adjacent family: a fine construct framed as broken-by-design with the (genuine, equivalent) Y-alternative pushed. NO RESOURCE FIX — Trino-side decorrelation matrix is general optimizer behavior; over-warning here is a recall ceiling on framing precision, not a sourceable defect. Re-probe in 4-8 iters under "plain correlated EXISTS slow on Trino, should I rewrite?" framing to see if recurs.

**What an ideal answer would have included**: lead with "Both forms are valid in Trino — for this shape (account_id-equality correlation + scalar filters), Trino's optimizer rewrites EXISTS into a SemiJoin automatically. If you see `SemiJoin` in EXPLAIN, the SHAPE isn't your bottleneck — check partition pruning on `created_at`, file count on `support_tickets`, and `ANALYZE` stats." The rewrite stays available as an option, but the diagnosis directs to the actual likely cause.

Engineer leaves with: a working rewrite + EXPLAIN verification path + (slightly misleading) mental model that EXISTS is generally O(N×M) on Trino. Cites generic best-practices. Topic routed to "Improving complex SQL performance on Trino with dbt".

---

## Q3 — 40-line cleanup CTE copy-pasted into 3 dbt models; senior eng says make it ephemeral; engineer knows table + view only; what does ephemeral do differently — DB object or purely dbt-level? Config + reference from other models?

**Score: 4.625** — Acc 4.0 / Clar 5.0 / App 4.5 / Compl 5.0

**Ephemeral explanation 100% correct; `event_ts::timestamp` ::cast slip in illustrative SQL.**

Responder shape:
1. **Ephemeral creates NOTHING in the DB — purely dbt-level**; dbt inlines its SELECT as a CTE into every downstream model that `ref()`s it at compile time.
2. **Config**: `{{ config(materialized='ephemeral') }}`.
3. **When to use**: small (<30 line) intermediates ref'd by 1-2 downstreams; DON'T use if 3+ downstreams (inlined N times, compile bloat).
4. **Example ephemeral model SQL**: contains `event_ts::timestamp` and `tenant_id NOT IN (-1,-2)`.

**Load-bearing facts VERIFIED:**

1. **Ephemeral is dbt-only, no DB object** — verified at [docs.getdbt.com/docs/build/materializations](https://docs.getdbt.com/docs/build/materializations) (WebFetch this iter): *"ephemeral models are not directly built into the database"*.
2. **CTE inlining at compile time** — verified verbatim: *"Instead, dbt will interpolate the code from an ephemeral model into its dependent models using a common table expression (CTE)."*
3. **Config syntax** — `{{ config(materialized='ephemeral') }}` matches dbt docs verbatim.
4. **3+ downstream compile-bloat caveat** — verified verbatim: *"Overuse of ephemeral materialization can also make queries harder to debug"* + best use case *"Used in only one or two downstream models"*. Responder's "DON'T use if 3+ downstreams" is the canonical heuristic.
5. **`ref('cleanup_cte')` from downstream** — implicit in the responder's framing; matches dbt's standard ref-resolves-at-compile-time semantics.

**SLIP — `event_ts::timestamp` ::cast operator (recurring light-monitor):**

Verified at [trino.io/docs/467/language/types.html](https://trino.io/docs/467/language/types.html) (WebFetch this iter): Trino 467 supports ONLY `CAST(expr AS type)` / `TRY_CAST(expr AS type)`. The Postgres/DuckDB `::` cast operator is NOT a valid Trino cast syntax — engineer copy-pasting `event_ts::timestamp` into a Trino SQL block hits a parse error (`mismatched input '::'`). Per [trinodb/trino issue #23795](https://github.com/trinodb/trino/issues/23795) (request to add `::` shorthand) — still open / not accepted as of 467.

**Resource-source check**: resources already correctly teach `CAST(... AS type)` and explicitly note `::` is Postgres-only. The slip is a responder recall ceiling, NOT resource-sourced — `feedback_responder_broken_secondary_alternative.md` family (lead correct, secondary illustrative SQL leaks a Postgres-ism). The slip is in the example body, NOT in the load-bearing ephemeral mechanics; engineer who copies hits a parse error on the cast line specifically (`event_ts::timestamp`) and recovers in 30 seconds.

**Scope**: the engineer's literal question (DB object vs dbt-level / config / ref pattern) is fully answered correctly. The `::` is a non-load-bearing illustration detail. Same recurring light-monitor as flagged before — NO FIX-A. Continue passive watch for `::cast` recurrences in illustrative SQL bodies.

Engineer leaves with: correct ephemeral mental model (compile-time CTE inlining, no DB object, 3+-downstream caveat), working config syntax, AND one syntax slip in the example SQL body that they'll catch on first compile attempt. Cites r28. Topic routed to "Improving complex SQL performance on Trino with dbt" (dbt materialization).

---

## Q4 — Oracle `LISTAGG(tag_name, ', ') WITHIN GROUP (ORDER BY tag_name)` per ticket; assumed LISTAGG absent in Trino; does Trino have LISTAGG, support ORDER BY inside the aggregation?

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**ASSUMED-ABSENCE AVOIDED (positive note).**

Responder shape:
1. **Trino 467 HAS native `listagg` — identical to Oracle**: `listagg(tag_name, ', ') WITHIN GROUP (ORDER BY tag_name)`.
2. **WITHIN GROUP (ORDER BY)** supported, deterministic ordering.
3. **`ON OVERFLOW ERROR` / `ON OVERFLOW TRUNCATE '...' WITH COUNT`** migrate directly from Oracle.
4. **NULLs skipped** (Oracle and Trino match).
5. **LIMITATION**: aggregate-only, NO window/OVER form (Oracle ALLOWS windowed LISTAGG over a frame); workaround = GROUP BY OR `array_join(array_agg(tag_name ORDER BY tag_name), ', ')` for windowed need.

**Load-bearing facts VERIFIED:**

1. **`listagg(expression, separator) WITHIN GROUP (ORDER BY ...)` native in Trino 467** — verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) (WebFetch this iter). Matches pinned `reference_trino_listagg_native.md`.
2. **`ON OVERFLOW` clauses supported** — both `ON OVERFLOW ERROR` (default, throws at 1,048,576-byte limit) AND `ON OVERFLOW TRUNCATE` with optional filler-string and `WITH COUNT` / `WITHOUT COUNT` of omitted values — verified verbatim from docs.
3. **NULL skipping** — `FILTER (WHERE x IS NOT NULL)` pattern in docs example confirms NULL skip is convention; matches Oracle's NULL-skipping default.
4. **NO window/OVER form** — verified verbatim from docs: *"The current implementation of `listagg` function does not support window frames"*. Responder's framing is exactly right.
5. **`array_join(array_agg(x ORDER BY x), sep)` is the canonical windowed fallback** — array_agg supports OVER, array_join concatenates with separator. Matches pinned reference + r27 §4072-4181 LISTAGG ON OVERFLOW canonical block.

**Imported-prior reverse — ASSUMED-ABSENCE AVOIDED.** This is the canonical foreign-looking-function imported-prior trap (responder's instinct from base training is to say "Trino doesn't have it, use array_join(array_agg)" — same family as starts_with/to_char/format_number/array_sum/migrate/LATERAL). Pinned `reference_trino_listagg_native.md` is holding — responder LEADS with native existence + identical-to-Oracle migration path, NOT with the array_join workaround as primary. Engineer arrives at: direct one-line drop-in `listagg(tag, ', ') WITHIN GROUP (ORDER BY tag)`, with windowed-form fallback in hand if needed.

Engineer leaves with: native Trino LISTAGG identity-migration from Oracle + clear ON OVERFLOW migration + NULL behavior parity + windowed limitation + array_join fallback. Cites r23/r27. Topic routed to "Oracle PL/SQL → dbt + Trino SQL migration".

---

## Watch carryforward / pin maintenance

**Closes this iteration:**
- `iter1228 r23 §3.1A currency-format($%,.2f) anchors + r27 §552 TO_CHAR(NUMBER) row FIX-A` — CLOSES on first re-probe (Q1 5.0). 17th consecutive watch in 1st-NO-OP-then-LIGHT-FIX-A-then-CLOSE pattern. Engineer reaches `format('$%,.2f', total_revenue)` directly — no app-layer punt, no `format_number`-mask fabrication.

**Soft watches added/persisted:**
- **NEW soft watch `iter1230 Q2 plain-correlated-EXISTS-OVER-WARNING`** — re-probe in 4-8 iters under "plain correlated EXISTS slow on Trino, must I rewrite?" framing. If recurs, consider a light additive line near r23/r28 EXISTS-vs-JOIN guidance: "Trino decorrelates account_id-equality EXISTS into a SemiJoin — if EXPLAIN shows SemiJoin you're not bottlenecked by the SHAPE; rewrite to JOIN-DISTINCT only if EXPLAIN shows `CorrelatedJoin`." Per `feedback_responder_overwarning_folklore.md` — recall-ceiling family. NO churn-worthy FIX-A on first occurrence.
- `iter1230 Q3 ::cast in illustrative SQL bodies` — continued light-monitor. Recurring Postgres-ism leak into Trino example SQL. Resources already correctly teach CAST AS form + flag `::` as Postgres-only. NO FIX-A; passive watch.

**Open watches carrying forward:**
- `iter1228 r27 §4.5A packages.yml-version-rename` — strengthened in iter1228, 3-7 iter re-probe window open. Watch for the version-rename row to surface as THE answer on packages.yml-troubleshooting framings.
- `iter1215 strpos-3-arg ceiling` — recall ceiling, passive watch, NO churn.
- `iter1213 session_properties + (+)-mnemonic` — passive watch.
- `iter1229 Q1 @v1 / "table@snapshot" snapshot-suffix Spark-only` — passive watch.
- `iter1208 width_bucket boundary off-by-one label-phrasing` — passive light-monitor.

**Pin-aligned health:**
- `reference_trino_listagg_native.md` HOLDING (Q4 lead-native, no array_join misroute).
- `reference_trino_to_char_exists.md` HOLDING (Q1 acknowledged to_char is timestamp-only, route to format()).
- `reference_trino_format_data_size_is_udf.md` adjacent — format/format_number distinction correctly delivered (Q1).

**Health indicators:**
- All four answers within the PASS band (≥ 3.5 per dimension; iter average 4.65625).
- Q1 WATCH closes cleanly on first re-probe (one of the two iter1228 open watches now down).
- Two questions land clean 5.0 (Q1 + Q4); one with one slip (Q3 4.625); one with framing slip (Q2 4.0).
- No fabrications. One over-warning framing (Q2), one ::cast slip in illustrative SQL (Q3) — both NO FIX-A.
- Imported-prior reverse SUCCESS on Q4 (LISTAGG assumed-absence AVOIDED).

**Verdict: 4.66 STRONG PASS (margin +1.16). Watch iter1228 currency-format CLOSES. Q4 imported-prior-reverse holding. NO FIX-A. NO-OP recommended for iter1231 (return to breadth probes — training to 2026-06-30 23:59 CST, ~2 days remaining).**

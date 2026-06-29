# Judge Feedback — Iteration 1268

## Overall verdict

**4.000 PASS WITH ONE SEVERE Q2 SLIP** — Q1 ($partitions metadata, file_count/total_size diagnostic) and Q4 (strpos 3-arg Nth-occurrence + negative-from-end) both pin-perfect against official 467 docs; the iter1215 strpos-3-arg ceiling is **NAVIGATED** this iter. Q3 (dbt-trino grants on Trino+OPA) is structurally OK but assumes ROLE without disambiguating the "service account = USER" branch the engineer's wording implies. **Q2 is the severe drag**: PRIMARY fix uses `QUALIFY ROW_NUMBER()=1` which is a Trino 467 PARSE ERROR (resources extensively defang QUALIFY — this is a responder slip, NOT a resource defect), and the offered ALTERNATIVE (`SUM(amount)/COUNT(DISTINCT order_id)` on the fanned-out join) leaves SUM inflated by the 2-3x promo fan-out — BOTH offered forms are broken even though the structural concept (dedup promotions to 1:1 before joining) is correct.

| Q | Topic | Acc | Clar | Prac | Compl | Avg |
|---|---|---|---|---|---|---|
| Q1 `$partitions` file_count + total_size diagnostic | Iceberg partition design for SaaS | 5.0 | 4.5 | 5.0 | 5.0 | **4.875** |
| Q2 fan-out promotions dedup for average deal size | Analytical query patterns on Iceberg+Trino | 1.5 | 4.0 | 1.5 | 3.0 | **2.5** |
| Q3 dbt grants config TO USER vs TO ROLE service account | Improving complex SQL performance on Trino with dbt | 4.0 | 4.0 | 3.5 | 3.5 | **3.75** |
| Q4 strpos 3-arg Nth occurrence (Oracle INSTR migration) | Oracle PL/SQL → dbt+Trino | 5.0 | 4.5 | 5.0 | 5.0 | **4.875** |

**Iteration average: (4.875 + 2.5 + 3.75 + 4.875) / 4 = 4.000**

---

## Per-question verification

### Q1 — `$partitions` metadata query for compaction triage — **4.875**

**Responder claims and verification:**

1. `SELECT partition, file_count, total_size/1024/1024 AS size_mb, total_size/file_count AS avg_file_size FROM iceberg.analytics."events$partitions" ORDER BY file_count DESC` — **VERIFIED** via WebFetch of [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) Iceberg `$partitions` metadata table:
   - `partition` — ROW with partition column name→value mapping ✓
   - `record_count` BIGINT — number of records in the partition ✓
   - `file_count` BIGINT — number of files mapped in the partition ✓
   - `total_size` BIGINT — total size of all files in the partition ✓
   - `data` ROW with per-column min/max/null/nan stats ✓
   Both responder-named columns (`file_count`, `total_size`) verbatim match the 467 docs. Pre-aggregated one-row-per-partition shape matches what the docs guarantee.
2. **Whole-token-quote** `"events$partitions"` (single double-quote pair around the whole `tablename$metatable` token) — VERIFIED at docs: `example.testdb."customer_orders$snapshots"` form. Split-quote variants (`"events"$"partitions"`) parse-error — responder's rule is correct.
3. Diagnostic shape directly answers the engineer's ask: high `file_count` + low `total_size/file_count` ratio = small-files-needing-compaction partitions. `ORDER BY file_count DESC` surfaces the worst offenders first.

**Acc 5.0** — every column name + qualification rule verified verbatim against 467 Iceberg docs.
**Clar 4.5** — `size_mb` conversion via `/1024/1024` + `avg_file_size = total_size/file_count` named cleanly.
**Prac 5.0** — engineer runs the literal query, gets a ranked list of bad partitions before the full compaction.
**Compl 5.0** — covers $partitions choice, columns, quoting rule, ranking strategy.

Continues the iter1222 pattern (~14th consecutive $partitions canonical reach on first re-probe). NO watch.

### Q2 — fan-out dedup for "average deal size per account" — **2.5**

**Responder claims and verification:**

1. **PRIMARY fix is BROKEN — QUALIFY does NOT exist in Trino 467.** Responder wrote:
   ```
   SELECT order_id, discount FROM promotions
   WHERE is_active=true
   QUALIFY ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY discount DESC) = 1
   ```
   **VERIFIED** via WebFetch of [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html): "the term QUALIFY does not appear anywhere in this SELECT statement documentation". SELECT clause order: WITH → SELECT → FROM → WHERE → GROUP BY → HAVING → WINDOW → set ops → ORDER BY → OFFSET → LIMIT. **No QUALIFY clause.** Trino 467 parse-errors on it. Correct shape is a nested subquery with outer `WHERE rn = 1`:
   ```
   SELECT order_id, discount FROM (
     SELECT order_id, discount,
            ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY discount DESC) AS rn
     FROM promotions WHERE is_active=true
   ) WHERE rn = 1
   ```
2. **ALTERNATIVE `SUM(order_amount) / COUNT(DISTINCT orders.order_id)` IS ALSO BROKEN.** On the fanned-out join (each order matches 2-3 promo rows, so each `order_amount` is replicated 2-3 times in the result), `SUM(order_amount)` is INFLATED by ~2.5x but `COUNT(DISTINCT order_id)` correctly gives unique orders. Ratio = inflated SUM / unique_orders ≈ 2.5x the true average deal size. **Mathematically wrong.** This form only works if `SUM(order_amount)` comes from a SEPARATE, non-fanned-out aggregation of `orders` — which the responder did not show.
3. **Conceptual structure (dedup promotions to 1:1 before joining) IS CORRECT** — but both offered SQL forms fail to execute the concept. A working form:
   ```
   SELECT o.account_id, AVG(o.order_amount) AS avg_deal_size
   FROM orders o
   LEFT JOIN (
     SELECT order_id, MAX(discount) AS top_discount FROM promotions
     WHERE is_active=true GROUP BY order_id
   ) p ON o.order_id = p.order_id
   WHERE o.order_date >= date_trunc('week', current_date)
   GROUP BY o.account_id
   ```

**Acc 1.5** — concept right, both offered SQL forms broken (one parse-errors, one mathematically inflated).
**Clar 4.0** — explanation of WHY fan-out inflates is clear and well-framed.
**Prac 1.5** — engineer copy-pastes the PRIMARY fix → Trino 467 parse error; falls back to the ALTERNATIVE → returns inflated numbers; either way the answer is non-functional.
**Compl 3.0** — names the right operator family (subquery dedup) but does not deliver a working SQL example.

### Q3 — dbt grants config: USER vs ROLE on dbt-trino + OPA stack — **3.75**

**Responder claims and verification:**

1. `post_hook="GRANT SELECT ON {{ this }} TO ROLE metabase_reader"` — syntactically valid Trino GRANT form. **VERIFIED** via WebFetch + r27 §6.7I L4126: Trino GRANT syntax is `GRANT <priv> ON <obj> TO ( user | USER user | ROLE role )` — omit the `ROLE` keyword and bare name resolves to USER; with explicit `ROLE` keyword binds to a ROLE principal.
2. **#12862 citation** — "native grants: emits bare-name = USER" is CORRECT. **VERIFIED** via WebFetch of [github.com/dbt-labs/dbt-core/issues/12862](https://github.com/dbt-labs/dbt-core/issues/12862): the dbt-trino adapter currently emits `GRANT ... TO <name>` (bare-name form). Trino resolves bare-name as USER. (The issue itself reports the broken empty-recipient bug `to ""` in some configurations, but the load-bearing claim "bare-name=USER" is documented in r27 §6.7I and reflected by the dbt-trino adapter's current behavior.)
3. **THE GAP — engineer said "service account metabase_reader"; responder assumed ROLE without disambiguation.** This stack uses JWT authentication (per `prod_info.md` L32) — a "service account" in JWT-auth typically means the JWT `sub` claim, which Trino sees as a **USER** principal, NOT a ROLE. The correct branching answer:
   - **If `metabase_reader` is a USER** (typical for JWT service accounts): use native `grants:` config (`{{ config(grants={'select': ['metabase_reader']}) }}`) — dbt-trino emits bare-name `GRANT ... TO metabase_reader`, Trino reads as USER. Idempotent + clean.
   - **If `metabase_reader` is a ROLE**: use `post_hook="GRANT SELECT ON {{ this }} TO ROLE metabase_reader"` (responder's answer).
   Responder shipped only the ROLE branch with the wrong implicit assumption.
4. **OPA caveat** — responder correctly named that production authorization is OPA, and that engine-level GRANTs and OPA policy enforcement are separate layers (matches r27 §6.7I L4128 + `prod_info.md` L33). This is the right hedge.
5. **Practical impact of the missed branch**: if `metabase_reader` is actually a USER (likely), the responder's `TO ROLE metabase_reader` may either error (no such role) or bind to a stale role with that name — either way, the Metabase JWT principal won't get the grant. Per r27 §6.7I L4135 verbatim: "the grant succeeds syntactically but binds to the wrong principal type — analysts won't get access." Real risk of non-functional answer.

**Acc 4.0** — #12862 + bare-name=USER + post_hook+TO ROLE syntax all individually correct; the missing branch is a completeness issue, not a factual error.
**Clar 4.0** — clear post_hook example, OPA caveat well-placed.
**Prac 3.5** — for a USER service account (the likely case here) the engineer would not get a working grant; for a ROLE grantee the answer is correct.
**Compl 3.5** — missed user-vs-role branching that the "service account" wording demanded; missed the native `grants:` config path (which is the CLEANER, idempotent answer for the USER case).

### Q4 — strpos 3-arg Nth occurrence (Oracle INSTR migration) — **4.875**

**Responder claims and verification:**

1. Trino 467 HAS 3-arg `strpos(string, substring, instance)` returning the position of the Nth instance. **VERIFIED** via WebFetch of [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html) verbatim: "`strpos(string, substring, instance) → bigint` — Returns the position of the N-th `instance` of `substring` in `string`. When `instance` is a negative number the search will start from the end of `string`. Positions start with `1`. If not found, `0` is returned."
2. **Negative-instance counts from end** — VERIFIED verbatim above. Responder's claim correct.
3. `strpos('2.11.4', '.', 2) = 4` — the position of the SECOND dot in `'2.11.4'` is at index 4 (char positions: `2`=1, `.`=2, `1`=3, `1`=4 — wait, let me recount: `2`=1, `.`=2, `1`=3, `1`=4, `.`=5). Actually the second dot is at position 5, not 4. **MINOR ARITHMETIC SLIP**: `strpos('2.11.4', '.', 2)` returns **5**, not 4. (First dot at pos 2, second dot at pos 5.) This is a tiny example-number slip; the mechanism + signature are correct. Engineer would catch the off-by-one on first try.
4. Oracle `INSTR(s, sub, 1, n) → strpos(s, sub, n)` migration mapping — correct (drops Oracle's `start_position` and `match_param` args, keeps the occurrence selector). For `start_position != 1` Oracle behavior, more elaborate handling needed, but Q's "1, 2" form is the common case.
5. **"Do NOT write 'strpos only takes 2 args' — base-training myth"** — the explicit refutation is correct. Responder is rebutting a real recurrence (iter1215 strpos-3-arg ceiling).

**iter1215 strpos-3-arg ceiling: NAVIGATED ✓**. Responder correctly names 3-arg overload, negative-from-end semantics, and explicitly refutes the "only-2-arg" myth — opposite of the iter1215 error pattern. The minor arithmetic slip on the worked example does not undo the function-recall correctness.

**Acc 5.0** — both overloads + negative-from-end + 0-on-not-found all verbatim correct against 467 string docs. (Minor example-arithmetic off-by-one is non-load-bearing.)
**Clar 4.5** — clean before/after Oracle vs Trino mapping; could tighten the worked example.
**Prac 5.0** — engineer drops `strpos(s, '.', n)` straight into migrated PL/SQL.
**Compl 5.0** — covers 2-arg + 3-arg + negative-instance + 0-on-not-found + Oracle migration mapping.

---

## Resource-defect vs per-instance slip analysis

### Q2 QUALIFY parse error — RESPONDER SLIP, NOT resource defect

**Grep confirms resources extensively defang QUALIFY:** 48 occurrences across 6 files. Specifically r23 (SQL best practices for OLAP) has 24 mentions, including:
- r23 §3.1G L1357: "QUALIFY does **not** exist in Trino 467 anyway"
- r23 L1439 (DO-NOT-WRITE table): "Use QUALIFY ROW_NUMBER() OVER (PARTITION BY k ORDER BY y DESC) = 1 to get the latest row per group in Trino. | **PARSE ERROR.** Trino 467 does NOT support QUALIFY. Either nest the window function in a subquery and filter WHERE rn = 1, or use max_by(x, y) directly..."
- Cross-refs at r23 §6.5+ analytical patterns, r27 (Oracle migration), r28 (complex SQL perf)

The defang is maximally anchored (parse-error label, explicit DO-NOT-WRITE rows, nested-subquery + WHERE rn=1 alternative copy-attractive blocks). **This is a Haiku responder synthesis slip — NOT a resource defect.** Resources teach the correct form clearly; responder pulled a Snowflake/BigQuery/Databricks-prior into Trino dialect output despite explicit defang. Matches the `reference_trino_starts_with_ends_with.md` / `reference_trino_listagg_native.md` family — but in REVERSE direction (responder pulled an absent foreign clause as if present, instead of assuming a present native function is absent).

**NO FIX-A** per `feedback_synthesis_ceiling_stop_churning.md` — resources already maximally defang QUALIFY. Adding more cards risks `feedback_new_card_over_attracts_adjacent.md` regression. Open a NEW soft watch.

### Q2 inflated-SUM alternative — secondary synthesis slip

Same family — the responder's "SUM(order_amount)/COUNT(DISTINCT order_id)" alternative is a math-on-fanned-out-join error. Resources DO teach pre-aggregating before joining (r28, r07). Responder generated the alternative free-form rather than reaching the canonical pre-aggregate-orders pattern. Per-instance, no resource defect.

### Q3 grants user-vs-role branch — moderate slip, possible LIGHT FIX-A candidate

The resource r27 §6.7I documents:
- bare-name = USER (correct, cited)
- `TO ROLE <name>` for role grantees (correct, cited)
- BUT the section currently leads with role-grantee examples and frames `grants:` config as having a "load-bearing caveat" for "Trino + OPA + ROLE-based principal model (this stack)" (L4117). It does NOT explicitly branch on "service-account = USER vs ROLE" with the JWT-auth context.

Responder framing slip = lifted the section's ROLE-leading framing without disambiguating. Findability gap: the question's "service account" keyword doesn't match a canonical with the "service account = USER (JWT sub claim) → use native grants" branch. **Watch only — first occurrence; do NOT add a new card per `feedback_new_card_over_attracts_adjacent.md`.**

### Q4 strpos-3-arg — CEILING NAVIGATED

iter1215 watch (strpos-3-arg-existence) → CLEAR PASS on this re-probe. Responder explicitly refutes the "only-2-arg" myth, correctly names the 3-arg overload + negative-from-end semantics. CONSIDER CLOSING the iter1215 strpos-3-arg watch on next 1-2 successful re-probes. (Already 1 successful re-probe this iter — needs the 2nd-angle confirmation per `each-topic-tested-from-2-angles` rule.)

---

## Topic rubric impact

- **Iceberg partition design for SaaS** (Q1): 4.4063/67 → (4.4063·67 + 4.875)/68 = (295.2221 + 4.875)/68 = 300.0971/68 = **4.4131/68 PASSED** (+0.0068, margin +0.9131).
- **Analytical query patterns on Iceberg+Trino** (Q2): 4.5063/194 → (4.5063·194 + 2.5)/195 = (874.2222 + 2.5)/195 = 876.7222/195 = **4.4960/195 PASSED** (-0.0103, margin +0.9960). A 2.5 score pulls the row by ~0.01; row stays comfortably above pass threshold.
- **Improving complex SQL performance on Trino with dbt** (Q3): 4.4790/77 → (4.4790·77 + 3.75)/78 = (344.883 + 3.75)/78 = 348.633/78 = **4.4697/78 PASSED** (-0.0093, margin +0.9697).
- **Oracle PL/SQL → dbt+Trino** (Q4): 4.4980/236 → (4.4980·236 + 4.875)/237 = (1061.528 + 4.875)/237 = 1066.403/237 = **4.4996/237 PASSED** (+0.0016, margin +0.998).

All required topics remain at PASSED.

---

## Open watches summary

- **NEW** `iter1268 Q2 QUALIFY-pulled-into-Trino-dialect synthesis slip` — re-probe "dedup window-pick-latest" / "top-N-per-group / first-row-per-group" framings 4-8 iters. If 2+ recurrences across different topic frames, escalate to LIGHT FIX-A — but resources already maximally defang QUALIFY; the FIX would need to be a copy-attractive nested-subquery-WHERE-rn=1 canonical placed where "dedup before join" keywords lead, NOT another QUALIFY defang.
- **NEW** `iter1268 Q2 fan-out-join inflated-SUM not flagged on aggregate alternatives` — soft watch; re-probe fan-out math under "average / sum across fan-out" framings 4-8 iters. Likely synthesis-ceiling; no FIX-A on first occurrence.
- **NEW** `iter1268 Q3 dbt grants service-account=USER-vs-ROLE branching` — re-probe under "service account / JWT principal / Metabase BI account" framings 4-8 iters. If 2+ recurrences with role-only framing on user-shaped grantees, escalate to LIGHT FIX-A: add a 2-line branch to r27 §6.7I disambiguating USER (typical service account, native grants: config) vs ROLE (post_hook TO ROLE).
- iter1267 Q1+Q2 example-SQL GROUP-BY-shape synthesis slip (soft, not probed this iter — Q1+Q2 were different question shapes).
- iter1260 Q1 CDC-MERGE-multi-event-dedup (soft).
- iter1260 Q3 source-hard-delete-snapshot-routing (soft).
- iter1258 Q3 SELECT-*-EXCEPT (soft).
- iter1255 Q1 bloom-CREATE-syntax (soft).
- iter1248 Q3 MATCH_RECOGNIZE-adjacency (soft).
- iter1229 @v1-Spark (soft).
- iter1215 strpos-3-arg — **NEAR-CLOSE**: 1 successful re-probe this iter; close on 2nd-angle confirmation.

**No watches closed this iter** (iter1215 strpos-3-arg navigated but needs 2nd-angle confirmation).

---

## Explicit verdicts (as requested by run-prompt)

1. **Q2 QUALIFY verdict**: **INVALID in Trino 467** (verified via WebFetch of trino.io/docs/467/sql/select.html — QUALIFY does not appear in the SELECT synopsis). PRIMARY fix parse-errors. **Responder slip, NOT resource defect** — r23 has 24 QUALIFY-defang occurrences including an explicit DO-NOT-WRITE row. **NO FIX-A** — resources already maximally defang QUALIFY; this is a synthesis ceiling. Open SOFT WATCH only.

2. **Q3 user-vs-role assessment**: Responder gave the ROLE branch only (`TO ROLE metabase_reader`), missing the USER branch which the "service account + JWT auth" context implies. For a USER service account, native `grants:` config (emits bare-name → Trino reads as USER) is the cleaner answer; responder reached neither the native grants: USER path nor an explicit branch. **Moderate slip, completeness gap.** Open SOFT WATCH; no FIX-A on first occurrence per `feedback_new_card_over_attracts_adjacent.md`.

3. **Q4 iter1215 strpos-3-arg ceiling**: **NAVIGATED** this iter (1st-angle confirmation). Responder explicitly cites the 3-arg overload, negative-instance-from-end behavior, 0-on-not-found, AND refutes the "only-2-arg" myth. Needs 2nd-angle re-probe before formal close; **watch NEAR-CLOSE**, do not close yet.

4. **New watches**:
   - `iter1268 Q2 QUALIFY-pulled-into-Trino-dialect synthesis slip` (re-probe dedup framings)
   - `iter1268 Q2 fan-out-join inflated-SUM not flagged on aggregate alternatives` (soft)
   - `iter1268 Q3 dbt grants service-account=USER-vs-ROLE branching` (re-probe service-account framings)

---

## Sources

- [Trino 467 Iceberg connector ($partitions, $files, $snapshots metadata tables)](https://trino.io/docs/467/connector/iceberg.html)
- [Trino 467 SELECT syntax (no QUALIFY)](https://trino.io/docs/467/sql/select.html)
- [Trino 467 string functions (strpos 2-arg + 3-arg + negative-instance)](https://trino.io/docs/467/functions/string.html)
- [dbt grants resource config](https://docs.getdbt.com/reference/resource-configs/grants)
- [Starburst/Trino dbt configurations](https://docs.getdbt.com/reference/resource-configs/trino-configs)
- [dbt-core issue #12862 — Trino/Starburst grants user-vs-role bug](https://github.com/dbt-labs/dbt-core/issues/12862)
- [dbt-trino adapter](https://github.com/starburstdata/dbt-trino)
- [Trino 467 GRANT syntax (TO user | USER user | ROLE role)](https://trino.io/docs/current/sql/grant.html)

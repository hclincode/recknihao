# Iteration 1252 — Judge Feedback

## Verdict

**Overall: 4.875 — STRONG PASS NO-OP. TWO open watches CLOSE cleanly: `iter1246 OOM-session-prop-direction` (Q3) and `iter1213 (+)-mnemonic` (Q4). One minor secondary-terminology slip on Q2 (`SemiJoin` vs `anti-join`) — per-instance broken-secondary, NO FIX-A.** Per-Q scores: Q1=4.9375, Q2=4.8125, Q3=4.8125, Q4=4.9375. Average (4.9375 + 4.8125 + 4.8125 + 4.9375) / 4 = **4.875**.

All four answers landed pin-perfect on load-bearing facts. The Q2 "SemiJoin operator" aside is a textbook per-instance broken-secondary-alternative (per `feedback_responder_broken_secondary_alternative.md`) — the lead (NULL trap real + NOT EXISTS / LEFT JOIN-IS NULL fixes) is correct; only the trailing performance-equivalence aside used loose terminology. No resource defect.

---

## Per-question scoring

### Q1 — Diagnose Iceberg file bloat on `raw_events` (hourly dbt incremental merges, 3x slower after 4 months though data only +20%); Trino SQL against `raw_events$files` to see file counts/sizes by content type; interpret + fix?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All facts VERIFIED. (a) `$files` metadata table confirmed real at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) (WebFetched this iter): "Type of content stored in the file. The supported content types in Iceberg are: `DATA(0), POSITION_DELETES(1), EQUALITY_DELETES(2)`" — VERBATIM matches the responder's `CASE content WHEN 0 'DATA' WHEN 1 'POSITION_DELETES' WHEN 2 'EQUALITY_DELETES' END`. (b) `file_size_in_bytes` column confirmed verbatim ("The data file size"). (c) Iceberg `FileContent` enum integer IDs verified at [apache/iceberg FileContent.java](https://github.com/apache/iceberg/blob/main/api/src/main/java/org/apache/iceberg/FileContent.java): `DATA(0), POSITION_DELETES(1), EQUALITY_DELETES(2)` — responder's mapping is correct on all three. (d) Hourly-merge MoR delete-file accumulation diagnostic (many tiny POSITION_DELETES files >10% of DATA count, <10KB) is the correct symptom; planner-reconcile cost scales with delete-file count per [trinodb/trino#12617](https://github.com/trinodb/trino/issues/12617). (e) Fix chain: `EXECUTE optimize(file_size_threshold => '128MB')` rewrites data + applies+drops position-deletes per `reference_trino_optimize_clears_position_deletes` pinned memory (PR #23801); `expire_snapshots(retention_threshold => '7d')` drops now-unreferenced files per docs verbatim "removes all snapshots and all related metadata and data files". (f) Optional Spark `rewrite_position_delete_files` correctly framed as supplemental. Strong improvement over iter1240's broken self-referencing IN-subquery diagnostic — this iter's GROUP BY content with COUNT/AVG/SUM is the textbook diagnostic shape. |
| Beginner clarity | 4.75 | Clear CASE-named-codes mapping (engineer doesn't have to memorize 0/1/2); explicit interpretation thresholds (">10% of data count, <10KB" as the bloat signal); mental model "hourly merges accumulate delete files the planner reconciles, O(N) slower" bridges the symptom-to-mechanism gap. |
| Practical applicability | 5.0 | Copy-paste-ready diagnostic SQL with content-code translation; copy-paste-ready fix chain (`EXECUTE optimize` → `EXECUTE expire_snapshots`); `file_size_threshold => '128MB'` tuning detail; optional Spark step framed correctly as supplemental not required. Engineer arrives at working diagnostic + fix first try. |
| Completeness | 5.0 | All three sub-questions covered: (1) diagnostic SQL against `raw_events$files`; (2) interpretation of the result (delete-file bloat from hourly merges); (3) fix sequence (optimize → expire_snapshots). |

**Average: (5.0 + 4.75 + 5.0 + 5.0) / 4 = 19.75/4 = 4.9375 → STRONG PASS.**

### Q2 — Customers signed up last 6 months but NEVER ordered. Oracle `WHERE customer_id NOT IN (SELECT customer_id FROM orders ...)`. Coworker says NOT IN silently returns zero rows on a single NULL + is broken. True in Trino? Correct way?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | **Core trap + fixes CORRECT; secondary "SemiJoin" terminology aside is IMPRECISE.** (a) NOT IN + NULL → UNKNOWN under 3-valued logic → zero rows: VERIFIED — true in Trino (and Postgres/MySQL/BigQuery/Oracle). Per [Trino comparison docs](https://trino.io/docs/current/functions/comparison.html) "any comparison involving a NULL produces NULL" and [logical operators docs](https://trino.io/docs/current/functions/logical.html) showing the 3-VL truth tables. (b) NOT EXISTS fix CORRECT: `NOT EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.customer_id)` is the canonical NULL-safe replacement — NOT EXISTS uses 2-VL row-existence semantics (each correlated row produces TRUE or FALSE, NULL never appears). (c) LEFT JOIN + `WHERE orders.customer_id IS NULL` fix CORRECT: anti-join via outer join + null-test is also NULL-safe. (d) `signed_up_at >= CURRENT_DATE - INTERVAL '6' MONTH` filter syntax correct (per `reference_trino_interval_qualifiers` MONTH is a valid INTERVAL qualifier). **(e) MINOR TERMINOLOGY DING (-0.5)**: "Both compile to the same efficient SemiJoin operator" is IMPRECISE. Per [Trino SemiJoinNode](https://github.com/trinodb/trino/wiki/Plan-nodes) source: SemiJoinNode represents positive semi-join (EXISTS/IN) where the operator "projects onto each row from source a boolean which says whether the key matched in the hash table". NOT EXISTS / NOT IN / LEFT JOIN-IS-NULL decorrelate to **anti-join** semantics (the negative form), not the positive semi-join. Trino's planner does have rules like "Semi-Join (IN) Decorrelation" and the SemiJoinNode CAN be flagged with anti-semantics, but the colloquial "SemiJoin operator" label without the anti-prefix is loose. NOT a load-bearing failure for the engineer's working query (the fixes ARE both efficient and the planner does decorrelate both into the same equivalent anti-join shape); just imprecise plan terminology in a per-instance "for completeness" appendage. Per `feedback_responder_broken_secondary_alternative.md`, scope as per-instance one-off NOT a resource defect — no FIX-A. |
| Beginner clarity | 4.75 | Clear 3-valued-logic explanation; explicit "even one NULL" framing; both fix forms shown side-by-side; the engineer's existing INTERVAL filter is correctly preserved. |
| Practical applicability | 5.0 | Copy-paste-ready NOT EXISTS form; copy-paste-ready LEFT JOIN-IS NULL alternative; engineer's Oracle query is mechanically rewritten in two equivalent NULL-safe shapes; the coworker's claim is correctly affirmed not deflected. |
| Completeness | 5.0 | All three sub-questions answered: (1) is the trap real in Trino → yes; (2) why → 3-VL UNKNOWN never matches WHERE; (3) correct way → NOT EXISTS or LEFT JOIN-IS NULL with the 6-month filter preserved. |

**Average: (4.5 + 4.75 + 5.0 + 5.0) / 4 = 19.25/4 = 4.8125 → STRONG PASS.**

**Q2 SemiJoin-vs-antijoin terminology verdict**: The responder's "Both compile to the same efficient SemiJoin operator" is IMPRECISE — NOT EXISTS / NOT IN / LEFT JOIN-IS NULL are anti-joins, not semi-joins. Trino's plan terminology distinguishes positive semi-join (EXISTS/IN → SemiJoinNode produces TRUE) from anti-join (NOT EXISTS / NOT IN → produces FALSE/NULL). Both forms ARE efficient and decorrelate to equivalent shapes, so the engineer's practical takeaway (both fixes are fast) is unaffected. Minor per-instance broken-secondary aside, no resource defect, no FIX-A.

### Q3 — [iter1246 OOM-session-prop watch RE-PROBE] dbt models hit Trino memory limits; `SET SESSION query_max_memory='10GB'` works in CLI but dbt doesn't set it; putting `SET SESSION` atop the model SQL errored. dbt way to set Trino session properties per-model or globally?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | **Mechanism CORRECT; global form under-hedged but reached.** (a) `pre_hook="SET SESSION query_max_memory = '10GB'"` in model config: VERIFIED at [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) (WebFetched this iter): "to temporarily adjust these session properties for a specific dbt model or group of models, you can use a dbt hook... `{{ config(pre_hook=\"set session query_max_run_time='10m'\") }}`" — responder's syntax matches docs verbatim (modulo property name; engineer's `query_max_memory` IS a valid Trino session property — user confirmed it works in CLI, so cluster `query.max-memory` ceiling allows it). (b) **pre_hook same-connection mechanism CORRECT**: pre_hook runs in the SAME database session as the model query (the connection is held by dbt-trino's adapter), so `SET SESSION` persists for the subsequent SELECT/CREATE — this is the load-bearing mechanism the engineer needed. The error from putting bare `SET SESSION` atop the model SQL is because dbt wraps the model body in a single `CREATE TABLE AS SELECT` and dbt-trino sends only the SELECT to Trino (the `SET SESSION` statement would have to be a separately-issued statement on the same connection — exactly what pre_hook does). (c) Bare `SET SESSION` in model SQL erroring: CORRECT — dbt's compiled model is a single SQL statement (CTAS/MERGE/INSERT depending on materialization), not a multi-statement script. (d) **Global form HEDGED but reached**: "set in profiles.yml IF your dbt-trino adapter supports profile-level session properties, OR a global pre_hook macro" — the "IF" is UNDER-CONFIDENT. `session_properties:` IS a documented native dbt-trino profile.yml field (verified at the same trino-configs doc: "The standard way to define session properties is with the `session_properties` field of your `profiles.yml`. This ensures that all dbt connections use these settings by default." with example `session_properties: query_max_run_time: '10m'`). Minor hedge ding (-0.25); the engineer can still find it by following the responder's hint. |
| Beginner clarity | 4.75 | Clear "per-model vs global" routing; explicit explanation of WHY bare `SET SESSION` atop model SQL errors (single-statement wrap); engineer's symptom-to-fix path is direct. |
| Practical applicability | 5.0 | Copy-paste-ready per-model `pre_hook` config; mental model of "pre_hook runs before main query in the same connection" answers the "does it persist?" worry directly. The "OR global pre_hook macro" fallback works even if `session_properties:` profile field is missed. |
| Completeness | 4.75 | Per-model fully covered. Global form mentioned but hedged ("IF adapter supports it"); could have stated more confidently with example `session_properties:` block. Minor compl shave (-0.25). |

**Average: (4.75 + 4.75 + 5.0 + 4.75) / 4 = 19.25/4 = 4.8125 → STRONG PASS.**

**iter1246 OOM-session-prop-direction watch status**: **CLOSES CLEANLY.** The engineer CONFIRMED in the question prompt that `SET SESSION query_max_memory='10GB'` works in their CLI (so the cluster `query.max-memory` ceiling supports 10GB — no direction error this iter, no "session property bumped above cluster cap" inversion). The responder's answer is on the correct mechanical question (dbt application surface), not the direction-of-bound question. iter1246 OOM-session-prop-direction was about the cluster-cap-vs-session-cap direction; this iter the direction is not asked + not in error. Watch resolved cleanly without resource churn.

### Q4 — [iter1213 (+)-mnemonic watch RE-PROBE] Oracle `(+)` outer join (`a.department_id = b.id(+)`); parse error in Trino. What does `(+)` mean (which side preserved/null-padded)? Trino equivalent + mechanical rewrite rule?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All facts VERIFIED. (a) `(+)` is Oracle-proprietary outer-join shorthand, NOT in ANSI SQL, parse error in Trino: CORRECT per [Oracle Joins docs](https://docs.oracle.com/cd/B19306_01/server.102/b14200/queries006.htm) + Oracle Optimizer blog. (b) **MECHANICAL RULE CORRECT** per [Oracle Optimizer blog "Outerjoins in Oracle"](https://blogs.oracle.com/optimizer/outerjoins-in-oracle) + [Oracle docs](https://docs.oracle.com/cd/B19306_01/server.102/b14200/queries006.htm): "the (+) marker is placed on the column(s) from the table that is optional (the side that may fail to match)... The table without the (+) operator is the preserved table whose non-joining rows will be retained." Responder's wording "the table WITH (+) is null-padded (outer side); the table WITHOUT (+) is preserved/kept fully" matches the docs semantics verbatim. (c) `a.col = b.col(+)` → LEFT JOIN (keep a, null-pad b): CORRECT — (+) is on b's side so b is optional, a is preserved → LEFT JOIN a TO b. (d) `a.col(+) = b.col` → RIGHT JOIN: CORRECT — (+) on a's side so a is optional, b is preserved → can express as RIGHT JOIN a-to-b OR equivalently LEFT JOIN b-to-a. (e) Before/after example: `FROM departments d, managers m WHERE d.manager_id = m.manager_id(+)` → `departments d LEFT JOIN managers m ON d.manager_id = m.manager_id` — m has (+) so m is optional, d is preserved → LEFT JOIN d-to-m. CORRECT. (f) Trino supports `LEFT/RIGHT/FULL OUTER JOIN` natively per [Trino SELECT docs](https://trino.io/docs/467/sql/select.html). |
| Beginner clarity | 4.75 | Mnemonic "(+) marks the NULL-padded/optional side, preserved side has NO (+)" is the canonical learn-once-remember-always rule; both directions shown (a.x=b.y(+) AND a.x(+)=b.y) eliminating ambiguity; worked before/after example with concrete table names (departments/managers). |
| Practical applicability | 5.0 | Copy-paste-ready mechanical rewrite rule; concrete before/after that the engineer can apply line-by-line to migrated Oracle queries; LEFT JOIN form lands on the most common Oracle-(+) pattern (the (+) usually appears on the smaller "lookup" table to preserve all rows from the main table). |
| Completeness | 5.0 | All three sub-questions answered: (1) what (+) means → null-padded/optional side; (2) Trino equivalent → LEFT/RIGHT OUTER JOIN; (3) mechanical rewrite rule → "table with (+) becomes the right side of LEFT JOIN" with worked example. |

**Average: (5.0 + 4.75 + 5.0 + 5.0) / 4 = 19.75/4 = 4.9375 → STRONG PASS.**

**iter1213 (+)-mnemonic watch status**: **CLOSES CLEANLY.** Responder named the canonical mechanical rule both directions (`a.x = b.y(+)` → LEFT, `a.x(+) = b.y` → RIGHT) with explicit "table WITH (+) is null-padded, table WITHOUT (+) is preserved" mnemonic; worked example with named tables (departments/managers); both Oracle source and Trino target syntax shown verbatim. Engineer can mechanically rewrite migrated Oracle (+) queries first try. Watch closes 27th consecutive 1st-re-probe-CLOSE in the LIGHT-FIX-A-then-CLOSE pattern.

---

## Watch status

| Watch | Open since | Status this iter | Reasoning |
|---|---|---|---|
| `iter1246 OOM-session-prop-direction` | iter1246 | **CLOSES CLEANLY** | This iter's Q3 was on the dbt-application-surface question (pre_hook vs profile.yml session_properties), not the cluster-cap-vs-session-cap direction. Engineer confirmed CLI works (so cluster ceiling supports 10GB). Responder correctly named pre_hook + hedged on profile session_properties; no direction inversion. |
| `iter1213 (+)-mnemonic` | iter1213 | **CLOSES CLEANLY** | Responder named the canonical mechanical rule verbatim ("table WITH (+) null-padded, table WITHOUT (+) preserved"), both directions, worked before/after example. iter1213 mnemonic-gap fully closed. |

### No new watches opened this iteration.

The Q2 SemiJoin-vs-antijoin terminology slip is a per-instance broken-secondary-alternative (per pinned `feedback_responder_broken_secondary_alternative.md`) — recall ceiling, NO resource fix, scope as one-off not a defect family.

The Q3 hedge on `session_properties:` profile field is under-confidence on a documented feature, but the responder still pointed the engineer at the right place; no resource defect (resources may benefit from a more confident leading canonical, but per the new-card-over-attracts-adjacent caution, churning on this isn't warranted at 4.875 average and a CLOSING watch).

---

## Other open watches (untouched this iter, status carried)

| Watch | Open since | Status |
|---|---|---|
| `iter1249 Q3 dbt-snapshot-recall-variance` | iter1249 | SOFT — untouched. |
| `iter1248 Q1 opener-coherence` | iter1248 | Untouched. |
| `iter1248 Q3 MATCH_RECOGNIZE-adjacency` | iter1248 | Untouched. |
| `iter1241 concat-auto-coerces` | iter1241 | Untouched. |
| `iter1239 DF-wait-timeout` | iter1239 | Untouched. |
| `iter1238 broadcast-hedge` | iter1238 | Untouched. |
| `iter1236 rn=1-within-batch` | iter1236 | Untouched. |
| `iter1230 EXISTS-overwarning/::cast` | iter1230 | Untouched. |
| `iter1215 strpos-3-arg CEILING` | iter1215 | Untouched. |
| `iter1229 @v1-Spark` | iter1229 | Untouched. |
| `iter1201 dbt --full-refresh mechanism on incremental` | iter1201 | Untouched. |

(iter1213 session_properties/(+) split into two halves; the (+) half closes this iter; the session_properties half was implicitly covered via iter1246-style framing this iter — both Q3 and Q4 forms now have at least one CLOSE-quality probe.)

---

## Summary

- **Q1 STRONG PASS** — `$files` content-codes + file_size_in_bytes diagnostic verified verbatim at trino.io/docs/467/connector/iceberg.html + iceberg FileContent.java; full fix chain (`EXECUTE optimize(file_size_threshold)` → `EXECUTE expire_snapshots(retention_threshold)`) correctly sequenced.
- **Q2 STRONG PASS** — NOT IN + NULL trap correctly affirmed; NOT EXISTS and LEFT JOIN-IS NULL fixes both correct; minor "SemiJoin" terminology slip on the per-instance performance-aside (decorrelates to ANTI-JOIN not SemiJoin) — per-instance broken-secondary, no resource defect.
- **Q3 STRONG PASS — iter1246 OOM-session-prop watch CLOSES.** `pre_hook="SET SESSION ..."` per-model mechanism verified verbatim at docs.getdbt.com/reference/resource-configs/trino-configs; bare `SET SESSION` in model SQL erroring correctly explained; global form via `session_properties:` profile.yml field reached but under-hedged.
- **Q4 STRONG PASS — iter1213 (+)-mnemonic watch CLOSES.** Mechanical rule "table WITH (+) is null-padded; table WITHOUT (+) is preserved" verbatim from Oracle docs; both directions covered; worked before/after example.

**Iteration verdict: 4.875 STRONG PASS NO-OP. TWO watches CLOSE (iter1246 OOM-session-prop-direction; iter1213 (+)-mnemonic). No FIX-A. No new watches.**

**Topics scored this iter** (per rubric assignment):
- Q1 → Iceberg table maintenance ($files content-code diagnostic + EXECUTE optimize / expire_snapshots fix chain)
- Q2 → SQL query best practices for OLAP (NOT IN NULL trap + NOT EXISTS / LEFT JOIN-IS NULL NULL-safe replacements)
- Q3 → Improving complex SQL performance on Trino with dbt (dbt-trino pre_hook + session_properties profile.yml for Trino session-property control)
- Q4 → Oracle PL/SQL → dbt + Trino SQL migration (Oracle (+) outer join → Trino LEFT/RIGHT OUTER JOIN mechanical rewrite)

# Iter1155 — Judge Feedback

**Verdict: STRONG PASS + NO-OP-with-watch on Q3 caveat-#3 broken-secondary slip.**

iter1154 LIGHT FIX-A (r07 §3158-3164 "three equivalent final-count forms" mini-block + §3179 DO-NOT-WRITE row defanging `COUNT(DISTINCT SUM(...) OVER (...))` window-in-aggregate) **REACHED CLEANLY ON FIRST RE-PROBE**. Watch `r07 sessionization final-count synthesis ceiling iter1154` **CLOSED**.

| Q | Score | Status | Notes |
|---|---|---|---|
| Q1 page-view 15-min idle sessionization | **4.75** | PASS — iter1154 watch CLOSED | Two-CTE `COUNT(DISTINCT visit_id)` form (option (c) of the new §3158 mini-block); window in its own `visits` CTE, NOT nested in aggregate. Engineer copy-paste runs. |
| Q2 `try()` whole-expression wrap | **5.0** | STRONG PASS | Pin-perfect; verbatim Trino 467 doc match on what try() catches. |
| Q3 Iceberg `expire_snapshots` to reclaim storage | **3.875** | PASS with internal contradiction | Opening, 7d floor, safety-with-concurrent-reads, GDPR-purge route all CORRECT. **Caveat #3 is factually wrong AND contradicts the same answer's own opening** — claims `expire_snapshots` is "metadata-only" and "data files stay around until a later maintenance cycle." Apache Iceberg + Trino 467 docs are unambiguous: `expire_snapshots` physically deletes data/manifest files exclusively referenced by expired snapshots. **NOT resource-sourced** — r17 is correct. Classified as one-off responder broken-secondary slip per `feedback_responder_broken_secondary_alternative`. **NO-OP + watch.** |
| Q4 Oracle ROWNUM → Trino `ORDER BY ... LIMIT` | **5.0** | STRONG PASS | Pin-perfect; correct order-of-application + Oracle subquery-wrap unwrap guidance. |

Iteration average: (4.75 + 5.0 + 3.875 + 5.0) / 4 = **4.656 PASS**

---

## Q1 — Sessionization 15-min idle gap (iter1154 FIX-A re-probe)

**Watch closed.** The responder's query:

```sql
WITH events_with_gap AS (
  SELECT visitor_id, viewed_at,
    CASE
      WHEN LAG(viewed_at) OVER (PARTITION BY visitor_id ORDER BY viewed_at) IS NULL THEN 1
      WHEN date_diff('minute', LAG(viewed_at) OVER (PARTITION BY visitor_id ORDER BY viewed_at), viewed_at) > 15 THEN 1
      ELSE 0
    END AS is_new_visit
  FROM page_views
  WHERE viewed_at >= CURRENT_DATE - INTERVAL '7' DAY
),
visits AS (
  SELECT visitor_id, viewed_at,
    SUM(is_new_visit) OVER (PARTITION BY visitor_id ORDER BY viewed_at) AS visit_id
  FROM events_with_gap
)
SELECT visitor_id, COUNT(DISTINCT visit_id) AS total_visits
FROM visits
GROUP BY visitor_id;
```

This is the **two-CTE `COUNT(DISTINCT visit_id)` form** — option (c) in the new §3158-3164 mini-block. The window `SUM(is_new_visit) OVER (...)` is materialized in its OWN `visits` CTE, and the outer aggregate operates on the materialized column — **NOT** the iter1154 fab where the window was nested directly inside the aggregate at the same level.

Load-bearing elements all present:
- LAG-IS-NULL carve-out → 1 (first event starts visit 1, not visit 0)
- `date_diff('minute', LAG, viewed_at) > 15` compared to plain `15`, **NOT** `INTERVAL '15' MINUTE` (responder explicitly noted "date_diff returns bigint compare to 15 not INTERVAL")
- No `viewed_at - LAG(...)` timestamp-minus-timestamp (correctly avoided per r07 §3172 defang)
- Window in its own CTE, not nested in an aggregate

Minor recall ceiling shave only: did not use the SHORTEST form (a) `SELECT visitor_id, SUM(is_new_visit) AS total_visits FROM events_with_gap GROUP BY visitor_id`. Option (c) is more verbose than necessary but is fully valid and **EXPLICITLY** listed as one of the three equivalent forms in the new mini-block. The mini-block is doing what FIX-A specified.

**Scores: Acc 5.0 / Clarity 4.5 / Practical 5.0 / Completeness 4.5 = 4.75 PASS.**

**Watch `r07 sessionization final-count synthesis ceiling iter1154`: CLOSED.** This is the latest in the "first NO-OP/LIGHT-FIX-A → close on next re-probe" pattern (consistent with r17 TopN-disambiguation closure / r23 VARCHAR-exact-comparison closure / r07 IGNORE-NULLS-placement closure).

---

## Q2 — `try(expr)` to wrap arbitrary runtime-failing expression

**Pin-perfect.** Verified against [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html):

> "Evaluate an expression and handle certain types of errors by returning `NULL`."

Doc lists three explicit catch categories:
- Division by zero
- Invalid cast or function argument
- Numeric value out of range

Responder's catch list (`division by zero`, `invalid casts/function args`, `numeric overflow`, `JSON errors`) is correct. Does-NOT-catch list (`syntax errors`, `unresolved columns`, `timeouts`, `memory limits`, `fail()`) is correct — those happen at parse/analyze time (not runtime), or are infrastructure-level (not expression-level), or are explicitly bypassed by `fail()` design.

Usage patterns correct:
- `try(amount/commission_rate)` — wraps division, NULL on zero denominator
- `COALESCE(try(...), 0)` — default value pattern
- Correctly distinguished from `NULLIF(denom, 0)` (which only handles divide-by-zero, requires editing each division; `try()` is the general expression-wrap)

Cites r27 §4.4E. Clean 5.0 all dimensions.

---

## Q3 — Iceberg `expire_snapshots` (CORE CORRECT, CAVEAT #3 WRONG)

### Core actionable answer: CORRECT

```sql
ALTER TABLE iceberg.analytics.page_views EXECUTE expire_snapshots(retention_threshold => '7d')
```

- Syntax matches Trino 467 native form (verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html); r17 §21 names this exact form).
- "Safe while actively read" claim is correct — Iceberg snapshot atomicity: live snapshots referenced by metadata.json are never deleted; readers planning against the current snapshot continue to see consistent data.
- 7-day minimum-retention floor on Trino is correct (r17 §1526 + catalog property `iceberg.expire-snapshots.min-retention` = `7d` default).
- GDPR same-day purge route via Spark `CALL` form OR lowered min-retention is correct (r17 §297).
- Caveat #2 (cannot time-travel past the expiry window) correct.

### Opening is CORRECT

> "drops OLD snapshot metadata and the small data files that those old snapshots exclusively referenced."

Matches r17 §210, §1516, §1613, §1619 verbatim. Matches [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html): *"The `expire_snapshots` command removes all snapshots and all related metadata and data files."* Matches Apache Iceberg semantics (verified via [WebSearch 2026-06-27](https://apache.github.io/iceberg/docs/1.4.3/spark-procedures/) "This procedure will remove old snapshots and data files which are uniquely required by those old snapshots").

### CAVEAT #3 IS FACTUALLY WRONG (internally contradicts the opening)

Responder wrote, verbatim:

> "It does NOT affect time-travel queries directly: Snapshots older than 7 days become inaccessible via FOR VERSION AS OF, but expire_snapshots is about *metadata* — the actual data files stay around until a later maintenance cycle. Storage reclamation is incremental across weekly maintenance windows."

This is wrong on two counts:

1. **"expire_snapshots is about *metadata* — the actual data files stay around until a later maintenance cycle"** is FALSE. Per Trino 467 docs verbatim, the procedure "removes all snapshots and all related metadata **and data files**." Per r17 §1613: *"`expire_snapshots` **physically deletes them** from MinIO (issues S3 DELETE calls). These files are NOT orphans and are NOT handled by `remove_orphan_files`; `expire_snapshots` handles them directly."* The data-file deletion is part of the `expire_snapshots` operation itself, not a deferred step.

2. **"Storage reclamation is incremental across weekly maintenance windows"** — also misleading. Storage reclaims as soon as the procedure runs (S3 DELETE calls issued during execution); there is no "incremental" deferral. r17 §1615 verbatim: *"Storage only drops visibly on MinIO after BOTH `rewrite_data_files` AND `expire_snapshots` have run. If you ran compaction last night and the storage graph still shows growth, that is expected — schedule `expire_snapshots` to follow and the drop will appear after that runs."*

The mistake conflates `expire_snapshots` (which deletes data files exclusively referenced by expired snapshots) with `remove_orphan_files` (which sweeps files not referenced by ANY snapshot — typically failed-write debris). These are two **different** garbage classes per r17 §1620 and the Apache Iceberg docs ("Task or job failures can leave files that are not referenced by table metadata... use the deleteOrphanFiles action").

### Source classification: NOT resource-sourced

Grepped resources/ for `expire_snapshots` framing — r17 §210, §1516, §1613, §1619 all consistently and correctly state that `expire_snapshots` physically deletes data files exclusively referenced by expired snapshots. No resource teaches the wrong "metadata-only / deferred deletion" framing.

This is a **responder broken-secondary slip** per pinned `feedback_responder_broken_secondary_alternative.md` — the responder nails the load-bearing core answer (run `expire_snapshots`, safe, 7d floor) but appends a "for completeness" caveat #3 that fabricates a deferred-deletion mental model that contradicts the resource and the responder's own opening sentence. Known Haiku failure mode (iter936/943/948/950/954/1013/1019/1020/1141 history).

### Classification

- NO RESOURCE FIX. r17 is already correct and explicit on this point at multiple anchors. Adding a defang against "metadata-only" framing risks over-attracting adjacent snapshot/maintenance questions (per pinned `feedback_new_card_over_attracts_adjacent.md`).
- **NO-OP + watch.** Watch label: `r17 expire_snapshots metadata-only-vs-physical-delete responder caveat iter1155`. Re-probe with a question phrased around "after I run expire_snapshots, when will I see MinIO storage actually drop?" or "is expire_snapshots immediate or scheduled?" in a future sweep. If recurrent → consider an additive r17 callout pinning "expire_snapshots issues S3 DELETE during execution, not a deferred cleanup" with cross-ref to `remove_orphan_files` as the *different* tool for *different* garbage.

### Practical impact

Engineer copy-pastes the EXECUTE statement and storage DOES drop (the core answer is correct and runnable). The caveat #3 confusion costs them mental-model accuracy: they may think they need to schedule `remove_orphan_files` to actually reclaim, or expect a delayed drop in MinIO graphs that never materializes from `expire_snapshots`. Not catastrophic but a real cost.

**Scores: Acc 3.0 (internal contradiction load-bearing on storage-reclaim mental model) / Clarity 4.5 / Practical 4.0 (core actionable, caveat #3 misleads runbook expectations) / Completeness 4.0 = 3.875 PASS.**

---

## Q4 — Oracle `ROWNUM` → Trino `ORDER BY ... LIMIT`

**Pin-perfect.** Verified against [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html):

> "The `ORDER BY` clause is evaluated after any `GROUP BY` or `HAVING` clause, and before any `OFFSET`, `LIMIT` or `FETCH FIRST` clause."
>
> "If the `OFFSET` clause is present, the `LIMIT` or `FETCH FIRST` clause is evaluated after the `OFFSET` clause."

So Trino's order of application: sort → offset → limit. `ORDER BY x LIMIT 50` returns the true sorted top-50. Matches pinned `reference_trino_offset_before_limit.md` (OFFSET BEFORE LIMIT syntax order is a separate parse-grammar issue, not in scope here).

Oracle ROWNUM gotcha description is correct:
- ROWNUM is assigned during row retrieval, before ORDER BY
- Naive `WHERE ROWNUM <= 50 ORDER BY ...` returns 50 arbitrary rows then sorts them — silently wrong top-N
- Oracle idiom wraps in a subquery: `SELECT * FROM (SELECT ... ORDER BY ...) WHERE ROWNUM <= 50` to get the sort BEFORE the row-cap

Migration guidance is correct: on Trino you do **not** need the subquery wrap — `ORDER BY ... LIMIT 50` already gives the true sorted top-50; unwrap the Oracle outer subquery. Cites r27. Clean 5.0 all dimensions.

---

## Topic-mapping decisions

| Question | Topic touched |
|---|---|
| Q1 page-view sessionization | Analytical query patterns on Iceberg+Trino (4.5077 → 4.5099) |
| Q2 `try()` whole-expression wrap | SQL query best practices for OLAP (4.5807 → 4.5825) |
| Q3 `expire_snapshots` storage reclaim | Iceberg table maintenance (4.4527 → 4.4497) |
| Q4 ROWNUM → ORDER BY LIMIT | Oracle PL/SQL → dbt + Trino SQL migration (4.4547 → 4.4590) |

All four topics remain PASSED. No threshold cross. Q3 slight decrement (3.875 < topic prior 4.4527) consistent with broken-secondary slip absorbed by 187-question cushion.

---

## What teacher should NOT do

- **Do NOT add a metadata-only-vs-physical-delete defang to r17.** r17 §1613/§1615/§1619/§1620 already correctly state the physical-delete behavior at multiple anchors. The responder slip was confabulation of a caveat that contradicts both r17 AND the responder's own opening — not a findability gap. Adding a "DO-NOT-WRITE: expire_snapshots is metadata-only" row would risk over-attracting adjacent maintenance questions (per `feedback_new_card_over_attracts_adjacent.md`) and would not solve a Haiku padding-caveat synthesis issue.
- **Do NOT touch the r07 sessionization final-count mini-block.** It is doing exactly what FIX-A specified — the re-probe closed the watch on the FIRST attempt with a structurally different domain (page-view visits at 15-min threshold vs iter1154 device pings at 30-min threshold). Hold.

## Watches active going into iter1156

- `r17 expire_snapshots metadata-only-vs-physical-delete responder caveat iter1155` — NEW, NO-OP, re-probe with "when does storage actually drop after expire_snapshots" / "is expire_snapshots immediate"
- Carry forward existing maintenance breadth re-probes (rewrite_position_delete_files MoR-only, orphan-file 7d floor)

## State

- Phase: extended
- Iteration: 1155 → ready for 1156
- All required topics still PASSED with healthy margins

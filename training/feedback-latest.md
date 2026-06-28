# Iteration 1236 — Judge Feedback

## Verdict

**Overall: 4.625 — STRONG PASS. iter1235 PRIMARY WATCH `incremental_predicates-ON-clause-dup-insert reconciled-content-reach` CLOSES on first re-probe (20th consecutive 1st-re-probe-CLOSE). NO NEW FIX-A.**

Mechanism + source-side NOT EXISTS fix REACHED on Q1's reconciled content; minor completeness gaps on the within-batch rn=1 dedupe pairing and an undefined SQL alias (per-instance recall, not source-defect). Q2 (cumulative SUM window with default-RANGE-peer caveat), Q3 (dbt seeds column_types in dbt_project.yml), Q4 (Oracle INSTR → strpos with substr-offset workaround navigating the iter1215 strpos-3-arg CEILING) all pin-perfect to near-perfect with full source-doc verification.

| Q | Score | Topic | Notes |
|---|---|---|---|
| Q1 | 4.0 | Improving complex SQL perf on Trino with dbt | iter1235 watch CLOSES; mechanism + NOT EXISTS source-side fix REACHED; minor: undefined `source_table.` alias + missing rn=1 within-batch dedupe pairing |
| Q2 | 4.875 | Analytical query patterns on Iceberg+Trino | Pin-perfect SUM-OVER-PARTITION-BY canonical + correct default-frame RANGE-tied-peers caveat |
| Q3 | 4.75 | Improving complex SQL perf on Trino with dbt | dbt_project.yml +column_types syntax matches docs verbatim; minor: didn't mention alt properties.yml form or --full-refresh requirement |
| Q4 | 4.875 | Oracle PL/SQL → dbt+Trino migration | Clean strpos-3-arg-as-Nth-occurrence vs Oracle-INSTR-3rd-arg-as-START-position distinction; substr-offset workaround math correct |

**Topic averages this iter:**
- Improving complex SQL perf on Trino with dbt: 4.4915/55 → **4.4874/57 PASSED** (-0.0041, Q1+Q3 both rolled in, count +2, margin +0.9874)
- Analytical query patterns on Iceberg+Trino: 4.5535/168 → **4.5554/169 PASSED** (+0.0019, margin +1.0554)
- Oracle PL/SQL → dbt+Trino migration: 4.4610/201 → **4.4630/202 PASSED** (+0.0020, margin +0.9630)

ALL REQUIRED TOPICS REMAIN PASSED with comfortable margins. No topic dipped below +0.7 from threshold.

---

## Q1 — Watch closure analysis (PRIMARY)

**WATCH `iter1235 incremental_predicates-ON-clause-dup-insert reconciled-content-reach`: CLOSES.**

The iter1235 reconciled content (r13 §5514+, r27 late-arriving card, r28 §382) landed three load-bearing facts:
1. incremental_predicates is for partition-pruning ONLY (not freshness guards)
2. The robust only-update-if-newer fix is SOURCE-SIDE
3. The pairing is ROW_NUMBER()=1 per key + `{% if is_incremental() %} NOT EXISTS(t.key=s.key AND t.updated_at>=s.updated_at) {% endif %}` → then a plain unconditional MERGE is correct

The responder reached facts (1) and (2) cleanly. The mechanism explanation matches docs.getdbt.com/docs/build/incremental-strategy verbatim:

> incremental_predicates are incorporated into the MERGE ON clause [...] merge into ... DBT_INTERNAL_DEST from ... DBT_INTERNAL_SOURCE on DBT_INTERNAL_DEST.id = DBT_INTERNAL_SOURCE.id and <predicate>

The responder correctly traced: `dest.updated_at < source.updated_at` is FALSE for a late older row (dest is newer) → ON clause fails → row falls to WHEN NOT MATCHED → INSERT → duplicate by order_id. That's exactly the failure mode the reconciled content captures.

The dbt docs explicitly recommend "filter upstream source data" within the model SQL as the correct approach — the responder's NOT EXISTS pre-filter matches the documented recommendation. The watch's primary axis (mechanism + source-side fix direction) reached cleanly. **Watch CLOSES.**

### Two minor gaps (recall ceiling, NOT resource-sourced)

**Gap A — Undefined `source_table.` correlation alias.** The model FROM is `{{ source('app','orders') }}` (no alias), but the responder's NOT EXISTS references `source_table.order_id` / `source_table.updated_at`. Engineer copy-pastes and gets a column-binding error; adds `AS source_table` in 30 sec. Per-instance SQL precision slip; the conceptual fix is correct.

**Gap B — Missing rn=1 within-batch dedupe pairing.** The reconciled resource pairs ROW_NUMBER()=1 with NOT EXISTS. NOT EXISTS handles cross-run late-older case; ROW_NUMBER()=1 handles within-batch duplicate keys (one CDC batch with multiple rows for the same order_id). With only NOT EXISTS, a batch with order_id-collisions can still trigger `MERGE_TARGET_ROW_MULTIPLE_MATCHES` on subsequent runs.

Partial reach of the canonical pairing, not a resource gap. **NEW SOFT WATCH** `iter1236 source-side-NOT-EXISTS-without-rn=1-within-batch-pairing` — re-probe in 4-8 iters under "dbt incremental merge throws MERGE_TARGET_ROW_MULTIPLE_MATCHES" or "same order_id appears multiple times in one CDC batch" framing.

**NO FIX-A.** Watch primary axis closes. Completeness sibling is per-instance recall on an already-anchored canonical; pre-emptive churn risks `feedback_new_card_over_attracts_adjacent` regression. If the within-batch axis recurs in 4-8 iters, consider a LIGHT additive line in the r13 source-side-fix card explicitly anchoring "covers cross-run AND within-batch — rn=1 is the within-batch half, NOT EXISTS is the cross-run half."

---

## Q2 — Cumulative SUM window function (pin-perfect)

Canonical answer:
```sql
SUM(amount) OVER (PARTITION BY customer_id ORDER BY spend_date
                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total
```

VERIFIED via [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) + [trino.io/blog/2021/03/10/introducing-new-window-features.html](https://trino.io/blog/2021/03/10/introducing-new-window-features.html): "If the frame is not specified, it defaults to RANGE UNBOUNDED PRECEDING [...] CURRENT ROW includes all rows where values of the sort key are the same as in the current row. We call them a peer group."

The responder's tied-peers caveat is load-bearing CORRECT: under the default RANGE frame, tied `spend_date` rows share the cumulative value; either explicit ROWS frame (which the SQL already uses) OR a tiebreaker (`ORDER BY spend_date, order_id`) gives per-row accumulation. The shown SQL is correct on its own because it uses ROWS explicitly.

---

## Q3 — dbt seeds column_types (matches docs verbatim)

VERIFIED at [docs.getdbt.com/reference/resource-configs/column_types](https://docs.getdbt.com/reference/resource-configs/column_types):

```yaml
seeds:
  jaffle_shop:
    country_codes:
      +column_types:
        country_code: varchar(2)
        country_name: varchar(32)
```

Responder's syntax matches verbatim. Preserve-leading-zeros (varchar) is the documented canonical use case (`zipcode: varchar(5)` example in docs). Minor completeness gaps:
- Didn't mention alternate `seeds/properties.yml` form (Option 2 in docs)
- Didn't surface `dbt seed --full-refresh` requirement after modifying column_types on an already-loaded seed (silent no-op without it per docs verbatim)

Both minor for the asked "where + syntax" question. Engineer arrives at working dbt_project.yml + correct leading-zero preservation.

---

## Q4 — Oracle INSTR → Trino strpos (CLEAN navigation of iter1215 ceiling)

This is adjacent to the documented `iter1215 strpos-3-arg CEILING` watch (Trino's 3rd arg is N-th OCCURRENCE, NOT Oracle's START position). The responder navigated it cleanly this iter.

VERIFIED at [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html):
- `strpos(string, substring) → bigint` — first occurrence, 1-indexed, 0 if not found (1-to-1 Oracle INSTR 2-arg match)
- `strpos(string, substring, instance) → bigint` — N-th occurrence; negative N searches from end; NOT a start-position arg

Substr-offset workaround math verified:
```sql
CASE WHEN strpos(substr(url,10),'/') > 0
     THEN strpos(substr(url,10),'/') + 10 - 1
     ELSE 0 END
```
`substr(url, 10)` shifts position 1 of the substring to position 10 of the original; if strpos returns k, original position is `k + 10 - 1 = k + 9`. Matches Oracle `INSTR(url, '/', 10)` semantics. CASE handles the 0-if-not-found return.

3-arg-as-Nth-occurrence example `strpos('a.b.c.d','.',2) → 4` correct (positions of '.' are 2,4,6; 2nd = 4).

Iter1215 CEILING successfully navigated this iter — both 2-arg and 3-arg semantics + substr-offset start-position workaround all reached on one answer. Recurring monitor.

---

## Open watches roll-up

- **iter1236 source-side-NOT-EXISTS-without-rn=1-within-batch-pairing** (NEW SOFT, 4-8 iter horizon)
- iter1235 incremental_predicates-ON-clause-dup-insert reconciled-content-reach — **CLOSED THIS ITER**
- iter1234 ROLLUP-date_trunc-expression-inside (soft, still open)
- iter1234 FOR-VERSION-AS-OF-quoting (passive)
- iter1233 IGNORE-NULLS-framing (per-instance, passive)
- iter1231 NEXT_DAY-note (passive)
- iter1230 plain-correlated-EXISTS-OVER-WARNING (per-instance, passive)
- iter1230 ::cast-Postgres-leak (passive, light-monitor)
- iter1215 strpos-3-arg CEILING — **navigated cleanly this iter (Q4)**, recurring monitor
- iter1213 session_properties/(+)
- iter1229 @v1-Spark
- iter1208 width_bucket

---

## Recommended next iter direction

Continue BREADTH. Iter1236 closed the iter1235 primary watch on first re-probe; the reconciled content reached the responder's keyword path. Pre-emptive churn on the within-batch-pairing sibling is high regression risk per `feedback_new_card_over_attracts_adjacent`. Probe novel under-tested angles (storage tiering, dbt snapshots, query-perf basics — the thinner topic rows in the 4.1-4.3 band) rather than re-probing the same dbt-incremental neighborhood. ~1.3 days remain to deadline (2026-06-30 23:59 CST).

---

## Source verifications this iter

- [docs.getdbt.com/docs/build/incremental-strategy](https://docs.getdbt.com/docs/build/incremental-strategy) — incremental_predicates lands in MERGE ON clause; recommended fix is upstream source filtering in model SQL
- [docs.getdbt.com/reference/resource-configs/column_types](https://docs.getdbt.com/reference/resource-configs/column_types) — column_types in dbt_project.yml or seeds/properties.yml; --full-refresh required after change
- [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html) — strpos 2-arg (first occurrence) + 3-arg (Nth occurrence, negative=from end), NO start-position arg
- [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) — window function semantics
- [trino.io/blog/2021/03/10/introducing-new-window-features.html](https://trino.io/blog/2021/03/10/introducing-new-window-features.html) — default frame = RANGE UNBOUNDED PRECEDING through current row's peer group (peers = tied ORDER BY values)

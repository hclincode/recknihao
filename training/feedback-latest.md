# Iter1175 — Judge Feedback

## Verdict: STRONG PASS — Average 4.875 / 5.0 — Q1 WATCH CLOSES (r27 LATERAL/CROSS APPLY FIX-A REACHED CLEANLY)

| Q | Topic row | Score | Verdict |
|---|---|---:|---|
| Q1 LATERAL/CROSS APPLY for "latest price-change per product" per-row correlated subquery | Oracle PL/SQL → dbt+Trino migration | 5.0 | **iter1174 r27 §35 LATERAL FIX-A REACHED CLEANLY — WATCH CLOSES on first re-probe. Affirmed LATERAL exists, ON true required for LEFT JOIN LATERAL, correct CROSS-vs-LEFT JOIN choice, ROW_NUMBER alternative noted as better-planning for top-N-per-group.** |
| Q2 `array_remove(arr, element)` removes single element from string array | Analytical query patterns on Iceberg+Trino | 5.0 | pin-perfect — one row in/out, no UNNEST, removes all occurrences, cites r07 |
| Q3 4×3 plan_tier × billing_region grid with explicit zeros for absent combos | Analytical query patterns on Iceberg+Trino | 4.5 | Cross-join-of-dimensions + LEFT JOIN + COALESCE pattern correct; minor completeness shave — used `SELECT DISTINCT … FROM accounts` for the dimension spine which silently drops any FULLY-ABSENT dimension value (e.g. zero enterprise accounts anywhere → 9 cells not 12). Static `VALUES ('free'),('starter'),('pro'),('enterprise')` CROSS JOIN VALUES is the bulletproof form for a known fixed list. Practical impact bounded — pattern works correctly the moment at least one row exists per tier/region. |
| Q4 Long-running Trino-on-Iceberg query + mid-query writes — reader-side snapshot isolation? | Iceberg table maintenance / Iceberg concurrent writes | 5.0 | pin-perfect — quoted r26 §45 verbatim ("a query started at snapshot S sees the table exactly as it was at S, regardless of how many writers committed after S"); correctly distinguished writer-side `write.delete/update/merge.isolation-level` props from reader visibility. Cites r26. |

Iter average = (5.0 + 5.0 + 4.5 + 5.0) / 4 = **4.875**. Three pin-perfect canonical reaches + one minor completeness shave. Q1 WATCH CLOSES on first re-probe (13 of last 13 watches close on first re-probe).

---

## Q1 — LATERAL / CROSS APPLY per-row correlated join (STRONG PASS 5.0) — WATCH CLOSES

### Responder answer (verbatim core)

> *"YES — Trino 467 supports LATERAL (ANSI standard, equivalent to APPLY)."*
>
> ```sql
> SELECT p.product_id, p.name, pc.*
> FROM products p
> LEFT JOIN LATERAL (
>   SELECT * FROM price_changes
>   WHERE product_id = p.product_id
>   ORDER BY changed_at DESC LIMIT 1
> ) pc ON true;
> ```
>
> *"LATERAL subquery references `p.product_id`, `ORDER BY changed_at DESC LIMIT 1` per product, one row per product. `ON true` required for LEFT JOIN LATERAL. CROSS JOIN LATERAL drops products w/ no changes; LEFT JOIN LATERAL … ON true keeps all (NULLs). For top-N-per-group at scale, `ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY changed_at DESC)` wrapped in subquery often plans better; LATERAL gives APPLY parity."*

### Verification

- **LATERAL exists in Trino 467**. Verified verbatim at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html): *"Subqueries appearing in the FROM clause can be preceded by the keyword LATERAL. This allows them to reference columns provided by preceding FROM items."* Same page: *"A LATERAL join can appear at the top level in the FROM list, or anywhere within a parenthesized join tree."* And: *"for each row of the FROM item providing the cross-referenced columns, the LATERAL item is evaluated using that row set's values"*.
- **ORDER BY + LIMIT inside LATERAL works**. Confirmed via web search — Trino has explicit decorrelation support for ORDER BY+LIMIT in correlated subqueries (PR #1415 "Decorrelate subqueries with Limit or TopN" by kasiafi; PR #8554 "Improve support for correlated subqueries with GROUP BY or LIMIT"). The classic top-N-per-group shape `FROM groups g CROSS JOIN LATERAL (SELECT * FROM items WHERE group_id = g.id ORDER BY date DESC LIMIT N)` is the documented use case.
- **ON true is the documented `LEFT JOIN LATERAL` form**. ANSI/SQL-standard; matches r27 §35 verbatim translation `OUTER APPLY (subq)` → `LEFT JOIN LATERAL (subq) ON true`.
- **ROW_NUMBER alternative routing correct**. r27 §35 verbatim: *"BUT for top-N-per-group, the `row_number() OVER (PARTITION BY account_id ORDER BY created_at DESC)` + outer `WHERE rn <= 3` rewrite is usually the better-planning, more idiomatic Trino form (a correlated LATERAL-with-LIMIT can plan as a per-row CorrelatedJoin). Pick LATERAL for 1:1 migration parity / genuinely per-row logic; pick `row_number()` for top-N-per-group at scale."*

### Watch close

`r27 LATERAL / CROSS APPLY FIX-A iter1174` — **CLOSES on first re-probe**. The iter1174 FIX-A added an r27 §35 myth-table row stating Trino 467 HAS LATERAL with the documented translation `CROSS APPLY → CROSS JOIN LATERAL` / `OUTER APPLY → LEFT JOIN LATERAL ... ON TRUE`, both forms + ROW_NUMBER selection rule, DO-NOT-WRITE defang of "Trino has no LATERAL", worked Oracle→Trino side-by-side example, and keyword anchors {CROSS APPLY, OUTER APPLY, LATERAL, CROSS JOIN LATERAL, LEFT JOIN LATERAL, per-row correlated join, per-account top-N tickets, Oracle CROSS APPLY translation, SQL Server APPLY in Trino}. iter1175 Q1 was deliberately phrased with DIFFERENT framing (price-changes-per-product, SQL Server/Oracle APPLY recall, single-most-recent variant of top-N) and the FIX-A reached cleanly — engineer gets the correct LATERAL affirmation AND the ROW_NUMBER planning-trade-off in the same answer. Imported-prior fab-class regression PREVENTED.

13 of last 13 watches close on first re-probe pattern HOLDS.

---

## Q2 — `array_remove(arr, element)` element removal (STRONG PASS 5.0)

### Responder answer (verbatim core)

> *"`array_remove(feature_flags, 'legacy_export')` — removes ALL occurrences of 'legacy_export' from each user's array. One row in / one row out. No `UNNEST` + re-aggregate needed."*

### Verification

- `array_remove(x, element) → array` — verified at [trino.io/docs/467/functions/array.html](https://trino.io/docs/467/functions/array.html). Docs verbatim: *"Remove all elements that equal `element` from array `x`."*
- Matches r07 §751 LEADING CANONICAL ("array_remove(arr, element) removes ALL occurrences") + iter750 PIN.
- Engineer's UPDATE-style use case (`UPDATE users SET feature_flags = array_remove(feature_flags, 'legacy_export')`) is the canonical retire-a-flag pattern — Trino 467 supports UPDATE on Iceberg tables per [trino.io/docs/467/sql/update.html](https://trino.io/docs/467/sql/update.html). One row in/out, no fanout.

Clean 5.0 all dimensions.

---

## Q3 — 4×3 plan_tier × billing_region grid with explicit zeros (PASS 4.5)

### Responder answer (verbatim core)

> ```sql
> WITH dim_tiers AS (SELECT DISTINCT plan_tier FROM accounts),
>      dim_regions AS (SELECT DISTINCT billing_region FROM accounts),
>      all_combinations AS (
>        SELECT t.plan_tier, r.billing_region
>        FROM dim_tiers t CROSS JOIN dim_regions r
>      ),
>      grouped_data AS (
>        SELECT plan_tier, billing_region, COUNT(*) AS account_count
>        FROM accounts GROUP BY plan_tier, billing_region
>      )
> SELECT c.plan_tier, c.billing_region, COALESCE(g.account_count, 0)
> FROM all_combinations c
> LEFT JOIN grouped_data g
>   ON c.plan_tier = g.plan_tier AND c.billing_region = g.billing_region
> ORDER BY c.plan_tier, c.billing_region;
> ```

### Verification

- **Pattern is fundamentally correct.** CROSS JOIN of two distinct-value sets → LEFT JOIN the grouped data → `COALESCE(count, 0)` is the textbook fill-zero-for-sparse-cells form. Trino 467 supports CROSS JOIN per [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) §JOIN syntax + `COUNT(*)` GROUP BY standard.
- Engineer can copy-paste and arrives at the right answer in the common case (every tier and every region has ≥1 account somewhere in `accounts`).

### Minor completeness shave (-0.5 Completeness)

The `SELECT DISTINCT plan_tier FROM accounts` / `SELECT DISTINCT billing_region FROM accounts` dimension-spine is a **DISTINCT-from-observed-data spine** — same family as the time-spine trap r07 §1608 explicitly warns against:

> r07 §1608 verbatim: *"**DO NOT** build the spine from `SELECT DISTINCT date_trunc('day', event_ts) FROM facts` — days with **zero events across ALL entities** will be MISSING (you only get days that appear at least once in the raw facts)."*

The engineer's literal stakeholder ask is **"all 12 cells"** (explicit 4×3 grid). If `enterprise` tier has zero accounts in ANY region, OR if `apac` region has zero accounts in ANY tier, the DISTINCT spine silently drops that entire row/column → engineer ships 9 cells (or 8) when stakeholders asked for 12.

The bulletproof form for a known fixed dimension set is **static VALUES lists**:

```sql
WITH dim_tiers(plan_tier) AS (VALUES ('free'),('starter'),('pro'),('enterprise')),
     dim_regions(billing_region) AS (VALUES ('us'),('eu'),('apac')),
     all_combinations AS (
       SELECT t.plan_tier, r.billing_region
       FROM dim_tiers t CROSS JOIN dim_regions r
     ),
     ...
```

This guarantees exactly 12 cells regardless of what's in `accounts`. The 4 tiers and 3 regions were explicitly named in the question, so the dimension set is **known fixed** — exactly the case where static VALUES dominates DISTINCT-from-data. `VALUES (...)` as a table-source is valid Trino 467 per [trino.io/docs/current/sql/values.html](https://trino.io/docs/current/sql/values.html) and is the canonical small-static-table form across r07/r09/r23.

### Classification — NOT a defect, not a resource fix

- Pattern is fundamentally right; engineer gets a working query that handles the common case correctly.
- Static-VALUES refinement is a recall ceiling — r07 has the time-spine canonical with DISTINCT-from-data warning but does NOT have a categorical-dimension-spine canonical pairing it with static VALUES for known-fixed-dimension cases.
- Responder framing is the standard textbook "all combinations" answer; the refinement is the more bulletproof variant.
- **NO RESOURCE FIX**. Adding a new categorical-dim-spine canonical card with static VALUES risks `feedback_new_card_over_attracts_adjacent` over-attractor on neighboring sparse-grid / fill-zero / pivot questions (which currently route correctly). Re-probe in next sweep with a phrasing that DOES have a fully-absent dimension value (e.g. "no enterprise accounts in our data yet, still want 12 cells") to test whether this gap is load-bearing or one-off recall.
- Watch label: `r07 categorical-dim-spine DISTINCT-from-data static-VALUES preferred iter1175` — if RECURS across phrasings with explicit fully-absent-dim-value framing, consider additive r07 cross-ref from §1608 time-spine canonical to a new categorical-dim-spine card. If ONE-OFF → leave untouched.

---

## Q4 — Iceberg reader-side snapshot isolation during long-running query (STRONG PASS 5.0)

### Responder answer (verbatim core)

> *"YES — Trino guarantees reader-side snapshot isolation. A query started at snapshot S sees the table exactly as it was at S, regardless of how many writers committed after S. The 20-min query sees its start snapshot; concurrent ingestion rows go to a DIFFERENT snapshot, invisible to the running query; later queries see them. Writer-side isolation-level props (`write.delete/update/merge.isolation-level`) control write conflicts, NOT readers."*

### Verification

- **Reader-side snapshot isolation is unconditional**. Verified verbatim in r26 §45: *"Plain reader-side guarantee is unchanged. Both isolation levels give readers full snapshot isolation: a query started at snapshot S sees the table exactly as it was at S, regardless of how many writers committed after S. The isolation level here is a writer-side conflict detection knob, not a reader consistency knob."* — quoted exactly by responder.
- **Iceberg snapshot model** verified at [iceberg.apache.org/spec/](https://iceberg.apache.org/spec/): each table version is a snapshot; commits create new snapshots; readers resolve `metadata_location` → `current-snapshot-id` at query-plan time and pin that snapshot for the entire query. New commits during query execution land in NEW snapshots not visible to the in-flight query. [Trino Iceberg connector docs](https://trino.io/docs/467/connector/iceberg.html) reinforce: time-travel `FOR VERSION AS OF` syntax exists precisely because each snapshot is an immutable view of the table.
- **Writer-side isolation-level** verified via web search of Apache Iceberg docs + Javadoc `org.apache.iceberg.IsolationLevel`:
  - `write.delete.isolation-level` / `write.update.isolation-level` / `write.merge.isolation-level` (default `serializable`, alternative `snapshot`).
  - **Serializable** (default): UPDATE/DELETE/MERGE FAILS if a concurrent commit added a new file that might contain rows matching the predicate.
  - **Snapshot**: weaker — UPDATE/DELETE/MERGE succeeds even if a concurrent commit happened, but may miss rows that the concurrent commit added.
  - Quoted from Iceberg docs: *"the serializable isolation level guarantees that an ongoing UPDATE/DELETE/MERGE operation fails if a concurrent transaction commits a new file that might contain rows matching the condition used in UPDATE/DELETE/MERGE"*. Both settings apply to WRITERS only; readers always get snapshot isolation regardless. Responder's "writer-side conflict detection knob, not reader visibility" framing is exactly correct.
- The mid-query-write mental model the engineer is worried about (the long-running 20-min query reading a mix of old + newly-committed rows) is **not a possible failure mode on Trino+Iceberg**. The only way a long query could fail due to concurrent activity is `expire_snapshots` deleting the data files the in-flight scan was planning to read — that's a maintenance-window issue (separately covered in r05 §3356 + r26), not a mid-query torn read.

Clean 5.0 all dimensions. r26 §45 LEADING CANONICAL on the reader-side guarantee is doing its job — engineer-facing "will my long query see mid-query writes?" routes correctly to the verbatim quote.

---

## Cross-cutting observations

**Strong pattern of one-iteration FIX-A → WATCH CLOSES.** iter1174 added a load-bearing factual correction (Trino HAS LATERAL, with translation table) and iter1175 Q1 with DIFFERENT framing reached the new canonical cleanly. This is now the 13th consecutive watch closing on first re-probe (across format_number, contains_sequence, percent-of-total transcription, INDF-as-NVL-substitute, IF-EXISTS-staging-guard, date-vs-string-literal, TRUNC-2-arg, and now LATERAL). The teacher's pattern of **additive myth-table rows with keyword anchors + DO-NOT-WRITE defang + worked example** consistently lands on Haiku's first re-probe — no recurrence of the imported-prior fab-class on LATERAL.

**Imported-prior-direction error class status.** The LATERAL gap was the **6th instance** of the foreign-looking-but-real Trino syntax / function class (starts_with, to_char, listagg, array_sum, format_number, LATERAL). Each has been resolved by an additive myth-table card pinning the existence + canonical usage shape. iter1175 Q1 confirms LATERAL is now in the "resolved" set. Next probes should look for further instances — candidates the responder might still slip on (unverified — speculative): WITH RECURSIVE (resource exists), JSON_TABLE / JSON_QUERY, GROUPING SETS expressions, TABLESAMPLE BERNOULLI, MATCH_RECOGNIZE.

**Minor Q3 completeness shave does NOT trigger FIX-A.** Q3's DISTINCT-from-data spine is the standard textbook answer; the static-VALUES refinement is more bulletproof but the gap is only load-bearing when an entire dimension value is fully absent. r07 §1608 has the time-spine warning; the categorical-dim case is one layer of abstraction removed and not currently in resources. Re-probe with explicit "no enterprise accounts anywhere, still want 12 cells" framing before deciding if this is a recall ceiling or a resource gap.

**Topic-row routing.** Q1 → Oracle PL/SQL → dbt+Trino migration (LATERAL is an Oracle/SQL-Server APPLY-translation question, scored under the migration topic, watch tied to r27). Q2 → Analytical query patterns on Iceberg+Trino (array_remove canonical lives in r07). Q3 → Analytical query patterns on Iceberg+Trino (cross-join dimension spine + LEFT JOIN + COALESCE-zero is r07 sparse-grid canonical family). Q4 → Iceberg table maintenance (snapshot-isolation reader-side canonical lives in r26 §45). No misroutes.

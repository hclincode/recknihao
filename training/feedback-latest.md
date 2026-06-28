# Iteration 1219 — Judge Feedback

**Verdict: 3.97 PASS (margin) + LIGHT FINDABILITY FIX-A on Q1.** Q2 WoW-pct-change FULL-OUTER-JOIN + COALESCE + dual-CASE-NULL pin-perfect (5.0). Q3 dbt tags-location + `--select tag:billing` vs `+tag:billing` upstream-deps + space-vs-comma OR-vs-AND all verified clean (4.875). **Q1 CoW-vs-MoR FAIL (2.75 — FINDABILITY HEDGE)** — responder partially answered (partition-aligned metadata-only delete, `rewrite_position_delete_files` is Spark-only, Trino 467 `EXECUTE optimize`) but **explicitly hedged "the resources don't contain a direct comparison of CoW vs MoR performance trade-offs for small frequent deletes"** when r13 §2996-§3001 contains EXACTLY that comparison table verbatim. Engineer with a 45-min Spark delete job leaves WITHOUT the load-bearing answer ("switch `write.delete.mode='merge-on-read'` from Spark; Trino 467's writer is already MoR-only"). **LIGHT FIX-A** — keyword-anchor r13 §2996 so "GDPR delete / small frequent deletes / which delete mode is faster / Spark rewriting whole table slow" routes to the comparison. **Q4 Oracle LPAD (3.25 — recall-ceiling, NO FIX-A)** — base form `LPAD(CAST(invoice_number AS VARCHAR),8,'0')` correct; missed the **truncation hazard** (lpad pads-OR-truncates to EXACTLY N — 9-digit invoice silently drops the trailing digit) + missed the **`format('%08d', invoice_number)` canonical** that r23 §716-758 explicitly recommends "whenever the value might exceed the pad width"; **the "no decimals for whole numbers" reassurance is wrong for a generic DECIMAL column** (`CAST(DECIMAL '12345.00' AS VARCHAR)='12345.00'` keeps the scale). All hits are recall-ceiling — r23 §716-758 keyword anchors ("zero-pad an id, truncation hazard, fixed-width truncation hazard") are dense; per `feedback_new_card_over_attracts_adjacent.md` no further defang. Watch.

---

## Per-question scores

### Q1 — GDPR delete: CoW vs MoR for ~10-50K rows × multiple/day; Spark whole-table rewrite is 45 min — **FAIL (FINDABILITY HEDGE) + LIGHT FIX-A**

| Dim | Score | Note |
|---|---|---|
| Technical accuracy | 3 | Partition-aligned delete = metadata-only is correct; `rewrite_position_delete_files` Spark-only correct; Trino 467 `EXECUTE optimize(file_size_threshold)` correct. **BUT the hedge "resources don't contain a CoW-vs-MoR comparison" is factually wrong** — r13 §2996-§3001 has the comparison table verbatim. |
| Beginner clarity | 4 | What's there is clear. The hedge leaves the engineer without the load-bearing recommendation. |
| Practical applicability | 2 | Engineer asked **explicitly** "which one makes delete jobs faster?" — answer dodges. Their 45-min Spark job stays at 45 min after reading this. Missed actionable: `ALTER TABLE ... SET TBLPROPERTIES('write.delete.mode'='merge-on-read')` from Spark + scheduled compaction (`EXECUTE optimize` Trino / `rewrite_position_delete_files` Spark) + `expire_snapshots` for actual GDPR byte removal. |
| Completeness | 2 | Missed three load-bearing facts: (1) **CoW = rewrite whole affected Parquet file per delete** = literally what's causing the 45-min job; (2) **MoR = small position-delete files** = fast write, periodic compaction merges them; (3) **Trino 467's Iceberg writer is MoR-only regardless of the `write.delete.mode` property** per trinodb/trino#17272 (r13 §5589, r17 §583/§721) — so the property only governs **Spark**'s writer, which is exactly the engineer's situation. |

**Average: 2.75 — FAIL.**

**GREP — FINDABILITY ROOT CAUSE.** The CoW-vs-MoR comparison block at `resources/13-postgres-to-iceberg-ingestion.md` L2996-L3001:

```
L2996: "When CDC replays Postgres DELETE (and UPDATE) events as DELETE FROM / MERGE INTO against Iceberg,
        the table's delete write mode determines what actually lands on MinIO. Iceberg supports two
        modes, controlled by the table property write.delete.mode:"
L3000: | Merge-on-Read (MoR)  | write.delete.mode = 'merge-on-read'  | Writes small positional or
        equality delete files ... Fast (only the small delete file is written) ... High-delete-rate
        CDC streams; tables with frequent UPDATEs/DELETEs where you can run periodic compaction |
L3001: | Copy-on-Write (CoW)  | write.delete.mode = 'copy-on-write'  | Rewrites every affected Parquet
        data file without the deleted rows ... Slower (full file rewrite on every DELETE) ... Tables
        with infrequent deletes where read performance matters most |
```

The section header at L2996 is framed around **"CDC replays Postgres DELETE events"** — a Postgres-CDC-narrow framing. The Q1 engineer's keywords are "GDPR delete / purge user_id rows / 45-min Spark job / small frequent deletes / which delete mode is faster" — NONE of which point at "CDC replays Postgres DELETE." Keyword anchors `Merge-on-Read`/`Copy-on-Write`/`write.delete.mode` exist deeper in the table cells but the section-level keyword magnet is wrong-shaped for a GDPR-purge question.

The responder DID land on r17 §157 ("LEADING CANONICAL — bulk-purge OLD DAY-PARTITIONS for retention / GDPR: a partition-aligned DELETE is METADATA-ONLY") — which is why the partition-aligned-metadata fact came through correctly. But that section is **partition-aligned-only** and does NOT cover the non-partition delete-by-user_id case the engineer actually asked. So the responder gave the partition-aligned fact (correct but inapplicable here) + hedged on the by-user_id case it didn't find anchored content for.

**LIGHT FIX-A RECOMMENDED.** Add a short LEADING CANONICAL block (or strong keyword preamble) at r13 §2996 (or as a cross-ref card in r17 immediately after §157) that:

1. **Keyword anchors:** "small frequent deletes, GDPR purge by user_id, delete by non-partition column, frequent row-level deletes, which delete mode is faster, write.delete.mode merge-on-read vs copy-on-write, Spark rewriting whole table slow, MoR vs CoW for frequent deletes, why is my delete job slow."
2. **The two-sentence answer:** CoW rewrites the whole affected Parquet file per delete (= the slow 45-min Spark symptom); MoR writes small position-delete files (fast). For 10-50K rows × multiple times/day, **MoR is dramatically faster on writes**.
3. **The Trino-467-MoR-only caveat (load-bearing on this stack since both Trino AND Spark write):** `write.delete.mode` only governs **Spark's writer** — Trino 467's writer is MoR-only regardless of the property (cross-ref r13 §5589 / r17 §583/§721 / trinodb/trino#17272). So setting the property has no effect on Trino-driven deletes (already MoR) but **does flip Spark-driven deletes** (the engineer's bottleneck).
4. **Compaction-as-required-companion:** MoR shifts cost to readers, so schedule `EXECUTE optimize` (Trino) / `rewrite_position_delete_files` (Spark 469+ / Spark only currently) periodically.
5. **GDPR-on-disk caveat:** delete files / file rewrites both leave bytes referenced by prior snapshots — `expire_snapshots` is required for actual MinIO byte removal (cross-ref r13 §1281-§1324).

**Watch label:** `iter1219 Q1 CoW-vs-MoR small-frequent-delete findability`. Re-probe in 4-8 iters with fresh phrasing ("billing fact table getting hammered with row deletes for compliance — should I change my delete mode?" / "Spark MERGE INTO is rewriting too much — which write mode handles small deletes better?") to verify the FIX-A keyword anchors are reaching the responder.

---

### Q2 — WoW % change per customer with FULL OUTER JOIN, handling 0-prior-week + new-customer — **STRONG PASS (NO-OP)**

| Dim | Score | Note |
|---|---|---|
| Technical accuracy | 5 | FULL OUTER JOIN of `this_week`/`last_week` weekly-grouped CTEs + `COALESCE(t.customer_id, l.customer_id)` for the union of customer ids + nested CASE handling all three branches (NULL→NULL for new customer, 0→NULL for div-zero, else `ROUND(100.0*(this-last)/last, 1)`) is the textbook canonical. |
| Beginner clarity | 5 | Separating new-customer (`last_week_calls IS NULL`) from div-zero (`last_week_calls = 0`) as two distinct CASE branches both returning NULL is exactly the right teaching framing — the engineer asked about both edge cases and got them disambiguated explicitly. |
| Practical applicability | 5 | Copy-paste ready Trino 467; INTEGER/DECIMAL div-by-zero throws caveat is correct per `reference_trino_division_by_zero` (verified RAW git-tag, r27 §4.4H locked); `100.0` literal correctly forces double arithmetic to avoid integer-division truncation; week-of-year window correctly framed. |
| Completeness | 5 | Both edge cases handled cleanly; INT-div-by-zero-throws callout adds the "why guard explicitly" load-bearing reason. Minor non-load-bearing: cross-year week-of-year comparison fragility briefly mentioned but not fixed (use `date_trunc('week', ...)` or year+week composite key for production) — recall completeness only. |

**Average: 5.0 — STRONG PASS, NO-OP.** No imported-prior, no broken-secondary, no over-warning. Cites r07 (WoW pattern) + r27 §4.4H (div-by-zero guard).

---

### Q3 — dbt tag placement + `--select tag:billing` upstream-deps behavior — **STRONG PASS (NO-OP)**

| Dim | Score | Note |
|---|---|---|
| Technical accuracy | 5 | Tags can go in `schema.yml` `config:` block OR inline `{{ config(tags=['billing']) }}` — both verified at [docs.getdbt.com/reference/resource-configs/tags](https://docs.getdbt.com/reference/resource-configs/tags). `dbt run --select tag:billing` selects ONLY tagged nodes (NOT upstream parents) — verified WebSearch above + [docs.getdbt.com/reference/node-selection/graph-operators](https://docs.getdbt.com/reference/node-selection/graph-operators). `+tag:billing` for ancestors (upstream parents). Space = UNION/OR, comma = INTERSECTION/AND — verified r27 §3722-§3734 + [docs.getdbt.com/reference/node-selection/set-operators](https://docs.getdbt.com/reference/node-selection/set-operators). |
| Beginner clarity | 5 | Engineer with 180-model project + 50-min CI gets a precise unambiguous answer: where to add the tag (two locations), what command runs (just the tagged ones), how to expand selection (leading `+`). |
| Practical applicability | 5 | Engineer pastes `tags: ['billing']` into `schema.yml` `config:`, runs `dbt run --select tag:billing`, and gets a billing-only hotfix run. If they need parent staging models too, `--select +tag:billing`. Direct CI cut from 50min → seconds. |
| Completeness | 4.5 | Could mention tags can also be set in `dbt_project.yml` under the `models:` block (less common for ad-hoc hotfix tagging, but exists for project-wide subtree tagging). Minor recall-completeness only, non-load-bearing for the engineer's question. |

**Average: 4.875 — STRONG PASS, NO-OP.** No imported-prior, no broken-secondary. Cites r27 §6.7F (set-operators).

---

### Q4 — Oracle `LPAD(invoice_number, 8, '0')` → Trino, CAST gotchas — **PASS (RECALL-CEILING, NO FIX-A)**

| Dim | Score | Note |
|---|---|---|
| Technical accuracy | 4 | `LPAD(CAST(invoice_number AS VARCHAR), 8, '0')` is correct and matches r23 §734 canonical verbatim. Trino does not implicitly coerce numbers to VARCHAR in function args — correct per r23 §714. "Don't double-cast via integer" is correct guard. **BUT** the reassurance **"if invoice_number is NUMERIC/DECIMAL the CAST to VARCHAR ... no decimals for whole numbers"** is incomplete/wrong for a DECIMAL column with non-zero scale: `CAST(CAST(12345 AS DECIMAL(10,2)) AS VARCHAR) = '12345.00'` (Trino preserves DECIMAL scale on the VARCHAR form). For Oracle NUMBER → Iceberg migration, NUMBER often becomes DECIMAL(p,s) with s≥0 — if s>0 the cast WILL include `.00` and break the 8-char pad. Safe form for a DECIMAL column: `LPAD(CAST(CAST(invoice_number AS BIGINT) AS VARCHAR), 8, '0')` (intermediate BIGINT strips the scale). |
| Beginner clarity | 4 | Clear on the base form. Missing hazard callouts (see Completeness). |
| Practical applicability | 3 | Engineer pastes the form, it works for **today's** data, then silently breaks when (a) `invoice_number` grows past 8 digits — `LPAD('123456789', 8, '0') = '12345678'` silently drops the trailing `9` — a real data-integrity hazard r23 §721-728 explicitly warns about — or (b) the column is DECIMAL(p,s) with s>0 and the `.00` shows up unexpectedly. |
| Completeness | 2 | **Two key omissions on a documented topic:** (1) `format('%08d', invoice_number)` — r23 §739-742 explicitly says **"Prefer this over lpad(CAST(order_id AS VARCHAR), 8, '0') whenever the id may exceed the pad width"** because `%08d` is a MINIMUM field width (Java Formatter) so a 9-digit number prints in full and is NEVER truncated. Engineer with an invoice_number column that will eventually exceed 8 digits gets this canonical zero-pad-without-truncation-hazard. (2) The **truncation hazard** itself — `lpad(x, N, '0')` pads-OR-truncates to EXACTLY N; r23 §721-728 has a READ-FIRST callout on this. |

**Average: 3.25 — PASS (borderline), RECALL-CEILING, NO FIX-A.**

**GREP — RESOURCE IS ALREADY MAXIMALLY DEFENDED.** `resources/23-sql-best-practices-olap.md` §716-758 has the SUB-CANONICAL block:

- L716 use-cases line lists keyword anchors: *"pad a string to a fixed width, build a fixed-width flat-file export, right-pad with spaces, left-pad, pad to N characters, **truncate if longer**, **zero-pad an id**, align text in a fixed field, ... **zero-pad order_id to 8 chars**"*
- L720-728 **READ FIRST** callout: `lpad/rpad pad OR TRUNCATE to EXACTLY size characters` with worked example `lpad('123456789', 8, '0') -> '12345678' (drops the trailing '9')` + FIX directive "use `format('%08d', n)` (below) which zero-pads a number AND prints a wider number IN FULL (never truncates)."
- L739-742 LEADING-CANONICAL block for `format('%08d', order_id)` with explicit "Prefer this over lpad(CAST(order_id AS VARCHAR), 8, '0') whenever the id may exceed the pad width."
- L751 paragraph repeats the truncation-hazard message + ID-column-specific warning.
- L758 cross-ref to r27 §7A.3.1 for Oracle LPAD migration angle.

The keyword anchors at L716/L718 explicitly include "zero-pad an id, truncation hazard, fixed-width truncation hazard, lpad(CAST ...)" — these should magnetize an Oracle-LPAD-on-invoice_number question. The responder DID land on the section (correct base form `LPAD(CAST(... AS VARCHAR), 8, '0')`) but did NOT surface the `format('%08d', ...)` SUB-CANONICAL alternative or the truncation-hazard callout sitting 5-15 lines away. This is a **Haiku recall-ceiling on a SUB-CANONICAL** (LEADING canonical lifted; co-located SUB-CANONICAL alternative not lifted). Per pinned `feedback_synthesis_ceiling_stop_churning.md` and `feedback_new_card_over_attracts_adjacent.md` (risk of over-attracting adjacent neighbors with more defang on already-dense anchors) — **NO FIX-A**, accept the recall ceiling.

The "no decimals for whole numbers" reassurance is the kind of casual over-confident reassurance the responder appends when it doesn't fully verify — non-resource-sourced, base-training filler. Common case (BIGINT/INTEGER `invoice_number`) is unaffected; DECIMAL(p, s>0) case silently breaks. Per `feedback_responder_broken_secondary_alternative.md` family (9th-ish instance — nails the LEAD, appends a slightly-wrong reassurance/secondary). No resource fix.

**Watch label:** `iter1219 Q4 lpad-CAST format-%08d-missed + DECIMAL-scale-decimals-reassurance`. Re-probe in 5-9 iters under fresh phrasing ("padding part_number that could grow to 10 digits" / "Oracle NUMBER → Trino with non-zero scale gotcha") to verify ceiling.

---

## Topic average updates

| Topic | Prior | Q | Δ | New | Status |
|---|---|---|---|---|---|
| Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup | 4.4475/222 | Q1=2.75 | -0.0076 | **4.4399/223** | PASSED, margin +0.9399 |
| Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL | 4.5465/156 | Q2=5.0 | +0.0029 | **4.5494/157** | PASSED, margin +1.0494 |
| Improving complex SQL performance on Trino with dbt | 4.5407/47 | Q3=4.875 | +0.0069 | **4.5476/48** | PASSED, margin +1.0476 |
| Oracle PL/SQL procedure → dbt + Trino SQL migration | 4.4563/182 | Q4=3.25 | -0.0066 | **4.4497/183** | PASSED, margin +0.9497 |

All required topics REMAIN PASSED. Iter1219 overall average: (2.75 + 5.0 + 4.875 + 3.25) / 4 = **3.97 PASS**.

---

## Carry-forward watches

| Iter | Watch | Status |
|---|---|---|
| 1219 (NEW) | **Q1 CoW-vs-MoR small-frequent-delete findability** — r13 §2996 keyword-anchor LIGHT FIX-A to magnetize "GDPR delete / small frequent deletes / which delete mode is faster" to the comparison table | OPEN — re-probe 4-8 iters with fresh phrasing |
| 1219 (NEW) | **Q4 `lpad(CAST...)` SUB-CANONICAL recall + DECIMAL-decimals reassurance** — Haiku misses co-located `format('%08d', ...)` SUB-CANONICAL + truncation-hazard callout despite dense keyword anchors; recall-ceiling, NO FIX-A | OPEN soft-watch — re-probe 5-9 iters |
| 1218 | `accepted_values` NULL-trap caveat — FIX-A added to r28 §242 + r27 §3006 | Re-probe 4-8 iters under "column-allows-NULL / one-test-for-both" framing |
| 1215 | `strpos` 3-arg assumed-absence base-prior — accept-ceiling per iter1211 pre-commitment, no further defang | Re-probe 6-10 iters with fresh phrasing |
| 1213 | session_properties + `(+)`-mnemonic | Re-probe 4-7 iters |
| 1206 | LIKE-on-ROW + `$partitions` | Re-probe 3-7 iters |

---

## Status

All required topics PASSED with healthy margins. The Q1 hedge is a clear findability defect on a load-bearing question; LIGHT FIX-A warranted to add keyword anchors at r13 §2996 (and/or a cross-ref card in r17 between §157 partition-aligned and §583 Trino-writer-MoR-only). Other three answers ranged from clean STRONG PASS (Q2/Q3) to borderline-PASS recall-ceiling (Q4). No new resource-defect family. Iter1220 next: BREADTH (probe other topics, re-probe Q1 CoW-vs-MoR after FIX-A under fresh phrasing).

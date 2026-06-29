# Judge Feedback — Iteration 1283

**Overall**: 4 questions, average **3.16 FAIL** (Q1 1.75 FAIL / Q2 4.75 STRONG PASS / Q3 3.50 PASS-borderline / Q4 2.625 FAIL).

**Headline**: TWO failing answers + one borderline. **Q1 perf-triage re-probe is the 2nd CONSECUTIVE NON-REACH** of the recipe at r18 §404 / r16 §295 (iter1282 partial reach with wrong no-bytes myth → iter1283 FULL HEDGE / "this appears to be a gap"); the iter1282 r05 §3833 reconcile DID land at r05, but the responder now never gets there — it lands at r18 L127 instead and bails. **Q4 reproduces a verbatim banned myth** at r27 L995 ("Trino strpos is 2-arg only / has no n-th-occurrence form") despite that exact phrasing being defanged on the keyword path. **Q3 silently skips the dbt-trino non-support caveat** for `hard_deletes` (the production-stack-critical gotcha that r09 §478 already teaches).

| Q | Topic | Score | Status | Verdict |
|---|---|---|---|---|
| Q1 | Perf-triage RE-PROBE | **1.75** | **FAIL** | iter1281+iter1282 perf-triage FIX-As **2ND CONSECUTIVE NON-REACH** — different failure mode (full hedge, L127 mis-land); 2-part FIX-A required at r18 |
| Q2 | Iceberg metadata tables for small files | **4.75** | STRONG PASS | All metadata tables + columns + whole-token quoting rule correct |
| Q3 | dbt snapshots SCD2 | **3.50** | PASS-borderline | dbt-trino non-support caveat for `hard_deletes` silently dropped — accuracy ding, not a resource defect (r09 §478 teaches it) |
| Q4 | Oracle INSTR → Trino | **2.625** | **FAIL** | Reproduced verbatim the r27 L995 banned myth on `strpos` 3-arg form; built a needless CASE/strpos/substr workaround |

---

## Q1 — Perf-triage: top queries by CPU + bytes from `system.runtime.*` (HARD watch iter1282-Q1 RE-PROBE)

**Score: 1.75** (Acc 1.5 / Clar 3.0 / Prac 1.0 / Compl 1.5) — **FAIL**

### What the responder said

- Hedged: *"resources mention system.runtime.queries but don't provide complete documentation of which columns exist... specific columns for CPU time and bytes scanned are not documented in the available resources. This appears to be a gap."*
- Cited **r18 "line 127"** as evidence — noted L127 "warns against invented columns but doesn't enumerate the actual schema."
- Did NOT produce the `system.runtime.queries` JOIN `system.runtime.tasks` recipe.
- Did NOT mention `physical_input_bytes` or `split_cpu_time_ms` at all.

### Confirmation of the 2nd consecutive non-reach + diagnosis

**(1) 2nd CONSECUTIVE NON-REACH confirmed.** iter1281 hedged + pivoted to EXPLAIN ANALYZE. iter1282 routed to r05 §3833 and lifted the no-bytes myth. iter1283 fully hedges + cites L127. The recipe at r18 §404 / r16 §295 has NEVER been reached on the perf-triage framing across three consecutive probes, despite:
- iter1281 anchor FIX-A at r18 §404 + r16 §295 read-this-first keyword block (verified: L406 — "cluster sluggish", "hammering", "what's running", "most-data-read", "find the heavy queries").
- iter1282 r05 §3833 reconcile (verified: now distinguishes admin perf-triage tasks-JOIN vs durable chargeback event-listener + DO-NOT-WRITE defang of the no-bytes-column myth).

**(2) AFFIRMATIVE-TOO-DEEP confirmed.** Grepped r18 structure:
- §404 header (line 404): "Finding expensive queries on Trino 467 (verified SQL recipes)"
- L406: READ-THIS-FIRST anchor block with all the perf-triage keywords (iter1281 FIX-A — present, correct)
- §410 (line 410): "The two source tables (Trino 467 schema)" — column reference begins
- L412-444: `system.runtime.queries` column reference + caveats ("no `catalog`, no `schema`, no `peak_memory_bytes` columns exist here")
- L446-456: `system.runtime.tasks` column reference (where `physical_input_bytes` + `split_cpu_time_ms` are listed)
- L458: Recipe 1 — Top 50 most expensive queries (the canonical JOIN recipe SQL with `SUM(t.physical_input_bytes)` + `SUM(t.split_cpu_time_ms)`)

The Recipe SQL at L458 is **~54 lines below the §404 anchor at L406**. Between them is the column-reference block (L410-456) which itself repeats the "no peak_memory_bytes" defang. A top-down responder hitting §404's anchor reads L410+ → sees "no `catalog`, no `peak_memory_bytes`" → confuses "specific banned columns don't exist" with "schema isn't enumerated here" → bails. **The Recipe is structurally too deep.**

**(3) LAND-POINT MISS confirmed (r18 L127).** Grepped r18 around L127:
- L127 is inside §44 "LEADING CANONICAL ONCALL WORKED EXAMPLE" → DO-NOT-WRITE banned-forms block (L123-136).
- L127 verbatim: *"`SELECT * FROM system.runtime.queries WHERE catalog = 'iceberg' ORDER BY peak_memory_bytes DESC` | The `catalog` column does NOT exist on `system.runtime.queries` ... The `peak_memory_bytes` column does NOT exist there either. Both are confidently-invented column names."*

The Q1 keywords (`system.runtime`, `system tables`, `ORDER BY`, "which queries consumed most CPU + scanned most bytes") match L127 — a query template with `ORDER BY peak_memory_bytes DESC` in a DO-NOT-WRITE row. The responder hit L127 first (§44 is much earlier in the file than §404), read the defang as "no schema is documented", and never reached §404. **The responder's own cite to "line 127" makes this diagnosis a direct lift-from-trace, not a guess.**

### VERIFY: recipe is correct Trino 467

- `system.runtime.tasks.physical_input_bytes` — added Trino release 330 per [trino.io/docs/current/release/release-330.html](https://trino.io/docs/current/release/release-330.html); present in r18 L449 column list; iter1141 pin validated.
- `system.runtime.tasks.split_cpu_time_ms` — present in r18 L449; CPU time canonical (NOT `cpu_time_ms`, NOT `analysis_time_ms`).
- JOIN key `q.query_id = t.query_id` — verified at [trino.io/docs/current/connector/system.html](https://trino.io/docs/current/connector/system.html) and r18 L470, r16 §295.
- The recipe SQL is correct Trino 467, validated. Responder's hedge is wrong about the resource state, not wrong about the underlying technology.

### Recommended 2-part FIX-A (BOTH light; confirms judge's hypothesis spec)

**Both edits land at r18; r05 §3833 reconcile from iter1282 is healthy (Grep confirmed: now points to r18 §404 / r16 §295) but the responder isn't reaching r05 either now — it's bailing earlier at L127.**

**Part 1 — AFFIRMATIVE-FIRST recipe hoist (r18 §404, insert at ~L407, AFTER the L406 anchor and BEFORE §410's column reference).**

Place a 12-line copy-pasteable SQL recipe RIGHT AFTER the read-this-first anchor (L406) so the responder gets the working SQL before wading into the column-reference + caveats block:

```sql
-- TOP CANONICAL — the per-query CPU + bytes-scanned recipe for the last ~15 minutes.
-- This IS the answer to "which queries are hammering the cluster" / "scanned the most bytes" / "burned the most CPU".
-- The schema notes that follow are reference material; the recipe IS the answer.
SELECT
  q.query_id,
  q."user",                                  -- "user" is reserved; double-quote required
  SUM(t.physical_input_bytes) / 1e9       AS gb_scanned,
  SUM(t.split_cpu_time_ms)    / 1000.0    AS cpu_seconds,
  q.query
FROM system.runtime.queries q
JOIN system.runtime.tasks   t  ON t.query_id = q.query_id
WHERE q.state = 'RUNNING'      -- or q.state IN ('RUNNING','FINISHED') for last ~15 min
GROUP BY q.query_id, q."user", q.query
ORDER BY gb_scanned DESC
LIMIT 20;
```

Followed by one line: *"For the schema details and additional recipes (frequency-weighted, kill commands), see the rest of this section."*

This way the responder that stops at the first SQL block they see still ships the right answer.

**Part 2 — LAND-POINT pointer at r18 L127 (the DO-NOT-WRITE myth row).**

Append to the L127 row's "The right answer" column (after the existing "For peak memory, scrape JMX MBeans... or the persisted event-listener `QueryCompletedEvent`."):

> **For the actual per-query CPU + bytes-scanned recipe (the question this banned form was trying to answer), see [this resource §"Finding expensive queries on Trino 467"](#finding-expensive-queries-on-trino-467-verified-sql-recipes) below — JOIN `system.runtime.queries q` to `system.runtime.tasks t ON q.query_id = t.query_id`, then SUM `t.physical_input_bytes` + `t.split_cpu_time_ms` per query.**

This catches the responder who lands at L127 and currently bails. Both edits are surgical (no new section, no keyword-magnet new card per `feedback_new_card_over_attracts_adjacent.md`).

### Optional Part 3 — secondary defang at L442

The "no `peak_memory_bytes` columns exist here" sentence at L442 is repeating itself; consider tightening to make it visually distinct from the "no schema documented" misread the responder is having. Lower priority.

### NEW HARD WATCH `iter1283-Q1 perf-triage 3rd-non-reach + L127 mis-land`

Re-probe within 2-3 iters under perf-triage framings (with AND without tenant keywords). After the 2-part FIX-A, responder should produce the JOIN recipe. **If hedge recurs after the affirmative-first recipe hoist, escalate to a top-of-file callout or duplicate the recipe block into the LEADING CANONICAL ONCALL TRIAGE section at §44 itself.** The pattern is a 3rd consecutive recall failure on a recipe that demonstrably exists and has been anchored twice; if the affirmative-first hoist doesn't close it, the recall-ceiling case must be considered (per `feedback_synthesis_ceiling_stop_churning.md`).

---

## Q2 — Iceberg metadata tables for small files (streaming 30s micro-batches)

**Score: 4.75** (Acc 4.75 / Clar 4.5 / Prac 5.0 / Compl 4.75) — STRONG PASS

### What the responder said

- `"events$files"` whole-token single-quote-pair quoting; split-pair `events."$files"` is a parse error.
- `$files` columns: `file_path`, `file_size_in_bytes`, `record_count`, `partition`; sort `ORDER BY file_size_in_bytes ASC` to find smallest files.
- `$partitions` columns: `partition`, `record_count`, `file_count`, `total_size`; useful for "worst partitions" view.
- `$history` columns: `made_current_at`, `snapshot_id`, `parent_id`, `is_current_ancestor`; snapshot lineage.

### Verification

- WebFetch of [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) confirmed:
  - `$files` columns include `content`, `file_path`, `file_format`, `spec_id`, `partition`, `record_count`, `file_size_in_bytes`, `column_sizes`, `value_counts`, `null_value_counts`, `nan_value_counts`, `lower_bounds`, `upper_bounds`, `key_metadata`, `split_offsets`, `equality_ids`, `sort_order_id`, `readable_metrics` — responder's subset matches.
  - `$partitions` columns: `partition`, `record_count`, `file_count`, `total_size`, `data` — responder's subset matches.
  - `$history` columns: `made_current_at`, `snapshot_id`, `parent_id`, `is_current_ancestor` — exact match.
  - Whole-token quoting: docs show `"test_table$files"` (one quote pair around the whole token) verbatim.
- Minor Compl shave (-0.25): no `content = 0` data-files-only filter (delete files inflate the small-files count for MoR tables); no `EXECUTE optimize(file_size_threshold => '256MB')` remediation cross-ref. Neither load-bearing for "how to inspect"; not docked further.

**No FIX-A. Clean reach to canonical canonical at r17 metadata-tables section.**

---

## Q3 — dbt snapshots SCD2 on customers (plan_tier / email / account manager evolution)

**Score: 3.50** (Acc 3.0 / Clar 4.5 / Prac 3.0 / Compl 3.5) — PASS-borderline

### What the responder said

- Snapshot = SCD2; `snapshots/customers_snapshot.sql` with `{% snapshot %}` block.
- `config(target_schema, unique_key='id', strategy='timestamp', updated_at='updated_at')`.
- Result columns: `dbt_scd_id`, `dbt_updated_at`, `dbt_valid_from`, `dbt_valid_to` (NULL = current).
- As-of-date query: `WHERE dbt_valid_from <= D AND (dbt_valid_to IS NULL OR dbt_valid_to > D)` — correct.
- `strategy='check'` alternative with `check_cols=[...]` for sources without a reliable updated_at.
- **THE PROBLEM**: *"Snapshots automatically handle source row deletions via the `hard_deletes` config (records deletion as a new version row with `dbt_is_deleted='True'` when set to 'new_record')."*

### Verification: hard_deletes IS unsupported on dbt-trino

VERIFIED via WebFetch of [docs.getdbt.com/reference/resource-configs/hard-deletes](https://docs.getdbt.com/reference/resource-configs/hard-deletes) and WebSearch this iter:

- Supported adapters listed: **dbt-postgres, dbt-bigquery, dbt-snowflake, dbt-redshift** — only these four.
- **dbt-trino is NOT on the list.** dbt-trino CHANGELOG (v1.10.2) doesn't mention `hard_deletes` either.

The production stack is dbt-trino. An engineer who sets `hard_deletes='new_record'` on a dbt-trino snapshot will get silent-no-op or compile error — **the responder's recommendation will silently not work** on the production stack.

### Is this a resource defect?

**No — r09 §478 already teaches the caveat (verified via Grep):** `resources/09-lakehouse-schema-design.md` L478 has a verbatim ADAPTER-SUPPORT CAVEAT block:

> *"ADAPTER-SUPPORT CAVEAT — verify on dbt-trino BEFORE relying on this (THIS stack). dbt's `hard_deletes` (and the legacy `invalidate_hard_deletes`) is adapter-implemented, and dbt's docs enumerate support for dbt-postgres / dbt-bigquery / dbt-snowflake / dbt-redshift only — dbt-trino is NOT on that list..."*

Plus the reconciliation fallback macro and the smoke-test instruction. The caveat is on the keyword path (right before the three-value `hard_deletes` table). This same content reached cleanly at iter1265 + iter1267 RE-PROBES (both STRONG PASS with the caveat surfaced verbatim).

This is a **per-instance responder recall slip** on a corner of the snapshot answer that's secondary to the main question (the engineer asked about plan_tier change tracking; deletions weren't the question — the responder volunteered the `hard_deletes` mention as a "for completeness" alternative without surfacing its dbt-trino unsupport).

Pattern matches `feedback_responder_broken_secondary_alternative.md`: leads pass, but the appended secondary alternative ("snapshots also handle hard deletes via X") drops the production-critical caveat. The core question (timestamp strategy + SCD2 columns + as-of query) is clean.

### Recommended action

**NO FIX-A this iter.** Caveat is already in r09 §478 and on the keyword path. Per `feedback_responder_broken_secondary_alternative.md` family + `feedback_synthesis_ceiling_stop_churning.md`, scope as per-instance responder slip on a volunteered secondary point, not a resource defect.

### NEW SOFT WATCH `iter1283-Q3 hard_deletes-as-volunteered-secondary-without-dbt-trino-caveat`

Re-probe under "set up a customers snapshot / customer SCD2 / snapshots end-to-end" framings (where deletions are NOT the primary ask but the responder might volunteer hard_deletes). If 2+ recurrences with the caveat dropped under DIFFERENT framings, escalate to a LIGHT in-place reinforce of r09 §478 (anchor the caveat into the same paragraph that introduces `hard_deletes='new_record'` so they can't be lifted separately).

---

## Q4 — Oracle INSTR → Trino, including `INSTR(tags, ',', 1, 2)` 2nd-comma form

**Score: 2.625** (Acc 1.5 / Clar 4.0 / Prac 2.0 / Compl 3.0) — **FAIL**

### What the responder said

- 2-arg: `INSTR(email, '@')` → `strpos(email, '@')` — correct; 1-based, 0 if not found.
- Also mentioned `position(sub IN string)` — correct alternative form.
- **THE PROBLEM**: *"For `INSTR(tags, ',', 1, 2)` (find the 2nd comma), Trino doesn't have the occurrence-counting overload, so you need a different approach"* — then built a convoluted CASE / strpos / substr workaround.

### VERIFIED: Trino 467 HAS the 3-arg `strpos(s, sub, n)` form

WebFetch of [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html) confirmed verbatim:

> *"Returns the position of the N-th `instance` of `substring` in `string`. When `instance` is a negative number the search will start from the end of `string`. Positions start with `1`. If not found, `0` is returned."*

So `strpos('a.b.c.d', '.', 2)` → `4` (2nd dot), `strpos('a,b,c', ',', 2)` → `4` (2nd comma). Direct 1:1 port of Oracle `INSTR(s, sub, 1, n)` (with the same 1-based + 0-if-not-found semantics).

The responder's claim "Trino doesn't have the occurrence-counting overload" is **factually wrong against Trino 467 docs**.

### This IS the verbatim banned myth at r27 L995

Grepped r27 L994-995 verbatim:

> *"`INSTR(s, sub, 1, n)` (position of the **n-th occurrence**) | `strpos(s, sub, n)` — the **3-arg form** | Trino `strpos` HAS a 3-arg form: `strpos(string, substring, instance) -> bigint` returns the position (1-indexed) of the N-th instance of substring... **DO NOT WRITE** \"Trino strpos is 2-arg only / has no n-th-occurrence form\" — that is a **base-training myth**; the 3-arg form exists. Keyword anchors: **position of the second occurrence, nth occurrence of a character Trino, find the 2nd/3rd instance**, position of last occurrence, find n-th delimiter position."*

The responder's *"Trino doesn't have the occurrence-counting overload"* is a paraphrase of the EXACT banned form *"Trino strpos is 2-arg only / has no n-th-occurrence form"*. Same myth, same effect — the responder regenerated it from base training despite the keyword-anchored DO-NOT-WRITE defang sitting on the keyword path ("position of the second occurrence", "find the 2nd/3rd instance" — both Q4 keywords).

### Is this a resource defect?

**No — the defang at r27 L995 is maximally strong** (correct 3-arg signature + verbatim DO-NOT-WRITE + 5 keyword anchors directly matching the Q4 phrasing + worked example `strpos('a.b.c.d', '.', 2)` → 4 which is structurally identical to the Q4 `strpos(tags, ',', 2)`). Adding more defang to L995 risks dilution.

Pattern: this is **another instance of a base-training-myth regeneration on already-defanged + maximally-keyword-anchored content** — same shape as iter954 to_char wrong codes, iter1019 TABLESAMPLE-after-WHERE, iter1020 regexp_extract-comma. These appear sporadically as Haiku recall variance even when the resource is bulletproof. Per `feedback_responder_broken_secondary_alternative.md` family + `feedback_synthesis_ceiling_stop_churning.md`, treat as **per-instance responder slip with no resource fix** — recall ceiling, not findability gap.

### Recommended action

**NO FIX-A.** Re-probe to confirm this is a one-off slip vs a recurring drift. The defang is keyword-anchored AND has the worked example AND the DO-NOT-WRITE — adding more would just churn.

### NEW SOFT WATCH `iter1283-Q4 strpos-3-arg-banned-myth recurrence`

Re-probe within 3-5 iters under "Oracle INSTR 4-arg / n-th occurrence" / "find the 2nd / 3rd comma in CSV string" / "position of nth delimiter" framings. If responder regenerates "no occurrence-counting overload" again, treat as recall ceiling (NOT a resource gap — the defang is already strong; further churning hurts more than helps).

---

## Cross-cutting patterns this iteration

### Pattern A — perf-triage recipe is NOT REACHING under 3 consecutive different routing FIX-As (Q1)

Three iters, three different failure modes on the same canonical recipe (r18 §404 / r16 §295 JOIN recipe):

| Iter | Failure mode | Land-point | Fix attempted |
|---|---|---|---|
| 1281 | Hedge + pivot to EXPLAIN ANALYZE | (none — no clear cite) | Anchor block at r18 §404 + r16 §295 (keyword-rich read-this-first) |
| 1282 | Mis-route to r05 §3833 + lift no-bytes myth verbatim | r05 §3833 | r05 §3833 reconcile → distinguishes admin perf-triage tasks-JOIN vs durable chargeback event-listener + DO-NOT-WRITE defang |
| **1283** | **Full hedge + cite L127 myth row as "no schema enumerated"** | **r18 L127 (DO-NOT-WRITE in §44 FIRST 60 SECONDS)** | **(not yet) — recommended 2-part: affirmative-first recipe hoist at §404 L407 + L127 land-point pointer** |

The pattern is: every FIX-A successfully closes ONE land-point, but the responder finds a NEW upstream land-point that ALSO has a "no [columns]" framing nearby and bails before reaching the recipe. The structural fix is to put the affirmative recipe BEFORE the negative-framing column reference, so the responder doesn't have to wade through "no X column" content to reach the working SQL. Recommended 2-part FIX-A spec is in Q1 above.

If the iter1283 affirmative-first hoist + L127 pointer also fail (4th non-reach), the next escalation is a top-of-file callout (above the §44 first-60-seconds section) or moving the recipe into §44 itself — accept that the §44 oncall section is the responder's home base and meet it where it lands.

### Pattern B — Responder volunteers caveat-bearing secondary alternative without the caveat (Q3, family with iter936 / iter954 / iter1013 / iter1019 / iter1020 etc.)

Per `feedback_responder_broken_secondary_alternative.md` + `feedback_responder_overwarning_folklore.md`. The lead answer is clean (timestamp strategy / SCD2 columns / as-of query); the volunteered secondary alternative (hard_deletes='new_record' for completeness) drops the dbt-trino non-support caveat. No resource fix; scope as per-instance.

### Pattern C — Base-training-myth regeneration on already-defanged + maximally-keyword-anchored content (Q4)

10th-ish instance in this family (after `starts_with`, `to_char`, `listagg`, `array_sum`, `format_number`, `migrate`, `LATERAL`, `truncate-2arg`, NVL2 etc.). The defang exists, sits on the keyword path, has worked examples + 5 anchor keywords matching the question; the responder still regenerates the myth.

Per `feedback_synthesis_ceiling_stop_churning.md` + `feedback_new_card_over_attracts_adjacent.md` — at some point this is Haiku recall ceiling, not a teachable gap. Re-probe; if 2+ recurrences with this specific defang, accept the per-instance cost.

---

## Topic scoring (rubric updates)

| Q | Topic row | Score | Δ |
|---|---|---|---|
| Q1 | Query performance regression diagnosis (line 369) | 1.75 | drops thinnest required row further |
| Q2 | Iceberg table maintenance (line 279) | 4.75 | +small |
| Q3 | dbt snapshots SCD2 (line 788) | 3.50 | -small |
| Q4 | Oracle PL/SQL → dbt + Trino migration (line 498) | 2.625 | -small |

All topics retain PASSED status (margins still positive after the dings), but Q1's row absorbs another sharp drop on a thin-history topic.

---

## Summary recommendations to teacher

1. **PRIORITY — r18 2-part FIX-A on perf-triage Q1 (this is the 3rd consecutive non-reach in a row).** Affirmative-first SQL recipe hoist at §404 L407 + land-point pointer at L127. Both surgical. Both spec'd above with verified Trino 467 syntax. DO NOT add a new section — additive new canonicals risk attracting adjacent neighbor questions per `feedback_new_card_over_attracts_adjacent.md`.
2. **Q2 — no action.** Clean reach.
3. **Q3 — no action.** Caveat is already at r09 §478 and on the keyword path; pattern is responder-recall-ceiling on a volunteered secondary alternative.
4. **Q4 — no action.** Defang at r27 L995 is maximally strong; this is recall ceiling. Re-probe under "2nd occurrence / nth comma" framings to track.
5. Add 3 new watches: `iter1283-Q1 perf-triage 3rd-non-reach + L127 mis-land` (HARD), `iter1283-Q3 hard_deletes-as-volunteered-secondary` (SOFT), `iter1283-Q4 strpos-3-arg-banned-myth recurrence` (SOFT).


# Iter 1264 — Judge Feedback

**Iter average: 4.5625 PASS** (above 3.5 threshold by +1.0625).
**Per-question:** Q1 4.875 / Q2 4.875 / Q3 3.5 / Q4 5.0.
**Pattern:** iter1263 r10 §487 NULL-partition FIX-A REACHED CLEANLY on Q1 first re-probe; **one LIGHT FIX-A recommended** on r09 §476 hard_deletes block to add a dbt-trino-adapter-support hedge (Q3 over-confident answer to an engineer who EXPLICITLY asked "be precise whether the native feature works on dbt-trino").

---

## Q1 — Iceberg `WHERE region IS NULL` pruning on identity-partitioned column [4.875]

**Dimensions:** Acc 5.0 / Clar 4.5 / Prac 5.0 / Compl 5.0

**Status:** iter1263 r10 §487 NULL-partition FIX-A **REACHED CLEANLY on first re-probe**. WATCH CLOSES.

The responder debunked the teammate's myth correctly and diagnosed the real cause:
- "Iceberg puts ALL rows with NULL into ONE dedicated partition; `identity(NULL)=NULL` is a single partition tuple"
- "`WHERE region IS NULL` DOES prune to the null partition (manifest `contains_null` flag, first-class prunable)"
- "Slow because of DATA SKEW (65% region=NULL = majority), not pruning failure — reading the null partition ≈ reading 65% of the table"
- Verification path: `SELECT partition, record_count FROM tbl$partitions` to confirm null partition holds the bulk
- Fixes: (a) sentinel `'free'` backfill + sub-partition by day, (b) add `day(occurred_at)` second transform so IS NULL still prunes by date, (c) `EXECUTE optimize` if small-files, (d) accept that count(*) over the majority IS a large scan

**Verified against:**
- [Apache Iceberg Table Spec](https://iceberg.apache.org/spec/) — manifest list `contains_null` partition summary field IS real; identity-transform NULL stored as nullable union in partition struct; `null_value_counts` per-column in data_file metrics; verified the spec supports the responder's mental model.
- r10 §487 NULL-values-on-a-partition-column canonical (iter1263 FIX-A) — responder cited it; the cross-ref to r18 §90 temporal-unwrap pruning is intact; the imported-prior Postgres/Oracle sargability defang IS in the canonical.

**Minor Clar shave (−0.5):** "skew" terminology assumed; a one-sentence "the null partition LEGITIMATELY contains most of the table because free-tier is the majority — pruning works but reading 65% of the table is inherently slow" would zero-assumption it. Not load-bearing.

**iter1263 Q1 NULL-partition-prune WATCH CLOSES.** Responder routed cleanly to the new r10 §487 canonical, debunked the teammate myth verbatim, diagnosed skew not pruning failure, gave four production-applicable fixes. No FIX-A.

---

## Q2 — Oracle SUM(CASE WHEN x='starter' THEN 1 ELSE 0 END) → Trino [4.875]

**Dimensions:** Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 4.5

The responder gave the correct cleanup:
- `SUM(CASE WHEN plan_type='starter' THEN 1 ELSE 0 END) AS starter_count` works in Trino 467 (cross-dialect compatible)
- Cleaner Trino native: `count_if(plan_type='starter') AS starter_count`
- Both one-pass, no self-join
- `count_if(x)→bigint` returns 0 when no matching rows (zero-group-safe)

**Verified against:**
- [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) `count_if()` signature: "Returns the number of TRUE input values. This function is equivalent to `count(CASE WHEN x THEN 1 END)`." Both NULL and FALSE are ignored. **Confirms responder's claim verbatim.**

**Minor Compl shave (−0.5):** could have surfaced `count(*) FILTER (WHERE plan_type='starter')` as a third equivalent Trino 467 form (SQL standard, also one-pass). Recall ceiling, not load-bearing.

No defect, no FIX-A. Clean Oracle→Trino canonical reach.

---

## Q3 — dbt snapshot timestamp strategy on Oracle customers / source HARD DELETE handling [3.5]

**Dimensions:** Acc 3.5 / Clar 4.5 / Prac 3.0 / Compl 3.0

**THE KEY VERIFY:** The engineer EXPLICITLY asked "be precise whether the native feature works on dbt-trino." The responder gave a confident **"YES native works"** WITHOUT addressing the dbt-trino adapter caveat.

**What's mechanically correct (factual accuracy partial credit):**
- `hard_deletes='new_record'` config replaces legacy `invalidate_hard_deletes=true` boolean in dbt 1.9+ — correct
- Three values: `ignore` (default), `invalidate` (closes validity window, no marker), `new_record` (inserts deleted-marker row with `dbt_is_deleted='True'`) — verified verbatim at [docs.getdbt.com/reference/resource-configs/hard-deletes](https://docs.getdbt.com/reference/resource-configs/hard-deletes)
- `dbt_is_deleted` is VARCHAR `'True'`/`'False'` not boolean — correct, verified at docs.getdbt.com
- Deletion timestamp = when dbt OBSERVED missing not exact Oracle DELETE time — correct (snapshot-cadence-limited)
- Pre-existing snapshot needs `--full-refresh` to add `dbt_is_deleted` column — correct

**What's missing — the dbt-trino adapter-support hedge the engineer literally asked for:**

Verified this iter via **[docs.getdbt.com/reference/resource-configs/hard-deletes](https://docs.getdbt.com/reference/resource-configs/hard-deletes)** (WebFetched) + **[dbt-trino CHANGELOG.md](https://github.com/starburstdata/dbt-trino/blob/master/CHANGELOG.md)** (WebFetched) + WebSearch on GitHub issues:

| Source | Verdict |
|---|---|
| docs.getdbt.com/reference/resource-configs/hard-deletes "Supported adapters" | Lists ONLY `dbt-postgres`, `dbt-bigquery`, `dbt-snowflake`, `dbt-redshift`. **dbt-trino is NOT in the list.** |
| dbt-trino CHANGELOG (Starburst, current v1.10.2) | **NO mention** of `hard_deletes`, `invalidate_hard_deletes`, or snapshot hard-delete support. |
| dbt-core issue #10235 (hard_deletes feature design), #11269 (bug check-strategy), #2819 (re-instate hard-deletes) | dbt-core issues; no dbt-trino-specific implementation issue/PR found. |

**Verdict on the responder's confidence: OVER-CONFIDENT.** On a production stack that is explicitly dbt-trino (per `prod_info.md` Transformation row), and on an engineer who explicitly asked for precision on dbt-trino, an unqualified "YES native works" is wrong by completeness/practical-applicability — the engineer will ship this into their dbt-trino setup and potentially hit a silent-no-op or compile-time error.

**The accurate answer must hedge:**
> "dbt 1.9+ adds the `hard_deletes='new_record' | 'invalidate' | 'ignore'` config natively, BUT the docs.getdbt.com supported-adapters list enumerates only dbt-postgres / dbt-bigquery / dbt-snowflake / dbt-redshift. **dbt-trino is NOT in the listed adapters**, and the dbt-trino CHANGELOG (current v1.10.2) does not mention adding hard_deletes support. So: run a smoke test on your dbt-trino version first; if the config is silently ignored or errors, fall back to a reconciliation model — anti-join `SELECT id FROM source` against `SELECT id FROM snapshot WHERE dbt_valid_to IS NULL` and stamp `deleted_at` on the missing ids."

**Resource-source check — RESOURCE DEFECT.** r09 §476 hard_deletes block (verified this iter, lines 476–514) covers the three-value table, the mechanics, the dbt 1.9+ requirement, the VARCHAR 'True'/'False' gotcha, and `--full-refresh` migration — but does **NOT** mention the dbt-trino adapter caveat. On a stack where dbt-trino is THE adapter, this is a load-bearing omission. The iter1260 judge flagged the same caveat as a "production-stack adapter-support nuance" but the iter1260 fix targeted r28/r27 incremental-routing findability (a different angle); r09's hard_deletes block was untouched.

**This is the SECOND occurrence of the same gap under DIFFERENT framing** (iter1260 was the "incremental can't catch source-hard-deletes / how" framing where the responder didn't reach hard_deletes at all; this iter is the "is hard_deletes native + precise on dbt-trino" framing where the responder reaches the feature but skips the caveat). **LIGHT FIX-A warranted.**

**RECOMMENDED LIGHT FIX-A — r09 §476 hard_deletes block:** Add a "dbt-trino adapter caveat" hedge note inside the existing canonical, BEFORE the three-value table:

> **dbt-trino adapter caveat — verify before relying.** The [docs.getdbt.com/reference/resource-configs/hard-deletes](https://docs.getdbt.com/reference/resource-configs/hard-deletes) "Supported adapters" section explicitly enumerates only **dbt-postgres / dbt-bigquery / dbt-snowflake / dbt-redshift** — **dbt-trino is not in the listed adapters**, and the [dbt-trino CHANGELOG](https://github.com/starburstdata/dbt-trino/blob/master/CHANGELOG.md) (as of v1.10.2) does not mention adding `hard_deletes` support. The legacy `invalidate_hard_deletes=true` boolean (dbt ≤1.8) may work via the default snapshot macro on dbt-trino, but is not guaranteed either. **On dbt-trino, run a smoke test on a tiny snapshot first** (drop a row from a 5-row source, run `dbt snapshot`, verify dbt_valid_to is stamped or a `dbt_is_deleted=True` row appears in the target). If the config is silently ignored or errors, **fall back to a reconciliation model**: anti-join `SELECT id FROM {{ source(...) }}` against `SELECT id FROM {{ ref('snap') }} WHERE dbt_valid_to IS NULL`, stamp `deleted_at = current_timestamp` on the missing IDs, and `UPDATE ... SET dbt_valid_to = deleted_at` (or insert a marker row mirroring the new_record shape).

Watch label to track: `iter1264 Q3 hard_deletes-dbt-trino-adapter-support-hedge r09 §476 LIGHT FIX-A` — re-probe under "hard_deletes precise dbt-trino" / "does invalidate work on dbt-trino" / "GDPR delete handling dbt-trino" framings 4–8 iters.

---

## Q4 — Oracle SUBSTR(product_code, 1, INSTR(product_code,'-')-1) → Trino [5.0]

**Dimensions:** Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 5.0

The responder nailed every load-bearing fact:
- `substr(product_code, 1, strpos(product_code,'-')-1)` works directly in arithmetic — correct
- `strpos` returns 0 if not found (same as INSTR) — verified at [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html) verbatim "If not found, `0` is returned."
- `substr` with length ≤ 0 returns EMPTY STRING `''` (safe, no error) — verified via raw [Trino 467 StringFunctions.java](https://raw.githubusercontent.com/trinodb/trino/467/core/trino-main/src/main/java/io/trino/operator/scalar/StringFunctions.java) source: `if (start == 0 || (length <= 0) || (utf8.length() == 0)) { return Slices.EMPTY_SLICE; }` — exact match
- `substr(NULL, ...)` returns NULL — correct
- Behavior table Oracle→Trino — clean
- `split_part(product_code,'-',1)` as a cleaner cross-ref idiom — correct (returns the full string when delimiter not found, no `-1` arithmetic needed); the cross-ref is the right secondary

Closes iter1257 Q4 strpos-arithmetic watch cleanly. No imported-prior slip, no broken-secondary, no over-warning. Clean 5.0.

---

## Topic score updates

| Topic | Before | This iter contribution | After |
|---|---|---|---|
| Iceberg partition design for SaaS: strategies, small-files, compaction | 4.3992 / 66 | Q1 = 4.875 | **4.4063 / 67 PASSED** (+0.0071, margin +0.9063) |
| Oracle PL/SQL procedure → dbt + Trino SQL migration | 4.4893 / 231 | Q2 = 4.875, Q4 = 5.0 | **4.4931 / 233 PASSED** (+0.0038, margin +0.9931) |
| dbt snapshots SCD2 | 4.2211 / 28 | Q3 = 3.5 | **4.1962 / 29 PASSED** (−0.0249, margin +0.6962, THINNEST near-bottom passing topic) |

All required topics REMAIN PASSED.

---

## Watch state

**CLOSES this iter:**
- `iter1263 Q1 Iceberg-NULL-partition-prune` — r10 §487 FIX-A REACHED CLEANLY on first re-probe; responder debunked the teammate myth verbatim + diagnosed skew + cited the canonical.
- `iter1257 Q4 strpos-arithmetic` — this iter's Q4 is the textbook strpos-arithmetic + substr-negative-length canonical reach, with split_part cross-ref as the cleaner secondary.

**NEW (this iter):**
- `iter1264 Q3 hard_deletes-dbt-trino-adapter-support-hedge r09 §476 LIGHT FIX-A` — re-probe 4–8 iters under "hard_deletes precise dbt-trino" / "does invalidate work on dbt-trino" / "GDPR delete handling dbt-trino" framings. If 2+ recurrences post-FIX-A under different framings, escalate to BOLD callout at the head of the r09 §476 block.

**Open watches (carry-forward):** iter1260 Q1 CDC-MERGE-multi-event-dedup; iter1258 Q3 SELECT-*-EXCEPT; iter1255 Q1 bloom-CREATE-syntax; iter1253 Q4 regexp_extract-2arg; iter1248 Q3 MATCH_RECOGNIZE-adjacency; iter1229 @v1-Spark; iter1230 EXISTS-overwarning; iter1215 strpos-3-arg CEILING.

---

## Recommendation

**1 LIGHT FIX-A this iter** — surgical reconcile of r09 §476 hard_deletes canonical to add the dbt-trino-adapter-support hedge (verbatim block proposed above; insert BEFORE the three-value table, after the engineer-facing keyword anchors).

Do NOT add another resource, do NOT touch the three-value mechanics table (which is correct), do NOT touch the `dbt_is_deleted` VARCHAR gotcha block (which is correct). Single hedge paragraph in the existing canonical, at the spot the responder reaches.

The fix is surgical, doesn't risk over-attracting adjacent SCD-2 questions (no keyword-magnet new card), reconciles in-place (per pinned `feedback_reconcile_dont_append.md`), and answers the specific dbt-trino caveat the engineer asked for + the prod_info.md stack mandates. Should close on first re-probe (historical 1st-re-probe-CLOSE rate ~27+ consecutive iters).

**Pattern observation:** the responder is now CONSISTENTLY reaching the right native dbt feature (hard_deletes) — that's the iter1260 improvement direction. The remaining gap is the **dbt-trino adapter-support caveat the engineer literally asked for**. That's a content gap in r09, not a recall ceiling or over-warning folklore.

**No broken-secondary, no fabrication, no imported-prior, no over-warning this iter.** Clean iter outside of the Q3 dbt-trino-caveat omission.

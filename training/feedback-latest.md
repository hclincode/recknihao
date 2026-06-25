# Judge Feedback — iter1101 (2026-06-26)

## Source verification

- **MinIO `mc ilm tier add` on bare-metal**: VERIFIED via docs.min.io/enterprise/aistor-object-store/administration/object-lifecycle-management/ + mc-ilm-rule-add reference + github.com/minio/minio/blob/master/docs/bucket/lifecycle/DESIGN.md. Bare-metal on-prem MinIO DOES support object-lifecycle tiering via `mc ilm tier add <TIER_TYPE> <ALIAS> <TIER_NAME>` + `mc ilm rule add --transition-days N --transition-tier <TIER_NAME>`. Transition trigger is OBJECT AGE (creation-date), NOT read-access. Transparent to Trino (same `s3a://...` path, cold-tier reads pay higher latency). r16 L499–621 (Mechanism A) is correct and matches docs.
- **dbt `hard_deletes` config**: VERIFIED via docs.getdbt.com/reference/resource-configs/hard-deletes. dbt 1.9+ accepts `hard_deletes='ignore'` (default) | `'invalidate'` (replaces legacy `invalidate_hard_deletes=true`, stamps `dbt_valid_to`) | `'new_record'` (inserts a row with `dbt_is_deleted='True'` meta column at deletion event). r09 L468–493 matrix is correct and matches docs.
- **Trino `ANALYZE` syntax**: VERIFIED via trino.io/docs/current/sql/analyze.html. Form is `ANALYZE table_name [WITH (...)]` — NO `TABLE` keyword (unlike Oracle `ANALYZE TABLE`). Optional `WITH (columns = ARRAY['col1','col2'])` scopes the column NDV collection. Stats written to Iceberg Puffin sidecar. Confirms Q4.
- **Trino window `PARTITION BY <expression>`**: VERIFIED via trino.io/docs/current/sql/select.html — window PARTITION BY accepts arbitrary expressions including `YEAR(col)`. (Only complex grouping CUBE/ROLLUP/GROUPING SETS is column-names-only per [Trino Complex Grouping Column-Names-Only] pin.) Confirms Q3.

---

## Per-question scoring

### Q1 — Storage tiering, access-recency framing (re-probe FIX-A #1)

**Question**: Can tiering key off read-access ("move files not read in 60 days")?

**Answer summary**: Correctly said NO read-access tiering (age-keyed only). BUT then claimed "MinIO bare-metal does not expose per-file access metrics… on-prem MinIO cannot tier", and recommended the "production-safe tiering strategy" is **partition-based retention with DELETION** (`DELETE FROM events WHERE created_at < now - INTERVAL '365' DAY`) or exporting to S3 Glacier offline. Did NOT mention `mc ilm tier add` / `mc ilm rule add --transition-days N --transition-tier` (Mechanism A) at all.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 2.0 | The age-vs-access framing reached (CORRECT). But the rest of the answer is source-contradicting: "on-prem MinIO cannot tier" is FALSE — MinIO bare-metal explicitly supports tiering via `mc ilm tier add` + `mc ilm rule add --transition-days N` per docs.min.io and per r16 L522–540 Mechanism A. The DELETE/Glacier-export recommendation is also stack-incompatible (Glacier is AWS-only; prod is on-prem). |
| Beginner clarity | 4.0 | Clear writing, but misleading by omission — engineer is given a confidently-wrong picture of the stack's capabilities. |
| Practical applicability | 2.0 | The recommended action — `DELETE FROM events WHERE created_at < ...` — DESTROYS the deep-history queryability the engineer explicitly needs. This is actively harmful guidance: the engineer wanted to keep old data queryable on cheaper storage; they were told to delete it. |
| Completeness | 2.0 | Missed Mechanism A (the canonical answer) entirely; missed Mechanism C (app-layer recent/archive split); missed `compression_codec=ZSTD` (Mechanism B). The negative-answer arrived but the positive substitute did not. |
| **Q1 average** | **2.5** | **FAIL** |

**FIX-A #1 verdict — PARTIAL REACH.** The new access-recency keyword anchors at r16 L501 + the capability-bound row "Access-aware tiering — NO" both DID reach the responder (it correctly denied access-aware tiering). BUT the affirmative positive substitute — Mechanism A age-based tiering with `mc ilm tier add` — was NOT surfaced. The responder collapsed "no access-aware tiering" → "no tiering at all" and bailed to DELETE. This is a NEW failure mode: the negative half of the FIX-A reached, the positive half did not.

---

### Q2 — dbt snapshot hard deletes (re-probe FIX-A #2)

**Question**: How to record physically-deleted source rows in a dbt snapshot.

**Answer summary**: Claimed "dbt snapshots DO NOT automatically detect hard deletes", "Neither strategy [timestamp or check] knows about deleted rows", recommended a manual LEFT JOIN pattern to stamp `dbt_valid_to`, and concluded "use a regular incremental model NOT a snapshot." Did NOT mention `hard_deletes='new_record'` / `invalidate_hard_deletes=true` / `dbt_is_deleted` at all.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 1.5 | Asserts the OPPOSITE of dbt docs. dbt 1.9+ has built-in `hard_deletes` config with three values (`'ignore'` / `'invalidate'` / `'new_record'`); `'new_record'` is the documented purpose-built mechanism for "record that a row was deleted and roughly when" (adds `dbt_is_deleted='True'` meta column). Legacy `invalidate_hard_deletes=true` exists on dbt ≤1.8. Responder's "snapshots can't do this, use a manual LEFT JOIN" is source-contradicting. |
| Beginner clarity | 4.0 | Clear writing; the wrong claim is asserted confidently which is dangerous for a beginner who can't fact-check. |
| Practical applicability | 2.0 | The recommended manual LEFT JOIN against a previous snapshot run + switch to incremental model is a substantial chunk of custom Jinja+SQL plumbing the engineer would have to write and maintain — when a ONE-LINE config (`hard_deletes='new_record'`) on their existing snapshot does it natively. |
| Completeness | 1.5 | Missed the entire `hard_deletes` API, missed `dbt_is_deleted` meta column, missed the legacy `invalidate_hard_deletes` for dbt ≤1.8, missed the `WHERE dbt_is_deleted='True'` query pattern, missed the cutover gotcha (full-refresh / ALTER ADD COLUMN). |
| **Q2 average** | **2.25** | **FAIL** |

**FIX-A #2 verdict — DID NOT REACH.** The r09 L354 keyword anchors include "hard delete", "hard deletes", "source row deleted", "invalidate_hard_deletes", "hard_deletes config", "hard_deletes new_record", "hard_deletes invalidate", "capture deletion timestamp in snapshot" — and the matrix at L468–493 documents the answer correctly. Yet the responder produced the exact opposite framing. Diagnosis: this is NOT a content gap (content is there) and arguably NOT pure findability either (the anchors include the engineer's phrasing). The likely root cause is **content-placement depth**: the hard-deletes matrix sits ~115 lines into the snapshot block (L468), AFTER the entire SCD2 meta-columns explanation, AFTER the strategy=timestamp/check sub-blocks, AFTER the unique_key alias trap. A keyword-driven responder that finds the snapshot block via "dbt snapshot" matches at L352 and may stop reading at the "strategy='timestamp' / 'check'" sub-blocks (L358, L378) — because those visually look like "the two answers", and the responder's prior says "snapshots only handle update-detection, not deletion-detection." The hard-deletes block is BURIED PAST the visual STOP point.

---

### Q3 — YTD running total reset each calendar year

**Answer summary**: `SUM(deal_amount) OVER (PARTITION BY sales_rep_id, YEAR(deal_closed_date) ORDER BY deal_closed_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`; explicit ROWS-not-RANGE frame justified by same-day tiebreaker.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | `PARTITION BY sales_rep_id, YEAR(date)` is valid Trino 467 (window PARTITION BY accepts expressions); resets at calendar-year boundary; `ROWS UNBOUNDED PRECEDING ... CURRENT ROW` is the canonical YTD frame; ROWS-vs-default-RANGE tiebreaker discussion is correct (default RANGE with same-day tiebreaks lumps all same-date rows into one window position). |
| Beginner clarity | 5.0 | Clear breakdown of the PARTITION-vs-ORDER-vs-frame three roles; tiebreaker aside is helpful without being noisy. |
| Practical applicability | 5.0 | Engineer can paste-and-run. |
| Completeness | 5.0 | Covers reset semantics, ordering, frame choice, and tiebreaker. |
| **Q3 average** | **5.00** | **PASS** |

---

### Q4 — Oracle DBMS_STATS → Trino

**Answer summary**: `ANALYZE schema.table` (NO `TABLE` keyword) + optional `WITH (columns = ARRAY['col1','col2'])` for scoped column NDV collection; produces a Puffin sidecar with NDV stats consumed by Trino CBO for join planning; stats DO NOT auto-update (re-run weekly or post-ingest); dbt post-hook or `run-operation` macro to automate; no partition-scoped ANALYZE on Iceberg.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Verified vs trino.io/docs/current/sql/analyze.html: form is `ANALYZE table_name [WITH (...)]` with no `TABLE` keyword — matches. `columns = ARRAY[...]` property verified. Puffin format for Iceberg stats verified vs iceberg.apache.org Puffin spec. "No partition-scoped ANALYZE on Iceberg" is correct (the WITH `partitions` property is Hive-only). |
| Beginner clarity | 5.0 | Migration framing (Oracle DBMS_STATS counterpart) helps the engineer mental-map. |
| Practical applicability | 5.0 | dbt post-hook / `run-operation` automation guidance is the right operational pattern; cadence guidance is concrete. |
| Completeness | 4.5 | Minor: didn't mention `EXPLAIN (TYPE DISTRIBUTED)` for join-plan verification post-ANALYZE, or `DROP STATS` via `EXECUTE drop_extended_stats` if stats become stale. Not a defect, edge incompleteness. |
| **Q4 average** | **4.875** | **PASS** |

---

## Iteration summary

| Q | Topic | Accuracy | Clarity | Applicability | Completeness | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | Storage tiering (FIX-A #1 re-probe) | 2.0 | 4.0 | 2.0 | 2.0 | **2.50** | FAIL |
| Q2 | dbt snapshots hard deletes (FIX-A #2 re-probe) | 1.5 | 4.0 | 2.0 | 1.5 | **2.25** | FAIL |
| Q3 | YTD running total | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** | PASS |
| Q4 | Oracle DBMS_STATS → Trino ANALYZE | 5.0 | 5.0 | 5.0 | 4.5 | **4.875** | PASS |

**Iteration average** = (2.50 + 2.25 + 5.00 + 4.875) / 4 = 14.625 / 4 = **3.656 PASS** (just over the 3.5 threshold, but pulled there by the two clean breadth Qs).

**Topic-row updates**:
- **Storage tiering** 3.75/4 → (15.0 + 2.5)/5 = **3.50/5 PASSED** (margin collapsed to threshold; ONE more sub-3.5 score pushes BELOW)
- **dbt snapshots SCD2** 4.2690/10 → (42.69 + 2.25)/11 = **4.0855/11 PASSED** (-0.184)
- **Analytical query patterns on Iceberg+Trino** 4.3785/49 → (214.5465 + 5.0)/50 = **4.391/50 PASSED** (+0.013)
- **Oracle PL/SQL migration** 4.4475/103 → (458.0925 + 4.875)/104 = **4.4516/104 PASSED** (+0.004)
- **Trino CBO / ANALYZE / Puffin** 4.6173/17 → (78.4941 + 4.875)/18 = **4.6316/18 PASSED** (+0.014)

All five topics REMAIN PASSED on paper. BUT **storage tiering at exactly 3.50/5 is now AT the threshold**, no margin — the row is structurally fragile; another below-3.5 storage-tiering answer drops the row below threshold.

No `::`/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/over-warning/broken-secondary/Spark-Oracle-spillover observed.

---

## Source-verified defects

1. **Q1 — Storage-tiering source contradiction.** Responder claimed "on-prem MinIO does not expose per-file access metrics … cannot tier", contradicting docs.min.io + r16 L522–540 (Mechanism A documents `mc ilm tier add` + `--transition-days N --transition-tier` for on-prem bare-metal MinIO). Recommended `DELETE FROM events WHERE created_at < now - INTERVAL '365' DAY` which (a) destroys the deep-history queryability the engineer explicitly needs and (b) ignores Mechanism A, which is the prod-stack canonical mechanism.

2. **Q2 — dbt-snapshots-hard-deletes source contradiction.** Responder claimed "dbt snapshots DO NOT automatically detect hard deletes" and "Neither strategy knows about deleted rows", contradicting docs.getdbt.com/reference/resource-configs/hard-deletes + r09 L468–493 (the `hard_deletes` config matrix). The exact requested capability — record that a row was deleted AND when — is precisely what `hard_deletes='new_record'` does (inserts a marker row with `dbt_is_deleted='True'` and `dbt_valid_from=<observed-deletion-time>`).

---

## FIX-A reach verdicts

- **FIX-A #1 (r16 storage-tiering access-recency anchors + capability-bound row + Mechanism A mc-ilm-tier-add)**: **PARTIAL REACH.** The negative half (no access-recency triggering) reached cleanly — the responder correctly denied access-aware tiering. The positive half (substitute is age-based via `mc ilm tier add` + `--transition-days N`) DID NOT reach — the responder collapsed "no access-aware tiering" → "no tiering at all on MinIO" → "DELETE old data". The Mechanism A block exists at r16 L522–540 but is BELOW the capability-bound table at L507–514; the access-recency row at L514 cleanly tells the responder "NO access-aware" but does not co-locate the affirmative "YES — age-based via mc ilm tier add as the substitute" answer in the same row. The responder reads the NO and stops, never reaching Mechanism A.
- **FIX-A #2 (r09 hard_deletes anchor list + hard_deletes value matrix)**: **DID NOT REACH.** Responder produced the exact OPPOSITE framing of the resource. The keyword anchors at L354 (which include "hard delete", "hard_deletes config", "hard_deletes new_record", "track deletions in SCD2", "capture deletion timestamp in snapshot") ARE comprehensive and match the engineer's natural phrasing, but the hard-deletes matrix is at L468 — ~115 lines into the snapshot block, AFTER the L358 `strategy='timestamp'` and L378 `strategy='check'` sub-blocks. The likely failure mode is the responder's content prior ("dbt snapshot strategies are timestamp/check; deletion handling is NOT a snapshot feature") overrides the buried positive answer, OR the responder reaches the L358/L378 strategy sub-blocks first and stops, treating them as "the answer."

---

## Teacher guidance — HOIST the affirmative answer to the top of each block

Both Q1 and Q2 share the same structural failure: the resource has the right answer, but it's NOT at the spot the responder lands. The responder hits the negative-framing first ("no access-aware" / "strategies are timestamp/check") and either bails or stops reading. **The fix is to HOIST the affirmative mechanism to the TOP of each block — before the negative-framing content.**

### FIX-A REDO #1 (r16 storage-tiering) — required next iter, NOT optional

Restructure the LEADING CANONICAL block at r16 L499 so the FIRST piece of content the responder reads is the affirmative answer, not the capability-bound denial. Two specific edits:

(a) **Insert a 4-line "YES/NO at-a-glance" answer ABOVE the capability-bound table** (i.e., between L501 and L503):

```markdown
> ### TL;DR for the engineer asking "can I tier old/cold data on this stack?"
>
> - **YES — on-prem MinIO supports age-based tiering** to a cheaper backend via `mc ilm tier add <TIER_NAME>` (one-time setup) + `mc ilm rule add --transition-days N --transition-tier <TIER_NAME>` (the ongoing rule). Transparent to Trino — same `s3a://...` path, cold reads pay higher latency. See Mechanism A below.
> - **NO — tiering does NOT trigger on read/access recency.** The trigger is days-since-CREATION, not days-since-last-read. A heavily-read 6-month-old file STILL transitions; a recent file nobody reads stays hot until it ages out. If you need access-aware tiering (S3 Intelligent-Tiering equivalent), build it at the app layer (Mechanism C).
> - **DO NOT `DELETE FROM ...` old data to "tier" it** — that destroys queryability. Tiering moves files to cheaper storage WITHOUT changing what Trino can read.
```

The third bullet is critical — it directly defangs the Q1 failure mode (responder recommended DELETE).

(b) **Reorder Mechanism A to come BEFORE the DO-NOT-WRITE table** (already true at L522) — but add a one-line cross-link at the END of the capability-bound table row "Access-aware tiering" pointing to the TL;DR: *"NO — but age-based IS available; see TL;DR above and Mechanism A below."* This prevents the responder from reading the NO in isolation.

### FIX-A REDO #2 (r09 dbt snapshots hard deletes) — required next iter, NOT optional

The hard-deletes matrix MUST move from L468 (buried) to immediately AFTER the "two strategies" intro at L356, or alternatively as its OWN LEADING CANONICAL block at the top of the snapshot section. Either way the affirmative `hard_deletes='new_record'` answer must be reachable BEFORE the responder hits the strategy=timestamp/check sub-blocks.

Recommended structure:

(a) **Add a new sub-heading immediately after L350** ("Practical note: You can maintain SCD Type 2 via Spark MERGE INTO ..."), at L351-ish:

```markdown
> ### TL;DR — three orthogonal snapshot decisions on dbt 1.9+
>
> Pick one value for EACH of these three configs — they compose orthogonally:
>
> 1. **Change-detection strategy** — `strategy='timestamp'` (preferred, requires `updated_at='<col>'`) OR `strategy='check'` (requires `check_cols=[...]`). See Option 1a / 1b below.
> 2. **Hard-delete handling** — `hard_deletes='ignore'` (default, deleted source rows freeze last version) OR `'invalidate'` (stamps `dbt_valid_to` on delete; replaces legacy `invalidate_hard_deletes=true`) OR `'new_record'` (inserts a marker row with `dbt_is_deleted='True'` — pick this if you need to record THAT a deletion happened and WHEN). See HARD DELETES block below.
> 3. **Meta column names** — `snapshot_meta_column_names={...}` if you want to rename the four defaults (`dbt_scd_id`/`dbt_updated_at`/`dbt_valid_from`/`dbt_valid_to`).
>
> The three are independent: timestamp+ignore is the dbt-pre-1.9 default; timestamp+new_record is the "track deletions" case.
```

(b) **Move the HARD DELETES block from L468 up to right after this TL;DR** — keep the matrix and worked example, just relocate.

(c) **Add a DO-NOT-WRITE row** explicitly defanging the Q2 failure pattern: *"'Snapshots can't detect hard deletes, write a manual LEFT JOIN against the previous snapshot run to stamp dbt_valid_to' — FALSE. Use `hard_deletes='invalidate'` or `'new_record'`; dbt does the LEFT JOIN internally. The manual LEFT JOIN is reinventing the built-in."*

### Re-probe plan for iter 1102

- Q1 angle: same access-recency framing, different verb ("archive files that haven't been read in 90 days"). Confirm Mechanism A surfaces.
- Q1 angle 2 (durability): different keyword family — "move old Iceberg partitions to cold storage without losing query access" — confirm `mc ilm tier add` reaches without the access-recency hook.
- Q2 angle: same hard-delete framing, different verb ("how do I capture Oracle DELETE events in my dbt snapshot history"). Confirm `hard_deletes='new_record'` surfaces.
- Q2 angle 2: dbt ≤1.8 framing ("we're on dbt 1.7, how do we mark deleted rows in snapshots"). Confirm `invalidate_hard_deletes=true` legacy surfaces.

If BOTH FIX-A REDOs reach next iter, the topics consolidate. If either fails again, the failure is NOT findability but a responder content-prior override — at that point the only remaining lever is a stronger DO-NOT-WRITE defang block that explicitly names the wrong claim verbatim ("the snapshot can't detect hard deletes is FALSE — here's why and here's the one-line fix").

### Non-FIX-A items (do not act on)

- Q3 is a clean breadth pass — no resource action.
- Q4 is a clean Oracle migration pass — no resource action. Minor completeness shave (EXPLAIN-after-ANALYZE verification, `EXECUTE drop_extended_stats`) is edge content, not a defect.

---

## Recommendation

- **Iteration verdict**: PASS on overall average (3.656 > 3.5) but with TWO serious source-contradicting defects on the FIX-A re-probes. The two clean breadth Qs (Q3, Q4) carried the average; the FIX-A re-probes themselves both FAILED.
- **Action**: TWO FIX-A REDOs required next iter (storage-tiering TL;DR hoist + DO-NOT-DELETE defang; dbt-snapshots TL;DR hoist + hard-deletes block relocation + DO-NOT-WRITE manual-LEFT-JOIN defang). NEITHER FIX-A from iter 1100 can be considered "reached" until the re-probes pass.
- **Storage tiering row is now THINNEST in rubric** at exactly 3.50/5 — same as the threshold; one more sub-3.5 storage-tiering answer drops it BELOW PASS. Treat this as the most fragile row in the system and protect it.
- **No state.json bump** (already 1101, already `passed: true`). No federation re-probe (4.50244/312 fragile-PASS per iter1097). No commit beyond rubric + this feedback.
- **Pattern**: this iter's failures are NOT new — they are the EXACT failure mode the iter 1100 FIX-A was meant to close. The iter 1100 FIX-As added correct content but in the wrong VISUAL POSITION; the responder finds the negative-framing first (which now correctly says "no access-aware" / explains strategies) and stops before reaching the affirmative mechanism. The FIX-A REDO must be a CONTENT-PLACEMENT change (hoist the affirmative to the TOP), not another content addition.

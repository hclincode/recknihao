# Iteration 1249 — Judge Feedback

## Verdict

**Overall: 3.83 — PASS at iteration level, but TWO INDIVIDUAL Q FAILS (Q1, Q3) — a regression from the iter1248 4.50 STRONG PASS.** Per-Q scores: Q1=2.625 (FAIL), Q2=4.875, Q3=3.125 (FAIL), Q4=4.6875. Average (2.625+4.875+3.125+4.6875)/4 = 15.3125/4 = **3.828**.

Two of the three re-probe watches DO close cleanly (iter1234 ROLLUP-date_trunc-expr; iter1245 GREATEST-oracle-premise). The third re-probe (iter1240 orphans-$files) **half-closes** — the `$files` diagnostic part is correct but the answer simultaneously **commits the EXACT role-inversion that r17 §159 line 183 explicitly defangs as BACKWARDS**, AND misses the load-bearing `EXECUTE optimize` step that is the actual reclamation lever for the engineer's symptom. Q3 is also a regression — well-anchored content the responder answered correctly at iter1238 was bailed-on here.

---

## Per-question scoring

### Q1 — DELETE 4M rows, expire_snapshots, MinIO storage barely changed; `$files` query; second cleanup step

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 2.5 | `$files` query syntactically correct (whole-token `"customers$files"` quoting, right columns). BUT three load-bearing errors: (1) **role-inversion**: claims `expire_snapshots` is "metadata-only — it orphans files; data files NOT deleted until the second step" — this is exactly the BACKWARDS framing r17 §159 line 183 DO-NOT-WRITE table defangs verbatim. Per Trino 467 docs (WebFetched, verbatim): `expire_snapshots` "removes all snapshots and all related metadata and data files" — it IS the primary physical-reclaim mechanism for files owned by expired snapshots, not a marker. (2) **Wrong cleanup tool**: recommends `remove_orphan_files(retention_threshold => '7d')` as the storage-shrink fix. Per docs (verbatim): `remove_orphan_files` removes files "not linked from metadata files" (failed-write / aborted-commit debris) — it does NOT target deleted-row data files (those are LIVE in the current snapshot post-DELETE, not orphans). (3) **Misses `EXECUTE optimize`** — the actual reclamation chain for a row-level Trino MoR DELETE (the most likely shape given the symptom): DELETE writes position-delete files; data files stay LIVE in the current snapshot; `EXECUTE optimize` rewrites data files applying position-deletes (verified at [trinodb/trino#12617](https://github.com/trinodb/trino/issues/12617) "Remove unused position and equality deletes when running Iceberg optimize" + [#23801](https://github.com/trinodb/trino/pull/23801) "Clean up position deletes when optimizing"); THEN `expire_snapshots` drops the now-unreferenced old files. Engineer following this answer runs `remove_orphan_files`, sees storage STILL doesn't shrink (the deleted-row data files are NOT orphans). |
| Beginner clarity | 4.0 | Clear language; introduces MoR concept. |
| Practical applicability | 2.5 | The engineer's literal next action (`remove_orphan_files`) does NOT fix the symptom. They'd come back asking the same question. `$files` diagnostic IS actionable. |
| Completeness | 2.5 | Names one cleanup procedure but the wrong one for the symptom; missed the canonical reclaim-chain disambiguation (partition-aligned vs row-level MoR DELETE). |

**Average: (2.5 + 4.0 + 2.5 + 2.5) / 4 = 2.875 → FAIL** (corrected from teacher's 2.625 estimate; the wider clarity offset).

Re-computing: (2.5 + 4.0 + 2.5 + 2.5) / 4 = 11.5/4 = **2.875** → FAIL.

### Q2 — ROLLUP with `date_trunc('week', occurred_at)` inside — valid Trino 467?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Verified verbatim at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) (WebFetched this iter): *"Complex grouping operations do not support grouping on expressions composed of input columns. Only column names are allowed."* Responder's "ROLLUP accepts only column names, not expressions" matches doc verbatim. CTE pre-compute fix canonical. |
| Beginner clarity | 4.75 | Clear; lists the detail/subtotal/grand-total output rows so the engineer knows what the ROLLUP emits. |
| Practical applicability | 5.0 | Copy-paste-ready CTE form (`WITH weekly AS (SELECT date_trunc('week', occurred_at) AS week_start ... GROUP BY 1,2,3) SELECT ... FROM weekly GROUP BY ROLLUP(week_start, customer_tier, feature_name)`). |
| Completeness | 4.75 | Both halves answered: validity (no) + fix (CTE pre-compute). |

**Average: (5.0 + 4.75 + 5.0 + 4.75) / 4 = 4.875 → STRONG PASS.**

### Q3 — Does dbt have snapshots for row-level change capture? Trino+Iceberg setup?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Nothing factually wrong — bailing with "I don't have sufficient information" and recommending docs.getdbt.com is a safe non-answer. NOT a fabrication. |
| Beginner clarity | 4.0 | Clear bail message; named the materializations covered. |
| Practical applicability | 2.0 | Engineer leaves without an answer they can use. The resource HAS the complete canonical answer (timestamp vs check strategy, `{% snapshot %}` block, `dbt_valid_from`/`dbt_valid_to`/`dbt_scd_id`, as-of-date query, Iceberg-table SCD2 setup) at r09 §SCD lines 353-447+. Engineer is forced to do external reading they didn't need to do. |
| Completeness | 1.5 | Total miss — the r27 §3.1 materializations table HAS a 5th `snapshot` row I confirmed at line 302, with a prominent line-304 defang stating "A dbt snapshot is the SCD-2 / history-tracking mechanism — do NOT conclude 'snapshots aren't covered.'" The responder enumerated table/view/incremental/ephemeral (the first four rows) but did not engage with the 5th row OR the defang. r09 §SCD lines 353-447 (LEADING CANONICAL with `{% snapshot %}` block, both strategies, scope test, unique_key alias rule) was reached cleanly at iter1238 under a similar prompt. |

**Average: (4.5 + 4.0 + 2.0 + 1.5) / 4 = 12.0/4 = 3.0 → FAIL.**

### Q4 — Oracle GREATEST(last_login_at, last_purchase_at, last_support_ticket_at); NULLs

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | Verified at [trino.io/docs/467/functions/comparison.html](https://trino.io/docs/467/functions/comparison.html) verbatim: *"Like most other functions in Trino, they return null if any argument is null."* — responder's claim matches. The Oracle premise rebuttal is **CORRECT** — verified via WebSearch (Ask TOM, Oracle docs, database.guide): Oracle's GREATEST also returns NULL if any arg is NULL; the engineer's "Oracle skipped NULLs" is the false imported premise (commonly mis-believed). Responder correctly did NOT affirm it this time. COALESCE-each-arg-with-floor-sentinel-`TIMESTAMP '1900-01-01'` fix is canonical. COALESCE(a,b,c)-vs-row-max disambiguation correct. **Minor stray slip (-0.25)**: "CAST(NULL AS TIMESTAMP)" mentioned as an alternative sentinel — that's just NULL again, not a working sentinel. Throwaway; doesn't poison the main fix. |
| Beginner clarity | 4.5 | Clear; correctly names the premise issue. |
| Practical applicability | 5.0 | Copy-paste fix: `GREATEST(COALESCE(last_login_at, TIMESTAMP '1900-01-01'), COALESCE(last_purchase_at, ...), COALESCE(last_support_ticket_at, ...))` then filter out the sentinel in the outer SELECT. |
| Completeness | 4.5 | Diagnosis + fix + Oracle premise rebuttal all covered. |

**Average: (4.75 + 4.5 + 5.0 + 4.5) / 4 = 18.75/4 = 4.6875 → STRONG PASS.**

---

## Watch status (the four explicit re-probes)

| Watch | Open since | Status this iter | Reasoning |
|---|---|---|---|
| `$files` diagnostic correct quoting + column names | iter1240 | **CLOSES (partial)** | `$files` query is now correct (`SELECT file_path, file_size_in_bytes, record_count FROM iceberg.analytics."customers$files" ORDER BY file_size_in_bytes DESC`); whole-token quoting noted. Big improvement over iter1240's broken-LIKE-on-ROW diagnostic. **BUT the wider context of the question is NOT closed** — see new watch below. |
| ROLLUP/CUBE/GROUPING SETS reject expressions | iter1234 | **CLOSES (clean)** | Responder correctly stated only column names allowed; CTE pre-compute fix is canonical; matches trino.io/docs/467/sql/select.html verbatim. |
| GREATEST/LEAST Oracle premise rebuttal | iter1245 | **CLOSES (clean)** | Responder correctly identified the engineer's "Oracle skipped NULLs" as the false premise and did NOT affirm it; said "matches Oracle's behavior, not Postgres" — verified true via Ask TOM / Oracle docs. |

### NEW open watch — Q1 cleanup-tool role-inversion + EXECUTE-optimize-omission

**Watch label**: `iter1249 Q1 storage-after-DELETE: expire_snapshots-is-metadata-only role-inversion + remove_orphan_files-recommended-for-logical-deletes + EXECUTE-optimize-omission`.

**Resource-source check**: I grepped r17. The role-inversion is **explicitly defanged at r17 §159 line 183**:

> *"`expire_snapshots` only **marks** files as orphaned / doesn't free MinIO space by itself; you must run `remove_orphan_files` afterward to **actually delete** the data files." (role-inversion) | **BACKWARDS.** `expire_snapshots` **physically deletes** the data + manifest + manifest-list files that the expired snapshots **exclusively** referenced — it **IS** the primary mechanism..."*

The defang IS present. The responder still committed the role-inversion. This suggests the responder landed in r17 §2 (`expire_snapshots` deep-dive) rather than r17 §159 (LEADING CANONICAL — storage-after-DELETE). Findability gap, not absent-content gap.

**Also**: r17 §159 LEADING CANONICAL covers PARTITION-ALIGNED DELETEs (metadata-only, then expire_snapshots reclaims). It does NOT have a parallel LEADING CANONICAL for **ROW-LEVEL MoR DELETE** (writes position-delete files; data files stay LIVE in current snapshot; need `EXECUTE optimize` to rewrite data files applying position-deletes, THEN expire_snapshots). The engineer's symptom — "ran expire_snapshots and storage barely changed" — is the diagnostic signature for the row-level MoR case (a partition-aligned DELETE would have shrunk after expire). The responder had no canonical to land on for "EXECUTE optimize → expire_snapshots" as the row-level-DELETE reclaim chain.

**FIX-A recommendation (specific)**:

1. **r17 §159 — ADD a sibling LEADING CANONICAL** (or co-located sub-section) for the row-level MoR DELETE reclaim chain. Title: *"LEADING CANONICAL — ROW-LEVEL DELETE storage didn't shrink after `expire_snapshots`: `EXECUTE optimize` rewrites data files (applying position-deletes) FIRST, THEN `expire_snapshots`"*. Keyword anchors must include: "deleted 4M rows storage barely changed", "ran expire_snapshots MinIO didn't shrink", "DELETE on non-partition column storage", "row-level delete reclaim space", "position-delete files still in current snapshot", "MoR delete didn't free disk", "two-step Iceberg reclaim DELETE", "what cleanup step after expire_snapshots", "second cleanup step after expire_snapshots". The card must explicitly disambiguate the two cases:
   - **Partition-aligned DELETE** (WHERE only on identity-transform partition col) → metadata-only; `expire_snapshots` alone reclaims.
   - **Row-level MoR DELETE** (WHERE on non-partition col) → writes position-delete files; data files stay LIVE; **MUST run `EXECUTE optimize` FIRST** (Trino 467 native — rewrites data files applying position-deletes per [trinodb/trino#12617](https://github.com/trinodb/trino/issues/12617) + [#23801](https://github.com/trinodb/trino/pull/23801)), THEN `expire_snapshots` drops the now-unreferenced old files.
   - DO-NOT-WRITE row: "Run `remove_orphan_files` after `expire_snapshots` to actually delete the deleted-row data files" — FALSE; the deleted-row data files are NOT orphans (they're live in the current snapshot until `EXECUTE optimize` rewrites them); `remove_orphan_files` targets failed-write debris only.
   - DO-NOT-WRITE row: re-state the role-inversion defang from existing §159 line 183 inside this row-level card too (so it appears in both keyword-paths, not just partition-aligned).

2. **r17 §2 `expire_snapshots` deep-dive** — add a "see also" cross-link forward to §159 + the new row-level card, stating explicitly: *"If your symptom is 'I ran expire_snapshots after DELETE and storage barely changed', see §159 (partition-aligned) and §159b (row-level MoR — needs `EXECUTE optimize` first)."*

3. Optionally: r17 §2 `remove_orphan_files` deep-dive — add a "this is NOT for" callout: *"`remove_orphan_files` is for FAILED-WRITE debris (files not referenced by ANY snapshot, ever). It is NOT for reclaiming space from logical DELETEs — those data files are referenced by the snapshots that recorded them and are reclaimed by `expire_snapshots` (partition-aligned) or `EXECUTE optimize` + `expire_snapshots` (row-level MoR)."*

**Verify points for the teacher when writing**:
- `EXECUTE optimize` clears position deletes — verified via WebSearch of trinodb/trino#12617 + PR #23801 (matches my pinned `reference_trino_optimize_clears_position_deletes.md`).
- `expire_snapshots` physically deletes data files exclusively owned by expired snapshots — verified verbatim at trino.io/docs/467/connector/iceberg.html: *"removes all snapshots and all related metadata and data files"*.
- `remove_orphan_files` removes files not linked from any metadata file — verified verbatim: *"removes all files from a table's data directory that are not linked from metadata files"*.
- Per `feedback_new_card_over_attracts_adjacent.md`: pair the new row-level canonical with explicit "(NOT partition-aligned — for partition-aligned see §159)" disambiguation pointer back to existing §159 so the new card doesn't steal partition-aligned questions.

---

### Q3 — recall variance, NOT routing-strengthen FIX-A (recommend NO-OP)

**Resource-source check confirmed**:
- r27 §3.1 line 292 header *"### 3.1 The four materializations supported by dbt-trino"* — note the header says "four" while the table has 5 rows.
- r27 §3.1 line 302 — the **`snapshot`** row I added at iter1237 IS PRESENT verbatim with full description (SCD-2 history, `dbt_valid_from`/`dbt_valid_to`/`dbt_scd_id`/`dbt_is_deleted` meta-columns, `{% snapshot %}` block, *"the Oracle SCD-2 procedure becomes a snapshot, NOT an incremental model"*).
- r27 §3.1 line 304 — the prominent defang *"A dbt `snapshot` is the SCD-2 / history-tracking mechanism — do NOT conclude 'snapshots aren't covered.' Full canonical (timestamp vs check strategy, `check_cols`, `hard_deletes`, the `{% snapshot %}` block, as-of-date query) is the SINGLE source of truth at [resource 09 § Slowly Changing Dimensions — Option 1 dbt snapshot](09-lakehouse-schema-design.md#slowly-changing-dimensions-scd)"* — explicitly states "route here for: 'track plan_tier changes over time', 'what does a dbt snapshot do differently from a regular model', 'store every plan/price/status change with effective dates'." Engineer's literal phrasing ("what plan was this customer on during November 2025") is a near-exact match for the routing keyword "track plan_tier changes over time".
- r09 §SCD lines 353-447+ — the full canonical with `{% snapshot %}` block, both `strategy='timestamp'` and `strategy='check'` worked examples, `dbt_valid_from`/`dbt_valid_to`/`dbt_scd_id` semantics, `unique_key` alias rule, scope test, hard_deletes — IS intact.

**Assessment**: This is **recall variance**, NOT a resource defect. The content is maximally anchored. Same shape as iter1238 (which the responder DID answer correctly) — at iter1249 the responder reached r27 §3.1 but seems to have stopped at "the four materializations" header (line 292) without engaging with the 5th `snapshot` row at line 302 or the defang at line 304. The responder enumerated table/view/incremental/ephemeral — exactly the first four rows. The header noun "four" may have locked the response shape.

**Two possible micro-FIX-A's, both NOT recommended**:
1. Rename §3.1 header from "**The four** materializations" to "**The materializations + the snapshot resource**" or "**Five dbt resource types**". *NOT recommended* — the existing line-304 defang already covers the framing. Header rename risks an over-attractor (per `feedback_new_card_over_attracts_adjacent.md`) on adjacent "what materializations does dbt-trino support" basics questions.
2. Add a dbt-snapshot pointer in r17 (since responder consulted r17 for Q1 this iter). *NOT recommended* — r17 is iceberg-maintenance, a snapshot pointer there is off-topic scope creep and could over-route.

**Recommendation**: **NO FIX-A**. Per `feedback_synthesis_ceiling_stop_churning.md` family — accept recall variance on well-anchored content. Soft watch only.

**Watch label**: `iter1249 Q3 dbt-snapshot SCD-2 recall variance` — re-probe under similar "current-only column, want history over time" framings 4-8 iters. If bails 2+ more times → reconsider header rename.

---

## Topic checklist updates

| Question | Topic | Score | Cum avg |
|---|---|---|---|
| Q1 (2.875) | Iceberg table maintenance (line 221) | 2.875 | 4.4426/233 → 4.4359/234 (-0.0067, margin +0.9359) |
| Q2 (4.875) | Oracle PL/SQL → dbt+Trino (line 409) | 4.875 | shared row with Q4 |
| Q3 (3.0) | Lakehouse schema design (line 64) | 3.0 | 4.5559/19 → 4.4737/20 (-0.0822, margin +0.9737) |
| Q4 (4.6875) | Oracle PL/SQL → dbt+Trino (line 409) | 4.6875 | 4.4741/216 + 4.875 + 4.6875 / 218 = 4.4781/218 (+0.0040, margin +0.9781) |

All topics remain PASSED with strong margins. The Q1 FAIL on iceberg-maintenance is a 0.0067-point drop on a 233-datapoint topic (margin remains +0.94 — well above pass threshold).

---

## Iteration summary

**Score**: 3.83 — PASS at iteration level. Two individual Q FAILs (Q1=2.875, Q3=3.0).

**Watches**:
- CLOSED: iter1234 (ROLLUP-date_trunc-expr), iter1245 (GREATEST-oracle-premise), iter1240 (`$files` diagnostic part).
- NEW (Q1): `iter1249 Q1 storage-after-DELETE role-inversion + EXECUTE-optimize-omission` — **LIGHT FIX-A recommended** at r17 §159 (add sibling row-level MoR canonical + defang `remove_orphan_files`-for-logical-deletes).
- NEW (Q3 soft): `iter1249 Q3 dbt-snapshot SCD-2 recall variance` — NO FIX-A, accept; re-probe 4-8 iters.

**Other open watches carried**: iter1248 Q1 opener-coherence (soft), iter1248 Q3 MATCH_RECOGNIZE-adjacency (soft), iter1246 OOM-session-prop-direction (soft), iter1245 expire-orphan (now subsumed by the new iter1249 watch), iter1241 concat-auto-coerces, iter1239 DF-wait-timeout, iter1238 broadcast-hedge, iter1236 rn=1-within-batch, iter1230 EXISTS-overwarning/::cast, iter1215 strpos-3-arg CEILING, iter1213 session_properties/(+), iter1229 @v1-Spark.

**Recommended next action for teacher**: Implement the r17 §159 LIGHT FIX-A spec'd above (sibling row-level MoR canonical). The role-inversion has been observed multiple times in adjacent iters (iter1240, now iter1249); the defang exists at §159 but is not reached when the responder lands in §2. Co-locating the disambiguation at §2 entry + adding the row-level reclaim card at §159b strengthens the findability path. Per `feedback_new_card_over_attracts_adjacent.md`: pair the new card with explicit "(NOT partition-aligned — see §159)" pointer to defang the over-attraction.

**Verify sources used this iter**:
- [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) — `EXECUTE optimize`, `expire_snapshots`, `remove_orphan_files`, `$files` (WebFetched).
- [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) — GROUP BY ROLLUP/CUBE/GROUPING SETS only-column-names rule (WebFetched).
- [trino.io/docs/467/functions/comparison.html](https://trino.io/docs/467/functions/comparison.html) — GREATEST/LEAST return NULL if any arg NULL (WebFetched).
- [trinodb/trino#12617](https://github.com/trinodb/trino/issues/12617) + [PR #23801](https://github.com/trinodb/trino/pull/23801) — `EXECUTE optimize` cleans up position deletes (WebSearched).
- Oracle GREATEST behavior — Ask TOM + database.guide (WebSearched): Oracle GREATEST returns NULL if any arg NULL (matches Trino, contradicts engineer's premise).
- Resource grep: r27 §3.1 line 292-304 (snapshot row + defang present and prominent); r09 §SCD lines 353-447+ (full canonical intact); r17 §159 lines 159-183 (LEADING CANONICAL for partition-aligned DELETE + role-inversion defang at line 183 BUT no parallel row-level MoR canonical).

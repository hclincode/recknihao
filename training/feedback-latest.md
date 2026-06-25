# Judge Feedback — iter1102 (2026-06-26)

## Source verification

- **MinIO `mc ilm tier add` / `mc ilm rule add --transition-days N --transition-tier <NAME>` on bare-metal**: VERIFIED prior (iter1101) vs docs.min.io. r16 L499–634 hoisted TL;DR now leads with the affirmative answer at L504. Content adequate.
- **dbt `hard_deletes='new_record'` semantics + `dbt_is_deleted='True'` VARCHAR flag + `dbt_valid_from` = observed deletion time**: VERIFIED vs docs.getdbt.com/reference/resource-configs/hard_deletes and r09 L356–510. The `hard_deletes` matrix at L473–510 + the TL;DR at L356–358 are both in place; the DO-NOT-WRITE row at L510 explicitly defangs the manual-LEFT-JOIN wrong claim.
- **Trino 467 `PERCENTILE_CONT`**: VERIFIED ABSENT — VIA WebFetch trino.io/docs/current/functions/aggregate.html: NO `percentile_cont` function exists on the page. `WITHIN GROUP (ORDER BY ...)` is supported ONLY for `listagg()`. Resources are correct: r05 L2234–2266 + r23 L267–316 + r23 L2262 all state Trino has NO `PERCENTILE_CONT` / `MEDIAN` / `percentile_disc`. The responder's "Trino has PERCENTILE_CONT() WITHIN GROUP as a window function for exact computation" claim in Q3 is a FABRICATION.
- **Trino 467 `CALL iceberg.system.rollback_to_snapshot('schema','table',id)` 3-arg form**: VERIFIED via WebSearch (starburst blog + trinodb/trino PR #24580) — exact form is `CALL system.rollback_to_snapshot(schema_name, table_name, snapshot_id)`. The `ALTER TABLE ... EXECUTE rollback_to_snapshot` table-procedure form is the NEWER deprecation-replacement landing in 469+ (PR #24580 "Deprecate `CALL rollback_to_snapshot` and add corresponding table procedure"). Responder's Q4 form is correct for 467.

---

## Per-question scoring

### Q1 — Cut old-data storage cost while keeping it queryable; is DELETE the only option; does bare-metal MinIO have storage classes (FIX-A REDO #1 re-probe)

**Answer summary**: "Trino has no native storage-tiering DDL/property (correct); the mechanism is MinIO `mc ilm tier add` + `mc ilm rule add --transition-days N --transition-tier <TIER>` scoped to the `data/` prefix (keep `metadata/` hot); once on a slower tier Trino queries still work normally (Iceberg doesn't care about physical tier). Did NOT recommend DELETE." **BUT** opened with *"Unfortunately, I don't have complete information on this in the resources"* and repeatedly hedged *"the resources don't provide the exact syntax or walk-through... you'd need to verify against MinIO official docs."*

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.0 | All substantive facts correct: no Trino-side tiering DDL/property; MinIO `mc ilm tier add` + `mc ilm rule add --transition-days N --transition-tier <NAME>` is the canonical mechanism; data stays queryable through Trino post-transition; scope to `data/` prefix (keep `metadata/` hot) is the correct ops practice. Did NOT recommend DELETE — a major recovery from iter1101's "DELETE FROM events WHERE created_at < ..." defect. The hedging language ("don't have complete information") is a presentation problem not a technical-wrongness problem — every concrete claim in the answer is correct. |
| Beginner clarity | 3.5 | The hedging UNDERCUTS the answer's confidence — the opener ("Unfortunately, I don't have complete information") immediately followed by the correct `mc ilm tier add` command is jarring and self-contradictory in voice. A beginner reading "I don't have complete information" before being given the command may not trust it and may go searching elsewhere. The substance is clearly written; the framing is not. |
| Practical applicability | 4.0 | Engineer gets the right command set (`mc ilm tier add`, `mc ilm rule add --transition-days N --transition-tier <TIER>`), the right scope guidance (data/ prefix, keep metadata/ hot), and the correct framing (this is a MinIO-ops change, not a Trino SQL change). The "verify against MinIO docs" tag is reasonable hedge for flag-name details (which the resource itself recommends — r16 L535 says "consult docs.min.io ... before running — do NOT guess flag names") but the answer reads as if the engineer must restart from scratch rather than continue from this skeleton. |
| Completeness | 4.0 | Covered Mechanism A (mc ilm tier add age-based), Trino-queryability (no SQL change), metadata-on-hot caveat (implied via data/ prefix scope), no-Trino-DDL truth. Missed Mechanism B (`compression_codec=ZSTD` whole-table) and Mechanism C (recent/archive UNION ALL view) — both relevant alternatives the engineer could have considered. Also did not explicitly address the "is DELETE the only option" sub-question with a YES/NO answer (the absence of DELETE recommendation is good, but the explicit "NO — tiering keeps data queryable, DELETE destroys queryability" framing would have been a stronger affirmative). |
| **Q1 average** | **3.875** | **PASS** |

**FIX-A REDO #1 verdict — MOSTLY REACHED.** Significant recovery from iter1101's 2.50 (FAIL / PARTIAL REACH). The affirmative-first TL;DR hoist at r16 L503–506 (YES age-based tiering keeps data queryable / NO not access-based / DO NOT DELETE) DID reach the responder — every concrete claim in the answer aligns with the TL;DR's three bullets. The residual gap is **responder hedging caution**, not a content gap: the responder gives the correct `mc ilm tier add` command + the correct queryability framing + correctly does NOT recommend DELETE, but couches all of it in "I don't have complete information / verify against docs" language. Diagnosis: r16 content is now adequate; this is the [Responder Over-Warning Folklore] pattern (Haiku surrounds the right answer with cautionary hedge, no resource fix needed) per the memory pin. Storage-tiering row recovers from threshold-fragility.

---

### Q2 — Teammate claims dbt snapshots are blind to hard deletes, must build LEFT JOIN detection — true? (FIX-A REDO #2 re-probe)

**Answer summary**: *"Your teammate is partially right (default 'ignore'), but dbt has a built-in solution."* Surfaced `hard_deletes='new_record'` config, the three options (`'ignore'`/`'invalidate'`/`'new_record'`), `dbt_is_deleted='True'` VARCHAR flag, `dbt_valid_from` = deletion observed time, query pattern `WHERE dbt_is_deleted='True'`; explicitly stated *"No manual LEFT JOIN needed."*

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Every fact matches docs.getdbt.com/reference/resource-configs/hard_deletes and r09 L473–510: three valid values (`'ignore'`/`'invalidate'`/`'new_record'`), `'new_record'` inserts a row with `dbt_is_deleted='True'` meta column (VARCHAR not boolean), `dbt_valid_from` of the marker row = the time dbt observed the row missing (not the source DELETE time), filter pattern `WHERE dbt_is_deleted = 'True'`. The "teammate is partially right" framing is technically sharp — captures that the DEFAULT behavior IS blind (`'ignore'`) but the built-in `hard_deletes` config fixes it. |
| Beginner clarity | 5.0 | The "teammate is partially right" hook is excellent for a beginner being pushed back on by a coworker — it gives them a way to phrase the rebuttal without confrontation ("we both were partly right, here's the one-line fix"). The three-row option-matrix walks the engineer through the decision; the explicit "No manual LEFT JOIN needed" closes the loop on the original wrong claim. |
| Practical applicability | 5.0 | One-line config `hard_deletes='new_record'` is paste-and-run; the query pattern `WHERE dbt_is_deleted = 'True'` is paste-and-run; the explicit refutation of the LEFT JOIN suggestion gives the engineer ammunition to push back on the teammate without re-implementing built-in behavior. |
| Completeness | 4.5 | Covered the three options, the marker-row mechanism, the VARCHAR flag, the deletion-observed-time semantics, the query pattern, the explicit "no LEFT JOIN needed" refutation. Did not surface the dbt-version requirement (dbt 1.9+ for `hard_deletes` / `'new_record'` mode; dbt ≤1.8 uses legacy `invalidate_hard_deletes=true` boolean) — a minor gap if the engineer is on an older dbt. Did not flag the cutover gotcha (existing snapshot table needs `--full-refresh` OR manual `ALTER TABLE ADD COLUMN` to add the conditional `dbt_is_deleted` column going forward). |
| **Q2 average** | **4.875** | **PASS** |

**FIX-A REDO #2 verdict — FULLY REACHED.** Textbook recovery from iter1101's 2.25 (FAIL / DID NOT REACH). The affirmative-first TL;DR hoist at r09 L356–358 (THREE orthogonal decisions: strategy / hard_deletes / meta-column-names; with the explicit "YES — hard_deletes='new_record' is the native answer; do NOT hand-roll a LEFT JOIN" line at L358) DID reach the responder cleanly; the DO-NOT-WRITE row at L510 ("dbt snapshots cannot detect hard deletes ... write a manual LEFT JOIN ... **FALSE**. dbt snapshots handle source-side hard DELETEs natively via the `hard_deletes` config") cemented the refutation. The answer reads as if it was written from the resource verbatim. dbt-snapshots row recovers durability.

---

### Q3 — p95 latency per endpoint, exact vs approx percentile, when to use each

**Answer summary**: `approx_percentile(response_time_ms, 0.95) GROUP BY endpoint` + `WHERE occurred_at >= current_date - INTERVAL '7' DAY`; ARRAY form `approx_percentile(col, ARRAY[0.5,0.95,0.99])` for multiple percentiles in one pass; T-Digest sketch mention; correctly said *"there is no exact PERCENTILE_CONT form on Trino (that's Postgres/Snowflake syntax)"*; **then contradicted itself** with *"Trino has PERCENTILE_CONT() WITHIN GROUP (ORDER BY ...) as a window function for exact computation."* Said approx_percentile has no accuracy-tuning parameter on 467.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 2.5 | The LEAD is fully correct: `approx_percentile(col, 0.95)` is the right Trino primitive; ARRAY form is correct; T-Digest framing is correct; "no PERCENTILE_CONT, that's Postgres/Snowflake" is the canonical r05 L2234 / r23 L267 / r23 L2262 answer. BUT the trailing "for completeness" alternative — "Trino has PERCENTILE_CONT() WITHIN GROUP as a window function for exact computation" — is a FABRICATION (verified vs trino.io/docs/current/functions/aggregate.html: no `percentile_cont` exists in any form, neither aggregate nor window; `WITHIN GROUP` is supported ONLY for `listagg`). It also self-contradicts the lead. A beginner reading both is confused; one who pastes the trailing claim hits a parse error. The lead survives; the trailer is wrong. |
| Beginner clarity | 2.5 | Self-contradiction is the antithesis of clarity — a beginner reading "Trino does NOT have PERCENTILE_CONT" three paragraphs above "Trino HAS PERCENTILE_CONT" cannot reconcile and may copy whichever they read last. The exact-vs-approx framing is otherwise readable. |
| Practical applicability | 3.5 | If the engineer reads only the lead, paste-and-run works (`approx_percentile(response_time_ms, 0.95) GROUP BY endpoint` is correct). If the engineer reads the trailer and tries `PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY response_time_ms)`, parse error at runtime. The presence of the contradiction degrades actionability — the engineer can't know which to trust. |
| Completeness | 4.0 | Covered the canonical answer (approx_percentile), GROUP BY semantics, WHERE-clause time filter, ARRAY form for multi-percentile, T-Digest under-the-hood note, no-accuracy-parameter caveat (correct per the [Trino approx_percentile Error] memory pin), exact-vs-approx tradeoff. Polluted with the fabricated PERCENTILE_CONT alternative which is a Completeness anti-pattern — adding wrong content is not "more complete." |
| **Q3 average** | **3.125** | **BORDERLINE FAIL (per-Q, but NO per-question veto in this iteration)** |

**Defect classification**: This is the [Responder Broken Secondary Alternative] memory-pin pattern verbatim — *"Haiku nails the LEAD but frequently appends a BROKEN 'for completeness' alternative form"*. The lead passes; the appended alternative is the fabrication. Per the pin, the prescription is *"scope each as per-instance one-off re-probe NOT a resource defect, don't churn (no single resource fix for responder padding)."*

**Grep audit of resources**: r05 L2234–2266 (the PERCENTILE_CONT footgun block) and r23 L267 + L293 + L316 + L2262 ALL correctly state PERCENTILE_CONT is NOT supported in Trino. The resources do NOT source this fabrication — the resources are right. This is a pure responder hallucination of a secondary alternative form. **No resource fix required.** Scope as a per-instance one-off.

---

### Q4 — Roll back an Iceberg table to before a bad dbt run, from Trino

**Answer summary**: List `"tbl$history"` (made_current_at, snapshot_id, parent_id, is_current_ancestor); then `CALL iceberg.system.rollback_to_snapshot('analytics','fct_aggregates', <id>)`; metadata-only operation (no data file rewrite); explicit caveat: *"There is NO `ALTER TABLE ... EXECUTE rollback_to_snapshot` form on Trino 467 (that arrived in Trino 469+)."*

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | 3-arg CALL form verified via WebSearch (Starburst blog + trinodb/trino PR #24580). PR #24580 explicitly deprecates the CALL form and adds the table-procedure (ALTER TABLE EXECUTE) replacement — confirming the responder's "EXECUTE form is 469+" caveat. `"tbl$history"` metadata table columns + ancestor lookup pattern correct per trino.io/docs/current/connector/iceberg.html. Metadata-only (no data rewrite) correct — rollback just repoints `metadata.json` to a prior snapshot ID. |
| Beginner clarity | 5.0 | Two-step workflow (find the snapshot ID from `$history`, then CALL with three args) is concrete and walkable. The version-availability note ("no EXECUTE form on 467") preemptively defangs a confused engineer who saw the EXECUTE form in newer Trino docs. |
| Practical applicability | 5.0 | Paste-and-run; the only edit the engineer needs to make is the schema/table name + the snapshot ID picked from the `$history` query. |
| Completeness | 5.0 | Covered discovery (`$history` columns), action (CALL with 3 args), semantics (metadata-only), version caveat (no EXECUTE on 467). Could optionally have mentioned `set_current_snapshot` (the analogous procedure for "move HEAD to this snapshot without history rewrite") or the `expire_snapshots`-interaction caveat (a rolled-back-from snapshot is still pinned by ancestors until expiry) — but those are edges, not defects. |
| **Q4 average** | **5.00** | **PASS** |

---

## Iteration summary

| Q | Topic | Accuracy | Clarity | Applicability | Completeness | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | Storage tiering (FIX-A REDO #1 re-probe) | 4.0 | 3.5 | 4.0 | 4.0 | **3.875** | PASS |
| Q2 | dbt snapshots hard deletes (FIX-A REDO #2 re-probe) | 5.0 | 5.0 | 5.0 | 4.5 | **4.875** | PASS |
| Q3 | p95 percentile, exact vs approx | 2.5 | 2.5 | 3.5 | 4.0 | **3.125** | borderline-FAIL on Q-average; no per-Q veto |
| Q4 | Iceberg rollback_to_snapshot from Trino | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** | PASS |

**Iteration average** = (3.875 + 4.875 + 3.125 + 5.00) / 4 = 16.875 / 4 = **4.219 PASS** (margin +0.719 over the 3.5 threshold).

**Topic-row updates**:
- **Storage tiering** 3.50/5 → (17.5 + 3.875)/6 = **3.5625/6 PASSED** (+0.0625, recovers from exact-threshold fragility)
- **dbt snapshots SCD2** 4.0855/11 → (44.9405 + 4.875)/12 = **4.1513/12 PASSED** (+0.066, recovers from iter1101 -0.184)
- **Analytical query patterns on Iceberg+Trino** 4.391/50 → (219.55 + 3.125)/51 = **4.3662/51 PASSED** (-0.025, Q3 drag from fabricated PERCENTILE_CONT alt)
- **Iceberg table maintenance** 4.4575/169 → (753.3175 + 5.00)/170 = **4.4607/170 PASSED** (+0.003)

ALL FOUR topics REMAIN PASSED. **Storage tiering recovers off the threshold** — was at exactly 3.50/5 entering this iter, now at 3.5625/6 with one positive datapoint of margin.

No `::`/QUALIFY/false-semi-join/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/over-warning/Spark-Oracle-spillover observed. ONE fabricated-function instance (Q3 PERCENTILE_CONT as window function) — sourced as responder hallucination per the [Responder Broken Secondary Alternative] memory-pin pattern, NOT from any resource. ONE responder-over-hedge instance (Q1 "I don't have complete information" hedge despite correct answer) — per [Responder Over-Warning Folklore] memory-pin pattern, no resource fix.

---

## FIX-A reach verdicts

- **FIX-A REDO #1 (r16 L503–506 affirmative-first TL;DR hoist + DO-NOT-DELETE third bullet)**: **MOSTLY REACHED.** The responder surfaced the canonical answer — `mc ilm tier add` + `--transition-days N --transition-tier <TIER>` scoped to `data/` prefix, with `metadata/` kept hot, data stays queryable through Trino post-transition. Did NOT recommend DELETE (the iter1101 defect is closed). Recovery from 2.50 → 3.875. Residual is responder hedging language ("I don't have complete information"), not a content gap. **Recommendation**: no further r16 edit. Content is adequate; the residual is a responder-side over-hedge pattern, not a resource problem.

- **FIX-A REDO #2 (r09 L356–358 affirmative-first three-orthogonal-decisions TL;DR + L510 DO-NOT-WRITE manual-LEFT-JOIN defang)**: **FULLY REACHED.** Recovery from 2.25 → 4.875. Textbook hoist-reach pattern — the responder produced an answer that reads as if written from the resource verbatim. Confirms the iter1101 placement diagnosis was correct (the content existed but was buried past the visual STOP point; hoisting to the top fixed it). **Recommendation**: no further r09 edit.

---

## Source-verified defects (NOT resource-sourced)

1. **Q3 — Responder fabricated PERCENTILE_CONT window function.** The responder's claim *"Trino has PERCENTILE_CONT() WITHIN GROUP (ORDER BY ...) as a window function for exact computation"* is a FABRICATION. Verified via WebFetch against trino.io/docs/current/functions/aggregate.html: `percentile_cont` does not exist on the page; `WITHIN GROUP` is supported ONLY for `listagg()`. The responder ALSO self-contradicts — its own earlier paragraph correctly said *"there is no exact PERCENTILE_CONT form on Trino (that's Postgres/Snowflake syntax)."* **Grep audit confirms r05 L2234–2266 + r23 L267 + L293 + L316 + L2262 ALL state Trino has NO PERCENTILE_CONT** — the resources are not the source. This is a pure responder one-off following the [Responder Broken Secondary Alternative] pattern (Haiku nails the lead, appends a broken "for completeness" alternative). Per the memory-pin prescription: **NO resource fix**, scope as a per-instance one-off re-probe; do not let it bias future judging.

2. **Q1 — Responder over-hedge despite correct answer.** The responder opened with *"Unfortunately, I don't have complete information on this in the resources"* and repeatedly hedged *"the resources don't provide the exact syntax or walk-through... you'd need to verify against MinIO official docs"* — but the answer itself contains the exact `mc ilm tier add` + `mc ilm rule add --transition-days N --transition-tier <TIER>` syntax that r16 L527–545 provides. This matches the [Responder Over-Warning Folklore] pattern. Per the memory-pin: NO resource fix; the content is present and adequate; the issue is responder caution framing.

---

## Teacher guidance

### Storage-tiering FIX-A REDO #1 — DECLARE REACHED, no further r16 edit

The TL;DR hoist at r16 L503–506 did its job. The responder surfaced the affirmative mechanism + queryability + no-DELETE recommendation. The residual hedging is responder-side caution, not a content problem — adding MORE content or hoisting it FURTHER will not fix a Haiku-padding pattern. Per [Responder Over-Warning Folklore]: "core info usually present, only the framing is over-cautious ... NO resource fix, don't let it bias the judge." The storage-tiering row recovered off the exact-threshold fragility (3.50/5 → 3.5625/6); one more clean datapoint and the row is comfortably above threshold.

### dbt-snapshots FIX-A REDO #2 — DECLARE FULLY REACHED, no further r09 edit

The TL;DR three-orthogonal-decisions hoist at r09 L356–358 + the DO-NOT-WRITE manual-LEFT-JOIN defang at r09 L510 did their job. Textbook reach pattern. The dbt-snapshots row recovered (4.0855/11 → 4.1513/12).

### Q3 PERCENTILE_CONT fabrication — NO resource fix

Resources are correct. The fabrication is a responder hallucination of a secondary alternative form, indistinguishable from the iter936/943/948/950/954/1013/1019/1020 pattern in the [Responder Broken Secondary Alternative] memory pin. Per the pin: scope as per-instance one-off, do NOT add a resource edit that would over-attract on neighboring questions. Re-probe with a different percentile-domain phrasing (e.g., "compute the median session duration per tenant" — should elicit `approx_percentile(x, 0.5)` only) next sweep IF the analytical-query row drops below 4.3.

### Q4 Iceberg rollback — clean breadth pass, no action

Maintenance row drifts up slightly. CALL form correct for 467, version-availability caveat correct.

### Re-probe plan (next sweep)

- **NO storage-tiering re-probe required** unless the row drops below 3.5 (currently 3.5625/6 with +0.0625 margin). If probing for durability, a fresh angle that doesn't trip the hedge: "what command would my MinIO admin run to set up cold tiering for objects older than 90 days?" — expects `mc ilm rule add --transition-days 90 --transition-tier <NAME>` without the hedge framing.
- **NO dbt-snapshots re-probe required** unless the row drops. If probing for durability, the legacy-version angle ("we're on dbt 1.7, how do we mark deleted rows in snapshots") to confirm `invalidate_hard_deletes=true` legacy surfaces.
- **NO PERCENTILE_CONT fabrication chase**. Re-probe at most ONE angle next sweep (e.g., "median per tenant"); if the lead is clean and the trailer is absent, treat as one-off-closed.
- **Q4 is breadth-clean** — no maintenance follow-up needed.

---

## Recommendation

- **Iteration verdict**: PASS (4.219 average, margin +0.719). Both FIX-A REDOs reached — storage-tiering MOSTLY (responder hedge residual, not content), dbt-snapshots FULLY. The iter1101 placement diagnosis was correct: hoisting the affirmative answer to the TOP of each block fixes the "responder reads the negative-framing first and stops" failure mode.
- **Storage-tiering durability**: row recovered from exact-threshold (3.50/5) to 3.5625/6 (+0.0625 margin). Still the thinnest required-topic row; protect with one more clean probe next sweep but do NOT re-edit r16.
- **Q3 PERCENTILE_CONT fabrication**: per-instance responder one-off, NO resource fix per memory-pin guidance. Resources are correct.
- **Action**: NO commit beyond rubric + this feedback. NO state.json bump (already 1102, already `passed: true`). NO federation re-probe (4.50244/312 fragile-PASS per iter1097).
- **Pattern**: the iter1100→1101→1102 arc closes cleanly. Iter1100 added correct content but the FIX-A re-probes failed because the content was placed below the responder's visual STOP point. Iter1101 hoisted to the top with affirmative-first TL;DRs + DO-NOT-WRITE defang. Iter1102 confirms reach on both. This is the canonical content-placement-fix pattern (analogous to iter948 HAVING-trims-memory folklore reconciled at r07 L37, and iter1098 r18 Check 3 reconciliation). The pattern works — hoist the affirmative answer ABOVE the negative-framing content, defang the wrong claim by name in a DO-NOT-WRITE row.

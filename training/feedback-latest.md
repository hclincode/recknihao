# Iteration 1224 — Judge Feedback

**Verdict: 4.578 PASS — iter1219 CoW-MoR FINDABILITY WATCH CLOSES (comparison REACHED).** Q1 reached the r13 §2994+ CoW/MoR comparison cleanly post-iter1219 findability-anchor add — facts on whole-file-rewrite (CoW, no delete files) vs position-delete files (MoR), `$files` content=1 diagnostic, and Trino-467-writer-MoR-only nuance are all VERIFIED correct. **BUT** the scenario-specific diagnosis was muddled: the user is SEEING delete files, which definitively means they are ALREADY on MoR; the teammate's "you're on CoW" is BACKWARDS, and the fix is COMPACTION (`EXECUTE optimize` / `rewrite_position_delete_files`) NOT a CoW→MoR mode switch. Responder's prose "CoW would rewrite your whole table — that's why your dashboard got slower" mis-attributes the slowness to a mode the engineer isn't on. Compaction is mentioned but not foregrounded as THE primary fix. Q2/Q3/Q4 all clean.

Per-question summary:
- Q1 3.6875 — CoW/MoR comparison REACHED (watch CLOSES); facts correct + diagnostic + Trino-467 nuance + property syntax all clean; SCENARIO DIAGNOSIS muddled (didn't identify already-on-MoR / teammate-backwards / compaction-is-the-fix-not-mode-switch); new soft watch
- Q2 5.0 — `CROSS JOIN UNNEST(tags) AS t(tag) GROUP BY tag` canonical + JSON-string variant + `LEFT JOIN UNNEST ... ON TRUE` empty-array handling + Oracle `TABLE()`→Trino mapping
- Q3 4.6875 — `strategy='check'` correct for no-reliable-`updated_at`; `check_cols`+hash-diff semantics; 4 dbt_* columns; `hard_deletes='new_record'`
- Q4 5.0 — Trino regexp_replace `$1/$2/$3` Java/Joni backreferences (NOT `\1`); `'($1) $2-$3'` example correct; `\1` defang correct

Iter average: (3.6875 + 5.0 + 4.6875 + 5.0) / 4 = **4.594** (rounded 4.58), margin +1.09.

---

## Q1 — Subscriptions Iceberg + Spark MERGE INTO + delete files accumulating; teammate says CoW→MoR

**Score: 3.6875** — Acc 3.5 / Clar 4.0 / App 3.75 / Compl 3.5

**Scenario.** `subscriptions` Iceberg table being updated by Spark `MERGE INTO`; after ~2 weeks dashboards slower. `EXPLAIN ANALYZE` shows "lots of delete files scanned." Teammate claims "we're on Copy-on-Write, should switch to Merge-on-Read." Engineer asks what CoW vs MoR do, how to tell which mode they're on, which to prefer.

**WATCH CLOSURE — iter1219 CoW-MoR findability.** iter1219 responder HEDGED "resources don't contain a direct comparison" (FALSE; r13 §2996 has the comparison table verbatim). iter1219 LIGHT FIX-A added a keyword-anchored leading canonical at r13 §2996. iter1224 (this iter) re-probe under structurally different framing (Spark MERGE INTO + delete-files-accumulating + teammate-said-X) REACHED the CoW vs MoR comparison cleanly — findability anchor works. **WATCH CLOSES on first re-probe** (~14th consecutive watch closure in 1st-re-probe-CLOSE pattern).

**Load-bearing facts CORRECT (VERIFIED):**

1. **CoW semantics** — "rewrites every affected Parquet file on DELETE/UPDATE; NO delete files; slow write, fast read." VERIFIED at [Dremio — Row-level Changes on the Lakehouse](https://www.dremio.com/blog/row-level-changes-on-the-lakehouse-copy-on-write-vs-merge-on-read-in-apache-iceberg/) ("CoW rewrites the entire data file when even a single row is updated or deleted") + [iceberglakehouse.com/iceberg/iceberg-merge-on-read](https://iceberglakehouse.com/iceberg/iceberg-merge-on-read/) ("Unlike COW, Merge-on-Read does not rewrite entire files when an update or delete occurs").
2. **MoR semantics** — "small position-delete files reference invalidated rows by ordinal position; fast write, slower read." VERIFIED at iceberglakehouse.com ("delete files that reference the data file and the ordinal position of the invalidated row") + [trinodb/trino PR #12704](https://github.com/trinodb/trino/pull/12704).
3. **Diagnostic** — `SELECT COUNT(*) FROM iceberg.analytics."subscriptions$files" WHERE content=1` (high count = MoR / many position deletes; zero = CoW). VERIFIED at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) `$files.content` enum (0=DATA, 1=POSITION_DELETES, 2=EQUALITY_DELETES).
4. **Trino 467 writer is MoR-only regardless of property** — VERIFIED via r13 §5589 + r17 §583/§721 + [trinodb/trino#17272](https://github.com/trinodb/trino/issues/17272). The `write.delete/update/merge.mode='merge-on-read'` property only governs SPARK's writer.
5. **Property syntax** — `ALTER TABLE ... SET TBLPROPERTIES('write.delete.mode'='merge-on-read', 'write.update.mode'='merge-on-read', 'write.merge.mode'='merge-on-read')` from Spark. Correct.
6. **Compaction mentioned** — `EXECUTE optimize` named as periodic compaction (correct fix for delete-file accumulation, verified via [Apache Iceberg knowledge base — Merge-on-Read](https://iceberglakehouse.com/iceberg/iceberg-merge-on-read/) "compaction reads all delete files, applies them to the data, and writes new clean data files, resetting delete file count to zero").

**DEFECT — scenario-diagnosis muddle (NOT resource-sourced, recall-ceiling reasoning slip):**

The user's `EXPLAIN ANALYZE` shows "lots of delete files scanned." Per the responder's own correct fact #1, **CoW produces ZERO delete files** — so seeing delete files DEFINITIVELY means the table is **already on MoR**. The teammate's "we're on CoW" is BACKWARDS for this scenario. The slowness is caused by **accumulated MoR position-delete files** that every read must merge against the data files (read amplification), NOT by CoW whole-file rewrites.

Responder's prose framing said: "With frequent updates, CoW would rewrite your whole table on each update — that's why your dashboard got slower." This mis-attributes the slowness to CoW when the engineer is on MoR. The CORRECT scenario diagnosis is:

> "The delete files you're seeing in EXPLAIN ANALYZE PROVE you're already on MoR — CoW doesn't produce delete files at all. Your teammate has it backwards. The dashboards slowed because MoR position-delete files have ACCUMULATED over 2 weeks of MERGE INTO writes — every read now merges many delete files against the data files. **The fix is COMPACTION, not a mode switch.** Run `ALTER TABLE iceberg.analytics.subscriptions EXECUTE optimize(file_size_threshold => '256MB')` (Trino-side) or `CALL iceberg.system.rewrite_position_delete_files(table => 'analytics.subscriptions')` (Spark-side) on a periodic schedule (nightly or every few hours). After compaction, `$files` content=1 count drops back to near-zero and read times recover."

Engineer following responder's prose would copy `SET TBLPROPERTIES write.X.mode='merge-on-read'` (a no-op — already MoR) and might also try `EXECUTE optimize` (the actual fix). They MIGHT recover via the secondary instruction but with the wrong mental model. Could file an unnecessary mode-switch ticket with the Spark team.

**Resource-source check CLEAN.** r13 §2996 (CoW-vs-MoR table), r13 §1293-1326 (delete-then-purge MoR cleanup recipe), and r17 §157+ (`EXECUTE optimize` + delete-file accumulation) all teach the right facts. The bridge "delete files visible = ALREADY on MoR → teammate-backwards twist → compaction-is-the-fix" is a multi-hop synthesis that the responder didn't assemble for the specific scenario. NOT a resource gap — Haiku reasoning-ceiling slip.

**NO FIX-A.** Adding an explicit "teammate-backwards diagnosis" card at r13 §2996 risks over-attracting adjacent generic mode-comparison questions per `feedback_new_card_over_attracts_adjacent.md`. The comparison + facts + diagnostic + fix tools are ALL in resources; the synthesis is what's missing.

**NEW SOFT WATCH** `iter1224 Q1 CoW-MoR scenario-diagnosis-when-symptom-implies-mode + compaction-not-mode-switch`: re-probe in 4-8 iters under "I see delete files / engineer thinks they need to change mode but actually on MoR / fix is compaction" framing. If recurs, consider a very light defang line in r13 §2996 (something like "If you see delete files in `$files` or `EXPLAIN ANALYZE`, you're ALREADY on MoR — CoW produces ZERO delete files. Accumulated MoR deletes are fixed by `EXECUTE optimize`, NOT by switching modes").

**Topic update.** Iceberg table maintenance 4.4399/223 → (990.0977 + 3.6875)/224 = 993.7852/224 = **4.4365/224 PASSED** (-0.0034, margin +0.9365).

---

## Q2 — events.tags ARRAY<VARCHAR> → count events per tag (Oracle TABLE() equivalent in Trino)

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**Scenario.** `events.tags` is an array of strings (`['mobile','enterprise','api']`). PM wants count of events per tag. Plain `SELECT tags, COUNT(*) GROUP BY tags` groups the whole array (wrong). Oracle would use `TABLE(...)`. What's the Trino way to turn each array element into its own row to GROUP BY?

**Load-bearing facts CORRECT (VERIFIED):**

1. **`CROSS JOIN UNNEST(e.tags) AS t(tag)`** — the canonical Trino array-explode. VERIFIED at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) verbatim: `CROSS JOIN UNNEST(scores) AS t(score)` example producing one row per array element.
2. **`GROUP BY tag ORDER BY event_count DESC`** — standard aggregation pattern, no nuance.
3. **JSON-string variant** — `CROSS JOIN UNNEST(CAST(json_parse(e.tags) AS ARRAY(VARCHAR))) AS t(tag)` correctly handles `tags` columns stored as JSON strings instead of native ARRAY. Two-step `json_parse` (string → JSON) then `CAST AS ARRAY(VARCHAR)` (JSON → typed array) is the canonical form.
4. **`LEFT JOIN UNNEST(...) AS t(tag) ON TRUE`** — correctly handles rows where `tags` is empty or NULL. VERIFIED at trino.io/docs/467/sql/select.html verbatim: "the only condition supported by the current implementation is `ON TRUE`" with LEFT JOIN UNNEST.
5. **Oracle `TABLE(...)`→Trino `CROSS JOIN UNNEST` mapping** — useful cross-dialect translation, explicitly addresses the engineer's Oracle background.

No imported-prior slip, no broken-secondary, no over-warning, no fabrication. Pin-perfect.

**Topic update.** SQL query best practices for OLAP 4.5884/279 → (1280.1636 + 5.0)/280 = 1285.1636/280 = **4.5916/280 PASSED** (+0.0032, margin +1.0916).

---

## Q3 — dbt snapshots SCD-2 for plan_tier history, source updated in-place in Oracle, NO reliable updated_at

**Score: 4.6875** — Acc 4.75 / Clar 4.75 / App 4.75 / Compl 4.5

**Scenario.** Build SCD-2 plan-tier history in dbt. Source `customers` table updated in-place in Oracle, NO reliable `updated_at`. dbt snapshot strategies check vs timestamp — which fits, and what's different?

**Load-bearing facts CORRECT (VERIFIED):**

1. **`strategy='check'` is correct for no-reliable-`updated_at`** — VERIFIED at [docs.getdbt.com/docs/build/snapshots](https://docs.getdbt.com/docs/build/snapshots): "The check strategy is useful for tables which do not have a reliable `updated_at` column" verbatim. Engineer's literal scenario → check strategy.
2. **`check_cols=['plan_name','billing_tier','annual_seats']`** — list of columns dbt re-hashes each run; any change in any listed column = new SCD-2 row. Correct.
3. **timestamp strategy vs check strategy contrast** — timestamp compares an `updated_at` column (fast, single column); check re-hashes `check_cols` and detects via hash diff (slower, works without a timestamp). VERIFIED at docs.getdbt.com snapshots reference.
4. **4 dbt_* columns** (`dbt_scd_id`, `dbt_updated_at`, `dbt_valid_from`, `dbt_valid_to`) — standard dbt snapshot metadata. dbt 1.9+ also adds `dbt_is_deleted` but ONLY when `hard_deletes='new_record'` is set.
5. **`hard_deletes='new_record'`** — VALID 1.9+ option for tracking deletions as marker rows with `dbt_is_deleted=True`. Alternative `hard_deletes='invalidate'` (stamps `dbt_valid_to=now()` when row disappears) is also valid; responder picked one of two equally-correct options.

**Minor compl shave (-0.5):**

- Didn't surface that with check strategy, `updated_at` is OPTIONAL (if configured, dbt uses it as the validity-window timestamp; if not, dbt falls back to current run time). Not load-bearing for engineer's literal "no reliable updated_at" scenario — they don't have one, so the fallback-to-run-time behavior is what they get by default.
- Didn't compare `hard_deletes='invalidate'` (close validity window) vs `hard_deletes='new_record'` (insert marker row) — both valid; iter1200 Q3 covered this disambiguation cleanly. Recall-ceiling, NOT load-bearing here.

Engineer leaves with the right answer (check strategy + check_cols + 4 dbt_* columns + hard_deletes for deletion tracking).

**Topic update.** dbt snapshots SCD2 4.2964/23 → (98.8172 + 4.6875)/24 = 103.5047/24 = **4.3127/24 PASSED** (+0.0163, margin +0.8127).

---

## Q4 — Trino regexp_replace backreferences: $1 vs \1 (Java/Joni vs Oracle/Postgres)

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**Scenario.** Oracle `REGEXP_REPLACE(phone_raw, '^([0-9]{3})([0-9]{3})([0-9]{4})$', '(\1) \2-\3')` → `'(555) 123-4567'`. Trino: does `regexp_replace` support backreferences, is `\1` right or different notation?

**Load-bearing facts CORRECT (VERIFIED):**

1. **Trino uses `$1`/`$2`/`$3` (Java/Joni regex)** — VERIFIED at [trino.io/docs/467/functions/regexp.html](https://trino.io/docs/467/functions/regexp.html) verbatim: "Capturing groups can be referenced in `replacement` using `$g` for a numbered group or `${name}` for a named group." Example: `regexp_replace('1a 2b 14m', '(\d+)([a-z]+) ', '3c$2 ')`.
2. **Correct Trino form** — `regexp_replace(phone_raw, '^([0-9]{3})([0-9]{3})([0-9]{4})$', '($1) $2-$3')` produces `'(555) 123-4567'`. Verified.
3. **`\1` DEFANG correct** — `\1` in Trino's replacement string emits a LITERAL backslash followed by `1` (no Oracle/Postgres-style backref interpretation). Engineer would get garbage like `'(\1) \2-\3'` literal output. Per `reference_trino_regex_backslash.md` (pinned), backslash is LITERAL in SQL string literals so `'\1'` in replacement is exactly two characters `\` + `1`.
4. **Java/Joni vs Oracle/Postgres cross-dialect framing** — useful translation context for the engineer's Oracle background. Correctly flagged dialect difference.

Pin-perfect. No defect.

**Topic update.** SQL query best practices for OLAP 4.5916/280 → (1285.1636 + 5.0)/281 = 1290.1636/281 = **4.5913/281 PASSED** (-0.0003, essentially flat, margin +1.0913).

---

## Watch ledger after iter1224

**CLOSED this iter:**
- `iter1219 Q1 CoW-vs-MoR small-frequent-delete findability` — CLOSES. Comparison reached cleanly on first re-probe under structurally different framing (Spark MERGE INTO + delete-files-accumulating + teammate-said-X). ~14th consecutive 1st-re-probe-CLOSE.

**NEW soft watches:**
- `iter1224 Q1 CoW-MoR scenario-diagnosis-when-symptom-implies-mode + compaction-not-mode-switch` — re-probe 4-8 iters under "I see delete files but engineer thinks they need a mode switch" framing. NOT a FIX-A on first occurrence (resources are correct; recall-ceiling synthesis slip). If recurs, very-light defang line at r13 §2996.

**Carry-forward open watches (no probe this iter):**
- `iter1223 Q3 packages.yml-install-canonical-gap` — re-probe 5-9 iters; FIX-A if recurs.
- `iter1223 Q4 GREATEST-Oracle-NULL-premise-slip` — recall-ceiling, no resource fix.
- `iter1215 strpos 3-arg synthesis ceiling` — no churn.
- `iter1213 session_properties + (+)-mnemonic` — light-monitor.
- `iter1222 CAST-DECIMAL/TRY_CAST` — light-monitor.
- `iter1221 Q1 quarterly-window-vs-transform-granularity diagnosis` — light-monitor.
- `iter1220 r10 transform-refinement-vs-column-addition cross-spec-pruning` — light-monitor.
- `iter1218 r28+r27 accepted_values-doesnt-catch-NULL FIX-A` — open FIX-A; re-probe under "ONE dbt test catches both NULL and unexpected literals" framing.
- `iter1214 retention_days param-fab + expire-vs-planning conflation` — CLOSED iter1218.
- `iter1208 width_bucket boundary off-by-one` — light-monitor.
- `iter1207 r13 §1293-1326 Spark-CALL-inline-tag` — light-monitor.
- `iter1206 LIKE-on-ROW + $partitions-omission` — CLOSED iter1222.

**Sources verified this iter:**
- [trino.io/docs/467/functions/regexp.html](https://trino.io/docs/467/functions/regexp.html) — `$g` numbered backreference + `${name}` named backreference syntax verbatim
- [docs.getdbt.com/docs/build/snapshots](https://docs.getdbt.com/docs/build/snapshots) — check strategy for tables without reliable `updated_at`; check_cols + optional updated_at
- [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) — `CROSS JOIN UNNEST(array) AS t(elem)` + `LEFT JOIN UNNEST(...) ON TRUE` empty-array form
- [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) — `$files.content` enum (0=DATA, 1=POSITION_DELETES, 2=EQUALITY_DELETES); `EXECUTE optimize` compaction
- [Dremio — Row-Level Changes on the Lakehouse: CoW vs MoR](https://www.dremio.com/blog/row-level-changes-on-the-lakehouse-copy-on-write-vs-merge-on-read-in-apache-iceberg/) — CoW rewrites entire file; MoR uses delete files
- [iceberglakehouse.com — Merge-on-Read in Iceberg](https://iceberglakehouse.com/iceberg/iceberg-merge-on-read/) — MoR position deletes accumulate; compaction is the fix

# Judge Score — Iter121 Q1

**Topic**: Iceberg Merge-on-Read (MoR) vs Copy-on-Write (CoW), diagnosing progressive query slowdown from delete-file accumulation
**Production stack**: On-prem k8s, Trino 467, Iceberg 1.5.2, Spark, MinIO, Hive Metastore

---

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 3 | One CRITICAL factual error (see below); rest is correct |
| Beginner clarity | 5 | Excellent — no unexplained jargon, concrete mental model |
| Practical applicability | 4 | Diagnostic SQL + remediation paths are runnable, but the wrong-default claim could waste engineer's time |
| Completeness | 4 | Covers both modes, detection, diagnosis, both remediation paths; misses `write.update.mode` / `write.merge.mode` which matter for an UPDATE-heavy workload |
| **Average** | **4.0** | PASSES (>= 3.5) |

---

## Verified against iceberg.apache.org / Iceberg 1.5.2 source

1. **`write.delete.mode` is the correct property name** — VERIFIED. Valid values: `copy-on-write`, `merge-on-read`. Settable via `ALTER TABLE ... SET TBLPROPERTIES(...)`.
2. **`content = 1` in `$files` = position delete files** — VERIFIED. Per the Iceberg spec, the `$files` metadata table `content` column uses: `0 = Data`, `1 = Position Deletes`, `2 = Equality Deletes`. The answer's SQL is correct.
3. **`delete-file-threshold` is a valid `rewrite_data_files` option** — VERIFIED. Also verified `target-file-size-bytes` and `min-input-files`. The answer's `CALL iceberg.system.rewrite_data_files(...)` invocation is syntactically and semantically correct, and the inline comment "rewrite any file with 1+ delete files" matches the documented behavior.
4. **MoR is the default for Iceberg 1.5.2** — **FALSE**. Verified from `apache/iceberg` tag `apache-iceberg-1.5.2`, `core/src/main/java/org/apache/iceberg/TableProperties.java`:

   ```java
   public static final String DELETE_MODE_DEFAULT = RowLevelOperationMode.COPY_ON_WRITE.modeName();
   public static final String UPDATE_MODE_DEFAULT = RowLevelOperationMode.COPY_ON_WRITE.modeName();
   public static final String MERGE_MODE_DEFAULT  = RowLevelOperationMode.COPY_ON_WRITE.modeName();
   ```

   The Iceberg library default for all three row-level operation modes (delete, update, merge) is **`copy-on-write`**, NOT `merge-on-read`. The answer states "Merge-on-Read (MoR) — the default on Iceberg 1.5.2" and later "you're probably running in MoR mode (the default)". Both are wrong at the library/spec level.

   Nuance: Some engines override this on the write path (e.g., Spark Iceberg session configs, certain catalog-level defaults), and the Trino Iceberg connector has its own session-level behavior, but at the Iceberg 1.5.2 table-property level a freshly created table is CoW unless someone explicitly set `write.delete.mode='merge-on-read'`. For Trino 467 specifically, Trino *can* write position deletes for v2 tables and frequently surfaces MoR semantics, but the framing "MoR is the default" misleads the diagnosis: the engineer's first reflex after reading this would be "of course we're in MoR, it's the default" rather than "someone on my team or in our table-creation template explicitly chose MoR — let me find out why."

---

## What the answer does well

- Mechanics description of MoR (write delete file -> read merges them) and CoW (rewrite full data file) is correct and uses a clean concrete example.
- The diagnostic flow — `SHOW CREATE TABLE` to check the property, then count `content = 1` rows in `$files` — is the right diagnostic loop and is runnable in Trino 467 against an Iceberg 1.5.2 table.
- Provides BOTH remediation paths: (a) stay in MoR and add `rewrite_data_files` with `delete-file-threshold=1` (correct option, correct semantics), (b) switch to CoW with `ALTER TABLE ... SET TBLPROPERTIES`. The note that switching only affects new writes (not existing files) is correct.
- The "where do you want to pay for it — on writes or on reads" framing is exactly the right mental model.
- Fits the prod stack: Trino for queries/diagnostics, Spark for `rewrite_data_files`, references MinIO storage. No off-stack tools recommended.
- Beginner clarity is genuinely strong — no orphaned jargon, the manifest/snapshot machinery is hidden behind the "delete file" metaphor.

## What needs to improve

1. **The "MoR is the default" claim is wrong and load-bearing.** This is the single biggest issue. The teacher should fix the resource to say: "In Iceberg 1.5.2 the library default for `write.delete.mode`, `write.update.mode`, and `write.merge.mode` is `copy-on-write`. MoR must be set explicitly, either at table creation time, via `ALTER TABLE`, or via an engine-level override (some Spark Iceberg session configs or catalog templates set it). If you're seeing delete-file accumulation, someone or some template explicitly chose MoR."
2. **The question is about UPDATEs but the answer only discusses `write.delete.mode`.** Iceberg has three separate properties: `write.delete.mode`, `write.update.mode`, and `write.merge.mode`. UPDATE statements go through `write.update.mode`, MERGE statements through `write.merge.mode`. For an UPDATE-heavy session-state-change workload, the engineer most likely needs to set ALL THREE (or at minimum `write.update.mode`) to control the mode. The current answer leaves them setting only `write.delete.mode`, which would NOT change the behavior of an `UPDATE` statement.
3. **Minor**: The answer says "from that point forward, each update is slower" — correct in direction, but for CoW with frequent small updates the cost can be enormous (rewriting a 256MB data file for a single-row change). Worth a one-line warning that CoW + frequent in-place updates can be pathologically bad, which is exactly why MoR exists.
4. **Minor**: No mention of `rewrite_position_delete_files` procedure, which is the targeted way to compact ONLY delete files without rewriting all data — useful when delete-file accumulation is the main pain but data files are already well-sized.

---

## Rubric topic updates

This question touches: **Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup** (current avg 4.640, 12 questions). Adding this 4.0 score: new avg = (4.640 * 12 + 4.0) / 13 = (55.68 + 4.0) / 13 = 59.68 / 13 = **4.591** over 13 questions. Status: still PASSED.

It also touches **Query performance regression diagnosis: oncall workflow for slow queries** (current avg 5.0, 2 questions). Adding 4.0: new avg = (5.0 * 2 + 4.0) / 3 = 14.0 / 3 = **4.667** over 3 questions. Status: still PASSED.

No new topic needs creation. Topic checklist remains fully PASSED.

---

## Recommended teacher actions (low priority — topic is already passing)

1. In whichever resource covers MoR vs CoW, correct the "default" statement. Cite the Iceberg 1.5.2 source: `DELETE_MODE_DEFAULT = COPY_ON_WRITE`. Note that engines/templates may override.
2. Add a note that `write.delete.mode` only controls DELETE statements; UPDATEs and MERGEs need `write.update.mode` and `write.merge.mode` respectively. For an UPDATE-heavy workload, set all three.
3. Optionally mention `rewrite_position_delete_files` as a lighter-weight compaction alternative when only delete files have accumulated.

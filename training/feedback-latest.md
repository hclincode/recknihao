# Judge Feedback — Iteration 542

## Overall verdict

**Per-question scores (Accuracy / Completeness / Clarity / Actionability)**:

| Q | Topic | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|---|
| Q1 | Switch Iceberg to CoW from Trino | 4.75 | 4.5 | 4.5 | 4.5 | **4.5625** |
| Q2 | `CURRENT_DATE - 7` vs INTERVAL | 4.75 | 4.5 | 4.75 | 4.75 | **4.6875** |
| Q3 | Expire snapshots + orphan files | 1.5 | 3.0 | 4.0 | 1.5 | **2.5** |
| Q4 | COMMENT ON TABLE syntax | 3.0 | 1.5 | 3.5 | 2.0 | **2.5** |

**Overall average = (4.5625 + 4.6875 + 2.5 + 2.5) / 4 = 3.5625 → PASS** (overall-average rule, per iter530-541 precedent).

Two questions sub-3.5 (Q3, Q4) materially drag the iteration. Headline iter543 fix is Q3.

---

## Q1 — Switch Iceberg table to CoW from Trino — **THE WIN**

**Score: 4.75 / 4.5 / 4.5 / 4.5 = 4.5625**

PROMINENT WIN: The iter541 Q3 fabrication (`SET PROPERTIES write_delete_mode = 'copy-on-write'` lifted from r28 L286 / r05 L3251) is GONE. Responder correctly stated:

1. Trino **cannot** flip the table to CoW from a Trino-side ALTER TABLE.
2. The properties are `write.delete.mode` / `write.update.mode` / `write.merge.mode` — three separate Iceberg-native properties, set from **Spark only** via `ALTER TABLE ... SET TBLPROPERTIES(...)`.
3. The Trino SET PROPERTIES allow-list does NOT include them — verifiable via the documented 15-property list.
4. Verification recipe: `SELECT key,value FROM "tbl$properties" WHERE key LIKE 'write.%.mode'` — pragmatic, correct.

VERIFIED at trino.io/docs/current/connector/iceberg.html (table-properties section lists exactly: format, format_version, partitioning, sorted_by, max_commit_retry, delete_after_commit_enabled, max_previous_versions, object_store_layout_enabled, data_location — none of write_delete_mode/delete_mode/write.*.mode appear). VERIFIED at trinodb/trino#17272: "Today Iceberg writes only support merge-on-read mode" — open feature request, NOT available on Trino 467. The teacher's iter542 r28/r05 reconciliation directly fed this correct answer.

**Minor nuance to note (light touch, not penalized heavily)**: The responder slightly implied that once the Spark side flips the property, all engines write CoW. The deeper truth is that **Trino's writer remains MoR even after the property flip** (#17272) — the property only takes effect on DML run FROM Spark. So even with the Spark property set, Trino-side MERGE/UPDATE/DELETE still produces delete files (MoR). Worth a one-sentence tightening in r28 §A's CoW-switch row — but not a correctness failure here.

---

## Q2 — `CURRENT_DATE - 7` vs INTERVAL

**Score: 4.75 / 4.5 / 4.75 / 4.75 = 4.6875**

Correct. `CURRENT_DATE - INTERVAL '7' DAY` is the canonical Trino 467 form. VERIFIED at trino.io/docs/current/functions/datetime.html — the documented examples are `date '2012-08-08' - interval '2' day`; there is no example of bare numeric subtraction, and Trino requires the explicit `INTERVAL '<value>' <unit>` form. `CURRENT_DATE - 7` returns a parse/type error on Trino (no operator(date, integer)).

The added guidance — explicit upper bound (`< CURRENT_DATE + INTERVAL '1' DAY`) and the `signed_up_at + INTERVAL '7' DAY` cohort-style example — is good SaaS-applicable hardening. Solid answer.

---

## Q3 — Expire snapshots + orphan files — **CRITICAL FABRICATION**

**Score: 1.5 / 3.0 / 4.0 / 1.5 = 2.5**

**VERIFIED VERDICT: The responder's `EXECUTE PROCEDURE iceberg.system.expire_snapshots(table => '...', retention_threshold => '7d')` syntax is INVALID Trino 467 — a classic Spark-CALL-vs-Trino-EXECUTE confusion, INVENTING a third form (`EXECUTE PROCEDURE`) that exists in neither Trino nor Spark.**

DOC EVIDENCE — trino.io/docs/current/connector/iceberg.html, table-procedures section, quoted verbatim:

> `ALTER TABLE test_table EXECUTE expire_snapshots(retention_threshold => '7d')`
> `ALTER TABLE test_table EXECUTE remove_orphan_files(retention_threshold => '7d')`

Both use the **`ALTER TABLE <tbl> EXECUTE <procedure>(args)`** form. There is no `EXECUTE PROCEDURE iceberg.system.*` form documented for Trino. (Spark uses `CALL catalog.system.expire_snapshots(table => '...', older_than => ..., retain_last => ...)` — that's the Spark surface, NOT Trino's.)

**r17 GREP RESULT — the canonical IS there, this is a responder findability/regeneration miss**:

r17 §1 maintenance-cookbook table (L20-25) explicitly contains:
```
| Snapshot expiry | ALTER TABLE iceberg.<schema>.<table> EXECUTE expire_snapshots(retention_threshold => '7d') | CALL iceberg.system.expire_snapshots(table => '<schema>.<table>', older_than => current_timestamp - interval '7' day, retain_last => 10) |
| Orphan-file sweep | ALTER TABLE iceberg.<schema>.<table> EXECUTE remove_orphan_files(retention_threshold => '7d') | CALL iceberg.system.remove_orphan_files(table => '<schema>.<table>', older_than => current_timestamp - interval '3' day, dry_run => true) |
```

r17 also has L144 explicitly warning: *"The single most common load-bearing inaccuracy is naming a Spark `CALL iceberg.system.<proc>` procedure as if it were a Trino `ALTER TABLE ... EXECUTE` form"* — and r17 L180: *"Mental model: if it's not in the Trino EXECUTE table or the Trino CALL table above, it's Spark-only on this stack."*

The responder invented a THIRD form — `EXECUTE PROCEDURE iceberg.system.<proc>` — which exists in NEITHER Trino NOR Spark and would fail at parse time. `EXECUTE PROCEDURE` is not a Trino statement keyword at all. (Trino has `EXECUTE <prepared_name>` for prepared statements only; the Iceberg-procedure surface is `ALTER TABLE ... EXECUTE <proc>(...)`.)

A grep of all resources/ confirms `EXECUTE PROCEDURE` appears in **zero files** — the responder did NOT lift this from any resource; it was hallucinated. This is regeneration drift on a topic where r17 has the correct form prominently in the first 25 lines.

Other parts of the answer (default 7d retention, branch/tag protection of snapshots, weekly off-ingestion schedule) are correct framing — that's why Completeness/Clarity score moderately. But the **invocation syntax — the entire load-bearing payload of the question — is wrong**. An engineer pasting that into Trino gets `mismatched input 'PROCEDURE'`. Accuracy and Actionability scored low accordingly.

**HEADLINE iter543 FIX (Q3):**
- r17 already has the correct canonical at L20-25 and the warning at L144/L180. The fix is responder-findability: ensure the keyword phrases "expire_snapshots in Trino", "remove_orphan_files in Trino", "cleanup old snapshots Trino" route to L20-25 directly. Add an additional EXPLICIT DO-NOT-WRITE row in r17 banning `EXECUTE PROCEDURE iceberg.system.<proc>(...)` as a Trino form (with the parse-error explanation) — current r17 anti-patterns cover the Spark-CALL-pasted-into-ALTER form, but NOT the `EXECUTE PROCEDURE` form specifically. The responder just invented a brand-new wrong variant.
- Recommended new r17 row text: *"`EXECUTE PROCEDURE iceberg.system.expire_snapshots(table => '...', retention_threshold => '7d')` — INVALID Trino. `EXECUTE PROCEDURE` is not a Trino statement keyword (Trino's `EXECUTE` is for prepared statements only); the documented form is `ALTER TABLE <tbl> EXECUTE expire_snapshots(retention_threshold => '7d')`. The Spark form is `CALL iceberg.system.expire_snapshots(...)`. Pasting `EXECUTE PROCEDURE` fails at parse time. Quote: trino.io/docs/current/connector/iceberg.html."*

---

## Q4 — COMMENT ON TABLE syntax — **honest decline, but findability miss**

**Score: 3.0 / 1.5 / 3.5 / 2.0 = 2.5**

The responder declined ("I don't have enough information... resources show COLUMN comments + dbt persist_docs but not the table-level COMMENT syntax"). The honest decline avoided fabrication — Accuracy scored moderately for not inventing wrong syntax. But:

1. **Trino DOES support `COMMENT ON TABLE` and `COMMENT ON COLUMN`** — VERIFIED at trino.io/docs/current/sql/comment.html:
   > `COMMENT ON ( TABLE | VIEW | COLUMN ) name IS 'comments'`
   > Examples: `COMMENT ON TABLE name IS 'comments'` / `COMMENT ON COLUMN name IS 'comments'` / set to NULL to remove.

2. **r27 §6.7J ALREADY references both `COMMENT ON TABLE` and `COMMENT ON COLUMN`** — at L3165 (section title) and L3192 (the §6.7H-vs-§6.7J comparison row). GREP confirms one resource file contains the phrase. So this is a **findability miss**, not a true content gap — r27 mentions the SQL but only in the context of dbt persist_docs, not as a standalone "how do I write a TABLE comment" section anchored to the keyword "TABLE comment Trino syntax".

3. The responder's recommended next step (check trino.io alter-table docs) is mildly off — `COMMENT` is its own DDL statement (`/sql/comment.html`), NOT a subform of `ALTER TABLE`. That's a wrong pointer — Completeness/Actionability penalty.

**HEADLINE iter543 FIX (Q4):**
- Add an EXPLICIT canonical block in r17 (or r27, but r17 is the better home since it covers Iceberg-side table DDL the responder routes to) titled "COMMENT ON TABLE / COMMENT ON COLUMN — Trino canonical syntax" with the bare keyword anchors. Suggested body:
  ```
  -- Add or update a table comment
  COMMENT ON TABLE iceberg.analytics.events IS 'Click-stream events fact table';
  -- Add or update a column comment
  COMMENT ON COLUMN iceberg.analytics.events.user_id IS 'Tenant-scoped user identifier';
  -- Remove a comment
  COMMENT ON TABLE iceberg.analytics.events IS NULL;
  ```
  Quote: trino.io/docs/current/sql/comment.html. Note that on Iceberg these persist as the Iceberg `doc` field on the table/column schema, visible via `SHOW COLUMNS` and the `$properties` surface, AND get picked up by dbt's `persist_docs: relation/columns: true` (cross-ref to r27 §6.7J).
- Add keyword anchors: "add table comment Trino", "update table description Trino", "COMMENT ON TABLE syntax", "Iceberg table description Trino".

---

## Iter543 next-teacher actions (prioritized)

1. **HIGH — Q3 fab fix**: Add explicit DO-NOT-WRITE row in r17 banning `EXECUTE PROCEDURE iceberg.system.<proc>(...)` as a Trino form with the parse-error consequence. Cross-ref the existing L20-25 canonical and L144/L180 mental-model warnings. Stress keyword anchors so the responder routes to the correct `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` form.
2. **HIGH — Q4 gap**: Add a standalone canonical block (in r17, with cross-ref from r27 §6.7J) for `COMMENT ON TABLE` and `COMMENT ON COLUMN`. Include the NULL-to-remove form, the Iceberg `doc` field persistence note, and keyword anchors. This is a small surgical add — Trino docs are unambiguous.
3. **LOW — Q1 nuance tighten**: One sentence in r28 §A's CoW-switch row clarifying that even after Spark sets `write.delete.mode='copy-on-write'`, Trino's writer remains MoR (#17272) — the Spark-side property only takes effect on DML run FROM Spark. The responder's framing was correct on the Trino-side ban but slightly soft on "what if I set it from Spark — will Trino respect it for its own writes?". Light touch.
4. **MAINTAIN**: Federation row at 4.49944/310 — untouched per directive. r22 §13.x — untouched per directive.

---

## Verification log

- trino.io/docs/current/connector/iceberg.html — quoted maintenance-procedure form `ALTER TABLE <tbl> EXECUTE expire_snapshots(retention_threshold => '7d')`; quoted property list (no write_delete_mode/delete_mode).
- trino.io/docs/current/sql/comment.html — quoted `COMMENT ON ( TABLE | VIEW | COLUMN ) name IS 'comments'`.
- trino.io/docs/current/functions/datetime.html — confirmed INTERVAL form required; no bare-integer subtraction example.
- trinodb/trino#17272 — quoted "Today Iceberg writes only support merge-on-read mode"; OPEN feature request.
- r17 L20-25 (correct canonical present) + L144/L180 (mental-model warnings present).
- r27 §6.7J L3165/L3192 (COMMENT ON TABLE/COLUMN referenced in dbt persist_docs context).
- `grep "EXECUTE PROCEDURE" resources/` → zero matches (Q3 fabrication confirmed; NOT lifted from any resource).

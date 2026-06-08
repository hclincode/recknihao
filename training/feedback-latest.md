# Judge Feedback — iter721 (EXTENDED PHASE)

**OVERALL: 4.9375 STRONG PASS** (per-Q avg (5.00+5.00+5.00+4.75)/4 = 19.75/4 = 4.9375; sub-score-sum 79/16 = 4.9375; dim-avg Acc(5+5+5+5)/4=5.00 / Comp(5+5+5+4)/4=4.75 / Clar(5+5+5+5)/4=5.00 / Act(5+5+5+5)/4=5.00 → 4.9375 — all three agree). Margin +1.4375 above the 3.5 floor. OVERALL AVERAGE governs per directive — no per-Q veto.

All four answers verified against trino.io/docs/467 (Iceberg connector metadata tables; datetime functions; SELECT/UNNEST grammar). ZERO dialect defects.

---

## Per-question scores

### Q1 — Iceberg version lineage ($history / $snapshots) — 5.00 (Acc5/Comp5/Clar5/Act5)
VERIFIED [trino.io/docs/467/connector/iceberg.html]. `$history` columns exactly match docs: `made_current_at` (TIMESTAMP(3) WITH TIME ZONE), `snapshot_id` (BIGINT), `parent_id` (BIGINT), `is_current_ancestor` (BOOLEAN). Column glosses all correct. `$snapshots` companion query (snapshot_id/committed_at/operation/summary) correct; summary is map(VARCHAR,VARCHAR). Whole-token-one-quote-pair rule (`"events$history"`, NOT `events."$history"`) correct. The lineage answer that Q1 actually asked is bulletproof: $history with parent_id chain + is_current_ancestor is exactly the "which version came from which / which is live" answer.

**rollback parenthetical mis-attribution — MINOR ACCURACY NIT (does NOT lower the score):** The responder labeled `CALL iceberg.system.rollback_to_snapshot` as "(Spark)". VERIFIED against [trino.io/docs/467/connector/iceberg.html]: the CALL form `CALL <catalog>.system.rollback_to_snapshot('schema','table',snapshot_id)` IS the documented, correct Trino 467 syntax (the `ALTER TABLE ... EXECUTE rollback_to_snapshot` form is 469+). So the "(Spark)" label is technically incorrect — that exact CALL form is native Trino 467. However, per directive this is a parenthetical aside, not the asked-about lineage answer, and the responder still pointed the engineer at the right procedure + "your team's rollback procedure" + the parent_id chain. Weighed as a non-scoring nit. This matches MEMORY [reference_trino_rollback_snapshot_form.md] — CALL is Trino-467-valid; ALTER TABLE EXECUTE is 469+.

### Q2 — MAP-explode (attributes → one row per key) — 5.00 (Acc5/Comp5/Clar5/Act5)
VERIFIED [trino.io/docs/467/sql/select.html] verbatim "Maps are expanded into two columns (key, value)". `CROSS JOIN UNNEST(attributes) AS t(attribute_key, attribute_value)` — TWO aliases for the two produced columns — is docs-correct. GROUP BY attribute_key counts each key. CROSS JOIN UNNEST in FROM before WHERE noted. Keys-only alternative `UNNEST(map_keys(attributes)) AS t(key)` — VERIFIED map_keys returns array(K), so a single-alias UNNEST of an ARRAY produces ONE column = ONE alias = valid. NO single-alias-dot-access regression, NO arity error.

**MAP-explode FIX-A (iter720) STAYS CLOSED.** This is the second clean re-probe from a fresh framing (iter720 = preferences map; iter721 = attributes map). The single-alias-dot-access form from iter719 did not recur. The r07 §1a leading canonical + co-located defang is holding across distinct phrasings.

### Q3 — epoch-millis → timestamp — 5.00 (Acc5/Comp5/Clar5/Act5)
VERIFIED [trino.io/docs/467/functions/datetime.html]: from_unixtime(unixtime) takes SECONDS (numeric) and returns timestamp(3) with time zone. `1e3` is a valid double literal in Trino, so `event_timestamp_ms / 1e3` is double division that PRESERVES fractional (sub-second) precision; integer `/1000` on a bigint would truncate the millisecond remainder. The /1e3 idiom is correct. CONFIRMED: Trino has `from_unixtime_nanos` (nanoseconds → timestamp(9) with tz) but NO native `from_unixtime_millis`, so the /1e3-into-from_unixtime approach is the documented idiom for millis. date_trunc('day', ...) wrapping for date grouping correct. to_unixtime reverse correct. No defect.

### Q4 — $files / $partitions storage layout — 4.75 (Acc5/Comp5/Clar5/Act4)
VERIFIED [trino.io/docs/467/connector/iceberg.html]: `$files` has `file_path` (VARCHAR), `file_size_in_bytes` (BIGINT), `record_count` (BIGINT) — all three used correctly. `$partitions` has `partition` (ROW), `record_count` (BIGINT), `file_count` (BIGINT), `total_size` (BIGINT) — all four used correctly. Whole-token-one-quote-pair rule applied. Aggregate SUM/COUNT/AVG/MAX over $files is exactly the right "how many files, how big" answer with no separate tracking table. Minor Act ding only: a one-line note that `partition` is a ROW (so per-partition output shows a struct column) would have pre-empted a likely follow-up; purely additive, nothing wrong.

---

## Resolution of prior flags

- **iter720 Q3 completeness flag (omitted $history for version-lineage phrasing): RESOLVED.** The iter721 $history cross-ref worked — the responder led with `$history` (made_current_at/snapshot_id/parent_id/is_current_ancestor) for the lineage question and offered `$snapshots` as the operation-metadata companion. The "$history=lineage/current-ancestor vs $snapshots=per-commit-operation" router landed. Q1 scored 5.00 (vs iter720 Q3's 4.75 Comp-dinged). Cross-ref CLOSED.
- **MAP-explode FIX-A (Q2): STAYS CLOSED** (second clean re-probe, fresh framing).

---

## iter722 flags / teacher directive

- **NO FIX-A required.** No dialect defect in any answer; all forms valid Trino 467.
- **OPTIONAL minor durability nudge (NOT required for PASS):** At the r17 rollback_to_snapshot card, confirm the responder's source content labels the `CALL ...rollback_to_snapshot` form as the **Trino 467 native** form (NOT "Spark"). The iter668 rollback CALL-form lock is correct in resources, but the responder emitted a "(Spark)" parenthetical — if r17 contains any phrasing that could lead the responder to associate CALL with Spark, tighten it so CALL is unambiguously labeled Trino-467-native (ALTER TABLE EXECUTE = 469+). This is the only thing approaching a gap, and it's a non-scoring parenthetical. If it does not recur on a rollback-focused re-probe, take no action (one occurrence is within noise). Consider a rollback-procedure-focused probe in iter722 to confirm the CALL-form attribution holds.
- HOLD all iter534-720 locks (~269 across 17 resource files). HOLD iter668 rollback CALL-form lock, iter720 MAP-explode r07 §1a canonical, iter721 $history cross-ref.
- Federation (r22) NOT probed this iter (4.49944 vs 4.5 thin) — row UNCHANGED, untouched.
- Do NOT bump state.json (orchestrator handles).

# Judge Feedback — iter720

**Verdict: PASS** — overall avg **4.94/5**

All four answers verified against trino.io/docs/467 (NOT against resources/). Every dialect claim is docs-correct. Production-stack fit confirmed (Trino 467 + Iceberg connector + Hive Metastore on-prem).

---

## Per-question scores

### Q1 — MAP-explode FIX-A re-probe (preferences map → one row per key/value)
| Dim | Score | Note |
|---|---|---|
| Accuracy | 5 | `CROSS JOIN UNNEST(preferences) AS t(pref_key, pref_value)` — TWO aliases. Docs verbatim: "Maps are expanded into two columns (key, value)." Docs-correct. No single-alias-dot-access form. |
| Completeness | 5 | Covers the 2-alias rule, the parse-error trap, AND CROSS-JOIN-drops-empty/NULL vs LEFT-JOIN-UNNEST-ON-TRUE-preserves — directly answers the count-by-preference goal. |
| Clarity | 5 | Plain language, runnable example tied to the user's exact preferences scenario. |
| Actionability | 5 | Copy-paste-ready against `iceberg.analytics.users`; GROUP BY pref_key,pref_value matches the stated counting intent. |
**Q1 avg: 5.00**

**FIX-A VERDICT: CLOSED.** The responder used the docs-correct 2-alias form `CROSS JOIN UNNEST(preferences) AS t(pref_key, pref_value)`, explicitly flagged single-alias as a parse error, and did NOT regress to the iter719 single-alias-dot-access (`AS t(x) ... x.key`) arity-error form. Verified against trino.io/docs/467/sql/select.html. The iter720 r07 §1a leading canonical + co-located defang did its job.

### Q2 — substr preview (first 50 chars)
| Dim | Score | Note |
|---|---|---|
| Accuracy | 5 | `substr(col,1,50)` / `substring(col,1,50)`; substr IS an alias; 1-indexed; negative start from end. All four facts docs-confirmed. |
| Completeness | 5 | Both names, both arg semantics, plus the negative-start bonus fact. |
| Clarity | 5 | Direct, matches the "first 50 chars" ask exactly. |
| Actionability | 5 | Runnable preview query. |
**Q2 avg: 5.00**

### Q3 — Iceberg snapshot history
| Dim | Score | Note |
|---|---|---|
| Accuracy | 5 | `"events$snapshots"` whole token in one quote-pair (docs-correct quoting). Columns snapshot_id/committed_at/operation/summary(map) all confirmed for 467. $files/$partitions descriptions correct. |
| Completeness | 4 | Answers the core fully. Minor: did not mention `$history` (made_current_at/is_current_ancestor) — the more direct "versions / lineage" table for the user's "what versions exist" sub-question. Not wrong, just one adjacent table omitted. |
| Clarity | 5 | Clear; explains the quoting rule plainly. |
| Actionability | 5 | Runnable; ORDER BY committed_at DESC gives newest-first history. |
**Q3 avg: 4.75**

### Q4 — ceil round-up
| Dim | Score | Note |
|---|---|---|
| Accuracy | 5 | `ceil`/`ceiling` round up (alias confirmed); floor down; round nearest. Docs-correct. |
| Completeness | 5 | Answers the round-up ask and contrasts floor/round. |
| Clarity | 5 | Trivially clear, matches the decimal-GB example. |
| Actionability | 5 | Runnable. |
**Q4 avg: 5.00**

---

## Overall

| Q | Avg |
|---|---|
| Q1 | 5.00 |
| Q2 | 5.00 |
| Q3 | 4.75 |
| Q4 | 5.00 |
| **OVERALL** | **4.94** |

**PASS** (>= 3.5; overall-average governs, no per-Q override).

## iter721 flags
- **No genuine dialect defect.** All forms valid Trino 467.
- **Minor durability nudge (NOT a fail):** Q3 omitted the `$history` metadata table. The user asked "what versions exist" — `$history` (made_current_at, snapshot_id, parent_id, is_current_ancestor) is the canonical lineage/version table and pairs with `$snapshots`. Teacher could add a one-line cross-ref in r17 so a future "versions/lineage" phrasing surfaces `$history` alongside `$snapshots`. Probe Q3 from a "table lineage / which snapshot is the current ancestor" angle in iter721 to confirm `$history` surfaces.
- MAP-explode is now a strong PASS at the FIX-A canonical; re-probe once more from a different phrasing (e.g. JSON-cast map, or LEFT JOIN preserve-empty emphasis) before treating it as bulletproofed.

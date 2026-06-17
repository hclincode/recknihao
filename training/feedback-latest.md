# Judge Feedback — iter1018

**OVERALL: 4.71875 (75.5/16) — PASS** (threshold 3.5; margin +1.21875). OVERALL AVERAGE governs — no per-Q veto.

Verification done BOTH directions against trino.io/docs/467 (functions/string.html, functions/aggregate.html, functions/regexp.html, language/types.html) + WebSearch — NOT resources/. Prod stack (Trino 467 + Iceberg + Hive Metastore + MinIO, on-prem k8s) — all 4 questions are pure SQL-dialect, fit cleanly; no federation/auth angle exercised.

---

## Per-question scores

### Q1 — events(target_url) contains 'app.' / position: strpos vs LIKE — 4.8125 CLEAN
- **Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75**
- VERIFIED (string.html): `strpos(string, substring) -> bigint`, "Positions start with 1. If not found, 0 is returned." 3-arg `strpos(string, substring, instance)` returns the N-th occurrence (negative instance searches from end). All exactly as the responder stated.
- `WHERE strpos(target_url,'app.') > 0` as a contains-test = correct. Responder correctly says strpos is NOT inherently faster than LIKE for a pure contains check (both scan; neither prunes on a non-partition substring predicate), and to reach for strpos only when you need the position — accurate, no OLTP-index folklore.
- 3-arg N-th-occurrence form correctly cited.

### Q2 — subscriptions(status) case-insensitive match — 4.75 CLEAN
- **Acc 5 / Comp 4.5 / Clar 4.75 / App 4.75**
- VERIFIED: `WHERE LOWER(status) = 'active'` (both sides lowered) = the canonical Trino 467 case-insensitive equality. Responder correctly states there is **no native ILIKE in Trino 467** (ILIKE is PostgreSQL-connector pushdown only — matches hard-locked r23 §3257 / r22 §13.x disambiguation and the no-native-ILIKE memory). `regexp_like(status,'(?i)^active$')` alternative VERIFIED (regexp.html: "Case-insensitive matching (enabled via the (?i) flag) is always performed in a Unicode-aware manner"); `^...$` anchors make it an exact match. No false "ILIKE-via-session-property" mechanism invented (watch-item (h) resolved in responder's favor).

### Q3 (KEY re-probe) — device_readings: ONE row per device = its most recent metric_value — 4.71875 CLEAN
- **Acc 5 / Comp 4.75 / Clar 4.625 / App 4.75**
- **iter1017 slip CONFIRMED ONE-OFF — did NOT recur.** Form 1: `ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY recorded_at DESC) AS rn` in a subquery, outer `WHERE rn=1` → returns exactly one row per device, the latest by recorded_at. CORRECT and standard (no DISTINCT ON in Trino; QUALIFY not in 467 — responder correctly used the subquery+WHERE form, not QUALIFY).
- Form 2: `max_by(metric_value, recorded_at) GROUP BY device_id` — VERIFIED (aggregate.html: "Returns the value of x associated with the maximum value of y over all input values"), one row per device, the metric_value at the max recorded_at. Correct single-column shortcut.
- **Critically, the responder did NOT repeat the iter1017 mistake** (which on a LAST_VALUE question wrongly prescribed a look-BACK frame `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` that returns the current row instead of the partition-latest). Here the responder uses two unambiguously-correct partition-latest patterns. The iter1017 (m) most-recent-per-group slip is confirmed a one-off; responder now uses max_by + ROW_NUMBER-DESC correctly. Carried verified fact (max_by(x,ts) OR ROW_NUMBER DESC = most-recent-per-group) holds.

### Q4 — support_tickets(is_escalated boolean): count escalated per month; SUM(is_escalated) errors — 4.625 CLEAN
- **Acc 4.75 / Comp 4.5 / Clar 4.75 / App 4.5**
- VERIFIED: `SUM(CAST(is_escalated AS integer))` — boolean→integer cast is supported (types.html confirms casting among boolean/integer/bigint types); true→1, false→0 is standard Trino/Presto semantics. SUM accepts numeric, not boolean, so `SUM(is_escalated)` on a raw boolean is a type error — responder correctly diagnoses the user's error.
- `count_if(is_escalated)` VERIFIED (aggregate.html: "Returns the number of TRUE input values. Equivalent to count(CASE WHEN x THEN 1 END)") — exists, idiomatic, same result as the CAST+SUM. Both correctly grouped per month. Responder correctly calls count_if the idiomatic choice.
- Sole nit (not a defect): no explicit note about NULL is_escalated handling is immaterial here (both CAST+SUM and count_if skip NULL); light Acc trim only.

---

## TICS / defects
- `::` cast shorthand ABSENT all 4 (double-lock r23 §3.1C + r27 §4.4A holds).
- No QUALIFY, no false-semi-join, no fabricated function (strpos/max_by/count_if/regexp_like all real & verified), no regex-backslash slip, no INTERVAL quarter/week, no OFFSET-before-LIMIT, no generate_subscripts/generate_series PG-series slip, no broken-secondary "for completeness" alternative.
- **Q3: the iter1017 look-back-frame mistake did NOT recur — confirmed one-off.**

## Recommendation: DEFAULT NO-OP
Margin +1.21875; all 4 correct and verified both directions; KEY Q3 re-probe confirms the iter1017 most-recent-per-group slip was a one-off (responder now uses max_by + ROW_NUMBER-DESC correctly). No source-verified findable gap, no resource defect, no 2-in-2 recurrence. NO resource edit; NO FIX-A; NO git commit (consistent with iter1001-1017 clean NO-OPs).

Re-probe (monitor only): (a) most-recent-per-group — max_by / ROW_NUMBER-DESC lead holds, watch any look-back-frame relapse; (b) case-insensitive LOWER()=LOWER() + no-native-ILIKE + (?i) flag; (c) boolean→int SUM(CAST) / count_if; (d) strpos position vs LIKE contains. Federation r22 §13.x hard-locked NOT probed (stays 4.49944/310). MUST NOT bump state.json (already 1018; orchestrator commits).

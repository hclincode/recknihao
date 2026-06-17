# Judge Feedback — iter1008

**OVERALL: 4.7734 (76.375/16) — PASS** (margin +1.2734; OVERALL AVERAGE governs, no per-Q veto).

Verified BOTH directions vs trino.io/docs/467 (sql/select.html, functions/comparison.html) + WebSearch on Trino optimizer semi-join decorrelation — NOT against resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark + dbt) — all 4 fit; no federation/auth angle.

---

## Per-question scores

### Q1 — pagination page 4 @25/page, ORDER BY signup_date DESC, "same as Postgres?" — 4.625 ★PAGINATION FIX HELD
- Acc 4.5 / Comp 4.75 / Clar 4.5 / App 4.75
- ★ **The responder NOW produces the CORRECT OFFSET-before-LIMIT form:** `SELECT user_id, signup_date FROM users ORDER BY signup_date DESC OFFSET 75 LIMIT 25;` — VERIFIED valid against the Trino 467 SELECT synopsis (sql/select.html): clause order `[ORDER BY ...] [OFFSET count [ROW|ROWS]] [LIMIT {count|ALL}]` — OFFSET comes after ORDER BY and BEFORE LIMIT. Responder explicitly states "OFFSET comes before LIMIT in clause order." CORRECT.
- ★★ **This is the 3rd consecutive pagination probe** after the iter1006 r27 L1912 FIX-A and the iter1007 r23 anti-patterns-table-row FIX-A. iter1006 Q4 and iter1007 Q1 BOTH produced the WRONG `LIMIT n OFFSET m` parse-error form (2-in-2). This iter the responder produces the correct `OFFSET 75 LIMIT 25`. **The findability fix appears to have WORKED** — the r23 anti-patterns card (OFFSET m LIMIT n, Page 4 @25/page) now reaches the responder.
- MINOR nit (the only ding): responder prose says "syntax is the same as Postgres / identical to Postgres." This is imprecise — Postgres accepts BOTH `LIMIT 25 OFFSET 75` AND `OFFSET 75 LIMIT 25`; Trino 467 accepts ONLY the OFFSET-first form (LIMIT-first is a parse error `mismatched input 'OFFSET'`). So the clause-order constraint IS a genuine PG→Trino difference, and "same as Postgres" undersells it. NOT a parse-error defect — the SQL produced is correct — so only a light Acc/Clar deduct, not a sink.
- Good bonus: "LIMIT alone does not reduce scan cost; pair with a WHERE that prunes files/partitions" — correct Iceberg cost-model framing.

### Q2 — combine subscriptions + legacy_subscriptions; auto-dedup or manual? — 4.8125 CLEAN
- Acc 5.0 / Comp 4.75 / Clar 4.75 / App 4.75
- VERIFIED (sql/select.html set operations): "If ALL is specified all rows are included even if rows are identical. If DISTINCT is specified only unique rows are included. If neither is specified, the behavior defaults to DISTINCT." Responder's "UNION ALL keeps duplicates; bare UNION = UNION ALL + DISTINCT (dedupes, costs extra CPU/IO)" is fully correct, including the default-DISTINCT semantics and the extra-cost caveat. Option1 (UNION ALL keep) vs Option2 (UNION dedupe) decision guidance is actionable and correct.

### Q3 — largest of amount_usd/discount_usd/credit_usd per row — 4.84375 CLEAN
- Acc 5.0 / Comp 4.75 / Clar 4.875 / App 4.75
- VERIFIED (functions/comparison.html greatest/least): "Like most other functions in Trino, they return null if any argument is null." Responder's "greatest() returns NULL if ANY arg is NULL; wrap each in coalesce(col, 0) (or a domain-safe default)" is fully correct — and correctly NOT the Postgres all-null rule. The COALESCE-wrap workaround is exactly right. The "domain-safe default" hedge is a thoughtful touch (0 may be wrong if negatives are possible). Matches the GREATEST/LEAST-NULL memory card.

### Q4 — accounts with >=1 ticket, each once, no GROUP BY / subquery dedup — 4.8125 CLEAN
- Acc 5.0 / Comp 4.75 / Clar 4.75 / App 4.75
- Responder gives both `WHERE EXISTS (SELECT 1 FROM support_tickets t WHERE t.account_id=a.account_id)` and `WHERE x IN (subquery)`, both correctly described as executing as a semi-join, returning each account once even with 50 tickets, no GROUP BY needed. VERIFIED conceptually against Trino optimizer behavior (subquery decorrelation → semi-join; EXISTS and IN both transform to semi-join). "Both equally fast, EXISTS slightly more readable" correctly AVOIDS the "EXISTS is faster" folklore. Clean.

---

## TICS / defects
- `::` PostgreSQL cast ABSENT all 4 (iter1003 one-off did not recur; ban double-locked r23 §3.1C + r27 §4.4A, not exercised).
- No QUALIFY / false-semi-join-mechanism / MAX-varchar / GREATEST-LEAST-NULL-inversion / fabricated-fn / broken-secondary / INTERVAL-quarter-week / regex-backslash.
- Sole nit = Q1 "same as Postgres" prose imprecision (minor clarity/accuracy, NOT a parse-error defect — SQL produced is correct).

## RECOMMENDATION = DEFAULT NO-OP
- Margin +1.2734; all 4 deliverables correct & verified both directions; zero parse-error defects this iter.
- ★ **Pagination OFFSET-before-LIMIT FIX HELD** — 3rd consecutive probe, responder now produces the correct form after the two FIX-As (iter1006 r27 L1912 + iter1007 r23 anti-patterns row). The 2-in-2 wrong-direction streak (iter1006+1007) is BROKEN. No further pagination edit needed.
- NO resource edit; NO FIX-A.
- Re-probe next sweep: (a) ONE more pagination Q to confirm the fix is durable across phrasings (3rd-correct → watch for regression, do not churn); (b) another UNION dedup Q — confirm default-DISTINCT framing; (c) another greatest/least multi-column Q — confirm any-NULL→NULL + COALESCE-wrap; (d) another EXISTS/IN semi-join Q — confirm no "EXISTS faster" folklore. Federation r22 §13.x hard-locked NOT probed (stays 4.49944/310).
- MUST NOT bump state.json (already 1008; passed=true; orchestrator commits).

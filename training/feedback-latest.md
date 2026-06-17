# Judge Feedback — iter1030

**OVERALL: 4.78125 (76.5/16) — PASS** (threshold 3.5; margin +1.28125; OVERALL AVERAGE governs, no per-Q veto)

Verified BOTH directions vs trino.io/docs/467 (functions/string.html starts_with-EXISTS-literal-prefix / ends_with-ABSENT; functions/comparison.html LIKE `_`=single-char-wildcard / `%`=zero-or-more / ESCAPE-clause-for-literal / GREATEST-LEAST return-NULL-if-any-arg-NULL) — NOT resources/. Prod stack (Trino 467 + Iceberg + MinIO, Hive Metastore) all 4 fit; no federation/auth angle.

---

## Per-question scores

### Q1 — literal `promo_` prefix (KEY — FIX-A re-probe) — 4.8125 CLEAN ✅ FIX-A CONFIRMED
- **LEAD `starts_with(promo_code, 'promo_')` CORRECT/safest** — string.html "Tests whether substring is a prefix of string", literal match, NO wildcard interpretation. The literal underscore in the prefix string is matched literally.
- **Responder now EXPLICITLY warns `LIKE 'promo_%'` is WRONG** — comparison.html: `_` "matches any single character" (single-char WILDCARD), so bare `LIKE 'promo_%'` matches "promo" + ANY-one-char + rest (e.g. "promoXanything", "promoZcode") — does NOT require a LITERAL underscore as the 6th char.
- **Escaped alternative `LIKE 'promo\_%' ESCAPE '\'` CORRECT** — ESCAPE clause confirmed comparison.html; escapes `_` to a literal underscore.
- **iter1028/1029 LIKE-underscore misconception appears RESOLVED.** The iter1029 §651/§653 FIX-A (literal-`_`/`%`-prefix caveat at the starts_with/prefix card) reached the responder: where iter1028 Q2 used bare `LIKE 'ff_%'` as the predicate (3.875) and iter1029 Q1 appended `LIKE 'ff_%'` "works equally well" (4.0 defect, 2-in-2), iter1030 Q1 now (a) leads with `starts_with`, (b) actively flags bare `LIKE 'promo_%'` as wrong with the correct underscore-wildcard reason, and (c) offers the correct ESCAPE form. No relapse.
- Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75

### Q2 — device_type value-frequency — 4.75 CLEAN ✅
- `SELECT device_type, COUNT(*) AS row_count ... GROUP BY device_type ORDER BY row_count DESC` — textbook value-counts. GROUP BY collapses to one row per device_type; COUNT(*) counts rows per group; ORDER BY ... DESC ranks most-frequent first. Correct and idiomatic.
- Acc 5 / Comp 4.5 / Clar 4.75 / App 4.75

### Q3 — GREATEST across columns + NULL caveat (KEY) — 4.8125 CLEAN ✅
- `GREATEST(usd_amount, eur_amount, gbp_amount)` across columns CORRECT — comparison.html, row-wise max of the args.
- **Caveat "GREATEST returns NULL if ANY arg is NULL" VERIFIED** — comparison.html "they return null if any argument is null" (Trino, like Oracle/MySQL/BQ); Postgres-contrast (PG ignores NULLs) correct. On a deals row with one populated + two NULL columns, bare GREATEST returns NULL — so the **COALESCE-wrap (COALESCE(col,0)) to floor NULLs is genuinely needed** to get "largest of the populated". Responder correctly diagnosed this and gave the wrap. Matches reference_trino_greatest_least_null.md.
- Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75

### Q4 — UNION ALL two labeled counts — 4.75 CLEAN ✅
- `SELECT 'mobile' AS device_type, COUNT(*) ... WHERE device_type='mobile' UNION ALL SELECT 'desktop', COUNT(*) ... WHERE device_type='desktop' ORDER BY device_type` — two stacked labeled scalar-count rows. Correct.
- **UNION ALL no-dedup** correct (keeps all rows, cheaper, no DISTINCT pass). ORDER BY applies to the WHOLE UNION result (trailing, after the final branch) — correct. GROUP BY alternative for many types is the right scaling note.
- Acc 5 / Comp 4.5 / Clar 4.75 / App 4.75

---

## TICS check
CLEAN all 4 — no QUALIFY, no false semi-join, no fabricated function (starts_with real & literal; GREATEST real; ends_with correctly ABSENT), no regex-backslash slip, no INTERVAL quarter/week, no OFFSET-before-LIMIT, no generate_subscripts, no broken "for completeness" secondary alternative. `::` cast ABSENT all 4.

## Defects
NONE. All 4 fully correct and verified both directions.

## Recommendation — DEFAULT NO-OP
Margin +1.28125; all 4 clean; both KEY questions resolved in the responder's favor. **The iter1029 §651/§653 LIKE-underscore FIX-A is CONFIRMED WORKING** — the responder now leads with starts_with AND proactively warns bare `LIKE 'promo_%'` is wrong (underscore = single-char wildcard) AND offers the ESCAPE form. The 2-in-2 literal-prefix recurrence is broken. NO resource edit; NO new FIX-A; NO git commit (orchestrator commits).

Re-probe (monitor only): (a) literal-`_`/`%`-prefix — FIX-A confirmed working iter1030, downgrade to passive monitor; (b) GREATEST/LEAST NULL-if-any-NULL + Postgres-contrast + COALESCE-wrap; (c) GROUP-BY value-counts ORDER BY DESC; (d) UNION ALL no-dedup + trailing-ORDER-BY-on-whole-result + GROUP-BY-scaling-alternative.

Federation r22 §13.x hard-locked NOT probed (stays 4.49944/310). MUST NOT bump state.json (already 1030; orchestrator commits).

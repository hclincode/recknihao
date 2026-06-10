# Judge Feedback — iter931 (re-probe sweep)

**Overall: 5.00 STRONG PASS** (Q1 5.00 / Q2 5.00 / Q3 5.00 / Q4 5.00 = 20.00/4). OVERALL AVERAGE governs — no per-Q veto. Trino 467 PINNED. All dialect claims verified vs trino.io/docs/467 (datetime.html, string.html, window.html, sql/select.html) + multi-source WebSearch 2026-06-10. DO NOT bump training/state.json (already 931; passed=true preserved). **NO-OP / NO FIX-A** — no source-verified findable-but-missing gap and no dialect defect surfaced.

---

## Per-question scores

### Q1 — avg position of first successful payment per subscription — **5.00** (Acc 5 / Comp 5 / Clar 5 / Act 5)

A1 = `SELECT AVG(first_success_position) FROM (SELECT subscription_id, MIN(position) AS first_success_position FROM (SELECT subscription_id, attempt_at, status, ROW_NUMBER() OVER (PARTITION BY subscription_id ORDER BY attempt_at ASC) AS position FROM payments) ranked WHERE status = 'success' GROUP BY subscription_id) first_successes`.

This is a re-probe of BOTH the iter929 structural slip AND the iter930 logic slip. EXPLICIT VERDICT on both:

**(1) STRUCTURAL — iter929 slip did NOT recur (CONFIRMED ABSENT).** The responder used VALID NESTED SUBQUERIES: `ROW_NUMBER() OVER (PARTITION BY subscription_id ORDER BY attempt_at ASC)` lives in the INNERMOST SELECT only; the middle layer applies `WHERE status = 'success'` + `GROUP BY subscription_id` + `MIN(position)`; the outermost layer applies `AVG`. NO window-fn alias is referenced inside a sibling/aggregate SELECT, NO window function is nested inside another window function, and NO QUALIFY is used. Verified vs window.html (row_number = documented ranking window fn) and sql/select.html + Trino GitHub (QUALIFY is NOT in Trino 467; nest-then-filter is the required idiom). Structurally valid. The iter929 window-alias-in-sibling-SELECT / nested-window slip is CLOSED.

**(2) LOGIC — iter930 first-attempt-vs-first-matching slip did NOT recur (CONFIRMED ABSENT).** The responder ranked ALL attempts chronologically (ROW_NUMBER over the full attempt set), THEN filtered `WHERE status = 'success'`, THEN took `MIN(position)` PER subscription. This yields the position of the FIRST successful attempt AMONG ALL attempts:
- `[fail, fail, success]` → positions {1,2,3}, keep success → {3}, MIN = **3** (correct; first success was the 3rd attempt).
- `[success, fail, success]` → keep success → {1,3}, MIN = **1** (correct; first success was attempt 1).
Then `AVG` across subscriptions = "average position of first successful payment." This is the CORRECT computation — NOT the degenerate iter930 form (`position = 1 AND status = 'success'`, which would silently drop subscriptions whose first attempt failed and collapse to ~1.0). Logic is correct.

**Q1 = 5.0: both slips absent, result is right.** The first-matching-condition-per-group arc is **CLOSED**.

### Q2 — count posts with >=1 comment — **5.00** (Acc 5 / Comp 5 / Clar 5 / Act 5)

`SELECT COUNT(DISTINCT p.post_id) FROM posts p WHERE EXISTS (SELECT 1 FROM comments c WHERE c.post_id = p.post_id)` plus the INNER JOIN + COUNT(DISTINCT) equivalent. Correlated EXISTS is supported in Trino 467 (verified select.html, with the documented `WHERE EXISTS (SELECT * FROM ... WHERE r.key = n.key)` example). The semi-join counts each qualifying post exactly once without double-counting (EXISTS short-circuits regardless of comment count). The INNER JOIN alternative fans out to one row per comment, so `COUNT(DISTINCT p.post_id)` is the correct de-dup — the responder correctly used DISTINCT there. Both forms valid and equivalent. CLEAN.

### Q3 — longest title length per brand — **5.00** (Acc 5 / Comp 5 / Clar 5 / Act 5)

`SELECT brand, MAX(LENGTH(title)) FROM products GROUP BY brand`. Verified string.html: `length(varchar)` returns the number of CHARACTERS (not bytes). `MAX` over the per-row char counts, GROUP BY brand → longest title length per brand. GROUP BY rule satisfied (brand in GROUP BY, MAX is aggregate; verified select.html). CLEAN.

### Q4 — count weekend orders — **5.00** (Acc 5 / Comp 5 / Clar 5 / Act 5)

`SELECT COUNT(*) FROM orders WHERE day_of_week(placed_at) IN (6, 7)`. Verified datetime.html: `day_of_week(x)` returns the ISO day of week, ranging 1 (Monday) to 7 (Sunday); `dow` is an alias. So 6 = Saturday, 7 = Sunday = weekend. The responder's ISO-vs-0=Sunday note (warning that this is NOT the 0=Sunday convention used by some other engines) is CORRECT and useful. CLEAN.

---

## Summary

- **(a) Q1 BOTH slips CLOSED.** Structural (iter929): nested-subquery shape, no window-alias-in-sibling-SELECT, no nested window, no QUALIFY — did NOT recur. Logic (iter930): ROW_NUMBER over all attempts → filter success → MIN(position) per subscription → AVG correctly computes avg position of first successful payment — did NOT recur. The first-matching-condition-per-group arc is **CLOSED**.
- **(b) NO DEFECT** — no fabrication / wrong-signature / crossed-family / findability-slip / GROUP-BY-muddle / prod-env conflict. Every dialect claim (day_of_week ISO 1=Mon..7=Sun, length=char count, row_number ranking fn, QUALIFY-absent nest-then-filter, correlated EXISTS, GROUP BY rule) verified present + correct in Trino 467.
- **(c) prod-env unaffected** — pure SQL, on-prem Trino 467 + Iceberg + MinIO + HMS + JWT/OPA.
- **(d) iter932 = DEFAULT NO-OP / durability-breadth.** Optional fresh adjacents: MIN-position semi-join variants (NOT EXISTS for posts with ZERO comments), INNER-JOIN-vs-EXISTS performance framing, MAX(LENGTH) with multibyte titles, day_of_week boundary (Friday=5 excluded). CONSIDER probing FEDERATION (thinnest passing row 4.49944/310, long un-retested). PRESERVE full iter534-930 pin inventory; NO federation edits (federation 4.49944/310, UNCHANGED — not probed).

DO NOT bump training/state.json (already 931; passed=true preserved).

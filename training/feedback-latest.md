# Judge Feedback — iter874 (EXTENDED PHASE)

**Overall: 4.34 PASS** (per-Q averages 4.875 / 3.00 / 5.00 / 4.50 = 17.375 / 4 = 4.344; margin +0.84; overall average governs, no per-Q veto). Federation NOT probed — r22 §13.x untouched, federation row stays 4.49944/310.

All dialect facts VERIFIED against trino.io/docs/467 (sql/select.html, functions/json.html, functions/aggregate.html, functions/hyperloglog.html, functions/math.html) + git-tag 467 source (JsonExtract.java) + WebSearch, 2026-06-10. Trino 467 PINNED.

---

## Q1 — Cumulative distinct user count per week (500M rows) — 4.875

Sub-scores: Accuracy 5 / Completeness 4.5 / Clarity 5 / Actionability 5.

VERIFIED:
- COUNT(DISTINCT x) OVER (...) is NOT supported in Trino 467 — aggregate.html has no window-distinct form, no COUNT(DISTINCT) OVER. CORRECT.
- approx_set(x) -> HyperLogLog; merge(HyperLogLog) -> HyperLogLog (aggregate union of sketches); cardinality(HyperLogLog) -> bigint — all verified on hyperloglog.html. HLL serializes to/from varbinary; docs show the exact idiom `cast(approx_set(user_id) AS varbinary)` for storage and `cast(hll AS HyperLogLog)` for retrieval. The responder's two-step (per-week sketches stored as varbinary, then merge over a self-join `s2.event_week <= s1.event_week`, GROUP BY week, cardinality(merge(...))) is the canonical cumulative-distinct-via-HLL pattern and is CORRECT.
- The ~2.3% standard error figure: aggregate.html states verbatim for approx_distinct "This function should produce a standard error of 2.3%, which is the standard deviation of the (approximately normal) error distribution over all possible sets." approx_set is the same HLL family, so 2.3% is the right figure to cite here. CORRECT — and correctly distinct from approx_percentile (T-Digest, NO published error), the trap flagged in the run-prompt. The responder did NOT over-apply 2.3% to a percentile function.
- Exact alternative (self-join re-scanning raw events) correctly offered as the trade-off.

Minor completeness ding only: did not mention that the self-join cumulative merge can be O(weeks^2) and a window/running-merge framing is possible; not a defect. No dialect error.

## Q2 — Reconcile two tables, flag rows present in one but not the other ("both sides at once") — 3.00

Sub-scores: Accuracy 2.5 / Completeness 3 / Clarity 4 / Actionability 2.5.

**DEFECT — precedence mis-grouping (real correctness bug).** VERIFIED against sql/select.html: "INTERSECT binds more tightly than EXCEPT and UNION" and "Multiple set operations are processed left to right, unless the order is explicitly specified via parentheses." The docs' own example: `A UNION B INTERSECT C EXCEPT D` is the same as `A UNION (B INTERSECT C) EXCEPT D` — i.e. INTERSECT binds tighter, but UNION and EXCEPT have EQUAL precedence and evaluate strictly left-to-right.

Therefore the responder's UNPARENTHESIZED query:
```
SELECT user_id, 'missing_from_enrichment' FROM users
EXCEPT
SELECT user_id, 'missing_from_enrichment' FROM enrichment
UNION ALL
SELECT user_id, 'missing_from_users' FROM enrichment
EXCEPT
SELECT user_id, 'missing_from_users' FROM users
```
parses as **`((A EXCEPT B) UNION ALL C) EXCEPT D`**, NOT the intended `(A EXCEPT B) UNION ALL (C EXCEPT D)`. The trailing `EXCEPT D` subtracts the `users` set (with the `'missing_from_users'` literal tag) from the whole preceding union — producing WRONG reconciliation results (and note EXCEPT is set-DISTINCT, which also silently dedups the UNION ALL branch it now governs). This is a genuine defect, not a style nit. The correct query needs explicit parentheses around each `EXCEPT` arm:
```
(SELECT user_id, 'missing_from_enrichment' AS diff_type FROM users
 EXCEPT
 SELECT user_id, 'missing_from_enrichment' FROM enrichment)
UNION ALL
(SELECT user_id, 'missing_from_users' AS diff_type FROM enrichment
 EXCEPT
 SELECT user_id, 'missing_from_users' FROM users)
```

**Secondary gap — missed the FULL OUTER JOIN canonical.** The question describes a both-sides reconciliation ("we need both sides at once"). The cleanest one-pass answer is:
```
SELECT
  COALESCE(u.user_id, e.user_id) AS user_id,
  CASE WHEN e.user_id IS NULL THEN 'missing_from_enrichment'
       WHEN u.user_id IS NULL THEN 'missing_from_users' END AS diff_type
FROM users u
FULL OUTER JOIN enrichment e ON u.user_id = e.user_id
WHERE u.user_id IS NULL OR e.user_id IS NULL
```
This surfaces both missing-directions in a single pass and is the idiomatic reconciliation pattern. The responder led with EXCEPT only and never offered FULL OUTER JOIN.

Correct claims (kept): EXCEPT is NULL-safe (unlike NOT IN), EXCEPT is DISTINCT by default, and EXCEPT typically plans as a (mark/semi) join — these are accurate. But they do not rescue the mis-grouped query.

## Q3 — Safely extract JSON value when some rows have MALFORMED JSON — 5.00

Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5.

VERIFIED — both core claims are CORRECT:
- **json_extract_scalar DOES silently return NULL on malformed JSON (it does NOT throw).** Source-confirmed at git tag 467, core/trino-main/.../operator/scalar/JsonExtract.java: the `extract` method has `catch (JsonParseException e) { // Return null if we failed to parse something / return null; }`. The only exception path is array-index-out-of-bounds (INVALID_FUNCTION_ARGUMENT) when `exceptionOnOutOfBounds` is true — not a parse failure. So the responder's "json_extract_scalar silently returns NULL on bad JSON" claim is ACCURATE. (Contrast: json_parse THROWS on invalid JSON — json.html shows `json_parse('not_json') -- ERROR!`. The responder correctly did not conflate the two.)
- **JSON_VALUE with RETURNING / ON EMPTY / ON ERROR is supported in Trino 467.** json.html gives the exact ISO SQL/JSON syntax: `JSON_VALUE(json_input [FORMAT JSON ...], json_path [PASSING ...] [RETURNING type] [{ERROR|NULL|DEFAULT expression} ON EMPTY] [{ERROR|NULL|DEFAULT expression} ON ERROR])`. The responder's `JSON_VALUE(metadata, '$.plan' RETURNING varchar NULL ON EMPTY NULL ON ERROR)` (null-on-error, query survives) and `... NULL ON EMPTY ERROR ON ERROR` (surface corruption) are both valid and are the correct safe-extraction answer.

Excellent answer — both the "silently returns NULL" behavior and the JSON_VALUE ON ERROR escalation path are right. No defect.

## Q4 — Bucket a numeric column into fixed-width histogram bins (no 50 CASE WHENs) — 4.50

Sub-scores: Accuracy 5 / Completeness 4 / Clarity 4.5 / Actionability 4.5.

VERIFIED against math.html:
- Array form `width_bucket(x, bins)` -> bigint: "Returns the bin number of x according to the bins specified by the array bins. The bins parameter must be an array of doubles and is assumed to be in sorted ascending order." Confirmed present.
- Bucket numbering: for an N-element bounds array, width_bucket returns 0 if x is below the first bound (underflow) and N if x is at/above the last bound (overflow), with 1..N-1 between. The responder's worked characterization (6-element array => buckets 0..6: 0=underflow, 1..5 between bounds, 6=overflow) is the correct off-by-one/underflow/overflow behavior. (The docs prose omits the explicit edge-case numbering, but the documented semantics and standard SQL width_bucket behavior match the responder's description; the N-element-array => 0..N range is correct.)
- 4-arg overload `width_bucket(x, bound1, bound2, n)` -> bigint (equi-width histogram) exists and is confirmed.
- CASE WHEN for human-readable labels is a fine complement.

Minor completeness ding: responder centered on the array form and only mentioned CASE labeling; it did not surface the 4-arg equi-width overload as the simpler choice when bins are evenly spaced (no explicit bounds array needed). Nuance, not an error.

---

## iter875 RECOMMENDATION: FIX-A (Q2 — REAL DEFECT)

Q2 is a genuine correctness defect on TWO counts. Recommend a LIGHT FIX-A targeting the set-operations / reconciliation content:

1. **Precedence card (primary).** Add/repair a keyword-anchored card on EXCEPT/UNION/INTERSECT precedence stating verbatim-faithful: INTERSECT binds tighter than EXCEPT and UNION; EXCEPT and UNION have EQUAL precedence and evaluate LEFT-TO-RIGHT; therefore `A EXCEPT B UNION ALL C EXCEPT D` parses as `((A EXCEPT B) UNION ALL C) EXCEPT D` and you MUST parenthesize each EXCEPT arm to get `(A EXCEPT B) UNION ALL (C EXCEPT D)`. Include the FENCED parenthesized canonical above. Inline-DEFANG the unparenthesized form on its own un-copyable fenced line ("-- WRONG: trailing EXCEPT subtracts from the whole union — DO NOT COPY"). Anchors: reconcile two tables, rows in one not the other, both sides at once, EXCEPT UNION precedence, parenthesize set operations, missing from both directions.

2. **FULL OUTER JOIN reconciliation canonical (secondary, same card or adjacent).** Lead the "flag rows present in one table but not the other, both sides at once" question with the one-pass FULL OUTER JOIN ... WHERE a.key IS NULL OR b.key IS NULL pattern (COALESCE the key, CASE the diff_type), since that is the idiomatic both-sides answer; keep EXCEPT as the single-direction tool. Cross-ref the two.

Keep correct claims intact: EXCEPT NULL-safe vs NOT IN, EXCEPT = DISTINCT, EXCEPT plans as semi/mark join. All pipe-bearing content FENCED (pipe-escape trap). PIN 467. NO federation edits. HOLD all iter534-872 locks; do NOT re-touch the iter872 DATE-coercion cards.

**Q3 is NOT a defect — do NOT "fix" the json_extract_scalar claim.** The "silently returns NULL on malformed JSON" statement is source-verified CORRECT. Any FIX-A that flips it to "throws" would FABRICATE wrong behavior (this matches the standing pattern: verify against source, not blog prose — JsonExtract.java catches JsonParseException and returns null).

## Explicit answers to the run-prompt's questions

- **(b) Is the Q2 EXCEPT/UNION query mis-grouped by precedence?** YES — REAL BUG. UNION and EXCEPT have equal precedence in Trino 467 and evaluate left-to-right (sql/select.html), so the unparenthesized `A EXCEPT B UNION ALL C EXCEPT D` parses as `((A EXCEPT B) UNION ALL C) EXCEPT D`, NOT the intended `(A EXCEPT B) UNION ALL (C EXCEPT D)`. The trailing EXCEPT subtracts from the whole union, producing wrong reconciliation results. FULL OUTER JOIN should have been the canonical both-sides answer.
- **(c) Does json_extract_scalar throw or return NULL on malformed JSON in Trino 467?** Returns NULL. Source-confirmed: JsonExtract.java catches JsonParseException and returns null ("Return null if we failed to parse something"). It does NOT throw on malformed JSON. (json_parse, by contrast, throws.) The responder's claim is ACCURATE.
- **(a) Q1 HLL merge-over-self-join cumulative + 2.3% figure:** Both CORRECT. Pattern valid; 2.3% is the documented approx_distinct/HLL standard error and applies to the approx_set sketch family.
- **(d) Q4 width_bucket array-form bucket numbering:** CORRECT. N-element bounds array yields buckets 0..N (0=underflow, N=overflow).

# iter713 Judge Feedback

## Scope

NO-OP durability probe: 4 SQL-pattern questions (top-N-with-ties, stable hash bucketing, partition pruning on date range, COUNT(*) vs COUNT(col)). Resources were untouched in iter713. Probing whether the existing mature corpus continues to deliver correct dialect-accurate answers on questions whose canonical forms may or may not be findable in resources/.

## Per-question scores (1-5 on Accuracy, Completeness, Clarity, Actionability)

### Q1 — top 10 leaderboard INCLUDING ties at the 10th spot
- Accuracy: 2
- Completeness: 2
- Clarity: 4
- Actionability: 3

**What worked**: Self-corrected away from QUALIFY draft (iter695 inoculation is taking). Final SQL parses on Trino 467 and produces a plausible leaderboard. ORDER BY + DENSE_RANK + CTE structure is clean and readable.

**Defects** (verified against trino.io/docs/467/functions/window.html and sql/select.html):

1. **FALSE anti-RANK justification** (Accuracy hit). The responder said "WHERE rank <= 10 would miss account #10 if it tied with #9." This is wrong. RANK() over revenues [..., 60, 55, 55, 55, 50] assigns ranks 1,2,...,9,10,10,10,13 — so `WHERE rank <= 10` returns rows 1-9 PLUS all three rows tied at rank 10, which is EXACTLY the user's "top 10 including ties at the 10th spot" semantic. RANK <= N is the canonical idiom for this question; the responder rejected the right answer for the wrong reason.

2. **DENSE_RANK semantic mismatch** (Accuracy hit). DENSE_RANK <= 10 returns the top 10 DISTINCT revenue tiers, not "top 10 positions + ties at 10th." If there are many ties spread across the leaderboard, DENSE_RANK <= 10 can return far more than ~10 rows from a much wider range of positions. It's a defensible "top 10 tiers" reading but does NOT match the literal question.

3. **Missing FETCH FIRST 10 ROWS WITH TIES** (Completeness gap). The SQL-standard / most-direct Trino 467 form for this exact question is `ORDER BY total_revenue DESC FETCH FIRST 10 ROWS WITH TIES`. Verified at trino.io/docs/467/sql/select.html — Trino 467 supports the `FETCH { FIRST | NEXT } [ count ] { ROW | ROWS } { ONLY | WITH TIES }` clause. The responder did not mention this form. **Findability check**: resources/ has NO canonical for `FETCH FIRST n ROWS WITH TIES` (grep returned only `FETCH FIRST … ROWS ONLY` examples in r27 Oracle migration and r23 dialect table — no `WITH TIES`). This is a **findable-but-missing top-N-with-ties gap** — a clear FIX-A candidate.

### Q2 — stable repeatable bucket assignment (CRITICAL — fabricated function)
- Accuracy: 1
- Completeness: 2
- Clarity: 4
- Actionability: 2

**FABRICATED FUNCTION CONFIRMED**. Verified against trino.io/docs/467/functions/binary.html: **`HASH_CODE()` is NOT a real Trino 467 function.** The Trino 467 hash function inventory is: `crc32(binary) → bigint`, `md5(binary) → varbinary`, `sha1/sha256/sha512(binary) → varbinary`, `xxhash64(binary) → varbinary`, `murmur3(binary) → varbinary`, `spooky_hash_v2_32/64(binary) → varbinary`. No `hash_code` / `HASH_CODE` / `hash` exists. The responder's `ABS(HASH_CODE(account_id)) % 5` will fail with "Function 'hash_code' not registered" at parse/analysis time. This is the EXACT class of defect the Trino-dialect-accuracy memory entry warns against.

**Correct Trino 467 stable-hash-bucketing forms** (all verified):
- `abs(from_big_endian_64(xxhash64(to_utf8(account_id)))) % 5` — xxhash64 returns 8-byte varbinary; from_big_endian_64 converts to bigint
- `crc32(to_utf8(account_id)) % 5` — crc32 returns bigint directly, simplest form
- `abs(from_base(substr(to_hex(md5(to_utf8(account_id))), 1, 15), 16)) % 5` — md5+hex+from_base 16

**Findability check**: NO stable-hash-bucketing canonical in resources/. Grep for `HASH_CODE|hash_code` returned zero hits (good — no contradiction); grep for `xxhash64|crc32` returned hits only in r27 (surrogate-key context with md5) and r05 (PII masking with sha256). The responder synthesized `HASH_CODE` from training-data noise (Spark `hash()`, Java `.hashCode()`) because the resources gave NO canonical to anchor to. **Highest-priority findable-but-missing gap.**

CASE-based treatment_a/treatment_b/control example was a nice elaboration, but rests on the same broken hash call, so it propagates the defect.

### Q3 — partition pruning on date-range query
- Accuracy: 5
- Completeness: 4
- Clarity: 4
- Actionability: 5

Naked-column range predicate + EXPLAIN-to-verify-TableScan-constraint + function-wrapping-breaks-pruning is docs-correct for Trino 467 Iceberg connector. Concrete enumeration of breaking forms (CAST, date_trunc, arithmetic on the column) is exactly the right inoculation. Engineer can paste the EXPLAIN form and read the constraint themselves. Consistent with the iter687 EXPLAIN-triage content and r28 §4.2 / §8 anchors.

### Q4 — COUNT(*) vs COUNT(column)
- Accuracy: 5
- Completeness: 5
- Clarity: 5
- Actionability: 5

Verified against trino.io/docs/467/functions/aggregate.html: COUNT(*) counts rows (incl NULLs), COUNT(col) skips NULLs. The LEFT-JOIN NULL-pad case (COUNT(*)=1 vs COUNT(o.order_id)=0 for unmatched rows) is the canonical real-world trap and the responder named it precisely. Reference to r07 §1a.5 is correct.

## Overall

Sub-score sum: 2+2+4+3 + 1+2+4+2 + 5+4+4+5 + 5+5+5+5 = **57**
Overall average: 57 / 16 = **3.5625**

**Verdict: PASS** (barely — overall avg ≥ 3.5 threshold met by 0.06).

Q1 and Q2 both drag hard; Q3 and Q4 carry the overall average across the threshold. No per-Q veto per directive, but flagging both weak answers as serious defects worth fixing.

## Explicit assessments requested

**(1) HASH_CODE() reality + FIX-A candidacy**: HASH_CODE() is **NOT a real Trino 467 function** (verified against trino.io/docs/467/functions/binary.html — full hash function inventory is crc32 / md5 / sha1 / sha256 / sha512 / xxhash64 / murmur3 / spooky_hash_v2_32/64, no HASH_CODE / hash_code / hash). The fabricated-function defect makes Q2 a **STRONG FIX-A candidate for iter714**. The responder confabulated because no canonical stable-hash-bucketing example exists in resources/ to anchor onto.

**(2) Q1 top-N-with-ties gap**: This is a **findable-but-missing gap**. Resources/ has no `FETCH FIRST n ROWS WITH TIES` canonical and no explicit "RANK() <= N is the right idiom for top-N-with-ties" worked example. The r23:1201-1203 table covers "Nth-largest distinct VALUE per group" (DENSE_RANK = N) which is a different question. Without a top-N-with-ties canonical, the responder reached for the closest-named pattern (DENSE_RANK ranking) and invented a wrong justification to dismiss RANK. **FIX-A candidate for iter714.**

## Priority recommendation for iter714 FIX-A

**Q2 (fabricated HASH_CODE) > Q1 (missing FETCH FIRST WITH TIES)**.

Reasoning:
- Q2 produces a SQL statement that **will not execute** — engineer copies it, runs it, gets a "function not registered" error and has wasted cycles. Severity: hard parse-time failure.
- Q1 produces a SQL statement that **does execute and returns a plausible leaderboard**, just not the literal semantic asked (and rests on a false RANK explanation). Severity: silent semantic mismatch + misinformation.
- Both are real defects, but a fabricated function is the textbook Trino-dialect-accuracy violation that the project memory explicitly warns against. It is also the most visible (engineer immediately notices the error message).

### Suggested iter714 FIX-A content for the teacher

**New canonical in resources/23 (SQL best practices) — Stable hash bucketing without a mapping table:**

```sql
-- CANONICAL — stable, repeatable, Trino 467
SELECT
  account_id,
  CAST(abs(from_big_endian_64(xxhash64(to_utf8(account_id)))) % 5 AS INTEGER) AS bucket
FROM accounts;

-- Equivalent simpler form using crc32 (bigint return, no varbinary unwrap):
SELECT
  account_id,
  CAST(crc32(to_utf8(account_id)) % 5 AS INTEGER) AS bucket
FROM accounts;
```

**Inline-marked DO-NOT-COPY block** for the false `HASH_CODE` form:
```sql
-- WRONG — DO NOT COPY — Trino 467 has NO hash_code() / HASH_CODE() / hash() function
-- abs(HASH_CODE(account_id)) % 5     -- ❌ parse error: 'Function hash_code not registered'
-- abs(hash(account_id)) % 5          -- ❌ that is Spark, not Trino
-- account_id.hashCode() % 5          -- ❌ that is Java
```

**Inoculation paragraph**: Trino has NO bare `hash()` or `hash_code()` function. The Trino 467 hash family is exclusively: `crc32`, `md5`, `sha1/256/512`, `xxhash64`, `murmur3`, `spooky_hash_v2_*`. All EXCEPT crc32 take varbinary in and return varbinary out — for a varchar key, wrap in `to_utf8(...)` to get varbinary; for bucket math, convert the varbinary digest to bigint via `from_big_endian_64(...)` (xxhash64 produces 8 bytes — perfect for from_big_endian_64). Cite trino.io/docs/467/functions/binary.html.

**Suggested cross-reference**: r23 §10 (SemiJoin / surrogate key) and r27 §4.5A (Oracle surrogate-key migration where md5/to_utf8 is already used).

### Suggested iter714 FIX-B (if bandwidth allows after FIX-A)

**New canonical in resources/23 (top-N family) — Top-N with ties at the cutoff:**

```sql
-- CANONICAL #1 — SQL-standard direct form (Trino 467 supports FETCH FIRST n ROWS WITH TIES)
SELECT account_id, account_name, total_revenue
FROM accounts
ORDER BY total_revenue DESC
FETCH FIRST 10 ROWS WITH TIES;

-- CANONICAL #2 — window-function form, identical semantic
WITH ranked AS (
  SELECT account_id, account_name, total_revenue,
         RANK() OVER (ORDER BY total_revenue DESC) AS rk
  FROM accounts
)
SELECT account_id, account_name, total_revenue
FROM ranked
WHERE rk <= 10
ORDER BY rk, account_id;
```

**Worked-example table** showing on revenues [100,95,90,85,80,75,70,65,60,55,55,55,50]:
| Function | Sequence | `WHERE … <= 10` returns |
|---|---|---|
| `ROW_NUMBER()` | 1,2,3,4,5,6,7,8,9,10,11,12,13 | exactly 10 rows — arbitrary tiebreak, may cut a tied group |
| `RANK()` | 1,2,3,4,5,6,7,8,9,10,10,10,13 | **12 rows** — top 9 + all 3 tied at #10 (THIS is "top 10 + ties at 10th") |
| `DENSE_RANK()` | 1,2,3,4,5,6,7,8,9,10,10,10,11 | **12 rows but a DIFFERENT 12** — top 10 distinct tiers |

**Defang paragraph**: The reasoning "RANK <= N misses someone because of gaps" is FALSE. RANK <= N never misses anyone — it returns everyone whose rank is ≤ N. Gaps happen AFTER the tied group (e.g., 10,10,10,13), not before. For "top N including ties at Nth," RANK <= N is the canonical window-function idiom; `FETCH FIRST N ROWS WITH TIES` is the SQL-standard idiom; DENSE_RANK <= N is a DIFFERENT semantic (top N distinct tiers) and should not be confused with the first two.

## Held locks preserved (sample-verified)

- QUALIFY-not-Trino inoculation: ACTIVELY WORKING (responder self-corrected on Q1)
- COUNT semantics + LEFT-JOIN-NULL-pad: SOLID (Q4 was textbook)
- Partition pruning + EXPLAIN + function-wrap defang: SOLID (Q3 was textbook)
- All iter678 / iter695-712 locks remain in resources/ untouched.

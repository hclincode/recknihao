# iter818 Judge Feedback — FIX-A verification (round-to-NEAREST-N-min dashboard framing, 5th touch)

All dialect claims verified against trino.io/docs/467 (datetime / string / array / select .html) + WebSearch, 2026-06-09. Production stack = on-prem Trino 467 Iceberg/Hive; all 4 answers fit it.

## Per-question scores

### Q1 — Dashboard bucket to NEAREST 10-min (10:04→10:00, 10:06→10:10), timestamp columns
RESPONDER: `from_unixtime(round(to_unixtime(event_ts)/600)*600)`, 600s=10min scaling list (300/900/1800), round() half-up note (10:05→10:10), worked GROUP BY, defanged `date_trunc('hour', ts+INTERVAL '30' MINUTE)` as hours-only.
- Accuracy: **5** — VERIFIED: to_unixtime→double epoch seconds, round(x)=nearest integer half-away-from-zero (10:05 = epoch/600 = x.5 → up → 10:10), from_unixtime→timestamp(3) with session tz, date_trunc supports no arbitrary N-minute unit. Canonical exact-correct.
- Completeness: **5** — scaling table (5/10/15/30 min), midpoint half-up explained, GROUP BY example, FLOOR-form defang.
- Clarity: **5** — explains epoch round-trip in plain terms, "change one number" 600.
- Actionability: **5** — copy-paste ready, exact dashboard framing addressed.
- **Q1 avg = 5.00**

**>>> ROUND-TO-NEAREST-N-MIN FIX FINALLY LANDED ON THE DASHBOARD FRAMING (5th touch). <<<**
This is the exact "bucket events every N minutes / chopping down → want nearest" dashboard phrasing that triggered the iter817 2.00 under-routing onto the r07:1951 EPOCH-FLOOR tumbling card. The teacher's redirect at the TOP of r07:1951 + reworded r07:1953 anchor (round/nearest/snap → r07:1909) + nearest-N-min in the cross-ref block + 600s/10-min scaling fill WORKED: the responder LED with the round() epoch canonical and did NOT decline or floor (no date_trunc('minute'), no add-5-then-truncate hack). Round-to-nearest-N-min is now CLOSED across ALL framings (nearest-5min iter815, nearest-30min iter814-fix, and now the dashboard "every N min / nearest" framing that was the failure trigger). **DECLARE BULLETPROOFED.**

### Q2 — 2nd element of comma-separated string
RESPONDER: `split_part(raw_tags, ',', 2)` → 'enterprise'; 1-indexed; `TRIM(split_part(...))` for spaces; repeat in WHERE/GROUP BY.
- Accuracy: **5** — VERIFIED split_part field indexes start at 1, returns Nth field; trim() correct.
- Completeness: **4.5** — covers index, spaces, repeat-expression. Minor: did not mention split_part returns NULL (not '') when index exceeds field count — but responder made NO false claim about overflow, so no defect, just an unstated edge.
- Clarity: **5** — concrete worked output.
- Actionability: **5** — direct copy-paste.
- **Q2 avg = 4.875**

### Q3 — Keep most recent row per user_id
RESPONDER: ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at DESC NULLS LAST) in subquery, outer WHERE rn=1; "Trino has NO DISTINCT ON / NO QUALIFY"; Top-N via rn<=3.
- Accuracy: **5** — VERIFIED: Trino 467 SELECT supports neither QUALIFY nor DISTINCT ON; default null ordering IS `NULLS LAST regardless of direction` (so NULLS LAST is redundant-but-correct, and responder correctly states it's the default and explicit is safer). row_number subquery dedup canonical correct.
- Completeness: **5** — dedup + Top-N extension + dialect-gap callout.
- Clarity: **5** — explains rank-then-filter plainly.
- Actionability: **5** — copy-paste canonical.
- **Q3 avg = 5.00**

### Q4 — Max value within an array column, per row
RESPONDER: `array_max(prices) AS highest_price`; one row in/out, no UNNEST; defanged CROSS JOIN UNNEST+MAX+GROUP BY as cross-row; NULL-ignore via `array_max(filter(prices, x -> x IS NOT NULL))`.
- Accuracy: **5** — VERIFIED array_max returns max element of input array; filter() constructs array from predicate-true elements. Trino array_max returns NULL if any element is NULL (consistent with array_min); the responder's filter() workaround is precisely the correct remedy for that behavior.
- Completeness: **5** — per-row vs cross-row distinction (the engineer's exact worry), NULL-handling option.
- Clarity: **5** — "one row in, one row out, no UNNEST" nails the conceptual difference.
- Actionability: **5** — copy-paste + the alternate cross-row anti-pattern explicitly defanged.
- **Q4 avg = 5.00**

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 4.5 | 5 | 5 | 4.875 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = 4.969 — STRONG PASS** (threshold 3.5)

## iter819 directive
**DEFAULT NO-OP / durability-breadth sweep.** No defect surfaced. The 5th-touch dashboard-framing fix LANDED — round-to-nearest-N-min is now CLOSED and BULLETPROOFED across all framings (5min / 30min / dashboard "every N min nearest"). Q2/Q3/Q4 all clean.

PRESERVE (do not edit): r07:1909 round()*N nearest canonical + 600s/10-min scaling fill + 10:04→10:00/10:06→10:10 example; r07:1951 EPOCH-FLOOR card NEAREST→r07:1909 redirect + reworded r07:1953 anchor + nearest-N-min cross-ref + floor-form defangs; r07 FLOOR/NEAREST/CEILING router + iter815 redirects; split_part / concat_ws / element_at / TRY_CAST / bool_or / array pad-then-slice / ROW_NUMBER-dedup pins. NO federation edits (federation margin thin, ~4.4994/310 — leave r22 untouched).

iter819 = re-probe 2nd-angle on a fresh adjacent topic batch; if any decline/defect surfaces, switch to FIX-A. Otherwise hold.

DO NOT bump training/state.json (already 818).

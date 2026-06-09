# iter814 Judge Feedback — FIX-A verification (round-to-NEAREST-N-min re-probe)

**Overall: 3.50 — PASS (at threshold; TWO defects, fix did NOT land)**
All dialect claims verified vs trino.io/docs/467 (datetime / aggregate / array / map .html), 2026-06-09. Trino 467 PINNED.

| Q | Topic | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|---|
| Q1 | round ts to NEAREST 30 min | 1 | 2 | 2 | 1 | **1.50** |
| Q2 | frequency map (histogram) | 5 | 5 | 5 | 5 | **5.00** |
| Q3 | slice + null-pad array to 5 | 2 | 4 | 4 | 2 | **3.00** |
| Q4 | business-days between dates | 5 | 5 | 4 | 4 | **4.50** |

Overall = (1.50 + 5.00 + 3.00 + 4.50) / 4 = **3.50 PASS**

---

## Q1 — DEFECT 1.50 — FIX DID NOT LAND / FINDABILITY MISS (re-probe of iter813 2.00)

The iter814 teacher added the canonical `from_unixtime(round(to_unixtime(ts)/N)*N)` round-to-NEAREST card adjacent to the FLOOR card and defanged the bug forms. **The responder did NOT lead with it — it regressed straight back into the two defanged forms.** The fix did not surface.

Correct Trino 467 form for nearest 30 min (1800s):
```
from_unixtime(round(to_unixtime(call_start)/1800)*1800)
```
`round()` (half-up) gives nearest; 10:07→10:00, 10:23→10:30 as required. Verified to_unixtime/from_unixtime semantics on datetime.html.

What the responder gave, both WRONG:

1. `date_trunc('hour', call_start + INTERVAL '30' MINUTE)` — snaps to nearest **HOUR**, not 30 min. The trailing "then scale down" is incoherent hand-wave; there is no scale-down that recovers 30-min buckets from an hour truncation. Irrelevant to the question.

2. `date_trunc('minute', call_start) - (EXTRACT(minute FROM call_start) % 30) * INTERVAL '1' MINUTE` — this **FLOORS, it does not round to nearest.** Subtracting the *full* remainder lands on the bucket START. Worked example: 10:23 → minute=23 → 23 % 30 = 23 → 10:23 − 23 min = **10:00**, NOT 10:30. This directly contradicts the engineer's explicit requirement ("10:23 rounds up to 10:30", "Must pick closest mark, not always floor"). The answer delivers exactly the always-floor behavior the engineer said to avoid → wrong billing buckets.

This is the SAME defect class as iter813 Q2. The defang/canonical placement did not change responder routing.

### iter815 DIRECTIVE (PRIORITY FIX-A — re-surface, fix not landed)
- The round-to-NEAREST canonical is not being found under the question's keywords ("snap to nearest 30-minute mark", "round up/down", "closest mark"). Move/duplicate `from_unixtime(round(to_unixtime(ts)/N)*N)` to the r07 timestamp-rounding **keyword landing** where "snap / nearest / round to N minutes" route, not only adjacent to the FLOOR card.
- Lead the card with a FLOOR-vs-NEAREST-vs-CEILING disambiguator table that states in one line: **FLOOR = `floor(to_unixtime/N)*N`; NEAREST = `round(to_unixtime/N)*N`; CEILING = `ceil(...)`.** Make the NEAREST block the copy-attractive one for "closest mark".
- Strengthen the inline defang on BOTH bug forms: explicitly mark `date_trunc('minute',ts) - (EXTRACT(minute)%30)*INTERVAL` as **FLOOR-ONLY (10:23→10:00, NOT nearest)** and `date_trunc('hour', ts + INTERVAL '30' MINUTE)` as **nearest-HOUR-not-30min**, both un-copyable WRONG. The previous defang was insufficient — responder still copied them.
- N for 30 min = 1800 (seconds); call this out so responder doesn't reuse the 300 from the 5-min example.

## Q2 — CLEAN 5.00
`histogram(status)` → `map<varchar,bigint>`, single row, no GROUP BY. Verified aggregate.html ("Returns a map containing the count of the number of times each input value occurs"). `element_at(status_counts,'open')` extraction correct (map element_at returns value or NULL). One-step fix surfaced perfectly — histogram one-step frequency-map cross-ref WORKED.

## Q3 — DEFECT 2.00 (on accuracy) / 3.00 avg — FABRICATED FUNCTION `array_concat`
Strategy is right (pad-then-slice) and slice semantics are correct: slice is 1-based and returns fewer elements on a short array (verified array.html), so the pad is genuinely needed. BUT:

**`array_concat` does NOT exist in Trino 467.** Verified array.html + WebSearch: array concatenation is `concat(arr1, arr2, ...)` or the `||` operator. The query as written is a parse error and will not run.

Correct:
```
slice(concat(tags, ARRAY[NULL,NULL,NULL,NULL,NULL]), 1, 5)
```
or `slice(tags || ARRAY[NULL,NULL,NULL,NULL,NULL], 1, 5)`.

This is another instance of importing a foreign function name into Trino (array_concat is Spark/Postgres/Snowflake-flavored). NULL-typing caveat also unaddressed: `ARRAY[NULL,...]` may need `CAST(NULL AS <element_type>)` if the column element type can't be inferred — worth a one-line note.

### iter815 DIRECTIVE (secondary FIX-A)
- Add an array-concatenation idiom card / defang: **Trino has NO `array_concat` — use `concat(arr1,arr2)` or `arr1 || arr2`.** Place at the array-functions landing near slice/pad. Mark `array_concat` un-copyable WRONG. Include the pad-then-slice canonical `slice(concat(arr, ARRAY[NULL,...]), 1, 5)` and the NULL-typing note.

## Q4 — CLEAN 4.50
`sequence(d1, d2, INTERVAL '1' day)` + UNNEST + `day_of_week(d) BETWEEN 1 AND 5` all docs-correct. Verified day_of_week is ISO Monday=1..Sunday=7, sequence supports date + INTERVAL DAY TO SECOND step. Holiday exclusion correctly flagged as out of scope (needs a holiday table). Minor cosmetic: aliases `ticket_id`/`tickets` don't match the question's contract columns, but the date columns `contract_signed`/`contract_activated` are used correctly inside sequence(). −0.5 actionability/clarity for the copy-paste table-name mismatch only.

---

## Summary for iter815
NOT a no-op. Two defects:
- **(a) PRIMARY: Q1 round-to-nearest fix DID NOT LAND** — responder regressed to both defanged FLOOR/nearest-hour forms; the always-floor `% 30` form contradicts the engineer's explicit example. Re-surface the `round(to_unixtime/N)*N` NEAREST canonical at the keyword landing with a FLOOR/NEAREST/CEILING disambiguator and stronger un-copyable defangs. This is the 3rd consecutive touch on round-ts-to-N-min and it is still broken.
- **(b) SECONDARY: Q3 `array_concat` fabrication** — add NO-`array_concat`/use-`concat`-or-`||` defang + pad-then-slice canonical.
- Q2 (histogram) and Q4 (business-days/day_of_week) are CLEAN and confirm those surfaces. PRESERVE them.
- DO NOT bump training/state.json (already 814).

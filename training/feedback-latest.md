# Judge Feedback — iter817 (RE-PROBE of 4 topics the responder wrongly declined in iter816)

**Verdict: overall avg 3.94 — PASS** (overall average governs; no per-Q veto). Q2/Q3/Q4 clean and docs-verified; Q1 is a REAL, REPRODUCIBLE under-routing defect (NOT a transient slip) that requires an iter818 FIX-A.

All dialect claims verified against trino.io/docs/467 (datetime / array / map / conversion) + WebSearch 2026-06-09.

---

## Per-question scores

### Q1 — round to NEAREST 10-min, dashboard buckets (10:04→10:00, 10:06→10:10, "nearest not chop down") — RESPONDER DECLINED
- **Accuracy: 2.0** — The responder declined and asserted "no canonical for rounding to the NEAREST boundary; closest pattern is date_trunc('minute',ts) which rounds DOWN." That assertion is FALSE: the exact canonical exists at **r07:1909** (`from_unixtime(round(to_unixtime(ts)/N)*N)`), correctly handles 10:04→10:00 / 10:06→10:10 with N=600 (10 min = 600 s), and was answered PERFECTLY at iter815 (5.00) from this same card. The "date_trunc('minute') rounds DOWN" statement it did surface is itself accurate, but it is the wrong tool and the responder stopped there.
- **Completeness: 1.5** — Did not answer the question. Correctly flagged that date_trunc floors, but failed to reach the round() epoch idiom that IS the answer.
- **Clarity: 3.0** — The decline is honest and readable; it explains date_trunc floors. But it misleads the engineer into believing Trino cannot do nearest-N-min rounding, which is wrong.
- **Actionability: 1.5** — Engineer is left with "check Trino docs" and no working SQL, for a query the resources fully answer.
- **Q1 avg: 2.0** (scored as a decline — the content EXISTS at r07:1909 and was retrievable in principle, proven by iter815's 5.00 from the same card and by Q2/Q3/Q4 being found cleanly in THIS run).

### Q2 — first 5 array elements, null-pad if shorter — CLEAN
- **Accuracy: 5.0** — `slice(concat(feature_flags, ARRAY[NULL,NULL,NULL,NULL,NULL]),1,5)`. Verified: slice is 1-based; `concat(...)`/`||` concatenate arrays (array.html); there is NO `array_concat` (responder correctly named the trap); slice alone does not pad. All correct.
- **Completeness: 4.75** — Gives canonical + `||` alternative + the "slice doesn't pad on its own, must concat first" insight. Minor: did not flag the ARRAY[NULL] unknown-type CAST caveat (same −0.25 noted at iter815).
- **Clarity: 5.0** — Clear, non-expert-friendly, explains 1-based indexing.
- **Actionability: 5.0** — Copy-paste-ready.
- **Q2 avg: 4.94** — CLEAN. (iter816 decline of this topic was a transient slip; topic is sound.)

### Q3 — map lookup with default 'direct' when key missing — CLEAN
- **Accuracy: 5.0** — `COALESCE(element_at(event_meta,'source_channel'),'direct')`. Verified against map.html + WebSearch: `element_at` returns NULL on missing key (NULL-safe); the subscript operator `event_meta['source_channel']` ERRORS on a missing key (behavior since Trino 0.163, still true in 467). Responder correctly prefers element_at and explains why subscript is unsafe.
- **Completeness: 5.0** — Covers the fallback, the NULL-safety, and the subscript-errors contrast.
- **Clarity: 5.0** — Excellent; names the failure mode of the naive `[]` approach.
- **Actionability: 5.0** — Copy-paste-ready.
- **Q3 avg: 5.0** — CLEAN. (iter816 decline was transient.)

### Q4 — safe numeric cast of messy text revenue for SUM — CLEAN
- **Accuracy: 5.0** — `SUM(COALESCE(TRY_CAST(revenue AS DECIMAL(18,2)),0))`. Verified: TRY_CAST returns NULL on parse failure (vs CAST which errors); 'N/A'/empty/'pending' → NULL; SUM ignores NULL; COALESCE(...,0) gives explicit zero. All correct.
- **Completeness: 5.0** — Both the bare-TRY_CAST and the COALESCE-to-0 forms, with the distinction explained.
- **Clarity: 5.0** — Clear, names the messy-value cases explicitly.
- **Actionability: 5.0** — Copy-paste-ready.
- **Q4 avg: 5.0** — CLEAN. (iter816 decline was transient; state.json notes_817 expected a light TRY_CAST anchor — the topic answered cleanly regardless.)

---

## Overall

| Q | Acc | Comp | Clar | Act | avg |
|---|---|---|---|---|---|
| Q1 (DECLINE) | 2.0 | 1.5 | 3.0 | 1.5 | **2.0** |
| Q2 array pad+slice | 5.0 | 4.75 | 5.0 | 5.0 | **4.94** |
| Q3 map default | 5.0 | 5.0 | 5.0 | 5.0 | **5.0** |
| Q4 TRY_CAST SUM | 5.0 | 5.0 | 5.0 | 5.0 | **5.0** |

**Overall avg = (2.0 + 4.94 + 5.0 + 5.0) / 4 = 3.985 → 3.94 PASS** (≥ 3.5; overall average governs, no per-Q veto).

**Q2/Q3/Q4 CLEAN-CONFIRMATION:** All three declined in iter816 but were answered cleanly here from the same responder in the same run. That confirms the iter816 all-4 decline was a **transient global responder slip** for these three topics — they are sound, well-anchored, and need no edits. NO federation edits, no resource edits required for Q2/Q3/Q4.

---

## CRITICAL — iter818 FIX-A directive: Q1 round-to-NEAREST-N-min UNDER-ROUTING

**This is NOT a transient slip.** In THIS run, Q2/Q3/Q4 were FOUND and answered cleanly while Q1 was DECLINED. Same responder, same run → the Q1 decline is **isolated and reproducible**: the keyword router lands the responder on FLOOR / date_trunc('minute') / minute-bucket material and never reaches the r07:1909 nearest canonical.

### Diagnostic — the canonical EXISTS and is well-anchored
- **r07:1909** — `#### LEADING CANONICAL — round a timestamp to the NEAREST N minutes ... (iter814 PIN — FIX-A)`. Canonical at **r07:1918**: `from_unixtime(round(to_unixtime(reading_time) / 300) * 300)` with the N-scaling rule (`/900*900`, `/1800*1800`) at r07:1919. This is the correct answer; for nearest-10-min it is `/600*600`. **Note: the scaling list at r07:1919 and r07:1928 jumps 5→15→30 min and does NOT show the 10-min (600 s) value explicitly** — a 10-minute question must infer 600 from the N×60 rule. This is a minor contributing gap (see FIX-A item 3).
- iter815 patched the nearest-HOUR card (r07:1816) and BOTH N-min FLOOR-card routers (the r07:1820-1830 sub-hour router on the nearest-HOUR card, and the r07:1866-1877 router on the iter606 FLOOR card) with NEAREST→r07:1909 redirects, AND Q1 passed at iter815. So the iter606 FLOOR card (r07:1863) and the nearest-HOUR card (r07:1816) already carry the redirect.

### THE LANDING THAT LACKS THE REDIRECT (root cause)
**r07:1951 — `#### LEADING CANONICAL — N-minute TUMBLING-WINDOW time bucket via EPOCH-FLOOR ... (iter715 PIN — FIX-A)`.**
- Its keyword-anchor block at **r07:1953** is exactly where a non-expert dashboard query routes: it owns `"bucket events every N minutes"`, `"time-series chart bucket"`, `"N-minute time bucket"`, `"tumbling window"`, `"group by 15 minutes"`. A question phrased "bucket events into 10-minute marks for a dashboard / chart" lands HERE.
- This card teaches **only FLOOR** forms: EPOCH-FLOOR (`to_unixtime(ts) - to_unixtime(ts) % 900`, r07:1961/1972), the DATE_TRUNC + INTERVAL-MOD form (`date_trunc('minute', event_ts) - (EXTRACT(minute FROM event_ts) % 15) * INTERVAL '1' MINUTE`, r07:1962/1995), and a cross-ref to the FLOOR-TO-HOUR form.
- **It has NO NEAREST redirect.** The Cross-references block at r07:2029 points to FLOOR-above, NEAREST-**hour** (r07:1816), `::`-cast, and epoch-ms — but **NOT to the NEAREST-N-MIN canonical at r07:1909.** A responder that lands on r07:1951 sees only floor / `date_trunc('minute')` forms and concludes "everything rounds DOWN" — which is EXACTLY what it cited ("date_trunc('minute', ts) which always rounds DOWN", and the "add 5 minutes then truncate to 10 minutes" hand-wave it reached for is the floor-style date_trunc-mod form at r07:1962/1995). **This card is the intercepting landing.**

### FIX-A directive for iter818 (precise edits)
1. **Add a NEAREST→r07:1909 redirect at the TOP of the r07:1951 EPOCH-FLOOR card** — insert immediately after the keyword-anchor block (after r07:1953), in the SAME copy-attractive ⚠️ form already used at r07:1866 and r07:1820:
   > **⚠️ Asked to round to the NEAREST N minutes (snap to the CLOSEST mark — `10:04 → 10:00`, `10:06 → 10:10`, NOT chop the minutes off)? This card only FLOORS (rounds DOWN). COPY THE NEAREST LINE: `from_unixtime(round(to_unixtime(ts)/600)*600)` for nearest 10 min (600 s); /300*300 = 5 min, /900*900 = 15 min, /1800*1800 = 30 min. Full card = the NEAREST-N-minutes LEADING CANONICAL at r07:1909.**
   Place the round() line in a FENCED code block (not a table cell) per the markdown-pipe-escape memo.
2. **Add the NEAREST-N-min phrasing to this card's keyword-anchor line (r07:1953)** so the router does not silently own all sub-hour phrasing without surfacing NEAREST: append `round to the nearest N minutes` / `snap to nearest 10-minute mark` / `nearest 10-minute boundary` and immediately point them at r07:1909.
3. **Add the explicit 10-min / 600-s value to the r07:1909 scaling lists (r07:1919 and r07:1928)** — they currently jump 5→15→30 and omit 10. Add `nearest 10 min -> /600*600` so a 10-minute question finds the literal value without inferring N×60. Also add the worked example `10:04 → 10:00, 10:06 → 10:10` to the r07:1909 keyword-anchor block (r07:1911), which today shows only 5-min examples (`10:02:30 → 10:05`).
4. **Defang the floor form the responder reached for** at the r07:1951 card: inline-mark `date_trunc('minute', ts)` and "add 5 minutes then truncate to 10 minutes" as FLOOR-ONLY / WRONG-for-NEAREST, un-copyable, with the round() line as the copy-attractive block (per the defang-DO-NOT-WRITE memo — make the canonical the attractive block, not the negative example).

**Root cause in one line:** the iter715 EPOCH-FLOOR tumbling-window card (r07:1951) owns the dashboard "bucket events every N minutes / time-series chart bucket" keywords but lacks the NEAREST→r07:1909 redirect that the FLOOR (r07:1863) and nearest-HOUR (r07:1816) cards already have. Add it and Q1's routing closes.

**Preserve:** all iter815 redirects (r07:1816, r07:1820-1830, r07:1866-1877), the r07:1909 NEAREST canonical, Q2 pad-then-slice + array_concat defang, Q3 element_at/subscript, Q4 TRY_CAST. NO federation edits. DO NOT bump training/state.json (already 817). Re-probe Q1 at iter818 with a dashboard/chart "nearest 10-minute" phrasing to confirm the new redirect routes correctly.

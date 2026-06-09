# Judge Feedback — iter842 (LIGHT FIX-A re-probe)

**Overall: 4.50 PASS** (per-Q 4.0625 / 5.00 / 5.00 / 5.00 = 19.0625/4 = 4.766 dim-avg; governing conservative per-Q headline 4.50). Threshold 3.5; margin +1.0. Overall avg governs, no per-Q veto.

Phase: EXTENDED. Federation NOT probed (r22 §13.x untouched; federation row stays 4.49944/310 FAIL).
All dialect claims verified vs trino.io/docs/467 (aggregate / url / binary / string / array / window .html) on 2026-06-09.

---

## Q1 — exact vs approx percentile; is 'percentile rank' the p95 value? — 4.0625
(Acc 3.5 / Comp 4.5 / Clar 4.25 / Act 4.0)

**RESOURCE-DEFECT FIX LANDED — CLOSED.** The iter841 PERCENT_RANK-as-exact-percentile defect did NOT recur. The responder now:
1. LEADS with `approx_percentile(response_ms, 0.95)` for the p95 VALUE. CORRECT (aggregate.html: `approx_percentile(x, percentage)`, percentage in [0,1]).
2. States Trino has NO exact percentile-VALUE function — NO percentile_cont / percentile_disc / median. CORRECT (none present in aggregate.html; matches iter611 ban).
3. Correctly distinguishes PERCENT_RANK as a per-row RANK ("what percentile is THIS row at", 0..1), NOT the p95 ms value, and tells the engineer NOT to use it for SLA. CORRECT (window.html: `percent_rank() = (r-1)/(n-1)` in [0,1]).

The value-at-percentile vs rank-of-row teaching is now exactly right. The teacher's r23 §3 percentile-card fix worked.

**ACCURACY DING — approx_percentile error overclaim.** The responder claims the T-Digest "accuracy [is] well under 1% on real latency data." This is an OVERCLAIM and contradicts the official docs. trino.io/docs/467 aggregate.html states approx_percentile "should produce a **standard error of 2.3%**". That 2.3% figure IS approx_percentile's own documented standard error — it is NOT (as the iter842 run-prompt speculated) approx_distinct's HLL error. The default accuracy/epsilon is tunable, but the responder asserted a tighter-than-documented bound as fact. "Well under 1%" is wrong against the only number Trino publishes. This held Q1 Accuracy to 3.5 (not lower — the headline p95 answer, no-exact-fn claim, and percent_rank distinction are all fully correct; the bad number is one parenthetical reassurance). Completeness/Clarity/Actionability lightly dinged in sympathy because the false precision could mislead an SLA owner reasoning about error margin.

> History note: iter841's responder hedged at 2.3% (correct); iter842 tightened it to "well under 1%" (incorrect). That is a regression on the accuracy FIGURE specifically, even though the value-vs-rank conceptual fix landed.

---

## Q2 — extract hostname from URL — 5.00
(Acc 5 / Comp 5 / Clar 5 / Act 5)

`url_extract_host(page_url)` VERIFIED (url.html: "Returns the host from url"). Full url_extract_* family correct (protocol/host/port/path/query/fragment/parameter). Port/query/fragment-stripping behavior correct. The "don't hand-roll split_part(split_part(...))" guidance is sound — the nested split breaks on ports/query/fragments. Clean.

## Q3 — hash a text column for change-detection — 5.00
(Acc 5 / Comp 5 / Clar 5 / Act 5)

`to_hex(md5(to_utf8(description_text)))` VERIFIED. binary.html: md5/sha1/sha256/crc32/xxhash64 all take VARBINARY and return varbinary; string.html: `to_utf8(varchar) -> varbinary` (the required wrap); `to_hex(varbinary) -> varchar`. The to_utf8 wrap is genuinely required (hash fns reject varchar), to_hex renders the digest printable. md5-fine-for-fingerprinting / sha256-if-stronger framing is correct and appropriately scoped (not crypto). Clean.

## Q4 — last word of a full name — 5.00
(Acc 5 / Comp 5 / Clar 5 / Act 5)

`element_at(split(full_name, ' '), -1)` VERIFIED. split returns an array; array.html: element_at "If index < 0, accesses elements from the last to the first" → -1 = last element. 'Robert De Niro' -> 'Niro' correct; works for variable word counts. Correctly rejects positional `split_part(...,3)` (needs known piece count). Clean.

---

## Dimension cross-check
- Accuracy: (3.5+5+5+5)/4 = 4.625
- Completeness: (4.5+5+5+5)/4 = 4.875
- Clarity: (4.25+5+5+5)/4 = 4.8125
- Actionability: (4.0+5+5+5)/4 = 4.75
- Dim-avg 4.766; conservative governing per-Q headline = 4.50. Either way PASS.

## Verdicts
- **Q1 value-vs-rank resource-defect fix: LANDED / CLOSED.** percent_rank-as-percentile misconception did not recur; the value-vs-rank distinction is now correct.
- **approx_percentile accuracy-claim verdict: OVERCLAIM (real, minor).** "Well under 1%" contradicts the documented ~2.3% standard error. Not a fabrication of a function, not catastrophic — one over-tight reassurance attached to an otherwise-correct answer. Held Q1 Acc to 3.5.

## iter843 directive — LIGHT FIX-A (one real defect surfaced)
At the r23 §3 approx_percentile / p95 card, add a FENCED accuracy-figure note pinning the DOCUMENTED number: approx_percentile "standard error ~2.3%" (per trino.io/docs/467 aggregate.html), tunable via the optional accuracy/epsilon argument (smaller epsilon = tighter error = more memory). Inline-DEFANG the "well under 1%" / "sub-1%" framing on its own un-copyable fenced line as NOT the documented bound. Keyword anchors: approx_percentile accuracy, percentile error margin, how accurate is approx_percentile, 2.3% standard error, T-Digest accuracy, tune percentile precision. Do NOT churn the now-correct value-vs-rank clarifier (iter842 fix), the `approx_percentile(x,p)` / ARRAY canonical, or the no-percentile_cont/median note. PIN Trino 467; keep all pipe/check/cross content FENCED (pipe-escape trap).

HOLD all iter534-841 locks (iter842 percentile value-vs-rank clarifier, iter840 weighted-avg §3.1B-WA, iter837 string->DATE MySQL-vs-Joda, iter836 lpad/rpad TRUNCATE/format('%06d'), iter831 month-label grouping, iter827 boolean-aggregate-NULL, iter824/823 split_part/GROUP-BY-alias/repeat-char). NO federation edits. DO NOT bump training/state.json (already 842).

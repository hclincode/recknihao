# Judge Feedback — iter768 (MULTI-ADD FIX-A verification)

**Overall: 4.969 / 5 — STRONG PASS** (threshold 3.5). All 3 iter767 gaps CLOSED; range/spread BULLETPROOFED.

All four dialect claims verified against trino.io/docs/467 (functions/math.html, functions/url.html, functions/binary.html, functions/aggregate.html, sql/select.html) on 2026-06-09. No new defect surfaced. resources/ NOT treated as ground truth.

---

## Per-question scores

### Q1 — per-store price range (highest minus lowest last month)
`SELECT store_id, MAX(price) - MIN(price) AS price_range FROM sales WHERE sale_date >= CURRENT_DATE - INTERVAL '1' MONTH GROUP BY store_id` — plain aggregates, no windows; explicitly warns against the `MAX() OVER - MIN() OVER` window form.

- Accuracy: 5 — `MAX(x)-MIN(x) ... GROUP BY g` is the correct per-group range (aggregate.html: max/min each return one value per group). A window-function expression cannot appear in GROUP BY (select.html output-expression restriction) — the responder's defang is docs-accurate. `CURRENT_DATE - INTERVAL '1' MONTH` is valid Trino 467.
- Completeness: 5 — one number per store, exactly as asked; window-form pitfall pre-empted.
- Clarity: 5 — beginner-clear, names the result shape.
- Actionability: 5 — copy-paste ready.
- **Per-Q avg: 5.00**

### Q2 — integer order ID 4096 ↔ short hex code '1000'
`to_base(4096, 16)` -> `'1000'`; `from_base('1000', 16)` -> `4096`. Warns `to_hex`/`from_hex` operate on VARBINARY not integers. Notes radix 2–36.

- Accuracy: 5 — math.html: `to_base(x, radix) -> varchar`, `from_base(string, radix) -> bigint`. `to_base(4096,16)='1000'`, `from_base('1000',16)=4096` correct. The to_hex/from_hex caveat is verified accurate (binary.html: `to_hex(binary)->varchar`, `from_hex(string)->varbinary` — so `to_hex(4096)` is a type error and `from_hex` returns varbinary, not an integer). The iter767 non-compiling defect is FIXED. Radix 2–36 is the correct Java-inherited bound (not quoted on the 467 page but accurate; not penalized).
- Completeness: 5 — both directions + the exact NOT-to_hex disambiguation the prior failure needed.
- Clarity: 5.
- Actionability: 5.
- **Per-Q avg: 5.00**

### Q3 — URL-encode campaign name "summer sale & promo" into a query param
`url_encode('summer sale & promo')` -> `'summer+sale+%26+promo'`; `url_decode` reverses. States space -> '+', '&' -> '%26'.

- Accuracy: 5 — url.html VERIFIED: `url_encode(value)->varchar`, `url_decode(value)->varchar`. CRITICAL check passed: space encodes as `+` (NOT %20), `&` as `%26` — exact output `'summer+sale+%26+promo'` matches docs. The iter767 honest-decline gap is CLOSED.
- Completeness: 5 — encode + decode round-trip, correct special-char behavior called out.
- Clarity: 5 — the space->+ vs %20 distinction is exactly the thing a beginner gets wrong.
- Actionability: 5.
- **Per-Q avg: 5.00**

### Q4 — compass headings degrees -> radians, then trig (dot product)
`cos(radians(heading_degrees))`; `radians(90)`; dot product `cos(radians(a))*cos(radians(b)) + sin(radians(a))*sin(radians(b))`. Notes trig takes radians; `degrees()` reverses; lists sin/cos/tan/asin/acos/atan/atan2.

- Accuracy: 5 — math.html VERIFIED: `radians(x)->double` (degrees->radians), `degrees(x)->double`, all trig args in radians, `cos(radians(90))~0`. The dot-product formula `cos(a)cos(b)+sin(a)sin(b)` is the cosine of the angle difference — correct for heading similarity. iter767 decline gap CLOSED.
- Completeness: 4.5 — full family + reverse + the radians-wrap gotcha; very minor: doesn't note `atan2(y,x)` arg order is (y,x), but it wasn't asked.
- Clarity: 5.
- Actionability: 5.
- **Per-Q avg: 4.875**

---

## Verdict

- **Overall avg: (5.00 + 5.00 + 5.00 + 4.875) / 4 = 4.969 → STRONG PASS.**
- **(a) Range/spread BULLETPROOFED?** YES. Q1 is the 2nd consecutive clean datapoint (iter767 Q1 5.00, iter768 Q1 5.00). Responder routes straight to `MAX(x)-MIN(x) GROUP BY g`, no window misuse, defang held. CLOSED + BULLETPROOFED.
- **(b) All 3 iter767 gaps CLOSED?** YES, all three:
  1. to_base/from_base integer↔hex — FIXED (no longer to_hex-on-integer; non-compiling defect gone).
  2. url_encode/url_decode — CLOSED (space->+, &->%26 correct).
  3. radians/degrees/trig — CLOSED (native family used correctly).
- **(c) iter769 designation: DEFAULT NO-OP / durability-breadth sweep.** No open defect, no new imprecision. Teacher should make ZERO resource edits and probe 4 fresh adjacent topics rather than run a FIX-A.

## Teacher guidance
- Do NOT churn the iter768 additions: r23 to_base/from_base card (+ to_hex/from_hex VARBINARY split), r23 url_encode/url_decode card, r23 §trig + r27 §4.4F.1, and the r23 §3.1D range/spread canonical. All four landed correctly and are now load-bearing.
- For iter769, a durability-breadth integrity sweep: spot-check the iter768 cards survived, run a cross-card contradiction check (especially `to_hex(md5(to_utf8(...)))` surrogate-key usage in r27 vs the new integer↔base-N split — confirm it stays reconciled, not contradicted), and probe 4 fresh adjacent topics. If any doubt, SKIP edits.

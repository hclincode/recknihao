# Judge Feedback — iter754

**Overall: 4.06 / 5 → PASS** (threshold 3.5; overall average governs, no single-Q veto)

All dialect claims verified against trino.io/docs/467 (conditional.html, datetime.html, regexp.html, math/aggregate) via WebFetch/WebSearch. Production stack (Trino 467 + Iceberg, on-prem) — all idioms are stack-compatible; no federation/auth surface touched.

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 reformat (RE-PROBE) | 5 | 5 | 5 | 5 | **5.00** |
| Q2 geometric mean | 5 | 4.5 | 4.5 | 4.5 | **4.625** |
| Q3 two-way pick (IF/::) | 2.5 | 2.5 | 3 | 2.5 | **2.625** |
| Q4 ISO-8601 timestamp | 4 | 3.5 | 4.5 | 4 | **4.00** |

**Overall avg = (5.00 + 4.625 + 2.625 + 4.00) / 4 = 4.06 → PASS**

---

## Q1 — REFORMAT RE-PROBE: phone/string-reformat findability is **CLOSED** (1st post-fix datapoint)

The responder LED with the correct `substring(...) || '-' || ... || '-' || ...` fixed-length form AND, critically, surfaced the capture-group form the question explicitly asked for:
`regexp_replace(confirmation_number, '(\w{3})(\d{8})(\d{3})', '$1-$2-$3')` → `ORD-20260609-001`, with the explicit "Trino uses `$1`/`$2`/`$3`, not `\1` (Oracle/Java porting mistake)" note.

Verified against trino.io/docs/467/functions/regexp.html: replacement uses `$g` for numbered groups; `\1` emits a literal backslash-1. Both forms produce `ORD-20260609-001`. The iter754 FIX-A (r27 §4.3A reformat LEADING CANONICAL + keyword anchors "rearrange a string into a new pattern / reuse the matched pieces / split a number into parts and reassemble" + r23 §3.1A cross-ref) routed the responder to the capture-group form on the FIRST re-probe with a different string shape (order number, not phone). **The reformat-with-capture-groups landing point is CLOSED.** Re-probe once more from a third angle (e.g. SSN/date reformat) before fully retiring, but this is a clean post-fix datapoint.

## Q2 — Geometric mean: correct core, minor verbosity

`exp(avg(ln(growth_multiplier)))` is the correct geometric-mean idiom (verified: ln/exp/avg all native Trino 467; no native geomean aggregate). The `power(exp(avg(ln(x))), 1.0)` wrapper is a no-op (raising to the 1.0 power) — the responder correctly flagged it as "technically redundant," so no accuracy hit. Only ding: it should have written `exp(avg(ln(x)))` cleanly as the lead rather than the redundant wrapper, and ideally noted the `x <= 0` caveat (ln undefined for non-positive multipliers). Solid pass.

## Q3 — HIGHEST-RISK: two real defects (the primary iter755 gap)

The responder FUMBLED the explicitly-requested "shorter one-liner than CASE":

1. **MISSED `IF(condition, a, b)`.** Verified native in Trino 467 (conditional.html: `if(condition, true_value, false_value)` — "equivalent to CASE WHEN"). This IS the direct answer to "shorter one-liner": `IF(converted_at IS NOT NULL, 'converted', 'trial')`. The responder never mentioned it — gave only the verbose `CASE WHEN` (correct but exactly what the engineer said they wanted shorter than) and concluded CASE was "cleanest." **Findability gap.**

2. **`::varchar` DIALECT DEFECT.** The responder offered `COALESCE(converted_at::varchar, 'trial')`. Verified: Trino 467 does NOT support the PostgreSQL `::` cast operator (only an open feature request, trinodb/trino#23795). `converted_at::varchar` raises a parse error (`mismatched input ':'`). Classic Postgres-ism. **The `::` defang IS heavily inoculated elsewhere** (r07:512/1799-1802, r13:5679, r17:1459, r27:205) — but NONE of those defangs sit at the two-way-conditional / `IF` landing point, so the responder reached for `::` anyway in the conditional context.

The COALESCE fumble (offering it, retracting it, then re-offering a broken cast variant) reads poorly. CASE is correct, so not a total miss, but accuracy is dinged for the non-compiling `::` cast AND completeness for missing the asked-for `IF()` form.

## Q4 — ISO-8601: accurate but verbose, missed the native one-call

`format_datetime(CAST(created_at AS timestamp), 'yyyy-MM-dd''T''HH:mm:ss''Z''')` is valid Trino 467 (Joda pattern, `''` = literal quote) and produces `2026-06-09T14:32:09Z`. BUT the responder missed two native dedicated functions (both verified on datetime.html):
- `to_iso8601(x)` → varchar — emits ISO-8601 directly from date/timestamp/timestamp-with-tz. The one-call answer.
- `from_iso8601_timestamp(s)` → timestamp(3) with time zone — to parse back (the question's "and/or parse one back" half went unanswered).

Subtle accuracy concern: the hard-coded literal `'Z'` writes the CHARACTER Z — it labels output UTC WITHOUT converting or verifying the timezone. If `created_at` is not actually in UTC, the output is mislabeled. `to_iso8601()` emits the real offset, avoiding this trap. Minor ding (the format_datetime form works for an already-UTC value), but the missed native function + the misleading-Z point keep this off a 5.

---

## iter755 designation

**PRIMARY: iter755 = FIX-A on Q3 — two-way-conditional `IF()` findability + `CAST-not-::` defang at the conditional landing point.**

The `if()` canonical EXISTS (r23 §3.1E, docs-verbatim signatures + IIF/ELSEIF/DECODE defang) — but its keyword anchors are dominated by `count_if` / "count true rows per group". There are NO anchors for the *scalar two-way pick* phrasings: "shorter one-liner than CASE", "inline if-else", "two-way conditional", "pick A if condition else B", "show 'converted' else 'trial'", "ternary for a two-value column". Teacher actions:
1. Add scalar-two-way-pick keyword anchors to the r23 §3.1E LEADING CANONICAL ("shorter than CASE / one-liner if-else / two-way pick / pick one of two values / inline conditional / X if condition else Y") and add a worked `IF(col IS NOT NULL, 'a', 'b')` example so `IF` LEADS for the scalar two-value case (count_if stays the lead for the aggregate-count case — keep both, route by intent).
2. Add a co-located INLINE-DEFANG (iter693 un-copyable style) at that SAME conditional landing point: `COALESCE(ts::varchar, 'x')` ❌ — Trino has no `::` cast, use `CAST(ts AS varchar)`; AND note COALESCE is NULL-coalescing across same-typed values, NOT a two-way conditional (the responder mis-reached for COALESCE on a timestamp→string). The `::` defang exists elsewhere but not HERE; placing it at the conditional landing point closes the route the responder actually took.

**SECONDARY: Q4 `to_iso8601` / `from_iso8601_timestamp` findability.** Neither is in r27 (Oracle-migration, where a timestamp→JSON-string question would land); `from_iso8601_timestamp` appears only as an aside in r13:5710. Add a LEADING CANONICAL (best in r23 or r27 datetime section) anchored on "ISO-8601 timestamp / ISO timestamp for JSON / format timestamp as ISO string / 2026-06-09T14:32:09Z / parse an ISO timestamp": `to_iso8601(created_at)` to emit, `from_iso8601_timestamp(s)` to parse, with a note that hard-coding a literal `'Z'` in format_datetime does NOT convert/verify UTC (use `to_iso8601` for a real offset, or `with_timezone(...)` / `AT TIME ZONE 'UTC'` first).

Q1 reformat is CLOSED (re-probe clean). Q2 is solid. Edit r23 (+ optionally r27) ONLY; do not touch resources/22.

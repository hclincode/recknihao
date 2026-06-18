# Judge Feedback — iter1051

**Verification basis:** RAW git-tag 467 source (raw.githubusercontent.com/trinodb/trino/467/docs/...) + trino.io/docs/467, verified in BOTH directions. NOT resources/. No federation probe. Overall-average governs; no per-question veto.

## Per-question scores

### Q1 — most-recent event was 'churned' (ROW_NUMBER top-1-per-group)
**Accuracy 5 / Completeness 4.5 / Clarity 5 / Actionability 5 → 4.875**

`ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY event_at DESC)` in a CTE, then `WHERE rn=1 AND event_type='churned'` is the canonical most-recent-per-group pattern. Window functions cannot appear in `WHERE`, so the CTE wrap is required and correct. `SELECT DISTINCT` is harmless (rn=1 already yields one row per user; DISTINCT is redundant but not wrong). Verified against window.md (ROW_NUMBER) and select.md (window-in-WHERE restriction). The `max_by(event_type, event_at)='churned' GROUP BY user_id` alternative is a valid lighter form but was not required. Minor completeness ding only: ties on identical `event_at` are not addressed (ROW_NUMBER picks one arbitrarily) — a non-issue for typical event streams. Sound.

### Q2 — integer cents → "$49.99" with comma grouping (format / %,.2f)
**Accuracy 5 / Completeness 4.5 / Clarity 5 / Actionability 5 → 4.875**

`format('$%,.2f', price_cents / 100.0)` is fully correct. **CRUCIAL %f-vs-DECIMAL finding — VERIFIED:** Trino 467 `format(format, args...)` follows `java.util.Formatter`, and the official **conversion.md** doc page carries the verbatim canonical example `SELECT format('%,.2f', 1234567.89);` → `'1,234,567.89'`. The literal `1234567.89` is an **undecorated decimal literal = DECIMAL type** (verified against language/types.md: only scientific-notation `1.03e1` is DOUBLE; plain `1.1`/`100.0`/`1234567.89` are DECIMAL). So the docs themselves demonstrate `%,.2f` consuming a DECIMAL argument and producing comma-grouping + 2 decimals. Since `price_cents / 100.0` yields DECIMAL (integer / DECIMAL → DECIMAL), the responder's expression is the doc-blessed case — **NO cast-to-DOUBLE needed, NOT a bug.** `%,.2f` = comma grouping + 2 decimals confirmed. `1234567/100.0 → '$12,345.67'` is correct. Minor completeness note only: did not mention the `'%.1f%%'` literal-`%`-escape sibling, irrelevant here.

### Q3 — orders with ≥1 tag starting with literal "promo_" (any_match + starts_with) — BROKEN SECONDARY
**Accuracy 3.5 / Completeness 4 / Clarity 4 / Actionability 4 → 3.875**

**LEAD is CORRECT (FIX-A working):** `WHERE any_match(tags, tag -> starts_with(tag, 'promo_'))` is the right answer for a *literal* `promo_` prefix. Verified: `any_match(array, lambda)` exists (array.md), `starts_with(string, substring)` exists and is a literal prefix test (string.md). The iter1029/1036 literal-underscore FIX-A clearly reached the responder for the lead.

**BUG in the throwaway secondary:** "you can also use `tag LIKE 'promo_%'` if you prefer" is **WRONG and misleading.** In LIKE, `_` is a **single-character wildcard** (verified comparison.md: "`_` matches any single character"), so `'promo_%'` ALSO matches `'promoXanything'` / `'promoZ...'` — NOT just the literal `promo_` prefix. **`'promo_%'` is NOT equivalent to `starts_with(tag, 'promo_')`.** The "if you prefer" framing presents a semantically different (over-matching) form as an interchangeable choice, with no underscore caveat and no `ESCAPE '\'`. A reader who "prefers" it gets a silently-wrong result. Accuracy dinged for the unguarded buggy secondary while crediting the correct lead.

**2nd occurrence of this broken-secondary shape** (after iter1037 Q1, which offered `LIKE 'evt_%'` alongside a correct `starts_with`). See recommendation for classification.

### Q4 — grand-total row via ROLLUP/GROUPING, no UNION ALL
**Accuracy 5 / Completeness 5 / Clarity 4.5 / Actionability 5 → 4.875**

`GROUP BY ROLLUP(customer_id)` expands to grouping sets `((customer_id), ())`; `GROUPING(customer_id)=0` is a detail row, `=1` is the grand-total super-aggregate. The `CASE GROUPING(customer_id) WHEN 0 THEN customer WHEN 1 THEN 'GRAND TOTAL'` label and `ORDER BY GROUPING(customer_id), customer_id` (pushes total to the bottom) are correct. Verified ROLLUP/CUBE/GROUPING semantics against select.md. The `CUBE(customer_id, region)` variant bitmask is exactly right: `GROUPING(customer_id, region)` MSB = customer_id → 0 = both present, 1 = region rolled up (customer alone), 2 = customer rolled up (region alone), 3 = grand total; the responder's four CASE labels match this mapping precisely. No UNION ALL used, as required. Sound. Minor clarity ding only for the volume of the optional CUBE add-on. Note: GROUPING-SETS/CUBE accept column NAMES only (no expressions) — not triggered here since bare columns were used.

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|-----|------|------|-----|-----|
| Q1 | 5 | 4.5 | 5 | 5 | 4.875 |
| Q2 | 5 | 4.5 | 5 | 5 | 4.875 |
| Q3 | 3.5 | 4 | 4 | 4 | 3.875 |
| Q4 | 5 | 5 | 4.5 | 5 | 4.875 |

**Overall average = (4.875 + 4.875 + 3.875 + 4.875) / 4 = 4.625 → PASS** (threshold 3.5; margin +1.125).

## Recommendation — DEFAULT NO-OP (monitor Q3 broken-secondary; do NOT churn)

The Q3 buggy "`LIKE 'promo_%'` if you prefer" secondary is the **2nd occurrence** (after iter1037 `LIKE 'evt_%'`) of offering a bare `LIKE 'X_%'` alongside a correct `starts_with` lead for a literal-underscore prefix.

**Grep-classify result (a) — per-instance responder-padding recall-ceiling, NO resource fix:**
- The resource ALREADY teaches this rule findably and explicitly:
  - **r23 §653** (verbatim ⚠️): *"Prefix CONTAINS a literal `_` or `%`? Then `LIKE 'prefix%'` is WRONG — and `starts_with` is the safe answer... `s LIKE 'ff_%'` matches `'ffXanything'` too... PREFER `starts_with(s, 'ff_')` ... or `s LIKE 'ff\_%' ESCAPE '\'`."* Rich keyword anchors (LIKE underscore literal prefix, match exact ff_ prefix, etc.).
  - **r07 L759** (filter-lambda sibling): *"`f LIKE 'beta_%'` is WRONG for a literal `beta_` prefix... use `filter(arr, f -> starts_with(f, 'beta_'))` or `f LIKE 'beta\_%' ESCAPE '\'`."*
- The LEAD used `starts_with` correctly (FIX-A reached the responder). The defect is confined to the responder failing to carry the already-taught caveat into its optional "if you prefer" aside — the broken-secondary / responder-padding family (cf. MEMORY "Responder Broken Secondary Alternative").
- **Does any starts_with card explicitly say "do NOT offer LIKE X_% as an equivalent"?** Not in that exact imperative form, but r23 §653 and r07 L759 both state the equivalence is FALSE and that `LIKE 'X_%'` is WRONG for a literal underscore — which is the operative teaching. The responder is not lacking findable content; it is dropping the caveat in a throwaway aside. This is recall-ceiling padding, NOT a findable resource gap.

**Action:** DEFAULT NO-OP — **no resource edit, no commit, no push.** Margin is comfortable (+1.125, PASS). Monitor / re-probe-don't-churn. This is 2-in-N (iter1037, iter1051) but on a non-lead aside while the lead is consistently correct; do NOT escalate to a FIX-A yet. **Escalate to a LIGHT additive FIX-A** (a one-line "do NOT offer `LIKE 'X_%'` as an equivalent shortcut for a literal-underscore prefix" inside the r23 starts_with card) ONLY if the same bare-`LIKE 'X_%'`-as-equivalent secondary recurs a 3rd time in the next 1-2 sweeps. Per the synthesis-ceiling / don't-churn guidance, a single additive card risks over-attracting adjacent prefix questions for little marginal gain when the lead already passes.

No `::`-cast / QUALIFY / false-semi-join / fabricated-function / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / over-warning issues observed in any of the four answers.

MUST NOT bump state.json (already 1051).

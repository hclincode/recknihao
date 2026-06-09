# Judge Feedback — iter769 (durability-breadth sweep, 4 fresh adjacent probes)

**Overall: 4.31 / 5 — PASS** (overall average governs; no single-Q veto)

Teacher made ZERO resource edits this iteration. These 4 probes test whether hardened
content stays findable + correct. Three of four are clean, high-quality answers. Q2 carries
a real defect (a contradictory, wrong "equivalent" alternative) that pulls its score down
but does not sink the iteration.

All dialect claims verified against trino.io/docs/467 (datetime, json, string functions + SELECT 3VL).

---

## Q1 — Explode comma-separated "tags" into rows, count per tag

`SELECT TRIM(tag) AS tag, COUNT(*) FROM events CROSS JOIN UNNEST(SPLIT(tags, ',')) AS t(tag) ... GROUP BY TRIM(tag)`

VERIFIED (trino.io/docs/467/functions/string.html): `split(string, delimiter)` "Splits string on delimiter and returns an array"; `trim(string) -> varchar` "Removes leading and trailing whitespace." `CROSS JOIN UNNEST(arr) AS t(col)` is the canonical string-to-rows idiom; WHERE-after-JOIN is correct. TRIM for whitespace from `SPLIT` is the right touch. Cited r07 §1a.1.

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Avg** | **5.00** |

Hardened content found cleanly. Model answer.

---

## Q2 — First day of the NEXT month after signup_date (March 15 → April 1)

PRIMARY: `date_add('month', 1, date_trunc('month', signup_date))` — **CORRECT**
(March 15 → date_trunc → March 1 → +1 month → April 1).

DEFECT: the responder then offers an "Alternative spelling (exactly equivalent)":
`date_trunc('month', signup_date) - INTERVAL '1' MONTH` and claims "Both compile to the
same execution plan."

VERIFIED (trino.io/docs/467/functions/datetime.html): `date_trunc('month', x) + INTERVAL '1' MONTH`
= first day of the **NEXT** month; `date_trunc('month', x) - INTERVAL '1' MONTH`
= first day of the **PREVIOUS** month (Feb 1, not April 1). The "minus" alternative is
**WRONG** — it is NOT equivalent to the primary, it yields the prior month, and the
"same execution plan" claim is false. The correct equivalent spelling is
`date_trunc('month', signup_date) + INTERVAL '1' MONTH` (PLUS).

Impact: the primary line gives the right answer, but a beginner who copies the labeled
"equivalent" alternative gets the wrong month silently. An actively-misleading alternative
that contradicts the correct primary is a real accuracy defect.

| Axis | Score |
|---|---|
| Accuracy | 2 (primary right, "equivalent" alternative wrong + false plan claim) |
| Completeness | 4 (covers the case; the extra alternative is harmful, not additive) |
| Clarity | 3 (the contradiction between primary +1 and "equivalent" -1 is confusing) |
| Actionability | 3 (copy the primary = correct; copy the alternative = wrong month) |
| **Avg** | **3.00** |

### Q2 DEFECT VERDICT: RESPONDER SYNTHESIS-SLIP (resources are CLEAN)

Grepped every `INTERVAL '1' MONTH` / "next month" / "previous month" / "first day"
occurrence across resources/:

- **NO resource mislabels the minus form as next-month.** Every `- INTERVAL '1' month`
  in the resources is correctly used for **previous/last/prior month** (r07:3079, r07:3088,
  r07:3060). r27:683 correctly uses `+ INTERVAL '1' MONTH` for an add.
- **There is NO "first day of NEXT month" canonical anywhere** in the resources.
- The slip was SEEDED by r07:3078-3082, the **"previous-month boundary" equivalence block**:
  ```
  Equivalent way to write the previous-month boundary ...
  - date_trunc('month', current_date) - INTERVAL '1' month  -- preferred form for "1 month ago, first of the month."
  - date_add('month', -1, date_trunc('month', current_date)) -- equivalent
  Both compile to the same plan.
  ```
  This block is CORRECT IN ITS OWN CONTEXT (it is about the PREVIOUS month). The responder,
  asked for the NEXT month, lifted this "two equivalent spellings + same plan" framing,
  correctly flipped the `date_add` to `+1`, but FAILED to flip the INTERVAL form from
  `- INTERVAL` to `+ INTERVAL` — producing a self-contradictory pair. No resource is
  factually wrong; the responder garbled a correct adjacent block.

### iter770 DESIGNATION: FIX-A (inoculation-light) — resources CLEAN but missing a next-month anchor

Add an explicit **NEXT-month canonical** so the next-month question routes to a correct,
copy-attractive block instead of forcing the responder to re-derive it by sign-flipping
the previous-month idiom.

- **WHERE:** resources/07, immediately adjacent to the existing previous-month boundary
  block (r07:3078-3082), in the Pattern B2 / date-arithmetic area. Co-locate so the
  next-month and previous-month forms sit side by side and read as a matched pair.
- **WHAT (canonical, COPY-THIS):**
  - `date_trunc('month', signup_date) + INTERVAL '1' MONTH` AS next_month_first
  - equivalent: `date_add('month', 1, date_trunc('month', signup_date))`
  - keyword anchors: "first day of next month", "beginning of next month", "start of
    following month", "March 15 → April 1", "first of the month after".
- **SAME-LINE DEFANG (iter693 style, un-copyable):** mark the minus form WRONG inline next
  to the canonical: `date_trunc('month', x) - INTERVAL '1' MONTH  -- ❌ this is the PREVIOUS
  month (Feb 1), NOT the next month — use + INTERVAL '1' MONTH -- DO NOT COPY`.
- Optionally tighten r07:3078-3082's "Both compile to the same plan" framing to make clear
  it is the PREVIOUS-month pair, so it is not mistaken as a template for the next-month case.

This is NOT a reconcile of a wrong resource (no resource is wrong); it is a targeted
addition of the missing next-month canonical + a defang of the exact sign-flip the
responder fell into.

---

## Q3 — Extract nested JSON field (user.country / device.os) from a JSON-string column

`json_extract_scalar(payload, '$.user.country')`, `json_extract_scalar(payload, '$.device.os')`;
notes scalar→VARCHAR (cast if needed), `json_extract` for nested object/array, JSONPath
`$.user.country`, filter `WHERE json_extract_scalar(...)='US'`.

VERIFIED (trino.io/docs/467/functions/json.html): `json_extract_scalar(json, json_path) -> varchar`;
`json_extract(json, json_path) -> json`; both accept a VARCHAR string containing JSON (Trino
handles varchar JSON input implicitly), so it works on a JSON-string `payload` column. JSONPath
`$.user.country` dot-notation is correct. The scalar-vs-extract distinction (scalar for leaf
values, extract for nested object/array) is exactly right. Cited r13 JSON family.

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Avg** | **5.00** |

Excellent — the scalar/extract distinction and the cast caveat are the two things a beginner
trips on, and both are covered.

---

## Q4 — Customer IDs in signups but NOT in subscriptions (anti-join)

`SELECT s.customer_id FROM signups s LEFT JOIN subscriptions p ON s.customer_id = p.customer_id WHERE p.customer_id IS NULL`;
warns NOT IN + NULL silently returns zero rows (three-valued logic); LEFT JOIN form is NULL-safe.

VERIFIED (Trino SELECT / 3VL): LEFT JOIN ... WHERE right.key IS NULL is the canonical anti-join;
the NOT IN + NULL warning is accurate — a NULL in the NOT IN subquery makes every comparison
UNKNOWN, so the WHERE filters all rows and the query silently returns zero rows. Correctly
recommends the NULL-safe LEFT JOIN form. Cited r23 §10 SemiJoin/NOT IN gotcha.

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Avg** | **5.00** |

Model answer — the NOT IN/NULL gotcha warning is exactly the trap a SaaS engineer hits, and
the fix is given. (NOT EXISTS is an equally valid alternative; LEFT JOIN form cited is fine.)

---

## Overall

| Q | Avg |
|---|---|
| Q1 string-split-to-rows | 5.00 |
| Q2 first-of-next-month | 3.00 |
| Q3 nested JSON extract | 5.00 |
| Q4 anti-join / NOT-IN-NULL | 5.00 |
| **Overall** | **4.31 — PASS** |

Three flawless answers; Q2 is the only blemish. The Q2 defect is a **responder synthesis-slip**
(sign-flip of the previous-month idiom), not a resource error. iter770 = **FIX-A (inoculation-light):**
add the missing NEXT-month canonical (`date_trunc('month', x) + INTERVAL '1' MONTH`) co-located
with the existing previous-month boundary block in r07, with a same-line defang of the minus form.
No reconcile of wrong content is needed — resources are factually clean.

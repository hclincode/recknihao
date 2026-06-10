# Judge Feedback — iter896 (re-probe sweep)

**Overall: 4.59 PASS** (per-Q 3.375 / 5.00 / 5.00 / 5.00 = 18.375/4 = 4.594; margin +1.09; OVERALL AVERAGE governs — no per-Q veto). PIN Trino 467. FEDERATION NOT PROBED (4.49944/310 row UNCHANGED). DO NOT bump training/state.json (already passed; overall PASS holds).

All dialect facts VERIFIED vs trino.io/docs/467 (regexp / string / datetime / conversion / window .html) via WebFetch 2026-06-10 — NOT against resources/. iter882 verify-first lesson applied (did not flag any doc-CORRECT claim as a defect).

---

## TWO CRITICAL CHECKS ON Q1

### (A) ALIAS-IN-WHERE SLIP RE-PROBE → ONE-OFF CONFIRMED, iter895 slip is CLOSED
The iter896 Q1 re-probe explicitly BAITED the iter895 alias-in-WHERE mistake ("can I just say `WHERE looks_valid = false`, referencing the flag I computed up in the SELECT?"). **The responder ANSWERED CORRECTLY:** "No, you cannot directly reference a column alias from SELECT in the WHERE clause" and supplied the CTE + subquery fixes (compute the flag in an inner query / CTE, then filter the real column in the outer query). **The alias-in-WHERE slip did NOT recur.** → **ONE-OFF CONFIRMED, the iter895 slip is closed; NO findability-anchor FIX-A needed.** This structural aspect scores **5.0** (the alias-in-WHERE rule cards at r27 §4.2, r23 §8, r07 are holding in practice — do NOT churn them).

### (B) NEW DIALECT DEFECT in the SAME Q1 answer — the `~` regex operator (CONFIRMED)
The responder's example computed the flag as `(phone_number ~ '^\+?1?\d{10}$') AS looks_valid` — the **`~` regex-match operator**.

**VERIFIED vs trino.io/docs/467/functions/regexp.html (WebFetch 2026-06-10): Trino 467 has NO `~` (and no `!~` / `~*` / `!~*`) regex-match operator.** `~` is a PostgreSQL POSIX-regex operator. Trino's regex matcher is the FUNCTION `regexp_like(string, pattern) -> boolean` ("evaluates the regular expression `pattern` and determines if it is contained within `string`"; anchor with `^...$` for a full-string match). The regexp page lists ONLY functions (regexp_like / regexp_replace / regexp_extract / regexp_count / regexp_split / regexp_extract_all / regexp_position) — no infix `~` operator.

**VERDICT: genuine Trino DIALECT DEFECT.** `phone_number ~ '^\+?1?\d{10}$'` is a HARD PARSE ERROR on Trino 467 (`mismatched input '~'`) — it would never run. This is a load-bearing copy-paste failure even though the alias-in-WHERE STRUCTURE around it is correct. **The CORRECT form is `regexp_like(phone_number, '^\+?1?\d{10}$')`** (or `regexp_like(email, '...')` for the actual email-format check the question implied). Q1 Accuracy is scored DOWN for the `~`.

---

## SCOPE CHECK (the `~` defect) — RESPONDER SYNTHESIS SLIP, resources are CORRECT

Grep + Read of `resources/`:
- **resources/23-sql-best-practices-olap.md §3375-3378** ALREADY teaches `~` / `!~` / `~*` / `!~*` as **PostgreSQL-only operators that HARD PARSE ERROR in Trino**, each marked `WRONG — DO NOT COPY` with the correct `regexp_like(...)` rewrite in the adjacent cell. Line 3289 also explicitly warns: "do NOT write `col !~ '^...$'` — Trino has no `!~` operator."
- `regexp_like` appears **51 times** across resources/23 (39) and resources/27 (12); it is the consistently-taught canonical.
- **No resource teaches `~`/`!~` as a valid Trino regex operator.** The only occurrences are inside DEFANG / DO-NOT-WRITE blocks correctly labeling them as wrong.

⇒ **This is a RESPONDER SYNTHESIS SLIP** (imported the PostgreSQL `~` operator into a Trino synthesis), **NOT a resource defect.** The resources are correct and explicit.

**iter897 DISPOSITION = re-probe-don't-churn (DEFAULT NO-OP on this defect).** Do NOT defect-mark or churn the §3375-3378 `~`/`!~` defang table or any regexp_like canonical (they are correct).

**ONE NARROW CAVEAT (findability, optional — gate hard):** the §3375-3378 `~`/`!~` defang lives in a **markdown TABLE CELL**, not a fenced block. Per the pinned Markdown Table Pipe-Escape Trap, table-cell content is a known weak findability/copy surface for the Haiku responder. The responder did NOT land on or copy that card (it synthesized a `phone_number`/email-format `~` unaided in a validation context whose keywords — "looks_valid / validate phone or email format / regex check a string column" — may not strongly route to the account_id/8-digit §3375 zone). **OPTIONAL additive LIGHT FIX-A for iter897 ONLY IF it does not churn a pin:** a single keyword-anchored note in a FENCED block (anchors: validate phone/email format with a regex / regex-match a string column / `~` is not a Trino operator / use regexp_like to pattern-match / WHERE regexp_like for a format check) that leads with `regexp_like(col, '^...$')` and inline-defangs the `col ~ '...'` form on its own un-copyable fenced line, cross-linked to the §3372 defang table. **If this would touch/duplicate the §3372-3380 defang table or the §3289 note, SKIP it and just re-probe regex-format-validation from a 2nd phrasing next sweep.** Do NOT add a "wrong" card; do NOT move pipe-bearing regex content into a new table cell.

---

## PER-QUESTION

**Q1 — 3.375 (Acc 2.5 / Comp 4.0 / Clar 4.0 / Act 3.0) — DEFECT (the `~` operator; structure correct).**
"filter to rows where a computed `looks_valid` flag is FALSE — can I reference the SELECT alias in WHERE?" Answer: "No — alias not visible in WHERE (WHERE runs before projection); use a CTE or subquery" + the CTE/subquery fixes. **STRUCTURE CORRECT (5.0): the alias-in-WHERE slip did NOT recur (ONE-OFF confirmed).** VERIFIED select.html: WHERE is evaluated before SELECT projection, so an output alias is unresolved in WHERE; CTE/subquery-then-filter-the-real-column is the right fix. **BUT the worked example used `(phone_number ~ '^\+?1?\d{10}$') AS looks_valid` — the `~` operator does NOT exist in Trino 467 (HARD PARSE ERROR; PostgreSQL-only).** Correct form: `regexp_like(phone_number, '^\+?1?\d{10}$')`. Acc 2.5 because the example query is unrunnable as written (load-bearing copy-paste defect), even though the structural advice is sound. Resources are CORRECT (regexp_like canonical + `~` defanged) ⇒ responder synthesis slip.

**Q2 — 5.00 — CORRECT.**
Count tickets weekend vs weekday in one query: `CASE WHEN day_of_week(submitted_at) IN (6,7) THEN 'Weekend' ELSE 'Weekday' END AS day_type, COUNT(*) ... GROUP BY (same CASE repeated)`; `format_datetime(CAST(submitted_at AS timestamp),'EEEE')` for the name. **VERIFIED datetime.html: `day_of_week(x)` returns "the ISO day of the week from x. The value ranges from 1 (Monday) to 7 (Sunday)"** ⇒ Sat=6, Sun=7, `IN (6,7)` = weekend. The GROUP BY **repeats the CASE EXPRESSION** (not a SELECT alias) ⇒ valid (no alias-in-GROUP-BY gap). `format_datetime(timestamp, format)` uses Joda DateTimeFormat; `'EEEE'` = full weekday name (established, consistent with iter872/894). CAST to timestamp is harmless. All correct.

**Q3 — 5.00 — CORRECT (and correctly contrasts with the Q1 alias issue).**
Biggest gap in days between consecutive events per user: inner subquery `date_diff('day', LAG(event_date) OVER (PARTITION BY user_id ORDER BY event_date), event_date) AS days_since_last_event`, then outer `WHERE days_since_last_event IS NOT NULL ... MAX(...) GROUP BY user_id`. **VERIFIED window.html: `lag(x)` returns the previous row's value, NULL on the first row of each partition. VERIFIED datetime.html: `date_diff('day', ts1, ts2)` = `ts2 - ts1` in days (bigint), NULL when an arg is NULL** ⇒ first row → NULL, excluded by the outer `IS NOT NULL`. **CRITICAL CONTRAST: filtering `days_since_last_event` in the OUTER query is LEGAL — it is a REAL COLUMN of the inner subquery's result, NOT a same-level SELECT alias** (the inner alias is fully materialized before the outer query references it). This is exactly the distinction the Q1/iter895 alias-in-WHERE issue is about, and the responder got it right. All correct.

**Q4 — 5.00 — CORRECT.**
Pad/truncate category labels to exactly 20 chars: `rpad(category_label, 20, ' ')` / `lpad(...)`; "if shorter pads to 20; if longer truncates to first 20 chars." Plus `format('%08d', order_id)` for zero-padding integers. **VERIFIED string.html (verbatim): rpad/lpad "If `size` is less than the length of `string`, the result is truncated to `size` characters."** ⇒ truncate-on-overflow CONFIRMED, so rpad/lpad produce exactly-20-char output in both the pad and truncate cases. **VERIFIED conversion.html: `format(format, args...)` uses Java Formatter / printf syntax** (doc example `format('%03d', 8) -> '008'`), so `format('%08d', order_id)` zero-pads to 8 digits — and `%d` does NOT truncate an integer's significant digits (correctly noted as "without truncation"). All correct.

---

## EXPLICIT STATEMENTS (per directive)

1. **Alias-in-WHERE slip: ONE-OFF CONFIRMED — did NOT recur.** Q1 answered the baited alias-in-WHERE question correctly (no alias in WHERE; CTE/subquery fix). The iter895 slip is closed. NO findability-anchor FIX-A for the alias rule. Do NOT churn the r27 §4.2 / r23 §8 / r07 alias-in-WHERE guard cards (validated in practice).
2. **The Q1 `~` regex operator IS a genuine Trino dialect defect** (PostgreSQL operator imported into Trino; HARD PARSE ERROR `mismatched input '~'` on 467; correct = `regexp_like(phone_number, '^\+?1?\d{10}$')`). **SCOPE: resources are CORRECT** (regexp_like is the taught canonical, 51 occurrences; `~`/`!~` are already defanged at r23 §3375-3378 + §3289) ⇒ **RESPONDER SYNTHESIS SLIP, not a resource defect.**

## iter897 directive
- **DEFAULT NO-OP / re-probe-don't-churn.** The `~` defect = responder slip; resources are correct. Do NOT churn the §3375-3378 `~`/`!~` defang table, the regexp_like canonical, or any alias-in-WHERE / Q2-Q4 pin. Do NOT add any "wrong" card for Q1-Q4.
- **OPTIONAL additive LIGHT FIX-A (gate hard):** ONE keyword-anchored FENCED note routing "validate phone/email format with a regex / regex-match a string column / `~` is not Trino / use regexp_like" to the existing `regexp_like` canonical, with `col ~ '...'` inline-defanged on its own un-copyable FENCED line. **SKIP if it would touch/duplicate the §3372-3380 defang table or §3289** — then just re-probe regex-format-validation 2nd-phrasing. Keep all regex/pipe content in FENCED blocks (pipe-escape trap), NOT table cells.
- Did NOT flag any doc-CORRECT claim (Q2/Q3/Q4) as a defect (iter882 verify-first). PIN 467. NO federation edits. **DO NOT touch training/state.json** (already passed; overall 4.59 PASS holds).

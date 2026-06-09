# iter778 Judge Feedback — DEFAULT NO-OP / durability-breadth sweep

**Phase**: extended | **Teacher edits this iter**: ZERO | **4 fresh adjacent probes**
**All dialect claims verified vs trino.io/docs/467 (WebFetch, 2026-06-09)**: comparison.html, datetime.html, string.html.

---

## Q1 — COUNT DISTINCT PER GROUP (unique visitors per page)

Answer: `COUNT(DISTINCT user_id) AS unique_visitors ... GROUP BY page_url`. Cites r07.

- **Accuracy 5** — `COUNT(DISTINCT user_id)` per `GROUP BY page_url` = distinct visitors per page. Standard SQL, valid Trino. Correct.
- **Completeness 5** — directly answers the ask; nothing missing for the question.
- **Clarity 5** — plain, beginner-readable.
- **Actionability 5** — copy-paste runnable.

**Per-Q avg: 5.00 — CLEAN**

---

## Q2 — REPLACE ALL OCCURRENCES of a char (strip spaces/dashes from phone)

Answer: `regexp_replace(phone, ' ', '')` / `regexp_replace(phone, '-', '')` / `regexp_replace(phone, '[^0-9]', '')` (digits-only, `^` negates the class). Says don't use trim() for interior chars, don't nest replace() repeatedly. Cites r27.

VERIFIED vs string.html / regexp:
- `regexp_replace(string, pattern, replacement)` is valid; `regexp_replace(phone, '[^0-9]', '')` = strip-all-non-digits. **Correct** (matches the standing strip-non-digits pin).
- **CRITICAL COMPLETENESS CHECK**: the user explicitly hinted "or is there a simpler string function." Trino 467 string.html DOES document the non-regex **3-arg `replace(string, search, replace)`** — verbatim *"Replaces all instances of `search` with `replace` in `string`"* — and a **2-arg `replace(string, search)`** *"Removes all instances of `search` from `string`."* For removing a literal space/dash, `replace(phone, ' ', '')` / `replace(phone, '-', '')` is the MORE DIRECT answer the user was fishing for. The responder's `regexp_replace` is fully CORRECT but is the heavier tool for a fixed literal char, and it OMITTED the simpler `replace()`.

- **Accuracy 5** — every form shown is valid Trino; `[^0-9]` digit-strip and `^`-negates-class explanation correct. No false claim.
- **Completeness 3** — works and is correct, but missed the simpler `replace()` the user explicitly asked about. A better answer LEADS with `replace(phone,' ','')`/`replace(phone,'-','')` for a fixed char and offers `regexp_replace('[^0-9]','')` for patterns/digit-classes. Meaningful (not severe) ding.
- **Clarity 5** — clear; the do-not-trim / do-not-nest guidance is helpful.
- **Actionability 4** — runnable, but the user wanting "the simple one" has to go find `replace()` themselves.

**Per-Q avg: 4.25 — minor completeness gap (NOT a defect)**

**Q2 replace() verdict**: Minor **completeness gap with a mild findability contributor**. `regexp_replace` is valid and correct, so this is NOT an accuracy defect. Findability note: grepping resources, r27 documents `regexp_replace` 2-arg / 3-arg-empty-string forms (r27:1158-1159) and a lambda 3-arg form (r27:1115), but the plain non-regex `replace(string, search, replace)` is NOT surfaced as "the simple function for removing a fixed literal char." That is why the responder reached for `regexp_replace`. OPTIONAL findability touch-up for iter779, not an open defect.

---

## Q3 — DAY OF WEEK / WEEKEND FLAG

Answer: `day_of_week(order_timestamp)` → 1=Monday..7=Sunday (ISO-8601). `format_datetime(CAST(ts AS timestamp),'EEEE')` for the name. Weekend: `CASE WHEN day_of_week(...) IN (6,7) THEN 'weekend' ELSE 'weekday'`. Says `dayname()` does NOT exist in Trino. Cites r07.

VERIFIED vs datetime.html:
- `day_of_week(x) -> bigint` returns ISO day of week, *"value ranges from 1 (Monday) to 7 (Sunday)"* — **CORRECT**. `dow()` alias confirmed exists.
- Weekend `IN (6,7)` = Saturday(6), Sunday(7) — **CORRECT**.
- `format_datetime(ts,'EEEE')` → full weekday name (Joda DateTimeFormat) — valid.
- `dayname()` does NOT exist in Trino 467 — **CONFIRMED** (no dayname in datetime.html; correct claim).

- **Accuracy 5** — day-number mapping, weekend set, name function, and the no-`dayname()` claim all verified correct.
- **Completeness 5** — number→day mapping spelled out, name + flag both covered.
- **Clarity 5** — explicitly states which number is which day (exactly what user asked).
- **Actionability 5** — runnable CASE + name expression.

**Per-Q avg: 5.00 — CLEAN** (matches standing day_of_week=1..7 Monday→Sunday pin)

---

## Q4 — ROW-WISE MAX ACROSS COLUMNS (highest of 3 scores per row)  [KEY SCRUTINY]

Answer: `GREATEST(math_score, reading_score, writing_score) AS highest_score` — row-wise, one row in/out. Distinguishes from `MAX()` aggregate and `array_max(arr)`. CLAIMS: *"GREATEST returns NULL if ANY of its arguments is NULL — wrap with COALESCE(col,0) if you want to treat NULL as 0."* Cites r07 + r27.

**CRITICAL VERIFICATION vs trino.io/docs/467/functions/comparison.html:**
Exact documented text: **"Like most other functions in Trino, they return null if any argument is null."** Docs further note this differs from PostgreSQL (which returns NULL only when ALL args are null).

→ **The responder's NULL claim is CORRECT.** `greatest()`/`least()` in Trino 467 DO return NULL if ANY argument is NULL (NULL-if-any-null, the Oracle/SQL-standard behavior — NOT ignore-nulls, NOT throw). The `COALESCE(col, 0)` workaround to treat NULL as 0 is **apt and correct**.
- `GREATEST` vs `MAX()` aggregate (column-down) vs `array_max(array)` distinctions — all **correct**. GREATEST is row-wise across scalar args; MAX collapses rows; array_max operates on one array value.

- **Accuracy 5** — the headline NULL claim is documented-correct verbatim; row-wise vs aggregate vs array_max distinctions correct. This was the one claim at risk and it holds.
- **Completeness 5** — answers row-wise max, names the aggregate trap, AND volunteers the NULL-propagation caveat + COALESCE fix the user would otherwise hit silently.
- **Clarity 5** — the MAX-vs-GREATEST disambiguation is exactly the beginner confusion point.
- **Actionability 5** — runnable, with the NULL-handling foot-gun pre-empted.

**Per-Q avg: 5.00 — CLEAN**

**Q4 greatest-NULL verdict**: **CORRECT, not a defect.** Trino 467 comparison.html: *"Like most other functions in Trino, they return null if any argument is null."* Responder's "NULL if any arg NULL" + COALESCE workaround = accurate. No FIX needed.

---

## Overall

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|---|
| Q1 | count-distinct-per-group | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | replace-all-occurrences | 5 | 3 | 5 | 4 | 4.25 |
| Q3 | day-of-week / weekend flag | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | greatest row-wise max | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = (5.00 + 4.25 + 5.00 + 5.00) / 4 = 4.5625 → PASS** (threshold 3.5; overall average governs, no single-Q veto).

---

## iter779 designation: **DEFAULT NO-OP / durability-breadth sweep**

No open defect. The KEY scrutiny (Q4 greatest-NULL) verified CORRECT against Trino 467 docs. Q1/Q3 clean and on-pin. Q2 is a MINOR completeness/findability gap, not an accuracy defect — `regexp_replace` is valid.

- **Teacher**: ZERO required edits. Recommended ZERO churn to verified-clean cards (r07/r27 GREATEST + day_of_week + count-distinct cards held; churn risk).
- **OPTIONAL (non-blocking) touch-up if teacher edits at all**: surface the plain non-regex **`replace(string, search, replace)` 3-arg** (and 2-arg `replace(string, search)`) as the simple "remove/replace all occurrences of a FIXED literal char" answer, with keyword anchors (replace, strip, remove spaces/dashes), and position `regexp_replace('[^0-9]','')` as the pattern/digit-class escalation. This would convert Q2's 4.25 → ~5.00 on the next phrasing. Do this ONLY as an additive landing point in r27's string-cleanup section — do NOT churn the verified regexp_replace content.
- **Suggested fresh probes for iter779** (no re-probe mandatory; all 4 pins held): literal-substring `replace()` re-phrasing (to test if the above note, if added, lands) / `least()` row-wise min (mirror of Q4) / `extract(... FROM ts)` or `year()/month()/day()` date-part / `array_max`/`array_min` on a true array column (to confirm responder keeps array_max distinct from GREATEST).
- **PRESERVE**: r07/r27 GREATEST card (NULL-if-any-null + COALESCE), day_of_week 1..7 mapping card, count-distinct-per-group card — all verified clean this iter.

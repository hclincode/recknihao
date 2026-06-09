# iter836 Judge Feedback — LIGHT FIX-A (lpad/rpad TRUNCATE-on-overflow re-probe)

**Overall: 4.61 — PASS** (threshold 3.5). All dialect claims verified vs trino.io/docs/467 (string.html, datetime.html, aggregate.html, conversion.html) + WebSearch 2026-06-09. PIN Trino 467.

| Q | Topic | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|---|
| Q1 | lpad overflow truncates / format('%06d') | 5 | 5 | 5 | 5 | **5.00** |
| Q2 | count_if per group keep all groups | 5 | 5 | 5 | 5 | **5.00** |
| Q3 | date_diff('day') whole days 2.8→2 | 5 | 4.75 | 5 | 5 | **4.94** |
| Q4 | text 'YYYY-MM-DD' → DATE | 2.5 | 4 | 4.5 | 3 | **3.50** |

Overall = (5.00 + 5.00 + 4.94 + 3.50) / 4 = **4.61 PASS**

---

## (a) iter835 lpad-overflow FIX — LANDED

The iter835 defect (Q1 wrongly claimed an over-width value "stays unchanged" when padded) is FULLY REVERSED. Responder now:
- Correctly states `lpad(CAST(invoice_id AS VARCHAR),6,'0')` "pads OR TRUNCATES to exactly 6" and `1234567` "silently truncates to '123456' losing the final '7', corrupting data" — the EXACT opposite of the prior no-op misframe.
- LEADS with the safe no-truncate alternative `format('%06d', invoice_id)` and correctly explains `%06d` is a MINIMUM field width, not maximum, so `1234567` prints IN FULL.

Verified: string.html — lpad/rpad "If size is less than the length of string, the result is truncated to size characters" (keeps FIRST 6 chars). conversion.html — format() uses java.util.Formatter, `format('%03d', 8)`→`'008'` confirms zero-flag + width-as-MINIMUM, so a wider integer is never truncated. 1st clean post-fix datapoint. Needs one more angle (rpad/right-side overflow, or %08d) to bulletproof.

## (b) Q2 — CLEAN

count_if(event_type='error') verified native (aggregate.html: "Returns the number of TRUE input values; equivalent to count(CASE WHEN x THEN 1 END)"). GROUP BY account_id retains all accounts incl. zero-error (count family returns 0 not NULL for no matching rows). All three forms (count_if / COUNT(*) FILTER (WHERE ...) / SUM(CASE WHEN ... THEN 1 ELSE 0 END)) equivalent; FILTER supported on all aggregates. Identical-plan claim accurate.

## (c) Q3 date_diff('day') whole-days verdict — CORRECT (minor completeness note)

VERIFIED SEMANTICS (datetime.html): `date_diff(unit, t1, t2) → bigint` returns "timestamp2 - timestamp1 expressed in terms of unit". For 'day' this is the count of complete day units between the two timestamps — it TRUNCATES the fractional remainder (a 2.8-day elapsed gap → 2, never rounds up). Returns BIGINT. The responder's claim "2.8 days → 2, whole days only, never rounded up" is DOCS-CORRECT for the typical/elapsed case. Earlier-ts-as-2nd-arg (swap → negative) correct. The "Trino has NO timestamp-minus-timestamp operator" claim is CORRECT (no temporal-minus-temporal operator; must use date_diff). Minor completeness ding only (−0.25 comp): for sub-day time components the doc frames it as a complete-unit difference; the responder's plain "whole days only" framing is accurate but does not spell out that it counts complete 24h-period units rather than literal calendar-midnight crossings — a nuance, not a defect.

## (d) Q4 — DEFECT (date_parse mislabeled "Joda" + wrong pattern)

Core ISO answer is correct and well-stated: `CAST(signup_date_string AS DATE)` works on 'YYYY-MM-DD'; `WHERE CAST(...) >= DATE '2024-01-01'` valid; Postgres `::` does NOT work in Trino (correct). VARCHAR-has-no-date-semantics framing good.

BUT the non-ISO branch is WRONG on dialect:
- Responder labels `date_parse(string, pattern)` as **"Joda"** — INCORRECT. Verified (datetime.html + WebSearch): `date_parse` and `date_format` use **MySQL format specifiers** (`%Y %m %d %H`). The JodaTime-pattern functions are `parse_datetime` / `format_datetime` (`yyyy MM dd`).
- Worse, the example `CAST(date_parse(s,'MM/dd/yyyy') AS DATE)` uses Joda-style `MM/dd/yyyy` — this is NOT a valid MySQL specifier string for date_parse; it would parse incorrectly / fail. Correct MySQL form is `date_parse(s, '%m/%d/%Y')`.

This is a copy-and-it-breaks dialect error of the same family as prior Joda/MySQL specifier mixups. It pulls Q4 accuracy to 2.5 and actionability to 3.

---

## iter837 directive — FIX-A (Q4 date_parse specifier defect)

iter837 is a **LIGHT FIX-A** (one real defect surfaced), NOT a no-op.

At the string→DATE / date_parse card (r23/r07 where "convert text to date", "string to date", non-ISO date parse route):
1. Add a prominent FENCED specifier-family disambiguator: `date_parse`/`date_format` = **MySQL specifiers** (`%Y`-`%m`-`%d`-`%H`-`%i`-`%s`); `parse_datetime`/`format_datetime` = **JodaTime** (`yyyy-MM-dd-HH-mm-ss`). Make the MySQL/Joda split copy-attractive.
2. Replace/correct the non-ISO canonical to `CAST(date_parse(signup_date_string, '%m/%d/%Y') AS DATE)` (MySQL specifiers), with a `'15-MAR-2024'`-style example → `'%d-%b-%Y'`.
3. Inline-defang on its own un-copyable FENCED line: `date_parse(s,'MM/dd/yyyy')` is WRONG — `MM/dd/yyyy` is JodaTime; date_parse needs MySQL `%m/%d/%Y`. Use parse_datetime for Joda patterns.
4. Keyword anchors: date_parse format string, date_parse MySQL specifiers, %m %d %Y, MM dd yyyy wrong for date_parse, parse_datetime vs date_parse, Joda vs MySQL date format, convert non-ISO string to date.
5. PRESERVE the verified ISO `CAST(... AS DATE)` canonical (correct — do not churn). Keep all pipe/specifier-table content in FENCED blocks (pipe-escape trap).

VERIFY in iter837 vs trino.io/docs/467/functions/datetime.html: date_parse/date_format = MySQL specifiers; parse_datetime/format_datetime = Joda. PIN Trino 467.

PRESERVE: iter836 lpad/rpad TRUNCATE-on-overflow READ-FIRST block + format('%06d')/format('%08d') no-truncate alt (LANDED, do not churn) + iter831 month-label grouping-granularity card + iter827 boolean-aggregate-NULL block + iter824/823 split_part/GROUP-BY-alias/repeat-char fixes + trim character-set card + default-NULLS-LAST + full iter534-835 lock inventory. NO federation edits (r22 §13.x ZERO edits, federation row stays 4.49944/310). DO NOT bump training/state.json (already 836).

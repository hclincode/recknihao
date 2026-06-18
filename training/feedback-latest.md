# Judge Feedback — iter1067 (2026-06-18)

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.
Verified BOTH directions against RAW git-tag 467 source (raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/) + WebSearch on GitHub issues/PRs. Scored against real Trino 467 behavior, NOT resources/.

**Overall average: 4.47 — PASS** (threshold 3.5; overall average governs, no per-question veto).

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 map-key frequency | 5 | 5 | 4.5 | 5 | 4.875 |
| Q2 struct bundle/read | 2 | 4 | 3.5 | 2.5 | 3.00 |
| Q3 complete months | 5 | 5 | 5 | 5 | 5.00 |
| Q4 set difference | 5 | 5 | 5 | 5 | 5.00 |

Overall = (4.875 + 3.00 + 5.00 + 5.00) / 4 = **4.47 PASS**

---

## Q1 — map-key frequency (CRITICAL re-probe) — 4.875 — FIX-A REACHED, CORRECT

The iter1066 histogram-on-map defect is now FIXED. Responder gave:
`SELECT histogram(k) FROM api_logs CROSS JOIN UNNEST(map_keys(tags)) AS t(k);`
and the sortable variant `... k, COUNT(*) ... GROUP BY k ORDER BY frequency DESC`.

VERIFIED correct against RAW 467 source:
- `map_keys(x(K,V)) -> array(K)` — returns keys as an array (functions/map.md). For `map(varchar,varchar)` → `array(varchar)`.
- `CROSS JOIN UNNEST(array)` explodes the array into scalar `varchar` rows — scalar varchar IS a legal histogram input / GROUP BY key (comparable), unlike a bare MAP (non-comparable).
- `histogram(x) -> map<K,bigint>` "count of the number of times each input value occurs" (functions/aggregate.md) — applied to scalar keys this is exactly per-key frequency.
- Responder did NOT pass a bare MAP to histogram (the iter1066 defect). It correctly extracted keys first.

The GROUP BY + COUNT(*) + ORDER BY DESC variant is the more useful answer for "most often" (directly sortable); histogram() returns an unordered map. Both are valid; minor clarity ding only because histogram() output isn't sorted by frequency.

## Q2 — bundle into struct, read fields back (CRITICAL) — 3.00 — ROW-FIELD-ACCESS DEFECT

**VERDICT: `ROW(first_name, last_name, tier)` yields ANONYMOUS (unnamed) fields. Dot-access `.first_name` does NOT work and requires a CAST to a named ROW type (or positional `[1]`/`[2]`/`[3]`).** Trino 467 does NOT propagate source column names into row constructor field names.

Source verification:
- RAW language/types.md: "By default, row fields are not named, but names can be assigned." Named fields via `CAST(ROW(1, 2e0) AS ROW(x BIGINT, y DOUBLE))`, then accessed with `.x`. Unnamed fields accessed only by position `ROW(1, 2.0)[1]`.
- WebSearch corroboration: trinodb/trino issue #4587 (anonymous ROW prints field0/field1), discussion #7758 ("very easy to construct an unnamed/anonymous Row using row(value1,...)"; "accessing an individual value in an anonymous row ... requires casting to a named row"), and PR #25261 (a PROPOSAL to add `row(1 as a)` naming — confirming it does NOT exist in 467). Dot-access-by-source-column-name is absent in 467.

Consequence for the responder's answer:
- Parts (a)+(b) — the HEADLINE example: `SELECT profile_card.first_name FROM (SELECT ROW(first_name, last_name, tier) AS profile_card FROM customers)` — is a **DEFECT**. The inner anonymous ROW has fields `field0/field1/field2`; `profile_card.first_name` raises a "Field 'first_name' not found" type error. To make dot-access work the constructor must be CAST: `CAST(ROW(first_name, last_name, tier) AS ROW(first_name VARCHAR, last_name VARCHAR, tier VARCHAR))`, then `.first_name` works. Or use positional `profile_card[1]`.
- Part (c) — CREATE TABLE with `profile_card ROW(first_name VARCHAR, last_name VARCHAR, tier VARCHAR)` — is CORRECT; a stored named ROW column IS dot-accessible as `.first_name`. (This is the named-ROW path the inline example skipped.)
- Part (d) — `json_format(CAST(profile_card AS JSON))` — VERIFIED valid. CAST of a NAMED row to JSON yields a JSON OBJECT `{"first_name":...}` (json.md: `CAST(CAST(ROW(123,'abc',true) AS ROW(v1 BIGINT,v2 VARCHAR,v3 BOOLEAN)) AS JSON)` → `{"v1":123,...}`). The `{"first_name":...}` claim is only correct when applied to the NAMED `profile_card` column (the CREATE TABLE form). Applied to the anonymous inline `ROW(...)` constructor, CAST AS JSON yields a positional ARRAY `[...]`, not an object — so (d)'s correctness depends on using the named form from (c), which the responder's prose conflates.

Because the dot-access defect is in the LEAD/headline pattern (not a "for completeness" appendix), this is a genuine accuracy defect, not responder padding. Accuracy 2; Completeness 4 (the correct named-ROW path IS present in part c); Clarity 3.5; Actionability 2.5 (an engineer who copies the headline gets a parse/type error).

ACTIONABLE for teacher: add/strengthen a findable canonical that the ROW CONSTRUCTOR is ANONYMOUS — to dot-access by name you must CAST to a named ROW type, e.g. `CAST(ROW(first_name,last_name,tier) AS ROW(first_name VARCHAR,last_name VARCHAR,tier VARCHAR)).first_name`, or use positional `[1]`. Defang the bare `ROW(a,b).a` form as WRONG. Pin: CAST-row-AS-JSON yields object ONLY for named rows, array for anonymous. Re-probe Q2 from a 2nd angle next sweep.

## Q3 — complete months active (CRITICAL) — 5.00 — CORRECT

`date_diff('month', started_at, COALESCE(cancelled_at, current_timestamp))`.
- VERIFIED date_diff is "timestamp2 - timestamp1 expressed in terms of unit" (datetime.md). For month, Trino 467 is DAY-AWARE / complete-units (confirmed via git-tag DateTimeFunctions.java per standing reference): drops fractional units.
- Responder's worked examples are exactly right: 25 days → 0; 2024-01-15→2024-02-14 = 0; 2024-01-15→2024-02-15 = 1.
- `COALESCE(cancelled_at, current_timestamp)` with a timestamp column is valid (current_timestamp is timestamp WITH TIME ZONE; implicit TIMESTAMP→TIMESTAMP WITH TIME ZONE coercion exists in 467).
- date_diff('day',...) → 25 for the days follow-up is correct.

## Q4 — set difference without big NOT IN/NOT EXISTS — 5.00 — CORRECT

`SELECT user_id FROM plan_a_users EXCEPT SELECT user_id FROM plan_b_users`.
- VERIFIED EXCEPT exists in 467 (sql/select.md): "returns the rows that are in the result set of the first query, but not the second"; defaults to DISTINCT.
- The clean set-difference / anti-join idiom is exactly right.
- NULL-safety contrast vs NOT IN is accurate: `NOT IN (subquery with NULLs)` yields UNKNOWN→no/empty rows; EXCEPT is set-based and treats NULL as a distinct comparable value, so it is NULL-safe. Correct.

---

## Clean checks (no defects)
No `::`-cast misuse, no QUALIFY, no false semi-join, no fabricated functions, no regex-backslash issue, no INTERVAL quarter/week, no OFFSET-before-LIMIT, no over-warning folklore. Q1/Q3/Q4 have no broken-secondary padding. Q2's defect is in the LEAD, not an appendix.

## Source URLs checked
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/language/types.md
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/json.md
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/map.md
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/aggregate.md
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/datetime.md
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/sql/select.md
- GitHub: trinodb/trino issues #4587, #860, discussion #7758, PR #25261

## Recommendation
PASS at 4.47 (margin +0.97). The one actionable item is the Q2 ROW-constructor anonymous-field defect — teacher should add a findable CAST-to-named-ROW canonical + defang `ROW(a,b).a`. MUST NOT bump state.json (already 1067; teacher owns it).

# Judge Feedback — iter784 (EXTENDED PHASE)

DEFAULT NO-OP / durability-breadth sweep. Teacher made ZERO resource edits.
Q1 re-probes set-ops (EXCEPT) to bulletproof; Q2 re-probes Iceberg `$snapshots` map-access
to confirm the iter783 `json_extract_scalar`-on-map slip did not recur; Q3-Q4 fresh.

All claims verified against trino.io/docs/467 + iceberg.apache.org via WebFetch/WebSearch.
FEDERATION NOT PROBED.

---

## Per-question scoring

### Q1 — SET DIFFERENCE (EXCEPT) — newsletter emails NOT in paying-customers
**Answer:** `SELECT email FROM newsletter_signups EXCEPT SELECT email FROM paying_customers`.
LED with the row-level `EXCEPT` operator; cited r23 §3.1F enhanced set-ops card; noted
EXCEPT = distinct rows in left not in right, NULL-safe unlike NOT IN, anti-join under the hood.

**Verification (trino.io/docs/467/sql/select.html):** CONFIRMED. "EXCEPT returns the rows that
are in the result set of the first query, but not the second." Default is `EXCEPT DISTINCT`
(de-dupes). NULLs are treated as equal for set membership (standard set semantics), so the
"NULL-safe unlike NOT IN" note is ACCURATE — NOT IN with a NULL in the subquery returns no
rows, EXCEPT does not have that trap. "Anti-join under the hood" is a fair plan description.
Correctly LED with the row-level operator (not array_except / not a key join).

- Accuracy: 5
- Completeness: 5
- Clarity: 5
- Actionability: 5
- **Q1 avg: 5.00**

This is the 2nd consecutive clean set-operations datapoint (iter783 INTERSECT, iter784 EXCEPT),
both LED with the correct row-level operator and cited the enhanced r23 §3.1F card.
**SET-OPERATIONS IS BULLETPROOFED.**

### Q2 — ICEBERG $snapshots — latest write's operation + records added
**Answer:** `SELECT snapshot_id, committed_at, operation, element_at(summary, 'added_rows') AS
rows_added, element_at(summary, 'deleted_rows') AS rows_deleted FROM
iceberg.analytics."orders$snapshots" ORDER BY committed_at DESC LIMIT 1`. States summary is a
MAP, accessor is `element_at(summary,'key')`; operation in {append, overwrite, delete, replace}.
Cited r17.

**Verification — TWO checks:**

(i) SLIP RE-CHECK (the primary re-probe target): The responder used MAP access
`element_at(summary, ...)` — NOT `json_extract_scalar`. **THE iter783 json_extract_scalar-on-map
SLIP DID NOT RECUR.** `$snapshots.summary` is `map(varchar,varchar)` (VERIFIED r17:1021 +
Iceberg docs) and `element_at(map,key)` is a correct accessor (equivalent to `summary['key']`).
The thing being re-probed PASSED. No iter785 FIX-A needed for the slip.

(ii) KEY-NAME ACCURACY: The responder used `'added_rows'` and `'deleted_rows'` (underscores,
"rows"). **These are the WRONG key strings.** VERIFIED against iceberg.apache.org / SnapshotSummary:
Iceberg snapshot-summary keys are HYPHENATED record-counts — `added-records`, `deleted-records`,
`total-records`, `added-data-files`, `total-data-files`, etc. There is NO `added_rows` /
`deleted_rows` key. `element_at(summary, 'added_rows')` returns NULL silently (key absent). The
correct key for added record count is `'added-records'` (hyphen, "records").

**Responder slip vs resource defect — VERDICT: RESPONDER SLIP, NOT a resource defect.**
r17 shows the CORRECT keys throughout:
- r17:1021 — "Access via `summary['added-records']`."
- r17:2913-2916 — `summary['added-records']`, `summary['deleted-records']`,
  `summary['total-records']`, `summary['added-data-files']`.
- r17:4001 — `summary['total-records']`.
The resource is correct (hyphenated keys, bracket map-access). The responder both (a) swapped
`summary['k']` for the equivalent `element_at(summary,'k')` — fine — and (b) invented underscore
"rows" key names instead of copying the canonical hyphenated "records" keys. Pure responder
synthesis slip.

Operation enum: responder gave {append, overwrite, delete, replace}. VERIFIED — Iceberg operation
values are exactly {append, replace, overwrite, delete}. Correct.

Severity: The re-probe target (map-access pattern) is CORRECT, so the headline check passes. But
the literal keys would silently return NULL — a real accuracy imprecision that would frustrate an
engineer (query runs, returns all-NULL counts, no error). Score Accuracy down moderately; credit
the correct accessor/structure/operation-enum and correct ORDER BY committed_at DESC LIMIT 1 for
"latest write."

- Accuracy: 3 (right accessor + right structure + right operation enum, but wrong key strings →
  silent NULLs for the exact counts the question asked for)
- Completeness: 4 (covers operation + counts + latest-snapshot ordering; keys would return NULL)
- Clarity: 5 (clean, explains summary-is-a-MAP and the accessor)
- Actionability: 3 (engineer copies it, gets NULL counts, must debug the key names themselves)
- **Q2 avg: 3.75**

### Q3 — ARRAY DEDUP + SORT (per-row)
**Answer:** `array_sort(array_distinct(tags)) AS clean_tags` -> `['beta','vip']`; descending via
comparator-lambda `array_sort(array_distinct(tags), (a,b) -> IF(a>b,-1,1))`. Cited r07 §1a.3.

**Verification (trino.io/docs/467/functions/array.html):** CONFIRMED. `array_distinct(x)` removes
duplicate values; `array_sort(x)` sorts ascending with nulls last; nesting gives
`['beta','vip']`. The comparator form `array_sort(array, (x,y) -> int)` returning -1/0/1 is valid
Trino 467 for custom ordering. All correct.

- Accuracy: 5
- Completeness: 5
- Clarity: 5
- Actionability: 5
- **Q3 avg: 5.00**

### Q4 — STRING -> DATE PARSE
**Answer:** `CAST(date_parse('2026-03-15','%Y-%m-%d') AS DATE)` (MySQL specifiers) or
`CAST(parse_datetime('2026-03-15','yyyy-MM-dd') AS DATE)` (Joda); for `'03/15/2026'` ->
`'%m/%d/%Y'` / `'MM/dd/yyyy'`. Notes date_parse uses MySQL %Y/%m/%d/%H/%i/%s; parse_datetime uses
Joda yyyy/MM/dd (capital M month, lowercase mm minutes); wrap in CAST AS DATE; do NOT use
parse_date (Snowflake/BigQuery). Cited r27.

**Verification (trino.io/docs/467/functions/datetime.html):** CONFIRMED. `date_parse(string,format)`
uses MySQL specifiers (%Y %m %d %H %i %s), returns timestamp(3). `parse_datetime(string,format)`
uses Joda patterns (yyyy MM dd), returns timestamp with time zone. Both valid; CAST(... AS DATE)
yields a DATE. %m/%d/%Y and MM/dd/yyyy for '03/15/2026' correct. "lowercase mm = minutes in Joda"
is accurate. "parse_date is not Trino" CONFIRMED — no parse_date in Trino 467 docs. Fully correct.
(Minor: for the ISO '2026-03-15' case, `CAST('2026-03-15' AS DATE)` works directly — a simpler
path the responder could mention — but date_parse is correct and necessary for the non-ISO case.)

- Accuracy: 5
- Completeness: 5 (both formats, both function families, anti-pattern called out)
- Clarity: 5
- Actionability: 5
- **Q4 avg: 5.00**

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 (EXCEPT) | 5 | 5 | 5 | 5 | 5.00 |
| Q2 ($snapshots map) | 3 | 4 | 5 | 3 | 3.75 |
| Q3 (array dedup+sort) | 5 | 5 | 5 | 5 | 5.00 |
| Q4 (string->date) | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = (5.00 + 3.75 + 5.00 + 5.00) / 4 = 18.75 / 4 = 4.6875 → PASS**
(margin +1.1875 above 3.5 floor; overall average governs, no single-Q veto.)

---

## Headline verdicts

- **(a) SET-OPERATIONS BULLETPROOFED?** YES. Q1 EXCEPT is the 2nd consecutive clean
  set-operations datapoint after iter783 INTERSECT. Both LED with the correct row-level operator
  (not array_except / not a key join) and cited the enhanced r23 §3.1F card. Set-operations is
  now BULLETPROOFED across distinct phrasings.

- **(b) $snapshots map-access SLIP RECUR?** NO. The responder used `element_at(summary, ...)`
  (MAP access), NOT `json_extract_scalar`. The iter783 json_extract_scalar-on-map slip did NOT
  recur. The re-probe target passed.

  **Q2 KEY-NAME VERDICT:** RESPONDER SLIP, not a resource defect. The responder wrote wrong key
  strings `'added_rows'`/`'deleted_rows'` (underscores, "rows") which would silently return NULL.
  The CORRECT keys are hyphenated record-counts (`'added-records'`, `'deleted-records'`,
  `'total-records'`). r17 already shows the CORRECT keys: r17:1021 ("Access via
  `summary['added-records']`"), r17:2913-2916, r17:4001. The resource is clean; the responder
  failed to copy the canonical key strings and invented underscore "rows" names. One-off synthesis
  slip on the literal key text only — the accessor, structure, ordering, and operation enum were
  all correct.

- **(c) iter785 DESIGNATION: DEFAULT NO-OP / durability-breadth sweep.**
  The re-probed slip did NOT recur and the keys are a minor one-off responder text slip against a
  resource that is already correct. No resource defect surfaced. No FIX-A required.
  OPTIONAL (very low priority, NOT required): if iter785 wants to inoculate the key-name slip,
  add a tiny copy-attractive "SNAPSHOT SUMMARY KEYS ARE HYPHENATED record-counts —
  `summary['added-records']` NOT `'added_rows'`" pin co-located with the r17:2913 canonical, with
  an inline un-copyable WRONG marker on `'added_rows'`. This is an inoculation nudge, not a defect
  fix — defer unless the underscore-keys slip recurs on a future $snapshots re-probe.

HOLD all prior locks. Federation r22 untouched (NOT probed this iter). DO NOT bump
training/state.json (already 784).

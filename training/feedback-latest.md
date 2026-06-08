# Judge Feedback — iter751 (DUAL FIX-A re-probe + 1 fresh)

**Phase:** extended. **Governing rule:** overall avg across 4 Qs ≥ 3.5 → PASS (no single-Q veto).
**Federation:** NOT probed — row UNCHANGED (303rd consecutive untouched).
**state.json:** NOT modified (already 751, set by teacher).

All four dialect claims were WebFetch/WebSearch-verified against trino.io/docs/467 (aggregate.html, array.html, regexp.html, comparison.html, string.html) plus Trino string-literal escaping behavior. ZERO dialect defects found.

---

## Q1 — MAP-MERGE-SUM (sum a MAP column's values per tag across rows, per agent) — RE-PROBE

Answer: inner `CROSS JOIN UNNEST(time_spent) AS t(tag, minutes)` + `SUM(minutes) GROUP BY agent_id, tag`, then outer `map_agg(tag, total_minutes) GROUP BY agent_id`. Explicitly defanged map_union_sum (Presto-only) and noted map_union does not sum.

VERIFIED (aggregate.html):
- `map_agg(key, value) → map(K,V)` "Returns a map created from the input key/value pairs." Confirmed.
- `map_union(x(K,V)) → map(K,V)` "If a key is found in multiple input maps, that key's value in the resulting map comes from an arbitrary input map." → confirms map_union does NOT sum colliding values (responder's defang correct).
- `map_union_sum` — NOT in Trino 467 docs (Presto-only). Responder's defang correct.
- Two-step idiom runs against a MAP column: the inner UNNEST(map) AS t(k,v) two-alias explode is the documented map→rows mechanic; the inner `GROUP BY agent_id, tag` guarantees one row per (agent,tag) so the outer map_agg receives DISTINCT keys per agent — no duplicate-key error. Correct.

Scores: Accuracy 5, Completeness 5, Clarity 5, Actionability 5. **Per-Q avg 5.00.**

## Q2 — LIKE-ESCAPE (match a LITERAL underscore, not the wildcard) — RE-PROBE

Answer: `WHERE message LIKE '%\_%' ESCAPE '\'`, with the escaped `_` matching a literal underscore and outer `%` as wildcards; ALSO offered `strpos(message,'_') > 0` substring alternative. Did NOT use contains()-on-varchar (the iter750 defect).

VERIFIED (comparison.html): "The wildcard characters `_` and `%` must be escaped to allow you to match them as literals. This can be achieved by specifying the ESCAPE character to use." Docs example `'South\_America' LIKE 'South\\\_America' ESCAPE '\'` → true. The responder's `'%\_%' ESCAPE '\'` is the correct literal-underscore idiom. VERIFIED (string.html): `strpos(string, substring)` returns position (1-based) or 0 if not found — `strpos(message,'_')>0` is a valid substring test. The iter750 contains()-on-varchar defect did NOT recur (contains() is ARRAY-only).

Scores: Accuracy 5, Completeness 5, Clarity 5, Actionability 5. **Per-Q avg 5.00.**

## Q3 — FLATTEN (list of albums each a list of track IDs → one flat list per playlist, no row explosion) — RE-PROBE

Answer: `SELECT playlist_id, flatten(album_list) AS all_track_ids FROM playlists`. Explained one-level collapse ARRAY(ARRAY(VARCHAR))→ARRAY(VARCHAR), one row in/out.

VERIFIED (array.html): `flatten(x) → array` "Flattens an `array(array(T))` to an `array(T)` by concatenating the contained arrays." Exactly one level, per-row, single array out, no row explosion. `flatten(album_list)` is precisely right.

Scores: Accuracy 5, Completeness 5, Clarity 5, Actionability 5. **Per-Q avg 5.00.**

## Q4 — regexp_extract_all (pull EVERY 'TKT-1234' token from free-text notes into an array) — FRESH

Answer: `regexp_extract_all(notes, 'TKT-\d+') AS ticket_references` → ARRAY(VARCHAR) of all matches, one row per account.

VERIFIED (regexp.html): `regexp_extract_all(string, pattern)` returns ALL matches as an array (docs example returns `[1, 2, 14]`); `regexp_extract` returns only the FIRST match — so regexp_extract_all is the right tool. Patterns use Java/RE2J syntax and accept `\d`.

Backslash nuance (verified, NO penalty): Trino follows ANSI SQL — backslash is NOT a special escape char in single-quoted string literals (`SELECT 'hello\bworld'` returns `hello\bworld` verbatim). Therefore `'TKT-\d+'` is preserved as the literal characters `TKT-\d+`, which RE2J reads correctly as "TKT- then one-or-more digits." The responder's SINGLE-backslash form is correct and matches digits. (Note for teacher: the docs' own `'\\d+'` double-backslash example is a known quirk — in real Trino SQL the literal `\\d+` reaches RE2J as escaped-backslash + `d+`, matching a literal backslash, NOT digits. The single-backslash form the responder used is the one that actually works. Do NOT "correct" the responder toward `\\d+`.)

NULL/empty nuance (minor, not a defect): regexp_extract_all returns an empty array `[]` when no match, not NULL — responder didn't mention it but it doesn't affect correctness.

Scores: Accuracy 5, Completeness 5, Clarity 5, Actionability 5. **Per-Q avg 5.00.**

---

## OVERALL

| Q | Acc | Comp | Clar | Act | avg |
|---|---|---|---|---|---|
| Q1 map-merge-sum | 5 | 5 | 5 | 5 | 5.00 |
| Q2 LIKE-ESCAPE | 5 | 5 | 5 | 5 | 5.00 |
| Q3 flatten | 5 | 5 | 5 | 5 | 5.00 |
| Q4 regexp_extract_all | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = 20.00/4 = 5.00 — STRONG PASS** (margin +1.50).

## Topic-closure status

- **map-merge-sum CLOSED** — 1st post-fix datapoint. iter750's Q2 gap (3.00) is fixed; responder produced the canonical UNNEST(map)+map_agg(k,SUM(v))+GROUP BY two-step AND correctly defanged map_union_sum (Presto-only) + map_union-arbitrary-value-wins. Clean. (Needs a 2nd clean datapoint from a different angle to reach BULLETPROOFED.)
- **LIKE-ESCAPE CLOSED** — 1st post-fix datapoint. iter750's contains()-on-varchar defect (3.375) is fixed; responder used `LIKE '%\_%' ESCAPE '\'` + strpos alternative, did NOT touch contains()-on-varchar. Clean. (Needs a 2nd clean datapoint to reach BULLETPROOFED.)
- **flatten BULLETPROOFED** — 2nd consecutive clean datapoint (iter750 Q3 clean → iter751 Q3 clean against fresh playlist/albums/tracks phrasing). flatten() canonical is durable.
- **regexp_extract_all** — fresh-clean (1st datapoint), docs-confirmed native, right-tool-vs-regexp_extract distinction correct.

## No new gaps / no defects

No dialect defects, no fabricated functions, no contradictions surfaced. All standing locks held.

## iter752 designation

Recommend: **re-probe map-merge-sum + LIKE-ESCAPE from a 2nd/different angle** to drive both toward BULLETPROOFED (each currently 1 clean post-fix datapoint). Suggested fresh angles:
- map-merge-sum 2nd angle: e.g. "per customer, merge per-order maps of {sku → qty} into one map summing qty per sku" (different domain/keyword surface).
- LIKE-ESCAPE 2nd angle: e.g. "find rows whose code contains a literal percent sign `%`" (the `%` wildcard, not `_`).
- Plus 1–2 FRESH picks from un-probed-recently locks (e.g. element_at(arr,-n) negative index; concat_ws skips NULL; CAST(bool AS int)→1/0; format('%,d') thousands separator).
- Do NOT churn flatten (now bulletproofed — iter693 lesson) or any bulletproofed card.
- If any defect surfaces → switch to FIX-A on that topic instead.

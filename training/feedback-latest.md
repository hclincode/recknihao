# Iter1179 Judge Feedback

**Overall verdict:** PASS WITH LIGHT FIX-A on Q2 — Q1 watch CLOSES cleanly, Q3 + Q4 clean, but Q2 shipped a broken interval-overlap predicate (BOTH halves of the comparison are wrong AND the join carries a spurious ordering filter that drops valid pairs). Classification: **resource-sourced findability gap** — r07 has only the calendar × intervals canonical (interval-overlap for "active per day") and has NO canonical for "find pairs of overlapping intervals in the same table (self-join)" framing. Responder garbled the SaaS pairs question by trying to map from the calendar-day canonical it knew.

Total iter1179 score: (4.875 + 1.75 + 5.0 + 4.75) / 4 = **4.09 / 5** — average pulled down by Q2 broken predicate.

| Q | Topic | Score | Note |
|---|---|---|---|
| 1 | SQL best practices — string-fuzzy-match family / levenshtein abbreviation | 4.875 | WATCH CLOSE iter1178 |
| 2 | Analytical query patterns — interval-overlap self-join PAIRS | 1.75 | BROKEN PREDICATE → LIGHT FIX-A |
| 3 | SQL best practices — regexp_replace 2-arg / `$1` capture refs | 5.0 | clean |
| 4 | Iceberg maintenance — multi-engine Spark+Trino concurrent reads/writes | 4.75 | clean (minor metastore-cache-ttl shave) |

---

## Q1 — Fuzzy city dedup, edit-distance for abbreviations (St. Louis vs Saint Louis, NYC vs New York City) — WATCH RE-PROBE

**Score: 4.875 / 5**
- Technical accuracy: **5** — Correctly framed edit-distance as wrong tool for abbreviation expansion. `levenshtein_distance(string1, string2) -> bigint` verified at [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html) ("Returns the Levenshtein edit distance of `string1` and `string2`, i.e. the minimum number of single-character edits (insertions, deletions or substitutions) needed to change `string1` into `string2`"). The "St. Louis → Saint Louis = 4+ edits, NYC → New York City = 10+ edits" arithmetic is correct. Bonus: explicit warning that raising threshold causes false positives (St. Louis → St. Chicago shared prefix collision).
- Beginner clarity: **5** — Concrete arithmetic on the engineer's literal example pair makes the wrong-tool message vivid. Lookup table mechanic explained with full SQL outline.
- Practical applicability: **5** — Concrete recommendation: curated reference/lookup table (`abbreviation` → `canonical`) joined + deterministic normalize (`St.` → `Saint`, `NYC` → `New York City`), then `levenshtein_distance` as a **secondary typo fallback** on the normalized form. Engineer knows exactly what to build: a `city_aliases(alias, canonical)` table + a `COALESCE(a.canonical, raw_city)`-then-`levenshtein_distance` pipeline. No threshold tuning trap.
- Completeness: **4.5** — Could have name-dropped phonetic-family (soundex / double-metaphone) as third option for true mis-spellings beyond ASCII edit-distance (e.g. `Smithe` vs `Smyth`); recall ceiling — Trino 467 has soundex but the question's literal frame is abbreviation-expansion, where phonetic is also the wrong tool. Not load-bearing.

### WATCH CLOSURE

`r27 §4.3-STR-FAMILY levenshtein-threshold-vs-abbreviation iter1178` watch: **CLOSES**. iter1178 responder overclaimed "edit-distance <= 2 catches abbreviation expansions"; iter1179 responder explicitly says small thresholds **miss** abbreviation pairs (4+ edits apart) AND big thresholds **false-positive** (shared-prefix collisions like St. Louis → St. Chicago). The honest-no-overclaim framing is exactly what the watch was checking for. First-iteration re-probe close with structurally different framing (St. Louis / NYC vs iter1178's Acme Corp / ACME CORPORATION).

---

## Q2 — Find PAIRS of overlapping deals in same table (self-join) — BROKEN PREDICATE — LIGHT FIX-A

**Score: 1.75 / 5**
- Technical accuracy: **1** — Predicate is broken BOTH ways. See "Predicate analysis" below.
- Beginner clarity: **3** — Plain English given, but the plain English itself encodes the bug (see below).
- Practical applicability: **1** — Engineer copies SQL, ships analytics that BOTH (a) wrongly flag non-overlapping deal pairs as overlapping AND (b) silently drop valid overlapping pairs. Reverse-direction harm on a "detect anomalies" use case.
- Completeness: **2** — Mentions ANALYZE + (account_id, start_date) sort hint as performance follow-ups, but the BASE query is wrong; perf advice is moot.

### Predicate analysis (CRITICAL)

Responder's JOIN condition:

```sql
FROM deals a INNER JOIN deals b
  ON a.account_id = b.account_id
 AND a.deal_id    < b.deal_id
 AND a.start_date <= b.start_date              -- BUG #1
 AND (b.end_date IS NULL OR b.end_date > a.start_date)  -- BUG #2 (trivially true given #1)
```

**Bug #1 — `a.start_date <= b.start_date` is a spurious ordering filter that DROPS valid overlapping pairs.**
- `a.deal_id < b.deal_id` already de-duplicates the (a,b)/(b,a) symmetry — it does NOT imply anything about start dates because deal_id is an arbitrary surrogate key independent of start_date.
- A pair where the lower-deal_id deal STARTS LATER than the higher-deal_id deal is silently dropped, even if the two date ranges DO overlap.
- Example: `deals(deal_id=1, start='2026-03-01', end='2026-04-01')`, `deals(deal_id=2, start='2026-01-01', end='2026-05-01')` — same account. Deal 1 (Mar→Apr) sits entirely inside Deal 2 (Jan→May), so they OBVIOUSLY overlap. But: `a=deal_1`, `b=deal_2`, `a.deal_id(1) < b.deal_id(2)` passes, then `a.start_date('2026-03-01') <= b.start_date('2026-01-01')` is FALSE → pair is silently dropped.

**Bug #2 — `b.end_date > a.start_date` is trivially true given Bug #1's ordering filter.**
- Given Bug #1 forces `a.start <= b.start`, the test `b.end > a.start` becomes `b.end >= b.start >= a.start` — always true for valid intervals (`b.end >= b.start` is implied, and `b.start >= a.start` is Bug #1's filter).
- So this clause does **NOT actually test overlap at all** — it is always true for valid intervals that passed Bug #1.
- The REAL overlap constraint when `a.start <= b.start` is `b.start <= a.end` (i.e. "a hasn't ended before b starts"), i.e. `(a.end_date IS NULL OR a.end_date >= b.start_date)`. The responder tested the WRONG end — `b.end vs a.start` instead of `a.end vs b.start`.

**Failure example (the prompt's diagnostic case).**
- `a = ('2026-01-01', '2026-02-01')`, `b = ('2026-03-01', '2026-04-01')` — no overlap (a fully before b).
- Responder's predicate: `a.start(Jan1) <= b.start(Mar1)` = TRUE; `b.end(Apr1) > a.start(Jan1)` = TRUE → **wrongly emitted as an overlapping pair**.

**Correct canonical (closed intervals, NULL end = open / +infinity):**

```sql
FROM deals a JOIN deals b
  ON a.account_id = b.account_id
 AND a.deal_id    < b.deal_id                                                       -- no-self + dedupe symmetry
 AND a.start_date <= COALESCE(b.end_date, DATE '9999-12-31')                        -- a starts on/before b ends
 AND b.start_date <= COALESCE(a.end_date, DATE '9999-12-31')                        -- b starts on/before a ends
```

The two-sided `a.start <= b.end AND b.start <= a.end` form (with `COALESCE` for open-ended NULL ends) is THE textbook interval-overlap predicate — works regardless of which deal starts first, and the `a.deal_id < b.deal_id` clause alone is sufficient to de-duplicate symmetric pairs without imposing a date ordering filter.

### Source classification — resource-sourced findability gap

`r07` interval-overlap canonical at §1674 ("LEADING CANONICAL — count active/open intervals on each day") covers the **calendar × intervals** pattern (active subscribers per day) — `calendar c JOIN intervals s ON s.start <= c.day AND (s.end IS NULL OR s.end > c.day)`. It is correct for that pattern.

Grep evidence for the **PAIRS-IN-SAME-TABLE self-join** canonical:
- Patterns searched: `pairs.{0,30}overlap | overlapping.{0,10}pair | self.join.{0,30}overlap | conflicting.{0,15}date | same.{0,5}entity.{0,30}overlap | two.{0,20}intervals.{0,30}overlap | a\.start.*<=.*b\.end | b\.start.*<=.*a\.end` across `resources/` → **ZERO matches**.
- No canonical for "find pairs of overlapping intervals in the same table" exists. The responder pulled from the calendar × intervals shape (which is what r07 teaches) and garbled the predicate by trying to adapt `s.start <= c.day` (one-sided, calendar is a scalar) to a two-table self-join (which needs two-sided).

Responder also explicitly attributed: "this is the r07 interval-overlap range join canonical" — that attribution is FALSE; r07's canonical is calendar × intervals, not self-join pairs.

### FIX-A spec (recommended)

Add a new card to **r07 immediately after §1841 CONTRAST card** (the three-time-series-patterns table) titled:

> ### LEADING CANONICAL — find PAIRS of overlapping intervals in the SAME table (self-join, two-sided overlap predicate — NOT the calendar × intervals shape)

Load-bearing content:
1. **The fact in one sentence.** To find pairs of rows in the SAME table whose date ranges overlap (e.g. find all PAIRS of deals for the same account whose `[start_date, end_date]` ranges overlap; find double-booked reservations on the same room; find employees whose employment periods overlap), self-join the table on the entity key + the **two-sided overlap predicate** `a.start <= b.end AND b.start <= a.end` (with `COALESCE(end, DATE '9999-12-31')` when NULL means open / current), PLUS `a.id < b.id` for unique pair de-duplication. **NEVER use a one-sided predicate** — that's the calendar × intervals shape and silently drops half the overlaps.
2. Worked canonical for the deals example:
   ```sql
   SELECT a.deal_id AS deal_a, b.deal_id AS deal_b, a.account_id,
          a.start_date AS a_start, a.end_date AS a_end,
          b.start_date AS b_start, b.end_date AS b_end
   FROM deals a
   JOIN deals b
     ON a.account_id = b.account_id
    AND a.deal_id    < b.deal_id                                            -- unique pairs, no self-pairs
    AND a.start_date <= COALESCE(b.end_date, DATE '9999-12-31')             -- a starts on/before b ends
    AND b.start_date <= COALESCE(a.end_date, DATE '9999-12-31')             -- b starts on/before a ends
   ;
   ```
3. **Why two-sided.** Two intervals `[a.s, a.e]` and `[b.s, b.e]` overlap iff `a.s <= b.e AND b.s <= a.e`. Either inequality alone is insufficient: `a.s <= b.e` alone admits `a` entirely after `b` (start later, end later); `b.s <= a.e` alone admits `b` entirely after `a`. The conjunction rules out both cases.
4. **DO-NOT-WRITE defang — the iter1179 broken predicate.**
   - `AND a.start_date <= b.start_date AND (b.end_date IS NULL OR b.end_date > a.start_date)` — WRONG. (a) The `a.start <= b.start` clause is a SPURIOUS ORDERING FILTER (deal_id < deal_id does not imply start date ordering) that silently drops overlapping pairs where the lower-deal_id deal started later. (b) GIVEN `a.start <= b.start`, the check `b.end > a.start` is **trivially true** for valid intervals (`b.end >= b.start >= a.start`), so it doesn't actually test overlap — it just acts as a filter that admits ALL same-account pairs satisfying the start ordering, regardless of overlap. Example: `a=[Jan1,Feb1]`, `b=[Mar1,Apr1]` (no overlap) → wrongly emitted as overlapping.
5. **NULL handling.** NULL `end_date` = "still open / +infinity". Use `COALESCE(end_date, DATE '9999-12-31')` (or a far-future TIMESTAMP if `end_date` is a timestamp). Do not omit the COALESCE — `NULL > anything` is NULL (falsy in a JOIN predicate), so an open-ended deal would silently fail the overlap test.
6. **Performance note.** On 2M rows, the self-join is `O(N^2 / partitions)` worst-case but in practice the `account_id` equi-join key + Trino's hash-join distribution makes it `O(rows-per-account^2 * accounts)`. ANALYZE TABLE so CBO can plan; if `rows-per-account` is small (typical SaaS — few deals per account), this is fast. Iceberg sort-by `(account_id, start_date)` helps file pruning.
7. **Keyword anchors:** find pairs of overlapping date ranges, two rows in same table whose ranges overlap, self-join interval overlap, find conflicting reservations / overlapping bookings / double-booked, overlapping employment periods, deals with overlapping date ranges, two-sided overlap predicate, `a.start <= b.end AND b.start <= a.end`, find pairs deals same account ranges overlap, detect range collisions, schedule conflict detection.
8. **Cross-ref:** "For the DIFFERENT shape — counting how many intervals are active on EACH calendar day — see §1674 (calendar × intervals range join). The calendar shape uses a ONE-sided predicate against a scalar calendar day; the self-join PAIRS shape uses a TWO-sided predicate between two interval rows. Do not copy the one-sided predicate into the self-join — that's the iter1179 break."

**Placement rationale.** Putting the new card right after §1841 CONTRAST table places it adjacent to the existing interval-overlap canonical (§1674) so the keyword `interval overlap` / `range join` lands the responder on the disambiguating CONTRAST table first, which then routes to either the calendar shape OR the self-join shape depending on framing.

### Watch label

`r07 PAIRS-of-overlapping-intervals self-join two-sided-predicate iter1179` — re-probe next sweep with structurally different self-join framing (e.g. "find double-booked rooms — pairs of reservations on the same room whose check-in/check-out windows overlap" / "find employees whose employment periods at our company overlap with their employment at a customer company"). If reaches the two-sided canonical → CLOSED.

---

## Q3 — Strip non-digits from phone numbers in Trino (regexp_replace)

**Score: 5.0 / 5**
- Technical accuracy: **5** — Both forms verified at [trino.io/docs/467/functions/regexp.html](https://trino.io/docs/467/functions/regexp.html):
  - 2-arg `regexp_replace(string, pattern)` "Removes every instance of the substring matched by the regular expression `pattern` from `string`" — matches responder's `regexp_replace('+1 (555) 123-4567', '[^0-9]') -> '15551234567'`.
  - 3-arg `regexp_replace(string, pattern, replacement)` with empty `''` is equivalent.
  - `$1`, `$2`, `${name}` for capture group references — verified verbatim ("Capturing groups can be referenced in `replacement` using `$g` for a numbered group or `${name}` for a named group"). Correctly noted `$1` is the Trino syntax, NOT `\1` (the Postgres/PCRE backslash form).
  - `\d` (or `[^0-9]` complement) Trino 467 supports per the regex character classes documented; matches `reference_trino_regex_backslash.md` pin (single backslash in SQL literal works).
- Beginner clarity: **5** — Two-arg vs three-arg distinction explicit; `[^0-9]` vs `\D` shorthand both shown.
- Practical applicability: **5** — Capture-group reformat example `regexp_replace(cleaned, '(\d{3})(\d{3})(\d{4})', '($1) $2-$3')` is a useful follow-up the engineer didn't explicitly ask for but will likely want next.
- Completeness: **5** — Cites r23. Both reading direction (extract digits) and writing direction (format back to display) covered.

---

## Q4 — Iceberg multi-engine (Spark + Trino) on shared HMS catalog — concurrency safety

**Score: 4.75 / 5**
- Technical accuracy: **4.75** — Core multi-engine multi-table concurrency answer is correct and aligns with Iceberg's stated design goals + the `iter1175 Q4` / `iter1156 Q3` rubric history on this exact topic:
  - (a) Both Trino 467 + Spark with Iceberg connector using shared HMS catalog: safe by design. Each query / transaction pins a snapshot at planning (HMS holds `metadata_location` pointer, engines fetch the current `metadata.json` at query start).
  - (b) Concurrent reads: no contention — snapshot-isolated, each reader sees the snapshot it pinned.
  - (c) Trino reads + Spark writes: next Trino query picks up Spark's new snapshot (HMS pointer-swap commit is atomic). In-flight readers continue against their pinned snapshot, unaffected by Spark commits.
  - (d) Same-table concurrent writes governed by `write.*.isolation-level` (`write.delete.isolation-level` / `write.update.isolation-level` / `write.merge.isolation-level`) — default `serializable`, alternative `snapshot` — matches the [Iceberg IsolationLevel Javadoc](https://iceberg.apache.org/javadoc/1.7.1/org/apache/iceberg/IsolationLevel.html) cited in iter1175 footnote. `commit.retry.num-retries` (default 4) governs optimistic-concurrency retries on conflicting commits.
  - (e) Spark writes to OTHER tables don't affect Trino at all — each table has its own `metadata.json` pointer in HMS, independent commit chains. This is correct.
  - Minor accuracy shave (-0.25): Trino's `hive.metastore-cache-ttl` (and `iceberg.metadata-cache.enabled`) can briefly serve a stale HMS metadata pointer to subsequent Trino queries — so "next Trino query picks up Spark's new snapshot" has a small staleness window bounded by the cache TTL. Responder didn't mention this. Not load-bearing for the safety question (it's a freshness window, not a correctness violation — Trino just sees a slightly older but still-consistent snapshot until cache expires).
- Beginner clarity: **4.75** — Some Iceberg terminology (manifest, snapshot, MoR) used without re-defining, but acceptable given the engineer's framing already implies familiarity. The "metadata in Iceberg manifests on MinIO, not engine internals" sentence is the key intuition for a SaaS engineer wondering "where does the lock live?" — answer: "there is no lock, atomic pointer-swap commits + snapshot reads."
- Practical applicability: **5** — Engineer's literal question ("safe to read from both? safe for Trino if Spark writes to other tables?") gets a direct YES/YES with concrete reasoning. Knows exactly what to do: nothing (default config is safe); relax `write.*.isolation-level` to `snapshot` only if false-positive commit failures appear on disjoint partitions.
- Completeness: **4.5** — Missing the metastore-cache staleness window mention (above); did mention `commit.retry.num-retries` for same-row commit races. Cites r26 + r21.

---

## Score updates to rubric

| Topic | Before | After | Δ |
|---|---|---|---|
| SQL query best practices for OLAP | 4.5721 / 254 | 4.5749 / 256 | +Q1 4.875 + Q3 5.0 |
| Analytical query patterns on Iceberg+Trino | 4.5515 / 130 | 4.5301 / 131 | +Q2 1.75 (resource gap → LIGHT FIX-A) |
| Iceberg table maintenance (concurrent writes / multi-engine) | 4.4639 / 200 | 4.4654 / 201 | +Q4 4.75 |

All three topics remain PASSED with healthy margins above threshold (3.5).

---

## Action summary

1. **Q1 watch CLOSES** — `r27 §4.3-STR-FAMILY levenshtein-threshold-vs-abbreviation iter1178` watch closed cleanly on first re-probe (consistent with recent watch-close pattern). No resource action needed.
2. **Q2 LIGHT FIX-A** — Teacher to add the "PAIRS of overlapping intervals in same table (self-join, two-sided predicate)" canonical to r07 (placement: right after §1841 CONTRAST card so the existing interval-overlap CONTRAST routes to it). Watch label: `r07 PAIRS-of-overlapping-intervals self-join two-sided-predicate iter1179`. Spec above.
3. **Q3 NO-OP** — clean.
4. **Q4 NO-OP** — clean (minor metastore-cache-ttl staleness window not mentioned but not load-bearing).

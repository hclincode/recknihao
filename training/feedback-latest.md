# Iter1117 — Judge Feedback

**Overall verdict: 4.9219 STRONG PASS** (margin +1.42 above 3.5). **iter1116 Q1 ts-minus-ts WATCH STREAM CLOSED — slip DID NOT RECUR.** This iter Q1 (`response_minutes` between `created_at` and `first_response_at`, explicitly tempting the engineer's "Python/Java subtraction instinct") was answered with the CANONICAL `date_diff('minute', earlier, later) -> bigint` form AND an explicit "Trino cannot subtract one timestamp directly from another" framing. Q2/Q3 also 5.00 / 5.00; Q4 4.75 with one minor "zero downside" shave on the expire_snapshots time-travel-loss caveat.

---

## Source verifications (Trino 467 docs / RAW 467 source)

- **Q1 date_diff signature**: trino.io/docs/current/functions/datetime.html — `date_diff(unit, timestamp1, timestamp2) -> bigint` "Returns `timestamp2 - timestamp1` expressed in terms of `unit`". Confirms responder's arg order = (unit, EARLIER, LATER) returns a POSITIVE value, and confirms the "timestamp - timestamp does not parse" framing (no `timestamp - timestamp` operator documented; only `timestamp +/- interval`). Responder is correct.
- **Q3 trim char-set semantic**: trino.io/docs/current/functions/string.html — `trim([[specification] [string] FROM] source)` documented as "Removes any leading and/or trailing characters as specified... from source"; verbatim example `trim(BOTH '$' FROM '$var$')` returns `'var'`. The `string` arg is a **SET OF CHARACTERS** (any-of), NOT a literal substring. Confirms `trim(BOTH '| ' FROM '| some value |')` strips ANY combination of pipe and space from both ends → `'some value'`. Matches memory pin `reference_trino_trim_charset` (Trino is char-set, NOT single-char or substring). Responder is correct.
- **Q2 ROW_NUMBER top-N-per-group**: trino.io/docs/current/functions/window.html — `row_number() OVER (PARTITION BY ... ORDER BY ...)` returns sequential within-partition rank; trino.io/docs/current/sql/select.html — Trino has NO `QUALIFY` clause (Snowflake/BigQuery only) so the canonical Trino top-N pattern is CTE/subquery with `WHERE rn <= N`. Responder is correct.
- **Q4 expire_snapshots syntax + downside**: trino.io/docs/current/connector/iceberg.html — `ALTER TABLE x EXECUTE expire_snapshots(retention_threshold => '7d')` is the canonical 467 form; "removes all snapshots and related metadata and data files" older than the threshold; "regularly expiring snapshots is recommended to delete data files that are no longer needed, and to keep the size of table metadata small"; minimum bounded by `iceberg.expire-snapshots.min-retention` (default `7d`); `retain_last` named param defaults to 1. **However: expiring snapshots DOES remove time-travel / rollback ability for those expired snapshots** (`FOR VERSION AS OF` / `FOR TIMESTAMP AS OF` on expired snapshot IDs/timestamps will fail). Responder's syntax + rationale is correct, but the "safe, zero downside" framing OVERSTATES — the time-travel-loss is real, even if usually acceptable for daily-write tables.

---

## Per-question scoring

### Q1 — Response time in MINUTES between created_at and first_response_at; "my instinct is to subtract them like Python/Java"

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | `date_diff('minute', created_at, first_response_at) -> bigint` is the EXACT canonical Trino 467 form. Arg order (unit, earlier, later) gives positive minutes per docs ("Returns timestamp2 - timestamp1"). Explicit "Trino cannot subtract one timestamp directly from another to get an interval" framing is correct (no `ts - ts` operator on datetime.html). Group-by team + AVG aggregate correct. |
| Beginner clarity | 5.0 | Directly addresses the "Python/Java subtraction instinct" the engineer named; explains the three args (unit string, earlier ts, later ts) explicitly so the engineer can copy-paste without guessing direction. |
| Practical applicability | 5.0 | Engineer can drop this into a team-SLA dashboard tomorrow: outer `SELECT team, AVG(response_minutes) FROM (...) GROUP BY team`. |
| Completeness | 5.0 | Covers the question (subtraction doesn't work, use date_diff, arg order, return type bigint, aggregate by team). No tail-padding broken alternative. |

**Q1 average: 5.000** — **iter1116 ts-minus-ts WATCH STREAM CLOSED**.

### Q2 — Top 5 users per account by event count (last 30 days), per-account not global

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Canonical Trino top-N-per-group: CTE with inner `GROUP BY account_id, user_id COUNT(*) AS event_count` + `ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY event_count DESC) AS rank` + outer `WHERE rank <= 5`. No QUALIFY misuse (Trino 467 has no QUALIFY). PARTITION BY scoping correctly delivers per-account top-N not global. |
| Beginner clarity | 5.0 | Explains why PARTITION BY = "restart numbering per account" vs global ordering; explains why the WHERE has to be in the outer block (can't reference window alias in same SELECT's WHERE in Trino). |
| Practical applicability | 5.0 | Drop-in shape; ORDER BY account_id, rank for stable display order. |
| Completeness | 4.75 | Could mention DENSE_RANK vs ROW_NUMBER for tie handling (two users with same event_count → ROW_NUMBER arbitrarily breaks the tie, DENSE_RANK keeps both at the same rank), but the question didn't ask about ties. Minor. |

**Q2 average: 4.9375**

### Q3 — Strip leading/trailing pipes AND spaces together (`'| some value |'`); can Trino remove multiple different chars in one trim?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | `trim(BOTH '| ' FROM s)` is the correct one-call form. The `'| '` arg IS a CHARACTER SET (per docs verbatim "Removes any leading and/or trailing characters as specified... from source") — strips any combination of `|` and space from the ends, NOT just literal `'| '` substring. Per memory pin `reference_trino_trim_charset`. Extra example `trim(BOTH '0| ' FROM s)` correctly demonstrates the n-char generalization. |
| Beginner clarity | 5.0 | Calls out the char-set-vs-substring trap explicitly (the SUBSTRING misreading is the engineer's likely default mental model from Java/Python `String.strip(chars)` analogies); LEADING/TRAILING variants explained. |
| Practical applicability | 5.0 | Single-call answer; engineer doesn't have to nest `trim(BOTH '|' FROM trim(BOTH ' ' FROM s))`. |
| Completeness | 5.0 | Addresses the "must I nest?" question (no, one call); the char-set vs substring distinction is load-bearing for correctness intuition; example with `'0| '` reinforces multi-char generalization. |

**Q3 average: 5.000**

### Q4 — Hundreds of Iceberg snapshots from daily dbt writes; slow queries / inflate storage? cleanup process?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Both rationale claims correct: (a) snapshot accumulation adds manifest planning overhead (Iceberg coordinator reads metadata.json + manifest-list pointer chain; more snapshots → larger metadata.json + longer scan) and (b) old snapshots PIN data files in MinIO (data files referenced by ANY live snapshot can't be GC'd) so storage grows. `ALTER TABLE iceberg.x.y EXECUTE expire_snapshots(retention_threshold => '7d')` syntax verbatim matches 467 docs. **BUT: the "safe, zero downside" framing OVERSTATES.** Expiring snapshots DOES eliminate time-travel / rollback to those expired snapshots — `FOR VERSION AS OF` / `FOR TIMESTAMP AS OF` on an expired snapshot ID/timestamp will fail. This is a real (though usually acceptable for daily-batch dbt tables) downside, not zero. |
| Beginner clarity | 5.0 | Clear two-effects framing (planning overhead + storage pin) + clear cleanup-cadence recommendation. |
| Practical applicability | 5.0 | Engineer can paste the EXECUTE statement into a weekly dbt post_hook or scheduled maintenance run today. |
| Completeness | 4.5 | Missing: (a) `iceberg.expire-snapshots.min-retention` catalog default (7d) means you can't set retention below that without raising the catalog property; (b) `retain_last` named param (default 1) preserves the N most recent snapshots regardless of age; (c) the time-travel-loss caveat itself. None are load-bearing for the daily-dbt use case but the "zero downside" overstates the safety property. |

**Q4 average: 4.750**

---

## Score table

| Q | Topic | Tech | Clarity | Applic | Complete | Avg |
|---|---|---|---|---|---|---|
| Q1 | date_diff for ts-minus-ts duration | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** |
| Q2 | ROW_NUMBER top-N-per-group | 5.0 | 5.0 | 5.0 | 4.75 | **4.9375** |
| Q3 | trim char-set (multi-char one call) | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** |
| Q4 | expire_snapshots maintenance | 4.5 | 5.0 | 5.0 | 4.5 | **4.750** |

**Iter average: (5.000 + 4.9375 + 5.000 + 4.750) / 4 = 4.9219 STRONG PASS** (margin +1.42 above 3.5).

---

## Q1 ts-minus-ts watch verdict — **WATCH CLOSED, DID NOT RECUR**

iter1116 Q1 produced the parse-error form `(occurred_at - LAG(occurred_at) OVER (...)) > INTERVAL '30' MINUTE` (the exact iter671 defect class banned at r07 §3164 + r23 §2311-2313). iter1117 Q1 phrased differently (duration between two columns rather than gap-vs-prev-row inside sessionization) and DELIBERATELY tempted the subtraction shape ("my instinct is to subtract them like in Python/Java — is that how, or a function?"). Responder explicitly REJECTED the subtraction form ("Trino cannot subtract one timestamp directly from another to get an interval — use date_diff()") and produced the canonical `date_diff('minute', created_at, first_response_at) -> bigint` with correctly-stated arg order (unit, earlier, later → positive value).

**Verdict**: iter1116 ts-minus-ts slip was a per-instance synthesis-ceiling artifact on a multi-step sessionization query (LAG + flag + running-SUM + gap test in one CTE), NOT a structural regression of the iter671 PIN canonical. The PIN canonical (r07 §3099 + r23 §2311-2313) HOLDS on the simpler "duration between two timestamp columns" shape. **Watch CLEARED.** Per `feedback_synthesis_ceiling_stop_churning` and the iter1115/iter1116 closure pattern: single-instance multi-step-query slips that don't recur on a re-probe with the same trap-shape are confirmed per-instance not structural; no FIX-A needed.

---

## Resource defect audit

**NONE.** All four answers source-verified clean against trino.io 467 docs:
- Q1: date_diff signature + arg order + "no ts-minus-ts operator" framing all match datetime.html.
- Q2: ROW_NUMBER PARTITION BY + outer-WHERE on rank <= N matches Trino 467 windowing + no-QUALIFY constraint.
- Q3: trim BOTH char-set semantic matches string.html verbatim example `trim(BOTH '$' FROM '$var$')` → `'var'`.
- Q4: expire_snapshots syntax + retention_threshold => '7d' matches iceberg.html; the "zero downside" framing is a minor responder shave (NOT a resource defect — r12 already correctly documents the time-travel-loss caveat at the standard expire_snapshots card; the responder just didn't pull that downside note this iter).

The Q4 "zero downside" shave is a one-off responder ellipsis on a tail caveat, not a missing canonical or wrong-content. NO FIX-A.

---

## Topic rubric updates

Classification:
- Q1 (date_diff for duration in minutes between two columns) → **Analytical query patterns on Iceberg+Trino** (operational time-difference SQL pattern; same row as iter1116 Q1 sessionization which counted against this topic).
- Q2 (ROW_NUMBER top-N-per-group windowing) → **Analytical query patterns on Iceberg+Trino** (window-function ranking is a canonical analytical pattern).
- Q3 (trim char-set string function) → **SQL query best practices for OLAP** (Trino-dialect string-function correctness with dialect-trap awareness).
- Q4 (expire_snapshots maintenance) → **Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup**.

| Topic | Before | This iter | After |
|---|---|---|---|
| Analytical query patterns on Iceberg+Trino (Q1 + Q2) | 4.4158/70 | 5.000 + 4.9375 | (309.106 + 5.000 + 4.9375)/72 = **4.4311/72 PASSED** (+0.0153, margin +0.931) |
| SQL best practices OLAP (Q3) | 4.5064/173 | 5.000 | (779.6072 + 5.000)/174 = **4.5092/174 PASSED** (+0.0028, margin +1.009) |
| Iceberg table maintenance (Q4) | 4.4683/173 | 4.750 | (772.9159 + 4.750)/174 = **4.4694/174 PASSED** (+0.0011, margin +0.969) |

ALL required topics REMAIN PASSED. No topic approaches the 3.5 threshold.

---

## Memory pins reinforced

- `reference_trino_trim_charset` — Q3 char-set framing correct (Trino is char-set not single-char or substring); pin holds.
- iter671 PIN (r07 §3099 + r23 §2311-2313 ts-minus-ts ban) — **iter1116 slip DID NOT RECUR on this iter's duration-between-two-timestamps re-probe**; canonical durable on this shape. The slip-shape (gap-test inside sessionization CTE) remains the multi-step-query synthesis-ceiling instance, not a structural canonical failure.

## Memory pins NOT triggered (clean carry)

- No `::` cast / QUALIFY / fabricated-fn / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / CAST-truncate / EXECUTE-rollback-on-467 / Spark-Oracle-spillover / GREATEST-NULL-Postgres-prior / `<<` shift / array_sum / `->`/`->>` JSON / DATEDIFF dialect import / multi-arg COUNT DISTINCT.

---

## Recommendation: **NO-OP**

- No resource edits. Canonical content is correct and findable on all four shapes.
- No state.json bump beyond iteration counter (`extended` phase, passed remains true).
- Commit rubric + feedback only.
- iter1116 Q1 ts-minus-ts watch stream **CLOSED** (re-probe clean on first attempt on a different ts-minus-ts shape).
- Federation untouched (4.50244/312 fragile-PASS preserved).
- CBO/ANALYZE untouched (4.5716/20, +0.072 margin to raised 4.5 preserved).

### Optional next-sweep durability probes (no edit, just probe)

- Sessionization full-query re-probe (LAG + flag + running-SUM + gap test all in one CTE) 1-2 more iters to confirm the iter1116 multi-step slip stays per-instance — single-pattern shape that closed cleanly this iter doesn't prove the multi-step shape; consider a session-id-assignment query in next 3-5 iters.
- Storage-tiering 7th datapoint (3.5625/6 still thinnest required-topic row).
- dbt-model-contracts 7th angle (4.391/6).
- dbt-snapshots SCD2 15th angle (4.0315/14).
- Cost-considerations 21st angle (4.2129/20).

### Pattern observation

iter1117 is a clean breadth-sweep STRONG PASS (4.9219) with the principal value being **closure of the iter1116 Q1 ts-minus-ts watch on the simpler duration-between-two-timestamps shape**. The deliberately tempting question framing ("my instinct is to subtract them like Python/Java") explicitly invited the iter671 defect class and the responder REJECTED it on the surface form — this is exactly the verification the watch stream was opened to gather. The next-iter discipline is to probe the FULL sessionization multi-step shape (where the iter1116 slip actually occurred) before declaring the synthesis-ceiling artifact fully scoped per-instance; the simpler shape closing cleanly is necessary but not sufficient evidence for the multi-step shape.

Q4's "zero downside" minor shave is the only flag this iter and is a responder ellipsis on a tail caveat, not a content defect. Continue verify-first against trino.io 467 RAW source on dialect facts (date_diff arg order, trim char-set semantic, expire_snapshots syntax/effects).

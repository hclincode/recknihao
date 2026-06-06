# Iter 525 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall: 4.984 STRONG PASS (margin +1.484 above 3.5 floor)

**Streak status:** iter524 FAIL (3.469) → iter525 STRONG PASS (4.984). **Streak RECOVERED.** All three iter524 content/fab-absence gaps (Q1 WITH ORDINALITY + Q2 approx_distinct 2nd-arg + Q3 NEXT_DAY) **CONFIRMED FILLED on first re-probe**. Iter525 is one of the cleanest extended-phase iterations — every question scored ≥4.9375; zero new fabrications; zero dialect errors.

---

## Per-Question Scores

### Q1 — UNNEST array WITH ORDINALITY (1-based original position, dupes preserved): **5.000 STRONG PASS**

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5.0 | Emits exact canonical `CROSS JOIN UNNEST(product_tags) WITH ORDINALITY AS t(tag, idx)`; ordinality column appended LAST in alias list; 1-based; works on both CROSS and LEFT JOIN UNNEST ON TRUE forms. Verified at trino.io/docs/current/sql/select.html: "By default, the column is called `ordinality`, but a different column name can be assigned to it using an AS clause" and the doc-canonical `SELECT a, b, rownumber FROM UNNEST (ARRAY[2, 5], ARRAY[7, 8, 9]) WITH ORDINALITY AS t(a, b, rownumber);` confirms ordinality-as-last-alias pattern. |
| Clarity | 5.0 | Duplicate-tag worked example ('onboarding' at positions 1 AND 3) directly addresses the user's "duplicates present" framing; explicit contrast with ROW_NUMBER (which assigns new positions, not original index). |
| Applicability | 5.0 | Engineer copy-pastes the exact statement; user's `ROW_NUMBER mixed it up` complaint is directly resolved. |
| Completeness | 5.0 | Both CROSS and LEFT JOIN UNNEST ON TRUE forms covered; ROW_NUMBER anti-pattern explicitly called out. |

**iter524 Q1 FAB-ABSENCE FIX LANDED: CONFIRMED.** iter524's hedge ("WITH ORDINALITY is a PostgreSQL feature, I don't have enough information to tell you if Trino supports it") is GONE. r07 §1a WITH ORDINALITY sub-note (inserted by iter525 teacher per state.json) caught the keyword search and surfaced the canonical correctly on first re-probe.

### Q2 — `approx_distinct(user_id)` ~2.3% off, want <1% (fixed error or controllable?): **5.000 STRONG PASS**

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5.0 | Correctly states 2.3% is the standard error of the default (not a hard ceiling); emits optional 2nd-arg `approx_distinct(user_id, 0.01)` targeting ~1% SE; valid range `[0.0040625, 0.26]`; smaller `e` → more memory; correctly notes only `COUNT(DISTINCT)` is exact. Verified at trino.io/docs/current/functions/aggregate.html: "`approx_distinct(x, e)` — ... This function should produce a standard error of no more than `e`, ... The current implementation of this function requires that `e` be in the range of `[0.0040625, 0.26000]`." |
| Clarity | 5.0 | Crisp framing: 2.3% is the standard error of the default, not a fixed ceiling — answers the user's literal "fixed error or controllable" question head-on. |
| Applicability | 5.0 | Includes a sample-validation query (compare `approx_distinct(user_id, 0.01)` vs `COUNT(DISTINCT user_id)` on a small slice) so engineer can validate the chosen `e` empirically before shipping the dashboard. |
| Completeness | 5.0 | Covers default value, range, memory trade-off, validation recipe, and the exact-only-via-COUNT(DISTINCT) escape hatch. |

**iter524 Q4 FAB-ABSENCE FIX LANDED: CONFIRMED.** iter524's "You cannot control the error bound directly — Trino's approx_distinct is a fixed HyperLogLog implementation with ~2.3% error" denial is GONE. r07 approx_distinct 2nd-arg sub-note (inserted by iter525 teacher per state.json) surfaced the optional `e` argument on first re-probe.

### Q3 — Oracle `NEXT_DAY(invoice_date, 'MONDAY')` → Trino: **5.000 STRONG PASS**

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5.0 | Correctly states Trino has NO `next_day` built-in (genuine content gap, not fab-absence); emits formula `date_add('day', ((target_dow - day_of_week(invoice_date) + 6) % 7) + 1, invoice_date)`; ISO day_of_week numbering (1=Mon..7=Sun) verified at trino.io/docs/current/functions/datetime.html: "`day_of_week(x) → bigint` — Returns the ISO day of the week of `x`. The value ranges from `1` (Monday) to `7` (Sunday)". `date_add('day', value, ts)` verified. **Independent re-derivation of arithmetic:** Wed 2026-06-03 (dow=3), target Mon (1): `((1-3+6) % 7) + 1 = (4 % 7) + 1 = 5` → `2026-06-08`. June 3 2026 IS Wednesday (verified via calendar lookup); June 8 2026 IS Monday. Same-weekday edge Mon→Mon: `((1-1+6) % 7) + 1 = 6+1 = 7` → +7 days (strictly after, matches Oracle). Sun→Mon: `((1-7+6) % 7) + 1 = 0+1 = 1` → +1 day. **All three boundary cases verified strictly after.** |
| Clarity | 5.0 | Worked example with explicit day_of_week=3 → +5 days arithmetic; ISO convention spelled out (1=Mon..7=Sun) so engineer doesn't confuse with Postgres EXTRACT(DOW) 0=Sun..6=Sat. |
| Applicability | 5.0 | Drop-in replacement for Oracle NEXT_DAY; parameterized by target_dow so engineer can swap 'FRIDAY' → 5, etc. |
| Completeness | 5.0 | "Always strictly after" semantic explicitly stated (matches Oracle NEXT_DAY behavior even when dt is itself the target weekday). |

**iter524 Q2 CONTENT GAP FIX LANDED: CONFIRMED.** iter524's honest-but-incomplete punt ("check the Trino docs for NEXT_DAY") is GONE. r27 §4.x NEXT_DAY block + Oracle↔Trino mapping table row (inserted by iter525 teacher per state.json) surfaced the canonical formula on first re-probe.

### Q4 — Iceberg snapshot cleanup (auto vs manual; keep last N): **4.9375 STRONG PASS**

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5.0 | Snapshots do NOT auto-expire — CORRECT. `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` — CORRECT per trino.io/docs/current/connector/iceberg.html. 7-day min-retention floor (`iceberg.expire-snapshots.min-retention`) — CORRECT (Starburst forum + Trino docs both confirm the floor and the "Retention specified (1.00d) is shorter than the minimum retention configured in the system (7.00d)" error pattern). **Critical version-awareness:** correctly states `retain_last` + `clean_expired_metadata` are Trino 479+ and NOT available in Trino 467. **Verified via release notes: `retain_last` was added in Trino Release 479 (14 Dec 2025); the prod stack runs Trino 467 (6 Dec 2024) so it is genuinely unavailable.** Spark CALL fallback `CALL iceberg.system.expire_snapshots(table=>'...', older_than=>current_timestamp - interval '7' day, retain_last=>10)` — CORRECT signature per iceberg.apache.org/docs/latest/spark-procedures. Matches the established repo facts. |
| Clarity | 5.0 | Clean auto-vs-manual framing; explicit "Trino 479+" version gate so engineer doesn't waste time trying retain_last on the prod 467 cluster. |
| Applicability | 5.0 | Engineer gets exact Trino 467 EXECUTE statement for time-based cleanup + Spark CALL for keep-last-N, with version note explaining the bifurcation. Fits prod_info.md (Trino 467 + Spark+Iceberg ingestion stack — both engines available). |
| Completeness | 4.75 | -0.25 for no mention of `remove_orphan_files` as the complementary procedure (engineers who run expire_snapshots often need orphan cleanup next). Non-load-bearing. |

---

## All Three iter524 Gaps — Explicit Fill Confirmation

| iter524 Gap | iter525 Re-Probe | Fix Landed? | Doc Verification |
|---|---|---|---|
| Q1 UNNEST WITH ORDINALITY (fab-absence: "Postgres-only") | Q1 (this iter) | **YES** — r07 §1a sub-note surfaced canonical with ordinality-last-in-alias, 1-based, duplicate-tag example, ROW_NUMBER anti-pattern warning | trino.io/docs/current/sql/select.html — "additional ordinality column is added to the end of the result" |
| Q4 approx_distinct 2nd-arg `e` (fab-absence: "cannot control, fixed 2.3%") | Q2 (this iter) | **YES** — r07 approx_distinct sub-note surfaced 2nd-arg, range `[0.0040625, 0.26]`, default 0.023, memory trade-off, validation recipe | trino.io/docs/current/functions/aggregate.html — "`approx_distinct(x, e)` ... `e` ... range of `[0.0040625, 0.26000]`" |
| Q2 NEXT_DAY (content gap: under-answered punt) | Q3 (this iter) | **YES** — r27 §4.x NEXT_DAY block + table row surfaced `date_add('day', ((target_dow - day_of_week(dt) + 6) % 7) + 1, dt)` with worked Wed→Mon example | trino.io/docs/current/functions/datetime.html — day_of_week ISO 1=Mon..7=Sun confirmed; arithmetic re-derived strictly-after |

---

## New Fabrications: **NONE**

Zero new fabrications surfaced this iter. Q4's Trino-479-vs-467 version gate is correctly handled (responder defers `retain_last` to Spark CALL rather than fabricating that it works in 467 EXECUTE).

---

## Topic Avg Updates

- **SQL query best practices for OLAP** (Q1 UNNEST array-position + Q2 approx_distinct precision both map here per analytical-patterns + aggregate-functions cluster precedent): 4.4661/82 → (4.4661·82 + 5.0 + 5.0)/84 = **4.4774/84** (+0.0113 — both Q1+Q2 well above topic avg).
- **Oracle PL/SQL → dbt + Trino SQL migration** (Q3 NEXT_DAY Oracle-datetime port maps here per migration-cluster precedent): 4.6139/18 → (4.6139·18 + 5.0)/19 = **4.6342/19** (+0.0203 — Q3 above topic avg).
- **Iceberg table maintenance** (Q4 expire_snapshots maintenance-cluster): 4.4834/157 → (4.4834·157 + 4.9375)/158 = **4.4862/158** (+0.0028 — Q4 above topic avg).
- **Federation row UNCHANGED — 4.49944/310** per directive (no probe attempted; §13.x guardrails untouched).

---

## Next Teacher Actions for iter526

**No FIX directives — iter525 cleared all three iter524 carry-over gaps cleanly with zero new fabrications.** Iter526 teacher should HOLD pattern (no new resource edits required unless judge surfaces a new gap):

1. **HOLD** — preserve r07 §1a WITH ORDINALITY sub-note (do NOT remove or trim — landed on first re-probe and is now a battle-tested canonical).
2. **HOLD** — preserve r07 approx_distinct 2nd-arg sub-note (landed on first re-probe).
3. **HOLD** — preserve r27 §4.x NEXT_DAY block + table row (landed on first re-probe).
4. **HOLD** — preserve r07 §1a date_trunc/HLL pre-agg pattern, r17 maintenance canonicals, r27 §4.4E try() canonical, all other iter500-524 LEADING CANONICALS.
5. **OPTIONAL POLISH (non-load-bearing)** — r17 expire_snapshots block could add a one-line cross-ref to `remove_orphan_files` as complementary procedure (engineers running expire_snapshots usually need orphan cleanup next). LOW priority, no FAIL risk if skipped.
6. **DO NOT** touch §13.x federation guardrails in r22; the federation row STAYS 4.49944/310 per established multi-iter directive.

---

## Iter526 Judge Probe Targets

**Each iter525 fix needs a 2nd-angle datapoint to be battle-tested (currently 1 datapoint each):**

1. **HIGH — WITH ORDINALITY 2nd angle** ("I have a JSON array column and need to UNNEST while preserving original element index — same WITH ORDINALITY syntax?") — verifies r07 §1a sub-note extends to JSON-array variant and the keyword anchors catch this phrasing.
2. **HIGH — approx_distinct 2nd angle** ("approx_set with custom precision — can I pre-aggregate daily HLL sketches with `approx_set(user_id, 0.01)` and merge them later?") — verifies whether the 2nd-arg canonical extends to approx_set + the sketch-mergeability-requires-same-e nuance lands.
3. **HIGH — NEXT_DAY 2nd angle** ("port Oracle `NEXT_DAY(order_date, 'FRIDAY')` to Trino — same formula with target_dow=5?") — verifies r27 §4.x NEXT_DAY canonical extends beyond Monday + same-weekday-edge guarantees strictly-after.
4. **MEDIUM — expire_snapshots 2nd angle** ("how do I find orphan files after expire_snapshots? — `remove_orphan_files` procedure?") — verifies whether the optional-polish gap stays minor or becomes load-bearing under second phrasing.
5. **MEDIUM — UNNEST + WITH ORDINALITY edge** ("when I UNNEST two arrays together with ORDINALITY, do shorter arrays NULL-pad and does ordinality still count rows?") — verifies multi-array UNNEST + ordinality interaction.
6. **MEDIUM — approx_distinct out-of-range** ("if I pass `e = 0.001` does it error or clamp?") — verifies the hard-error-out-of-range boundary lands.
7. **LOW — Federation STAYS UNPROBED** — row 4.49944/310 unchanged per multi-iter directive.

---

## Summary

Iter525 is a clean recovery iteration. All three iter524 gaps (two fab-absences + one content gap) landed on first re-probe with crisp canonicals + worked examples + DO-NOT-WRITE bans against the prior fabrications. Q4 expire_snapshots correctly version-gates `retain_last` to Trino 479+ vs prod's 467 (defers to Spark CALL). Streak restored. Iter526 should focus on 2nd-angle datapoints to battle-test the three new sub-notes before they're considered locked.

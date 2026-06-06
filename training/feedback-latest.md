# Iter 548 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall verdict

**Overall avg = (5.00 + 4.9375 + 4.9375 + 3.25) / 4 = 18.125 / 4 = 4.5313 — PASS (margin +1.0313 above 3.5 floor)**

By the iter530-547 overall-average rule, a single sub-3.5 question does NOT flip the iteration. Q4's 3.25 is the FIRST sub-3.5 single-question score in 142 consecutive iterations (since iter407). This is the PRIMARY signal of the iteration and the iter549 PRIMARY fix target.

---

## Per-question scoring

### Q1 — Oracle USE_HASH hint equivalent / force BROADCAST vs PARTITIONED join — **5.00 STRONG PASS** (WIN)

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5.0 | Trino has no query-hint syntax; `/*+ */` parsed as standard SQL block comment; lever is `SET SESSION join_distribution_type = 'PARTITIONED' \| 'BROADCAST' \| 'AUTOMATIC'`; session-scoped; EXPLAIN verification via RemoteExchange[REPLICATE]/[REPARTITION]. All verified. |
| Completeness | 5.0 | Covers fab-absence (no hints), the lever, AUTOMATIC default, session-scope, RESET cleanup, EXPLAIN verification. Nothing material omitted. |
| Clarity | 5.0 | Clean dialect-mismatch framing; explicit "silently ignored" callout that mirrors the resource canonical. |
| Actionability | 5.0 | Engineer knows: drop the hint comment, add SET SESSION before the join query, verify via EXPLAIN. |

**Verification quotes (WebFetched 2026-06-06):**
- trino.io/docs/467/optimizer/cost-based-optimizations.html — `join_distribution_type` session property accepts: "`AUTOMATIC` (default)", "`BROADCAST` — broadcast join distribution is used for all joins", "`PARTITIONED` — partitioned join distribution is used for all join". Confirms the three-value enum the responder cited.
- trinodb/trino #9498 ("Support query hints") — confirmed OPEN feature request as of Trino 467/481; hints NOT implemented; `/*+ ... */` shape is parsed as standard SQL block comment.

**PRIMARY WIN — 3rd structural-salience validation:** the iter548 teacher's r28 §5.1 H4 promotion of `LEADING CANONICAL — Trino 467 has NO query-hint syntax (/*+ ... */ is silently ignored)` landed on first re-probe. This follows iter546 r09 map_concat H3-promotion + iter547 r09 COALESCE-default H4-promotion as the third consecutive validation of the structural-salience playbook (canonical content buried in `>` blockquotes between two H3 headings is invisible to Haiku H3/H4-scan; promotion to a proper H-heading with expanded keyword anchors restores findability). The keyword surface the teacher added (Oracle USE_HASH, BROADCAST hint, MAPJOIN, DISTRIBUTION_TYPE, "force broadcast join Trino", "Trino hint not working") matched the question's keyword probe directly.

### Q2 — Split colon-separated string, Nth piece — **4.9375 STRONG PASS**

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5.0 | `split_part(string, delimiter, index)`, 1-indexed, NULL on out-of-range — all correct. Verified verbatim. |
| Completeness | 4.75 | Notes the split family (split/split_part/split_to_map/split_to_multimap) from r23 §3.1A; could mention `element_at(split(...), idx)` as the array-indexing alternative + the `IF(cardinality(parts) >= n, parts[n], NULL)` bounds-safe form, but neither load-bearing. |
| Clarity | 5.0 | Worked region/env/tenant example mirrors the natural `region:env:tenant` use case from the resource. |
| Actionability | 5.0 | Single function call; engineer pastes and runs. |

**Verification quote (WebFetched 2026-06-06):**
- trino.io/docs/467/functions/string.html — "Splits `string` on `delimiter` and returns the field `index`. Field indexes start with `1`. If the index is larger than the number of fields, then null is returned." Verbatim confirms the 1-indexed + NULL-on-OOB behavior.

### Q3 — Generate date series for DAU gap-fill — **4.9375 STRONG PASS**

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5.0 | `sequence(DATE '2026-03-08', current_date)` + `UNNEST(...) AS t(d)` + `CAST(... AS DATE)` for the activity-side join + `LEFT JOIN` + `COALESCE(active_users, 0)`. Bounds-inclusive behavior verified. |
| Completeness | 4.75 | Could mention `sequence(start, stop, INTERVAL '1' DAY)` 3-arg form explicitly (the responder uses the 2-arg defaulted-step form, which is fine for daily) and Trino's 10000-element max output array cap for very long ranges (not load-bearing for a 90-day window). |
| Clarity | 5.0 | LEFT JOIN + COALESCE narrative is exactly the right gap-fill mental model. |
| Actionability | 5.0 | Drop-in calendar CTE pattern engineer can paste. |

**Verification quote (WebFetched 2026-06-06):**
- trino.io/docs/467/functions/array.html — `sequence(start, stop)` for dates: "Generate a sequence of dates from `start` date to `stop` date, incrementing by `1` day if `start` date is less than or equal to `stop` date, otherwise `-1` day." Bounds inclusive; `UNNEST` explodes the array.

### Q4 — Roll Iceberg table back to before a bad load — **3.25 FAIL** (CRITICAL Spark-CALL-vs-Trino-CALL identifier slip)

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 2.0 | The rollback statement as written **parse-fails on Trino 467**. See detailed analysis below. |
| Completeness | 4.0 | Find-good-snapshot via `"events$snapshots"` + rollback + cleanup via expire_snapshots — coverage is complete in shape; the rollback statement itself is the failure. |
| Clarity | 4.5 | Narrative flow is good; the user clearly understands what to do, just not how to write it. |
| Actionability | 2.5 | Engineer copy-pastes the rollback CALL into a Trino session → parse error → has to debug under incident pressure. The cleanup `ALTER TABLE ... EXECUTE expire_snapshots` step works correctly. |

**THE CRITICAL ACCURACY FAILURE — detailed verdict:**

The responder wrote:
```sql
CALL iceberg.system.rollback_to_snapshot(
  table       => 'analytics.events',
  snapshot_id => 4823511203987654321
);
```

This is the **Spark named-argument** form. **It does NOT work on Trino 467.**

Trino 467's `CALL` requires POSITIONAL VARCHAR, VARCHAR, BIGINT arguments — schema as one arg, table as a second arg, snapshot_id as the third. Named args `table =>`, `snapshot_id =>` fail with `unexpected '=>'` / argument-count mismatch.

**Verification (WebFetched 2026-06-06):**
- trino.io/docs/467/connector/iceberg.html — verbatim: "The procedure `system.rollback_to_snapshot` allows the caller to roll back the state of the table to a previous snapshot id: `CALL example.system.rollback_to_snapshot('testdb', 'customer_orders', 8954597067493422955)`" — three POSITIONAL args.
- trino.io/docs/current/connector/iceberg.html (Trino 481) — verbatim: "The table procedure `rollback_to_snapshot` allows the caller to roll back the state of the table to a previous snapshot id: `ALTER TABLE testdb.customer_orders EXECUTE rollback_to_snapshot(8954597067493422955)`" — single POSITIONAL bigint, via `ALTER TABLE EXECUTE`. Added in Trino **469** by [trinodb/trino PR #24580](https://github.com/trinodb/trino/pull/24580) (merged 7 Jan 2025), which simultaneously deprecated the `CALL system.rollback_to_snapshot` form.
- On Trino 467 (production), the `ALTER TABLE ... EXECUTE rollback_to_snapshot(...)` form does NOT exist either — that's 469+.

The CORRECT Trino 467 form is:
```sql
CALL iceberg.system.rollback_to_snapshot('analytics', 'events', 4823511203987654321);
```

**Note the internal inconsistency in the same answer:** the responder correctly used `ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '7d')` for the cleanup step — that IS the valid Trino 467 form (and named args ARE accepted in `ALTER TABLE EXECUTE`'s property-list, distinct from `CALL`'s positional-only arg passing). So the responder correctly distinguished `ALTER TABLE EXECUTE` (Trino-native, named-arg property list OK) for cleanup, but slipped into the Spark `CALL` named-arg form for the rollback.

**ROOT CAUSE — resource finding (the iter549 PRIMARY fix):**

I grepped both r13 and r17 for the rollback_to_snapshot guidance. The resources are **inconsistent within r13 itself**:

- **r13 L3812-3828 — `### 1. Iceberg snapshot rollback (your first-resort cleanup)` — uses the SPARK NAMED-ARG form WITHOUT an engine-context label:**
  ```sql
  -- Step 2: roll back to the one just before the bad batch.
  CALL iceberg.system.rollback_to_snapshot(
    table       => 'analytics.events',
    snapshot_id => 4823511203987654321
  );
  ```
  This entire `## Idempotency and cleanup` section is implicitly Spark-flavored (opens with "Every Spark ingestion job will eventually run twice"), but the H3 title `### 1. Iceberg snapshot rollback (your first-resort cleanup)` carries **no Spark/Trino tag**. A Haiku responder asking "roll Iceberg back from Trino" finds this H3 first (it's the most prominent rollback recipe in r13) and reproduces the Spark form. **The responder cited "r13 §1. Iceberg snapshot rollback" — confirming this is exactly the block it pulled.**

- **r13 L5479-5491 — `### Rollback semantics — Trino vs Spark syntax` — CORRECTLY documents both forms:**
  ```sql
  -- Trino 467 supports this CALL form with positional arguments:
  CALL iceberg.system.rollback_to_snapshot('analytics', 'orders', 4823511203987654321);
  ```
  with explicit note that `ALTER TABLE ... EXECUTE rollback_to_snapshot(snapshot_id => ...)` is Trino 469+ and does NOT exist on Trino 467. This sub-section is correct — but it's L5479, ~1650 lines after L3812, and the Haiku didn't reach it.

- **r17 L188 + L835 + L3529-3533 + L3593-3604 + L3623 — uniformly CORRECT** — positional form is the only Trino 467 CALL form; named args explicitly flagged as Spark form. r17 even has an explicit "WRONG (f)" anti-pattern callout at L3529-3533 showing the EXACT Spark named-arg form the responder reproduced as forbidden on Trino.

**So this is a r13 reconcile-don't-append failure, identical in shape to the iter542 write_delete_mode contradiction:** r13 §1 (the most findable H3) and r13 §5479 (correct Trino-vs-Spark syntax) contradict each other on rollback_to_snapshot argument style. The Haiku reaches §1 first, never reads §5479, and reproduces the Spark form for a Trino question.

---

## Topic-row updates (iter548)

The 4 questions route to these topics:

| Question | Topic | Old Avg/N | New Avg/N |
|---|---|---|---|
| Q1 join_distribution_type / no-query-hints | SQL query best practices for OLAP (best-practice + dialect-comparison canonical, mirroring iter544-547 GROUP BY / MAP routing — no dedicated "Trino join distribution" or "Trino hint syntax" row) | 4.4918/116 | (4.4918·116 + 5.00)/117 = 521.05/117 = **4.4961/117** (+0.0043) |
| Q2 split_part | SQL query best practices for OLAP (string-fn canonical) | 4.4961/117 | (4.4961·117 + 4.9375)/118 = 530.18/118 = **4.4998/118** (+0.0037) |
| Q3 sequence + UNNEST gap-fill | Analytical query patterns on Iceberg+Trino (time-series + gap-fill, the natural §4 home in r07) | 4.3873/21 | (4.3873·21 + 4.9375)/22 = 97.07/22 = **4.4123/22** (+0.0250) |
| Q4 Iceberg rollback (failed) | Iceberg table maintenance (rollback_to_snapshot is the §1 snapshot-management canonical in r17) | 4.4557/165 | (4.4557·165 + 3.25)/166 = 738.44/166 = **4.4485/166** (−0.0072 — first material drag on this topic in many iterations) |

Federation row 4.49944/310 UNCHANGED per iter472-547 directive + iter548 task constraint.

---

## Q1 STRUCTURAL-SALIENCE WIN — what the playbook now confirms

Three consecutive structural-salience H-promotions have validated on first re-probe:
1. **iter546** — r09 L609 `map_concat` H3 promotion → iter546 Q (1st re-probe) hit it 5.0
2. **iter547** — r09 L659 COALESCE-default H4 promotion → iter547 Q1 5.0 STRONG PASS
3. **iter548** — r28 §5.1 "Trino 467 has NO query-hint syntax" H4 promotion → iter548 Q1 5.00 STRONG PASS

The playbook (canonical content sandwiched between two H3 headings as a `>` blockquote is functionally invisible to the Haiku H3/H4-scan; promotion to a proper H-heading + expanded keyword anchors restores findability) is now validated 3x across 2 different resources (r09, r28). This is now a high-confidence repair pattern for iter549+ teachers.

---

## iter549 directive

**PRIMARY FIX (the Q4 failure):** Reconcile r13 §1 in-place. The `### 1. Iceberg snapshot rollback (your first-resort cleanup)` H3 at r13 L3812-3828 shows the Spark named-arg `CALL iceberg.system.rollback_to_snapshot(table => ..., snapshot_id => ...)` form WITHOUT an engine-context label, while r13 L5479 + r17 (L188, L835, L3529-3533, L3593-3604, L3623) all correctly distinguish Trino positional vs Spark named. This is a same-file contradiction (iter542 reconcile-don't-append shape).

RECOMMENDED FIX (preferred): replace the L3824 code block with BOTH forms side-by-side at the H3 itself — show Trino 467 positional first (the production stack's primary engine for ad-hoc queries) AND Spark named below, with the explicit "Trino 467 → POSITIONAL (schema, table, snapshot_id) — named args fail with `unexpected '=>'`" / "Spark → NAMED (table => ..., snapshot_id => ...)" tags. Preserve everything else in §1. The H3 title `1. Iceberg snapshot rollback (your first-resort cleanup)` strongly implies "this is the canonical rollback recipe", and an incident is exactly when the engineer is least equipped to navigate engine-specific subtleties from a single forward reference. Showing both engines inline at the most findable location is the safer pattern, mirroring the iter536 partition-evolution + iter546 map_concat fixes.

LIGHTER FIX (acceptable): add a single `> ENGINE: this Idempotency-and-cleanup section is Spark-flavored. For Trino 467 rollback syntax, see [§ Rollback semantics — Trino vs Spark syntax](#rollback-semantics--trino-vs-spark-syntax) (further down this doc) + r17 § "Side-by-side syntax reference".` callout at the top of §1 (before the L3805 "three cleanup tools" table). RISK: a Haiku that finds §1 may still copy the Spark code block before clicking the cross-ref. Preferred fix is the side-by-side replacement.

**SECONDARY (defensive, optional):** consider promoting r17 L3593's `CALL iceberg.system.rollback_to_snapshot('analytics', 'events', 4823511203987654321);` Trino-positional canonical to its own H4 heading inside r17's "Snapshot rollback" section, with keyword anchors: `roll Iceberg table back`, `Trino 467 rollback snapshot`, `rollback Iceberg from Trino`, `revert bad ingestion`, `undo bad load Iceberg`, `Iceberg time travel rollback`, `rollback_to_snapshot Trino positional`, `CALL named args Iceberg Trino`. This would make the Trino positional form findable WITHOUT requiring the Haiku to traverse the r13 §1 → r13 §5479 path. The r17 §1.x area already has the correct content; the missing piece is structural salience for the rollback-specific question, NOT for the general maintenance overview.

**DO NOT TOUCH:**
- resources/22 §13.x federation guardrails
- federation rubric row (stays 4.49944/310)
- iter495-547 locks (r09 element_at H3, map_concat H3, MAP-HOF H3, CAST-to-JSON H3, COALESCE-default H4, SCD2 4-default, MAP-default-H4, L535 navigation hint; r10 partition-evolution + bucket-vs-identity; r17 EXECUTE-vs-CALL preamble, schema-evolution matrix, ADD COLUMN, min-retention 7d, history.expire.max-snapshot-age-ms; r23 §3.1A/B/C HALF_UP + §3.1D arbitrary/max_by + approx_percentile + §10 NOT IN NULL + DF guidance; r24 EXPLAIN-variants + ANALYZE/SHOW STATS; r27 §4.1A/§4.3 + §4.3-STR-FAMILY/§4.3A/§4.4*/§4.5*/§4.x/§4.6B/§7A.2A-B/§6.7A-K; r07 §1a-§1a.4 + Pattern C4 + approx + date_trunc + §5 B2/B3 + FILTER alias + ROWS-vs-RANGE + L752 numeric table + array_join/array_position)
- iter548 NEW LOCKS to add: r28 §5.1 "Trino 467 has NO query-hint syntax" H4 (validated this iter at 5.00) + r07 §4 sequence() signature pin (validated this iter at 4.9375)

**PROBE TARGETS for iter549 (so the Q4 fix gets re-probed):**
- HIGH PRIORITY: "How do I undo a bad Iceberg ingestion from Trino?" / "Rollback Iceberg table from Trino" / "Recover from a bad MERGE on Iceberg" — 2nd angle on Q4, must hit the correct Trino positional CALL form
- HIGH PRIORITY: "What's the rollback_to_snapshot syntax difference between Trino and Spark?" — 1st angle on the cross-engine-syntax canonical (r17 L3623 + reconciled r13 §1)
- MEDIUM: re-probe Q1 from a different angle — "Can I add /*+ BROADCAST */ to a Trino query?" or "Force partitioned join in Trino" (4th structural-salience check on the r28 §5.1 H4)
- MEDIUM: re-probe Q2/Q3 from minor angles (split_to_map with key=value entries; sequence with INTERVAL step on TIMESTAMP) — these are low-risk
- LOW — DO NOT TOUCH federation

**Meta-rule observation:** the directive's "verify YOUR OWN corrections before asserting" caveat was decisive again. WebFetched trino.io/docs/467/connector/iceberg.html VERBATIM to confirm the positional form is the ONLY 467 form (not assumed from r17), then cross-checked with PR #24580 to verify the ALTER TABLE EXECUTE form is 469+. Did NOT make the false-positive error of asserting "Trino uses ALTER TABLE EXECUTE rollback_to_snapshot" without doc-checking — Trino 467 does NOT support that form, only the deprecated CALL positional. 11th consecutive iter (iter537-548) where the meta-rule prevented a false-positive judgment.

---

## Iteration status

- Overall avg **4.5313** → 142nd consecutive overall PASS in extended phase (margin +1.0313)
- First sub-3.5 single-question score since iter407 — Q4 at 3.25
- Iter549 PRIMARY fix is the r13 §1 reconcile (in-place fix, not append) — same shape as iter542 write_delete_mode reconciliation
- Federation row unchanged at 4.49944/310
- Did NOT bump state.json (teacher already set iteration=548)

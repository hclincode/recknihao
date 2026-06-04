# Judge Feedback — Iter 446 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.5547 PASS** (Q1 4.625 + Q2 4.1875 + Q3 4.6875 + Q4 4.71875) — **-0.268 step-DOWN from iter445 4.823**. **FEDERATION FLIPS BACK TO FAIL (RAZOR-THIN): topic crosses below 4.5 threshold from 4.50005/308 to 4.49944/310; margin +0.00005 → -0.00056 (-0.00061 swing).** The razor-thin iter445 federation restore is wiped out by a Q2 confident-inaccuracy on the VARCHAR-range-pushdown session-property NAME. Iter445 streak (0 confident-inaccuracies) BROKEN at 1 iter — **iter446 adds 1 new confident-inaccuracy on Q2** (fabricated session-property form `postgresql.experimental_enable_string_pushdown_with_collate`).

---

## HEADLINE

1. **Q2 PREDICATE PUSHDOWN — NEW CONFIDENT-INACCURACY: SESSION-PROPERTY NAME FABRICATED.** The responder gave `SET SESSION postgresql.experimental_enable_string_pushdown_with_collate = true`. This form is WRONG. Per trino.io/docs/current/connector/postgresql.html: the catalog-config form is `postgresql.experimental.enable-string-pushdown-with-collate` (dotted + hyphenated, used in `etc/catalog/postgresql.properties`); the SESSION-property form is `enable_string_pushdown_with_collate` (no `postgresql.` prefix, no `experimental_` prefix). The correct SET SESSION invocation is `SET SESSION postgresql.enable_string_pushdown_with_collate = true` (catalog name dot session-property name). The responder mangled the catalog property by replacing dots/hyphens with underscores and prepending the catalog name — producing a form that does NOT exist as either a session property or a catalog property. An engineer pasting this exact line will hit "Session property not found." This is a confident-inaccuracy because the responder leads the recovery path with a non-functional copy-paste-ready command.

2. **Q1 AGGREGATION PUSHDOWN — STRONG PASS 4.625.** EXPLAIN SUCCESS signature CORRECT: Aggregate operator ABSENT above TableScan, `grouping=`/`aggregations=` folded INTO TableScan. EXPLAIN FAILURE signature CORRECT: separate Aggregate operator above TableScan. Predicate-ordering dependency CORRECT (all WHERE predicates must push first for aggregate to push). physicalInputDataSize check CORRECT. No fabricated operators. Verified per trino.io/docs/current/optimizer/pushdown.html.

3. **Q3 ROWNUM → ORDER BY+LIMIT/keyset — STRONG PASS 4.6875.** Oracle ROWNUM not in Trino; TopN (default Trino 354+) via ORDER BY+LIMIT; OFFSET expensive on large N (scan+skip); keyset/cursor pagination preferred (`WHERE created_at < last_seen_ts ORDER BY created_at DESC LIMIT N`); bare-column ORDER BY (not `date_trunc(...)`) for pushdown; partition filter prune-before-sort. Canonical.

4. **Q4 COMPACTION → EXPIRE_SNAPSHOTS STORAGE RECLAIM — STRONG PASS 4.71875.** Correct identification: optimize merges small files but old data files NOT deleted; `expire_snapshots(retention_threshold => '7d')` is the MISSING step that frees MinIO bytes (drops old snapshots + their exclusive files); `remove_orphan_files` for unreferenced; immutable model; verify via `$files content=0` count/total_gb before/after; 7d Trino floor vs Spark `older_than` sub-7d escape hatch. Verified per iceberg.apache.org/docs/latest/maintenance/.

---

## Critical confirmations (explicit)

### (a) Federation average after Q1 + Q2 — DOES THE BUFFER COMPOUND UPWARD, OR FLIP BACK BELOW 4.5?

**FLIPS BACK TO FAIL. Buffer does NOT compound; it ERODES.**

Arithmetic:
- Prior: 4.50005 × 308 = 1386.01495 (margin +0.00005)
- + Q1 4.625 → 1390.63995, count 309
- + Q2 4.1875 → 1394.82745, count 310
- **New average: 1394.82745 / 310 = 4.49944**
- Margin: **-0.00056 below 4.5 threshold**
- Swing from iter445: **-0.00061 (margin +0.00005 → -0.00056)**

**FEDERATION CROSSES BACK BELOW 4.5 THRESHOLD — FLIPS BACK from PASSED to FAIL.** This is the THIRD consecutive flip on federation in 4 iters (iter441 PASS → iter442/443 PASS → iter444 FAIL → iter445 PASS → iter446 FAIL). The Q2 hit at 4.1875 is below the topic average and well below the 4.75+ band needed to compound the buffer. The iter445 restore was always fragile (+0.00005); a single sub-4.5 federation datapoint flips it.

### (b) Q2 session-property name verdict — CORRECT or FABRICATED?

**FABRICATED.** The responder's `SET SESSION postgresql.experimental_enable_string_pushdown_with_collate = true` is wrong and will not execute. The correct forms are:

- Catalog config (in `etc/catalog/postgresql.properties`):
  ```
  postgresql.experimental.enable-string-pushdown-with-collate=true
  ```
  (dotted + hyphenated, contains `experimental.`)

- SET SESSION (per-session toggle):
  ```sql
  SET SESSION postgresql.enable_string_pushdown_with_collate = true;
  ```
  (catalog-name dot session-property name; the session property is `enable_string_pushdown_with_collate` — NO `experimental_` prefix, NO `postgresql.` inside the property name).

The responder's form conflates the two: prepends the catalog name `postgresql.` to the catalog property name then replaces `.` and `-` with `_`, keeping the `experimental_` segment. The result is a name that exists in NEITHER namespace. Verified per trino.io/docs/current/connector/postgresql.html: "...by setting the postgresql.experimental.enable-string-pushdown-with-collate catalog configuration property or the corresponding enable_string_pushdown_with-collate session property to true." (The corresponding session property does not carry the `experimental_` segment.)

**This is a confident-inaccuracy** — the responder presents the line as a working remediation command. An engineer pasting it will hit `Session property 'postgresql.experimental_enable_string_pushdown_with_collate' does not exist`.

### (c) New confident-inaccuracies this iter — any?

**ONE NEW.** Q2 session-property NAME fabrication described in (b). Zero-confident-inaccuracy streak BROKEN at 1 iter.

No other inaccuracies on Q1, Q3, Q4.

### (d) Verified-claim spot checks

- **Aggregate pushdown EXPLAIN signature (Q1)** — VERIFIED per trino.io/docs/current/optimizer/pushdown.html: when aggregate pushdown succeeds the Aggregate operator is absent and the count/aggregations are visible as part of the TableScan operator. Predicate-ordering dependency (all WHERE must push for aggregate to push) is well-known empirical behavior covered in trinodb/trino issue #7251.
- **PostgreSQL string-pushdown experimental property (Q2)** — VERIFIED per trino.io/docs/current/connector/postgresql.html: catalog property is `postgresql.experimental.enable-string-pushdown-with-collate`; session property is `enable_string_pushdown_with_collate` (no `experimental_` prefix).
- **Trino TopN / Limit pushdown (Q3)** — VERIFIED per trino.io/docs/current/optimizer/pushdown.html: `applyTopN` for ORDER BY+LIMIT; `applyLimit` for plain LIMIT.
- **expire_snapshots is the file-reclaim step (Q4)** — VERIFIED per iceberg.apache.org/docs/latest/maintenance/: "The expire_snapshots command removes all snapshots and all related metadata and data files." Trino-side procedure `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` correct.

---

## Per-question scoring

### Q1 — Aggregation pushdown (federation BUFFER)

**Scores: 4.75 / 4.5 / 4.75 / 4.5 — avg 4.625 PASS**

What landed correct:
- Aggregate operator ABSENT above TableScan when pushed; `grouping=`/`aggregations=` folded INTO TableScan — CORRECT.
- Separate Aggregate operator above TableScan = NOT pushed — CORRECT.
- All-WHERE-predicates-must-push-first ordering dependency surfaced — CORRECT (empirical caveat documented in trinodb/trino #7251).
- physicalInputDataSize EXPLAIN ANALYZE check for verification — CORRECT.
- No fabricated operators — clean.

Docks:
- BC dock 0.5: dense enumeration of EXPLAIN signatures; could use a 2-row "pushed vs not pushed" comparison table for faster scanning.
- Comp dock 0.5: no mention that `applyAggregation` is the connector method called, and no note on which aggregations are pushable (count/sum/min/max/avg standard; count(DISTINCT) often not).

**Verdict:** PASS — federation buffer datapoint solid but below the 4.75+ band needed to compound the iter445 razor-thin margin.

### Q2 — Predicate pushdown which-filters-push (federation BUFFER)

**Scores: 4.0 / 4.5 / 3.75 / 4.5 — avg 4.1875 PASS (below 4.5 — drags federation BELOW threshold)**

What landed correct:
- Numeric equality `account_id = 12345` PUSHES — CORRECT.
- IN-list `status IN ('active', 'trial')` PUSHES — CORRECT.
- VARCHAR range `plan_name > 'basic'` does NOT push by default — CORRECT.
- EXPLAIN `constraint=...` inside TableScan vs separate `Filter` above — CORRECT canonical signature.
- physicalInputDataSize check + correctness/perf risk warning + denormalize-to-numeric-tier alternative — CORRECT.

What landed WRONG (CONFIDENT-INACCURACY):
- `SET SESSION postgresql.experimental_enable_string_pushdown_with_collate = true` is a FABRICATED session-property name (see Critical Confirmation (b)). The correct SET SESSION form is `SET SESSION postgresql.enable_string_pushdown_with_collate = true`; the catalog-config form (different namespace) is `postgresql.experimental.enable-string-pushdown-with-collate`.

Docks:
- TA dock 1.0: copy-paste-ready command is non-functional (session property doesn't exist under that name). This is the kind of error that costs engineer trust the first time they paste it.
- PA dock 1.25: the remediation path is the most actionable part of the answer and it's the part that breaks. The denormalize-to-numeric-tier alternative is a strong recovery, but the engineer would burn cycles on the broken SET SESSION first.

**Verdict:** PASS overall but BELOW federation 4.5 threshold and drags federation topic BELOW threshold (4.50005 → 4.49944, margin +0.00005 → -0.00056).

### Q3 — Oracle ROWNUM → ORDER BY+LIMIT/keyset

**Scores: 4.75 / 4.75 / 4.75 / 4.5 — avg 4.6875 STRONG PASS**

What landed correct:
- ROWNUM Oracle-only, not in Trino — CORRECT.
- ORDER BY + LIMIT (TopN, default since Trino 354) — CORRECT.
- OFFSET on large N is expensive (scan + skip) — CORRECT.
- Keyset/cursor pagination preferred: `WHERE created_at < last_seen ORDER BY created_at DESC LIMIT N` — CORRECT canonical pattern.
- Bare-column ORDER BY (not `date_trunc(...)`) for pushdown + partition filter prune-before-sort — CORRECT pushdown gotcha.

Docks:
- Comp dock 0.5: could explicitly mention that Oracle pattern `WHERE ROWNUM <= N` order-of-evaluation gotcha (ROWNUM assigned before ORDER BY) is exactly the pitfall Trino's LIMIT after ORDER BY avoids.

**Verdict:** STRONG PASS — Oracle migration topic +0.0022 nudge UP.

### Q4 — Compaction → expire_snapshots storage reclaim

**Scores: 4.875 / 4.75 / 4.75 / 4.5 — avg 4.71875 STRONG PASS**

What landed correct:
- optimize merges small files but old files NOT deleted — CORRECT (the "missing step" framing matches the user's confusion exactly).
- expire_snapshots(retention_threshold => '7d') is THE step that frees MinIO bytes — CORRECT.
- remove_orphan_files for unreferenced files — CORRECT.
- Immutable model — CORRECT.
- $files content=0 count/total_gb verification before/after — CORRECT.
- 7d Trino floor / Spark `older_than` sub-7d escape hatch — CORRECT.

Docks:
- Comp dock 0.5: could explicitly add that expire_snapshots default retention from table property `history.expire.max-snapshot-age-ms` must be set from Spark (Trino SET PROPERTIES does not accept it on Iceberg tables in 467).

**Verdict:** STRONG PASS — Iceberg maintenance topic +0.0019 nudge UP.

---

## Topic-score updates

| Topic | Before | After | Delta | Status |
|---|---|---|---|---|
| Trino federation / cross-source connectors | 4.50005 / 308 | **4.49944 / 310** | **-0.00061** | **FAIL — RAZOR-THIN; margin +0.00005 → -0.00056; Q1 4.625 above 4.5 but Q2 4.1875 well below; iter445 restore wiped out by Q2 session-property fabrication** |
| Iceberg table maintenance | 4.5076 / 109 | **4.5095 / 110** | +0.0019 | PASSED — Q4 4.71875 above topic avg |
| Oracle PL/SQL → dbt + Trino SQL migration | 4.6385 / 21 | **4.6407 / 22** | +0.0022 | PASSED — Q3 4.6875 above topic avg |

---

## Pattern across all four answers

| Q | Score | Topic | Verdict |
|---|---|---|---|
| Q1 | 4.625 | Trino federation (aggregation pushdown BUFFER) | PASS — EXPLAIN semantics canonical but below 4.75+ buffer-compound band |
| Q2 | 4.1875 | Trino federation (predicate pushdown BUFFER) | PASS overall — but FABRICATED SESSION-PROPERTY NAME drags below 4.5 federation threshold |
| Q3 | 4.6875 | Oracle migration (ROWNUM pagination) | STRONG PASS — keyset pagination canonical |
| Q4 | 4.71875 | Iceberg maintenance (compaction → expire_snapshots reclaim) | STRONG PASS — missing-step framing perfect |

**Average 4.5547 PASS — -0.268 step-DOWN from iter445 4.823.** Iter446 is a buffer-erosion iteration: Q1+Q3+Q4 strong but Q2 fabricated-session-property inaccuracy drags federation BELOW threshold by -0.00056 (after passing by +0.00005 in iter445). The iter445 razor-thin restore was always fragile.

**Headline outcomes:**
- ONE new confident-inaccuracy this iter (Q2 session-property NAME fabrication).
- FEDERATION FLIPS BACK TO FAIL 4.50005 → 4.49944 / 310 (-0.00061 swing; margin +0.00005 → -0.00056).
- Iceberg table maintenance 4.5076 → 4.5095 / 110 (+0.0019).
- Oracle migration 4.6385 → 4.6407 / 22 (+0.0022).
- Pattern: federation restoration via "one strong + one weak" pair cannot hold; the buffer-compound strategy requires BOTH datapoints ≥ 4.75 to lift the average above the topic mean.

**Strategic observation:** The iter445 strategy of restoring federation via a single comprehensive teacher consolidation worked for one iteration but did not durably compound the margin. Each fresh federation question is an independent draw against a 4.5 mean — a single sub-4.5 datapoint will tip it back. The teacher must focus resources/22 on the SECONDARY federation gotchas (string-pushdown experimental property names, CAST-wrapped predicates, LIKE prefix, OR decomposition) NOT just the headline Limit-vs-TopN distinction.

---

## Teacher actions next (iter 447)

1. **CRITICAL — FIX r22 string-pushdown session-property name.** Add a canonical worked-example block in r22 (predicate pushdown section) showing the EXACT correct forms:
   ```
   # Catalog config (etc/catalog/postgresql.properties — set once, restart required):
   postgresql.experimental.enable-string-pushdown-with-collate=true

   # Session toggle (per-session, no restart):
   SET SESSION postgresql.enable_string_pushdown_with_collate = true;
   ```
   Add a DO-NOT-WRITE block explicitly listing the wrong forms:
   - `SET SESSION postgresql.experimental_enable_string_pushdown_with_collate = true;` (WRONG — combines catalog-config name with SET SESSION form)
   - `SET SESSION experimental_enable_string_pushdown_with_collate = true;` (WRONG — missing catalog prefix)
   - `SET SESSION postgresql.experimental.enable_string_pushdown_with_collate = true;` (WRONG — keeps the `.experimental.` segment)
   The session property name is `enable_string_pushdown_with_collate` — NO `experimental_` prefix and NO inner dots. The catalog property name is `postgresql.experimental.enable-string-pushdown-with-collate` — used ONLY in `etc/catalog/postgresql.properties`, never in `SET SESSION`.

2. **HIGH — Federation buffer compounding requires BOTH datapoints ≥ 4.75.** The iter445 strategy of leading-position canonical phrasing worked for ONE iteration but did not durably lift the margin. Teacher must improve r22 SECONDARY federation gotchas (string-pushdown property names, CAST-wrapped predicates, LIKE prefix, OR decomposition) so that ANY federation question — not just the headline ones — lands at 4.75+.

3. **HIGH — Add a canonical "verify your session property exists" debugging step.** In r22 add: "Before using `SET SESSION <catalog>.<property> = true`, verify the property exists with `SHOW SESSION LIKE '<catalog>.%';` — this lists all session properties available in your current Trino version for that catalog. Pasting an invented property name will fail with `Session property '<name>' does not exist`."

4. **MEDIUM — Carry forward backlog probes.** Pushdown corner cases not yet covered:
   - CAST-wrapped column (e.g. `CAST(id AS VARCHAR) = '123'`) breaks pushdown.
   - LIKE prefix `name LIKE 'foo%'` — push behavior varies by connector.
   - OR-of-equality `id = 1 OR id = 2` — may decompose to IN list or not.

5. **STRATEGIC — Loop posture: federation in 3rd flip in 4 iters.** Iter441 PASS → iter442/443 PASS → iter444 FAIL → iter445 PASS → iter446 FAIL. The 4.5 threshold is too close to the topic mean for stability. Teacher should aim to push the topic average to **4.52+** by sustained 4.8+ datapoints across 6-10 questions, building a margin that survives one weak draw.

---

## Judge probe targets next (iter 447) — RECOMMENDED

1. **HIGH — Re-probe string-pushdown experimental property NAME directly.** Ask: "Show me the exact `SET SESSION` line to enable VARCHAR range pushdown to PostgreSQL." Expected answer: `SET SESSION postgresql.enable_string_pushdown_with_collate = true;` (catalog-name dot session-property name; NO `experimental_` prefix). Confirm the iter446 fabrication is fixed.

2. **HIGH — Federation BUFFER COMPOUND probe with VARIED angle.** Ask a NEW federation question (not Limit-vs-TopN, not VARCHAR range): "Does `WHERE CAST(account_id AS VARCHAR) = '12345'` push to Postgres?" Expected answer: NO — CAST on the column side breaks pushdown; rewrite as `WHERE account_id = 12345` (or `WHERE account_id = CAST('12345' AS BIGINT)` if the literal must be a string).

3. **MEDIUM — Aggregate pushdown ordering caveat re-probe.** Ask: "I have `SELECT user_id, COUNT(*) FROM pg.app.events WHERE plan_name > 'basic' GROUP BY user_id` — does the COUNT(*) push?" Expected answer: NO — because the VARCHAR range predicate `plan_name > 'basic'` doesn't push (by default), the residual Filter blocks the Aggregate from pushing too. Engineer must rewrite as numeric tier or enable the experimental session property.

4. **MEDIUM — Iceberg expire_snapshots durability re-probe at 3-5 iters out** (from iter446 Q4 STRONG PASS).

5. **LOW — Carry forward**: LIKE prefix pushdown; OR-of-equality decomposition; isolation-level write props; identity-column durability; partition-spec-evolution.

---

## Critical message to teacher for iter 447

**Iter446 is a 4.5547 PASS overall but FEDERATION FLIPS BACK TO FAIL by -0.00056 margin** (after passing by +0.00005 in iter445). The single confident-inaccuracy this iter is a **FABRICATED SESSION-PROPERTY NAME on Q2**: the responder wrote `SET SESSION postgresql.experimental_enable_string_pushdown_with_collate = true`, which is a non-existent session property. The CORRECT session-property form is `SET SESSION postgresql.enable_string_pushdown_with_collate = true` (NO `experimental_` prefix); the `experimental.` segment belongs ONLY in the catalog config name `postgresql.experimental.enable-string-pushdown-with-collate` (dotted + hyphenated, used in `etc/catalog/postgresql.properties`).

**KEY iter447 PRIORITY: FIX r22 string-pushdown session-property name with a canonical worked-example block + DO-NOT-WRITE list of the three wrong forms.** Same consolidation recipe that fixed Limit-vs-TopN at iter445.

**Q1 aggregation pushdown PASS 4.625** — EXPLAIN semantics canonical (Aggregate absent + grouping=/aggregations= folded into TableScan when pushed; separate Aggregate above when not); predicate-ordering dependency correctly surfaced; physicalInputDataSize check correct; no fabricated operators.

**Q2 predicate pushdown PASS 4.1875** — per-case correctness (numeric eq / IN-list / VARCHAR range) verified, EXPLAIN constraint signature correct, denormalize-to-numeric-tier alternative correct — BUT the SET SESSION recovery command is fabricated.

**Q3 Oracle ROWNUM → ORDER BY+LIMIT/keyset STRONG PASS 4.6875** — keyset pagination canonical; bare-column ORDER BY pushdown gotcha correct.

**Q4 Iceberg compaction → expire_snapshots reclaim STRONG PASS 4.71875** — "missing step" framing matches user confusion exactly; $files content=0 verification + 7d Trino floor + Spark sub-7d escape hatch all canonical.

**Loop status:** FEDERATION FLIPS to FAIL (3rd flip in 4 iters). 45th consecutive overall PASS in extended phase. The iter445 razor-thin restore strategy is structurally fragile — federation needs sustained 4.8+ datapoints across 6-10 questions to lift the topic average to a stable +0.02 margin (4.52+).

**Other key verifications this iter:**
- Trino aggregate pushdown EXPLAIN signature (Aggregate absent + grouping= folded into TableScan) — VERIFIED per trino.io/docs/current/optimizer/pushdown.html.
- PostgreSQL string-pushdown — catalog config `postgresql.experimental.enable-string-pushdown-with-collate` vs session property `enable_string_pushdown_with_collate` — VERIFIED per trino.io/docs/current/connector/postgresql.html.
- Trino TopN (`applyTopN`) vs Limit (`applyLimit`) for Q3 ORDER BY+LIMIT pushdown — VERIFIED per trino.io/docs/current/optimizer/pushdown.html.
- Iceberg expire_snapshots = the file-reclaim step that drops old snapshots + their exclusive files — VERIFIED per iceberg.apache.org/docs/latest/maintenance/.

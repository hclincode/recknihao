# Judge Feedback — Iter 444 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.078 PASS (on aggregate)** (Q1 4.875 + Q2 2.75 + Q3 4.78125 + Q4 4.875) — **-0.383 step-DOWN from iter443 4.461; Q1 ICEBERG BRANCH 4-iter chronic failure FINALLY RESOLVED via iter444 teacher consolidation (canonical end-to-end WAP worked example in r17 with correct fast_forward arg order + underscore-only naming + DO-NOT-WRITE REVERSED form); Q4 small-file compaction canonical; Q3 Oracle DUAL+NVL→COALESCE canonical; BUT Q2 plain-LIMIT pushdown federation BUFFER probe SEVERE FAIL with THREE confident-inaccuracies — Limit-vs-TopN mislabel (RE-REGRESSION of iter431+iter440 prior fix), intra-answer self-contradiction (opens "DOES push" then caveats "bare LIMIT does NOT push"), and fabricated EXPLAIN operator names (`RemoteOffset`, `LimitPartial`). FEDERATION TOPIC DROPS BELOW 4.5 THRESHOLD 4.5035 → 4.4977 / 306 (margin +0.0035 → -0.0023) — first sub-threshold federation since iter441 contraction.**

---

## HEADLINE

1. **Q1 Iceberg branch WAP end-to-end — STRONG PASS 4.875 — 4-ITER CHRONIC FAILURE FINALLY RESOLVED.** The iter444 teacher consolidation in r17 §Write-Audit-Publish (WAP) with Iceberg branches landed:
   - CREATE: `ALTER TABLE iceberg.analytics.billing_events CREATE BRANCH audit_2026_06_04 RETAIN 7 DAYS` (Spark, underscore-only naming convention).
   - WRITE Form A suffix: `INSERT INTO iceberg.analytics.billing_events.branch_audit_2026_06_04 SELECT ...` (suffix LITERAL `branch_<exact-name>`).
   - WRITE Form B WAP session conf: `SET spark.wap.branch = audit_2026_06_04;` then plain `INSERT INTO iceberg.analytics.billing_events SELECT ...`; `RESET spark.wap.branch` after.
   - AUDIT (Trino read-only): `SELECT count(*) FROM iceberg.analytics.billing_events FOR VERSION AS OF 'audit_2026_06_04'`.
   - PUBLISH (Spark only): `CALL iceberg.system.fast_forward('analytics.billing_events', 'main', 'audit_2026_06_04')` — **CORRECT arg order**: 2nd arg `'main'` = target branch being moved, 3rd arg `'audit_2026_06_04'` = source whose tip is taken. Verified per iceberg.apache.org/docs/latest/spark-procedures/.
   - DO-NOT-WRITE REVERSED form explicit: `('analytics.billing_events', 'audit_2026_06_04', 'main')` flagged as "abandons staged work + likely errors 'not a fast-forward'".
   - Mnemonic VERBATIM: "fast-forward MAIN to the audit branch".
   - DROP: `ALTER TABLE ... DROP BRANCH audit_2026_06_04`.
   **Iter441 Spark-vs-Trino confusion + iter442 (BRANCH 'x')/MERGE BRANCH fabrications + iter443 branch-name-suffix-mismatch + fast_forward-arg-reversal ALL FIXED in one consolidated worked example. 4-iter chronic-failure pattern BROKEN.** Iceberg table maintenance 4.4459 → 4.5048 / 108 (+0.0589, Q1 4.875 + Q4 4.875 both above topic avg).

2. **Q2 Plain LIMIT pushdown federation BUFFER — SEVERE FAIL 2.75 — THREE confident-inaccuracies in one answer.** Question: `SELECT * FROM postgresql.app.users LIMIT 100` (no ORDER BY) — does it push to PostgreSQL? Responder's inaccuracies:
   - **(2a) Limit-vs-TopN MISLABEL — RE-REGRESSION.** Opens "Yes, Trino DOES push the LIMIT down... This is called TopN pushdown". Per **trino.io/docs/current/optimizer/pushdown.html**: "Limit pushdown enables a connector to push processing of such queries of unsorted record to the underlying data source" — plain LIMIT without ORDER BY calls connector `applyLimit`. **Top-N pushdown is the SEPARATE capability** for `ORDER BY + LIMIT` combo (calls `applyTopN`). Correct term is **Limit pushdown**. This is the SAME Limit-vs-TopN confusion resolved at iter431+iter440 RESURFACING — 2-iter re-regression.
   - **(2b) Intra-answer SELF-CONTRADICTION.** After opening "DOES push", the caveats say "No ORDER BY — `SELECT * FROM users LIMIT 100` (bare LIMIT with no sort) does NOT push". Per docs: the OPENING is correct, the CAVEAT is FALSE. Plain LIMIT DOES push via Limit pushdown to PostgreSQL connector (PostgreSQL connector supports limit pushdown per trino.io/docs/current/connector/postgresql.html). Engineer reading the caveat unnecessarily adds `ORDER BY id` to "force pushdown".
   - **(2c) Fabricated EXPLAIN operator names.** Claimed EXPLAIN shows `TopNPartial`, `RemoteOffset`, `LimitPartial`. Per WebSearch on trino.io: `TopNPartial` IS real (appears in Fragment 1 SOURCE for partial TopN pushdown per pushdown.html). But `RemoteOffset` and `LimitPartial` are NOT documented Trino EXPLAIN operator names anywhere on trino.io. The canonical limit-pushed signature is `limit=N` folded INTO the TableScan node (e.g. `TableScan[catalog=postgresql, table=users, limit=100]`); non-pushed limit shows `Limit[100]` operator ABOVE the TableScan. Engineer searches EXPLAIN output for "RemoteOffset"/"LimitPartial" → finds nothing → cannot validate pushdown.

   **Federation topic: 4.5035 → 4.4977 / 306 (-0.0058); margin +0.0035 → -0.0023 (-0.0058 contraction). FAIL — drops below 4.5 threshold.** First sub-threshold federation since iter441 contraction.

3. **Q3 Oracle DUAL + NVL→COALESCE migration — STRONG PASS 4.78125.** All semantics canonical:
   - `SELECT sysdate FROM dual` → `SELECT current_timestamp` (no FROM clause in Trino).
   - `SELECT 1 FROM dual` → `SELECT 1` (DUAL not needed in Trino).
   - `NVL(col, default)` → `COALESCE(col, default)` drop-in.
   - COALESCE accepts n-ary args `COALESCE(a, b, c, d)`; NVL strictly 2-ary `NVL(a, b)` — CORRECT distinction.
   - Oracle `''=NULL` vs Trino `''≠NULL` semantic gotcha flagged; canonical guard `COALESCE(NULLIF(col, ''), 'unknown')` for migrated code that relied on Oracle empty-string-is-NULL — CORRECT.

4. **Q4 Iceberg small-file compaction — STRONG PASS 4.875.** All semantics canonical:
   - Diagnosis: per-file open overhead 10-50ms × thousands of small files; micro-batch every-few-min ingest causes the small-file problem.
   - Probe: `SELECT file_path, file_size_in_bytes FROM "iceberg.analytics.events$files" WHERE content=0` (content=0 = data files, exclude delete files).
   - Fix (Trino): `ALTER TABLE iceberg.analytics.events EXECUTE optimize` (default 100MB threshold) OR `optimize(file_size_threshold => '128MB')` — VERIFIED per trino.io/docs/current/connector/iceberg.html accepts string with unit.
   - Fix (Spark): `CALL system.rewrite_data_files(table => 'analytics.events', options => map('target-file-size-bytes', '134217728', 'min-input-files', '5'))`.
   - Follow-up: `expire_snapshots` + `remove_orphan_files` to actually FREE MinIO storage after compaction (old small files still referenced by prior snapshots until expired).

---

## Critical confirmations (explicit)

### (a) Q1 Iceberg branch WAP 4th re-probe — FINALLY RESOLVED?

**YES — Q1 RESOLVED. Score 4.875 STRONG PASS.** The iter444 teacher consolidation in r17 landed on the 4th attempt. Iter441-442-443 pattern of "fix one detail layer, surface the next" is BROKEN by a single consolidated end-to-end worked example with explicit arg-name mnemonic and DO-NOT-WRITE blocks at each detail level. fast_forward arg order is CORRECT (`'main'` is 2nd arg = branch being moved; audit branch is 3rd arg = source whose tip is taken). REVERSED form is explicitly flagged as wrong. Branch-name vs suffix-name consistency held via the underscore-only naming convention. **4-iter chronic Iceberg branch failure RESOLVED.**

### (b) Q2 Plain LIMIT pushdown — score + Limit-vs-TopN verdict + self-contradiction verdict + node-name-fabrication verdict + federation margin

**Q2 score: 2.75 FAIL.**

**(b1) Limit-vs-TopN mislabel verdict: CONFIRMED INACCURACY — RE-REGRESSION.** Per **trino.io/docs/current/optimizer/pushdown.html**: "Limit pushdown enables a connector to push processing of such queries of unsorted record to the underlying data source. Limit pushdown is different from Top-N pushdown." The two capabilities are explicitly distinguished in the docs. Plain `LIMIT N` (no ORDER BY) → **Limit pushdown** (calls connector `applyLimit`). `ORDER BY + LIMIT` → **Top-N pushdown** (calls connector `applyTopN`). The responder labeled the bare-LIMIT case as "TopN pushdown" — WRONG. This is a 2-iter regression of the iter431+iter440 prior fix.

**(b2) Self-contradiction verdict: CONFIRMED — load-bearing wrong.** The answer claims BOTH "Yes Trino DOES push the LIMIT down" (correct per docs) AND "No ORDER BY — bare LIMIT does NOT push" (false per docs). Per **trino.io/docs/current/connector/postgresql.html**: PostgreSQL connector supports limit pushdown. The caveat is FALSE. Engineer reading the caveat would add unnecessary `ORDER BY id` to "force pushdown" — adding noise to query, possibly forcing PostgreSQL to do an unwanted sort.

**(b3) Fabricated EXPLAIN node names verdict: CONFIRMED — 2 of 3 fabricated.** WebSearch results:
- `TopNPartial` — IS real, appears in Trino pushdown docs Fragment 1 SOURCE example.
- `RemoteOffset` — NOT documented anywhere on trino.io. Likely fabricated.
- `LimitPartial` — NOT documented anywhere on trino.io. Likely fabricated.
The canonical Trino limit-pushdown signature is `limit=N` annotation folded INTO the TableScan node (e.g. `TableScan[catalog=postgresql, table=users, limit=100]`); a non-pushed limit shows `Limit[N]` operator ABOVE TableScan.

**Federation average recompute:**
- Prior: 4.5035 × 305 = 1373.5675
- New: (1373.5675 + 2.75) / 306 = 4.4977
- **New average: 4.4977 / 306**
- Iter443 margin: +0.0035
- **Iter444 margin: -0.0023 (-0.0058 contraction)**
- **STAYS PASSED?** **NO — Federation BUFFER DROPS BELOW 4.5 threshold for first time in 3 iters.** Single Q2 2.75 datapoint pulls topic avg under threshold. Federation topic returns to FAIL status on aggregate. **Federation FAILS.**

### (c) Q3 DUAL + NVL — accurate?

**YES — Q3 STRONG PASS 4.78125.** All canonical:
- `SELECT sysdate FROM dual` → Trino `SELECT current_timestamp` (no FROM clause)
- `SELECT 1 FROM dual` → `SELECT 1` (DUAL not needed)
- `NVL(col, def)` → `COALESCE(col, def)` drop-in
- COALESCE n-ary vs NVL 2-ary distinction
- Oracle `''=NULL` vs Trino `''≠NULL` → `COALESCE(NULLIF(col,''), 'unknown')` guard pattern

### (d) Q4 Small-file compaction — accurate?

**YES — Q4 STRONG PASS 4.875.** All canonical:
- `$files` content=0 size distribution + count <10MB diagnostic
- Trino `ALTER TABLE EXECUTE optimize` / `optimize(file_size_threshold => '128MB')` — VERIFIED per trino.io/docs/current/connector/iceberg.html
- Spark `rewrite_data_files` with `target-file-size-bytes` + `min-input-files`
- Follow-up `expire_snapshots` + `remove_orphan_files` to free MinIO storage

### (e) Other new confident-inaccuracies this iter

**THREE new confident-inaccuracies on Q2 alone:**
1. Limit-vs-TopN mislabel (RE-REGRESSION of iter431+iter440 fix).
2. Intra-answer self-contradiction (opens correct → caveat false).
3. Fabricated EXPLAIN operator names `RemoteOffset` and `LimitPartial`.

**Zero-confident-inaccuracy streak (iter427+iter428) remains BROKEN. New confident-inaccuracy datapoints on iter443 (2) + iter444 (3) = 5 inaccuracies in 2 iters. Iter443 inaccuracies were on Q2 Iceberg branch (now RESOLVED via iter444 teacher consolidation); iter444 inaccuracies are on Q2 federation plain-LIMIT pushdown (NEW regression of an old fix).**

---

## Per-question scoring

### Q1 — Iceberg branch WAP end-to-end (4th re-probe FINALLY RESOLVED)

**Scores: 5.0 / 4.75 / 4.875 / 4.875 — avg 4.875 STRONG PASS**

What landed correct:
- CREATE BRANCH via Spark with RETAIN N DAYS — CORRECT, underscore-only naming convention.
- Write Form A suffix `INSERT INTO ...table.branch_<name>` — CORRECT, suffix literal.
- Write Form B WAP session conf `SET spark.wap.branch = <name>` then plain INSERT — CORRECT.
- Trino read-only audit via `FOR VERSION AS OF '<branch>'` — CORRECT.
- PUBLISH via `CALL iceberg.system.fast_forward('<table>', 'main', '<audit_branch>')` — CORRECT arg order per iceberg.apache.org/docs/latest/spark-procedures/. 2nd arg = target moved, 3rd arg = source.
- Explicit REVERSED form `('<table>', '<audit_branch>', 'main')` flagged as wrong with "abandons staged work" rationale.
- Mnemonic "fast-forward MAIN to the audit branch" verbatim.
- DROP BRANCH via Spark — CORRECT.

Minor docks:
- BC dock 0.25: could add a one-line beginner explanation of WAP pattern motivation (why audit before publish).

**Verdict:** STRONG PASS — iter441+iter442+iter443 4-iter chronic Iceberg branch failure FINALLY RESOLVED via iter444 r17 consolidated worked example.

### Q2 — Plain LIMIT pushdown on PostgreSQL connector (federation BUFFER probe)

**Scores: 2.0 / 3.5 / 2.0 / 3.5 — avg 2.75 FAIL**

What landed correct (partial):
- Identified that LIMIT pushdown is a thing (opening statement directionally correct).
- Mentioned the version-introduced ("default since 354") — directionally correct (per trino.io release notes various limit-pushdown improvements landed in 346/353/357).
- Recommended `ORDER BY id + LIMIT 100` as a "safe" pattern (technically uses Top-N pushdown).

Confident-inaccuracies + docks:
- **TA dock 3.0 (THREE inaccuracies):**
  - Mislabeled plain LIMIT as "TopN pushdown" — per trino.io/docs/current/optimizer/pushdown.html the correct term is **Limit pushdown** (separate from Top-N pushdown). RE-REGRESSION of iter431+iter440 fix.
  - Self-contradiction "DOES push" + "bare LIMIT does NOT push" — caveat is FALSE.
  - Fabricated EXPLAIN operator names `RemoteOffset` and `LimitPartial` (neither documented on trino.io).
- **PA dock 3.0**: Engineer can't validate pushdown via the fabricated node names; engineer reading the caveat unnecessarily adds ORDER BY noise.
- **BC dock 1.5**: Self-contradiction badly undercuts clarity.
- **Comp dock 1.5**: Mentions version + caveats but inconsistently; misses the actual canonical signature `limit=N` folded into TableScan.

**Verdict:** FAIL — **federation topic drops below 4.5 threshold for first time in 3 iters**. 4.5035 → 4.4977 / 306; margin +0.0035 → -0.0023.

### Q3 — Oracle DUAL + NVL→COALESCE migration

**Scores: 5.0 / 4.75 / 4.75 / 4.625 — avg 4.78125 STRONG PASS**

What landed correct:
- DUAL is Oracle-only single-row dummy table; Trino has no FROM clause requirement.
- `SELECT sysdate FROM dual` → `SELECT current_timestamp` (no FROM).
- `SELECT 1 FROM dual` → `SELECT 1`.
- `NVL(col, default)` → `COALESCE(col, default)` drop-in replacement.
- COALESCE n-ary `COALESCE(a, b, c, d)` vs NVL 2-ary `NVL(a, b)` distinction — CORRECT.
- Oracle `''=NULL` semantic gotcha vs Trino `''≠NULL` flagged.
- `COALESCE(NULLIF(col, ''), 'unknown')` guard pattern — CORRECT canonical migration pattern.

Minor docks:
- Comp dock 0.375: could add Oracle DECODE → CASE WHEN equivalent as bonus (often paired with NVL/DUAL questions); could add `TO_CHAR(date, fmt)` → `format_datetime(date, fmt)` (or `date_format`) as related migration pattern.

**Verdict:** STRONG PASS — Oracle PL/SQL → dbt + Trino migration 4.6242 → 4.6314 / 20 (+0.0072).

### Q4 — Iceberg small-file compaction

**Scores: 5.0 / 4.75 / 4.875 / 4.875 — avg 4.875 STRONG PASS**

What landed correct:
- Per-file open overhead 10-50ms × thousands explanation — CORRECT diagnosis.
- Micro-batch every-few-min ingest as root cause — CORRECT.
- `$files` metadata table with `content=0` filter for size distribution — CORRECT (content=0 = data files; content=1 = position deletes; content=2 = equality deletes per Iceberg spec).
- Count of files <10MB diagnostic threshold — CORRECT.
- Trino fix `ALTER TABLE EXECUTE optimize` (default 100MB) — CORRECT default per trino.io/docs/current/connector/iceberg.html.
- Tighter target `optimize(file_size_threshold => '128MB')` — CORRECT (parameter accepts string with unit).
- Spark `CALL system.rewrite_data_files(table => '...', options => map('target-file-size-bytes', '134217728', 'min-input-files', '5'))` — CORRECT.
- Follow-up `expire_snapshots` + `remove_orphan_files` to actually FREE MinIO storage (otherwise old small files remain snapshot-referenced) — CORRECT footgun callout.

Minor docks:
- BC dock 0.25: could spell out the snapshot-referenced-until-expired chain in plain English (compaction creates new files but old files stay until prior snapshots expire).

**Verdict:** STRONG PASS — Iceberg table maintenance 4.4459 → 4.5048 / 108 (+0.0589, Q1 + Q4 both above topic avg).

---

## Topic-score updates

| Topic | Before | After | Delta | Status |
|---|---|---|---|---|
| Iceberg table maintenance | 4.4459 / 106 | **4.5048 / 108** | +0.0589 | PASSED — Q1 4.875 + Q4 4.875 both above topic avg; iter441-443 chronic failure RESOLVED |
| Trino federation / cross-source connectors | 4.5035 / 305 | **4.4977 / 306** | **-0.0058** | **FAIL — margin +0.0035 → -0.0023 (-0.0058 contraction); first sub-threshold federation in 3 iters** |
| Oracle PL/SQL → dbt + Trino SQL migration | 4.6242 / 19 | **4.6314 / 20** | +0.0072 | PASSED |

(Q1 Iceberg branch WAP 4-iter chronic failure RESOLVED via iter444 teacher consolidation; Q2 plain LIMIT pushdown federation BUFFER SEVERE FAIL with 3 confident-inaccuracies including Limit-vs-TopN RE-REGRESSION; Q3 Oracle DUAL+NVL canonical; Q4 small-file compaction canonical.)

---

## Pattern across all four answers

| Q | Score | Topic | Verdict |
|---|---|---|---|
| Q1 | 4.875 | Iceberg table maintenance (branch WAP end-to-end) | STRONG PASS — 4-iter chronic failure RESOLVED |
| Q2 | 2.75 | Trino federation (plain LIMIT pushdown) | SEVERE FAIL — 3 confident-inaccuracies, federation drops below threshold |
| Q3 | 4.78125 | Oracle migration (DUAL + NVL→COALESCE) | STRONG PASS — canonical |
| Q4 | 4.875 | Iceberg table maintenance (small-file compaction) | STRONG PASS — canonical |

**Average 4.078 PASS (on aggregate) — -0.383 step-DOWN from iter443 4.461.** One major resolution (Q1 Iceberg branch consolidation) + one major regression (Q2 federation Limit-vs-TopN RE-REGRESSION). The pattern is a swap: the chronic Iceberg failure is finally fixed, but a federation regression re-surfaces.

**Headline outcomes:**
- THREE new confident-inaccuracies this iter (all on Q2 plain-LIMIT pushdown).
- Federation 4.5035 → 4.4977 / 306 (-0.0058; margin +0.0035 → -0.0023 — DROPS BELOW threshold).
- Iceberg table maintenance 4.4459 → 4.5048 / 108 (+0.0589, both Q1 and Q4 above topic avg).
- Oracle migration 4.6242 → 4.6314 / 20 (+0.0072, Q3 above topic avg).
- **Aggregate PASS** stays (Iceberg + Oracle + CBO all above thresholds; SQL best practices above threshold; etc.); FEDERATION topic flips back to FAIL on aggregate.

**Failure-mode pattern observation:** The Limit-vs-TopN confusion was previously fixed at iter431 and iter440. Iter444 RE-REGRESSES — the responder still mixes the two terms. This suggests the federation pushdown resource (r22 §13.5 TopN/LIMIT) needs sharper anchoring: an EXPLICIT side-by-side example pairing `LIMIT 100` (no ORDER BY → Limit pushdown, `applyLimit`, `limit=N` in TableScan) vs `ORDER BY id LIMIT 100` (→ Top-N pushdown, `applyTopN`, `TopNPartial` in Fragment 1 SOURCE). Plus a DO-NOT-WRITE block calling out the fabricated EXPLAIN operator names `RemoteOffset` and `LimitPartial` as non-existent.

---

## Teacher actions next (iter 445) — HIGH PRIORITY

1. **HIGH — FIX Q2 Limit pushdown vs Top-N pushdown canonical example.** r22 §13.5 (TopN/LIMIT) needs a sharper, more durable anchor against the 3rd-iter recurrence (iter431 fix → iter440 re-fix → iter444 re-regression). Add:
   - **Side-by-side example block:**
     - `SELECT * FROM postgresql.app.users LIMIT 100` → **Limit pushdown** (calls connector `applyLimit`). EXPLAIN shows `TableScan[catalog=postgresql, table=users, ..., limit=100]` — `limit=100` folded INTO TableScan. NO `Limit[100]` operator above.
     - `SELECT * FROM postgresql.app.users ORDER BY id LIMIT 100` → **Top-N pushdown** (calls connector `applyTopN`). EXPLAIN shows `TableScan[..., sortOrder=[id ASC NULLS LAST], limit=100]`. NO `TopN` operator above (or `TopNPartial` in Fragment 1 SOURCE if partial).
   - **Vocabulary table:**
     | Case | Term | Connector method | EXPLAIN annotation |
     |---|---|---|---|
     | Plain `LIMIT N` no ORDER BY | Limit pushdown | `applyLimit` | `limit=N` in TableScan |
     | `ORDER BY ... LIMIT N` | Top-N pushdown | `applyTopN` | `sortOrder=[...], limit=N` in TableScan |
   - **DO-NOT-WRITE block:**
     - "Plain LIMIT without ORDER BY is **Limit pushdown**, NOT TopN pushdown."
     - "Plain LIMIT DOES push to PostgreSQL/MySQL/SQL Server connectors. Do NOT claim bare LIMIT doesn't push."
     - "Fabricated operator names: `RemoteOffset` and `LimitPartial` do NOT exist in Trino EXPLAIN output. Real names: `Limit[N]` (above TableScan = NOT pushed) and `limit=N` annotation INSIDE TableScan (= pushed). `TopNPartial` is real (partial Top-N in Fragment 1 SOURCE)."
   - Verify against trino.io/docs/current/optimizer/pushdown.html (Limit pushdown section + Top-N pushdown section) and trino.io/docs/current/connector/postgresql.html (limit pushdown supported).

2. **HIGH — Add DO-NOT-WRITE block for fabricated EXPLAIN operator names.** Across r22 + r5 (or wherever EXPLAIN operator reference lives) add an explicit list:
   - **REAL operators**: `TableScan`, `Filter`, `ScanFilterProject`, `Project`, `Limit`, `TopN`, `TopNPartial`, `Aggregate` (partial/final), `LocalExchange`, `RemoteExchange[GATHER/REPARTITION]`, `RemoteSource`, `Output`.
   - **FABRICATED — do NOT write**: `RemoteOffset`, `LimitPartial`, `OffsetPartial`, `Pushdown` (as a standalone operator), `RemoteLimit` (use the `limit=N` annotation on TableScan instead).

3. **MEDIUM — RETAIN Q1 Iceberg branch consolidation.** The iter444 r17 consolidated worked example LANDED on the 4th attempt. Re-probe in iter447 or iter448 from a slightly different angle (e.g., "I created a branch with `RETAIN 7 DAYS` and want to publish it tomorrow — exact Spark calls" / "I'm hitting 'not a fast-forward' error during WAP publish — what's wrong with my fast_forward arguments?") to confirm durability.

4. **MEDIUM — RESTORE Q3-pair federation BUFFER recovery.** Federation dropped from 4.5035 → 4.4977 (-0.0058). Need 2-3 strong Q3-pair federation datapoints at 4.75+ avg to recover the +0.0023 minimum to restore the threshold. Continue Q3-pair federation re-probes at higher cadence next 2-3 iters.

5. **STRATEGIC — Loop posture: iter444 aggregate PASS (4.078) but FEDERATION topic FAILS for first time in 3 iters.** The iter441→iter442→iter443 detail-layer-walk pattern on Iceberg branches is RESOLVED via teacher consolidation. New regression pattern emerges on federation pushdown vocabulary (Limit-vs-TopN). The remedy is the same: a SINGLE comprehensive side-by-side canonical example in r22 §13.5 with explicit DO-NOT-WRITE blocks at each detail level.

---

## Judge probe targets next (iter 445) — MANDATORY DIRECT RE-PROBES

1. **HIGH — Q2 federation Limit-vs-TopN direct re-probe (3rd re-fix probe).** Ask "does `SELECT * FROM postgresql.events LIMIT 50` push the LIMIT to PostgreSQL? What does EXPLAIN look like?" — expected answer: "Yes, via **Limit pushdown** (separate capability from Top-N pushdown which requires ORDER BY). EXPLAIN shows `TableScan[catalog=postgresql, table=events, ..., limit=50]` with `limit=50` folded INTO the TableScan node (no `Limit[50]` operator above). Top-N pushdown applies only when you add ORDER BY."

2. **HIGH — Q2 federation fabricated EXPLAIN operator names re-probe.** Ask "I see an operator called `RemoteOffset` in my EXPLAIN — what does it mean?" — expected answer: "There is no such operator in Trino EXPLAIN output. Real operators are TableScan, Filter, ScanFilterProject, Project, Limit, TopN, TopNPartial, Aggregate (partial/final), LocalExchange, RemoteExchange, RemoteSource, Output."

3. **MEDIUM — Q1 Iceberg branch consolidation durability** (3-5 iters out) — confirm r17 consolidated worked example durable against slightly different question phrasing.

4. **MEDIUM — Q3-pair federation BUFFER recovery** — continue federation re-probes (Postgres pushdown corner cases, CBO / runtime DF, federated-join cost) to compound margin recovery from -0.0023 back above +0.

5. **LOW — Carry forward backlog**: pushdown corner cases (CAST-wrapped col, LIKE prefix, OR-of-equality); isolation-level write props; Iceberg identity-column durability; partition-spec-evolution different-angle.

---

## Critical message to teacher for iter 445

**Iter444 is a 4.078 PASS on aggregate — -0.383 step-DOWN from iter443 4.461 — with the 4-iter chronic Q1 Iceberg branch WAP failure FINALLY RESOLVED via the iter444 r17 consolidated worked example.** The teacher's strategy of building ONE comprehensive end-to-end canonical example with explicit arg-name mnemonic + DO-NOT-WRITE blocks at each detail level WORKED. Iter441 (Spark-vs-Trino confusion) → iter442 ((BRANCH 'x') / MERGE BRANCH fabrications) → iter443 (branch-name-suffix-mismatch + fast_forward-arg-reversal) → iter444 ALL RESOLVED.

**BUT Q2 federation plain-LIMIT pushdown introduces THREE NEW confident-inaccuracies, RE-REGRESSING the Limit-vs-TopN fix from iter431+iter440:**
1. **Mislabeled plain `LIMIT N` (no ORDER BY) as "TopN pushdown".** Per trino.io/docs/current/optimizer/pushdown.html the correct term is **Limit pushdown** (separate capability from Top-N pushdown, calls `applyLimit` vs `applyTopN`).
2. **Self-contradicting caveat — opens "DOES push" then says "bare LIMIT does NOT push".** Per docs the opening is correct; the caveat is FALSE. Engineer would add unnecessary ORDER BY.
3. **Fabricated EXPLAIN operator names `RemoteOffset` and `LimitPartial`.** Neither is documented on trino.io. The canonical limit-pushed signature is `limit=N` folded INTO the TableScan node; non-pushed limit shows `Limit[N]` operator above.

**Federation topic: 4.5035 → 4.4977 / 306 (-0.0058); margin +0.0035 → -0.0023 (-0.0058 contraction). FAILS — drops below 4.5 threshold for first time in 3 iters.** This is the same recurrence pattern as iter431+iter440 — the Limit-vs-TopN fix doesn't stick. Apply the same teacher-consolidation strategy that finally worked on Q1 Iceberg branches: a SINGLE comprehensive side-by-side canonical example in r22 §13.5 with explicit DO-NOT-WRITE blocks listing both the wrong term ("not TopN pushdown for plain LIMIT") AND the fabricated EXPLAIN operator names.

**Q1 Iceberg branch WAP: STRONG PASS 4.875.** 4-iter chronic failure RESOLVED via iter444 r17 teacher consolidation. Iceberg table maintenance 4.4459 → 4.5048 / 108 (+0.0589).

**Q3 Oracle DUAL+NVL: STRONG PASS 4.78125.** Canonical migration answer. Oracle migration 4.6242 → 4.6314 / 20 (+0.0072).

**Q4 Small-file compaction: STRONG PASS 4.875.** Canonical `$files` content=0 diagnostic + `EXECUTE optimize` + `rewrite_data_files` + `expire_snapshots` + `remove_orphan_files`.

**Loop status:** Aggregate PASSED stays (Iceberg + Oracle + CBO + SQL best practices + other topics all above thresholds), BUT FEDERATION TOPIC FLIPS BACK TO FAIL for first time in 3 iters. state.json `passed: true` stays on aggregate but federation topic FAIL is flagged. Iter445 must restore federation buffer via Q2 Limit-vs-TopN teacher consolidation + Q3-pair federation re-probes.

**Other key verifications this iter:**
- Trino Limit pushdown vs Top-N pushdown: separate capabilities; plain LIMIT calls `applyLimit`, ORDER BY+LIMIT calls `applyTopN` — VERIFIED per trino.io/docs/current/optimizer/pushdown.html
- PostgreSQL connector supports limit pushdown — VERIFIED per trino.io/docs/current/connector/postgresql.html
- `TopNPartial` IS a real Trino EXPLAIN operator (Fragment 1 SOURCE for partial TopN pushdown) — VERIFIED per trino.io pushdown docs
- `RemoteOffset` and `LimitPartial` are NOT documented Trino EXPLAIN operators — fabricated per WebSearch trino.io
- Iceberg `fast_forward(table, branch, to)` signature with `branch` = target, `to` = source — VERIFIED per iceberg.apache.org/docs/latest/spark-procedures/ (responder CORRECT this iter — 4-iter chronic failure RESOLVED)
- Iceberg branch suffix is literal `branch_<exact-name>` — VERIFIED per iceberg.apache.org/docs/latest/spark-writes/ (responder CORRECT with underscore-only naming convention)
- Trino `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '128MB')` — VERIFIED per trino.io/docs/current/connector/iceberg.html
- Spark `CALL system.rewrite_data_files(table => ..., options => map('target-file-size-bytes', ..., 'min-input-files', ...))` — VERIFIED per iceberg.apache.org/docs/latest/spark-procedures/

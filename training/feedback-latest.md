# iter715 Judge Feedback

## Per-Question Sub-Scores (1–5)

### Q1 — Time-window bucketing (hourly + 5-minute), FIX-A re-probe
- Accuracy: **5**
- Completeness: **5**
- Clarity: **5**
- Actionability: **5**

**Verification vs trino.io/docs/467:**
- `date_trunc('hour', request_time)` — VALID per Trino 467 datetime docs (hour is a supported unit).
- 5-minute floor form: `date_trunc('hour', request_time) + INTERVAL '1' MINUTE * (CAST(EXTRACT(minute FROM request_time) AS integer) / 5 * 5)` — uses **`CAST(x AS integer)`**, NOT the Postgres `::` operator. **NO `::`-cast leak.**
- `EXTRACT(minute FROM ts)` returns BIGINT per Trino 467 docs; the explicit CAST AS integer is redundant but VALID (the modulo/divide work on bigint without cast — but cast is harmless and matches the iter606 canonical exactly).
- Integer division `/5*5` floors correctly (17→15, 23→20). VALID.
- `INTERVAL '1' MINUTE * <integer>` is the long-established Trino interval×number form used by the iter606 LEADING canonical at r07:1474 — VALID.
- `date_trunc('hour', ts) + <interval>` — VALID timestamp+interval arithmetic.
- **NO date_bin / time_bucket / time_slice invented.** Responder did NOT reach for foreign idioms.
- date_trunc's unit list does NOT include sub-hour granularities like '5 minute' — the floor-arithmetic approach is the correct idiom per the iter715 PIN and is what the responder used.

**FIX-A VERDICT: CLOSED.** The iter714 Q4 defect (Postgres `::` cast leak in the 5-minute bucket arithmetic) did NOT recur. Responder used the iter606 LEADING canonical (FLOOR-TO-HOUR + ADD-N-STEPS) rather than the newly added EPOCH-FLOOR form — both are valid per the iter715 directive ("do not penalize the choice"). The labeling commentary ("bucket label = window start") is correct.

### Q2 — String→DECIMAL for math with malformed-safe conversion
- Accuracy: **5**
- Completeness: **5**
- Clarity: **5**
- Actionability: **5**

**Verification vs trino.io/docs/467:**
- `try_cast(varchar AS DECIMAL(18,2))` — VALID; returns NULL on malformed input (per conversion functions page).
- DECIMAL(18,2) — within max precision 38, VALID.
- `WHERE TRY_CAST(price_string AS DECIMAL(18,2)) IS NOT NULL` correctly filters malformed rows.
- `SUM(DECIMAL(p,s))` return-type widening: **CONFIRMED** — Trino's SUM(decimal(p,s)) returns `decimal(38, s)`, so SUM of DECIMAL(18,2) returns DECIMAL(38,2). The responder's claim "SUM widens to decimal(38,2) so no overflow" is **technically accurate**.
- SUM/AVG skip NULL — CONFIRMED standard SQL behavior, accurately stated.

No defects. The DECIMAL-widening claim is the kind of detail that is often gotten subtly wrong; the responder got it right.

### Q3 — Iceberg expire snapshots + remove orphan files
- Accuracy: **4**
- Completeness: **5**
- Clarity: **5**
- Actionability: **5**

**Verification vs trino.io/docs/467/connector/iceberg.html:**
- `ALTER TABLE iceberg.analytics.customers EXECUTE expire_snapshots(retention_threshold => '7d')` — VALID Trino 467 form (NOT Spark CALL). CONFIRMED.
- `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')` — VALID. CONFIRMED.
- The `retention_threshold` DataSize/duration string `'7d'` — VALID.

**Minor inaccuracy (flagged per directive):** The inline comment `-- (keep last 10)` is WRONG. Trino's `expire_snapshots` is driven by `retention_threshold` (a duration), not a "keep last N" count parameter. The SQL itself is correct, but the parenthetical commentary misrepresents how `expire_snapshots` is parameterized. This could mislead an engineer into thinking they can specify a snapshot count — they cannot via the Trino ALTER TABLE EXECUTE form.

The "branches/tags protect snapshots" claim is reasonable — Iceberg's $refs table carries `min_snapshots_to_keep` and `max_snapshot_age_in_ms` per branch/tag, which the Iceberg core spec uses to determine retention. The Trino docs do not explicitly state the interaction in the expire_snapshots section, but the claim aligns with Iceberg's reference-protection semantics.

Net: -1 on Accuracy for the "(keep last 10)" misleading comment.

### Q4 — Dedup keep most-recent row per customer
- Accuracy: **5**
- Completeness: **5**
- Clarity: **5**
- Actionability: **5**

**Verification vs trino.io/docs/467:**
- `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC) AS rn` in a CTE + outer `WHERE rn = 1` — VALID, canonical Trino dedup pattern.
- `max_by(name, updated_at)` + `MAX(updated_at)` GROUP BY customer_id — VALID alternative. `max_by(x, y)` returns x at the maximum y per Trino 467 aggregate functions docs.
- "no QUALIFY in Trino 467 — wrap in subquery/CTE" — CORRECT; reinforces the iter695 QUALIFY-not-in-Trino lock.

Both forms shown, correctly explained, with the QUALIFY callout that prevents the most common Snowflake-leak failure mode.

---

## Overall Score
Sum: 5+5+5+5 + 5+5+5+5 + 4+5+5+5 + 5+5+5+5 = **79 / 16 = 4.9375**

**VERDICT: PASS** (overall avg 4.94, well above 3.5 threshold)

---

## FIX-A CLOSURE STATEMENT
**time-window-bucketing FIX-A (Q1): CLOSED.**
- Postgres `::`-cast leak (the iter714 Q4 defect): did NOT recur. Responder used `CAST(EXTRACT(minute FROM request_time) AS integer)` throughout.
- date_bin / time_bucket / time_slice / Spark window() / BigQuery TIMESTAMP_TRUNC(INTERVAL): NONE invented.
- Idiom used: the iter606 LEADING canonical (FLOOR-TO-HOUR + ADD-N-STEPS via INTERVAL '1' MINUTE × integer-divided-extracted-minute). Per the iter715 directive, the choice of iter606's FLOOR-TO-HOUR form over the new EPOCH-FLOOR LEAD is not penalized; both are docs-correct.
- Hourly bucket form: `date_trunc('hour', ts)` — clean, idiomatic Trino.
- The iter715 r07:1507 LEADING canonical insertion successfully prevents foreign-idiom regression even though the responder did not pick its EPOCH-FLOOR form — the CO-LOCATED ::-cast defang and DO-NOT-WRITE foreign-idiom matrix appear to have held the responder on-dialect.

---

## Genuine new gap for iter716

**Minor: `expire_snapshots` parameter-semantics confusion** — Q3 produced a stray inline comment `-- (keep last 10)` next to the `expire_snapshots(retention_threshold => '7d')` call. Trino's `expire_snapshots` procedure (and the Iceberg ALTER TABLE EXECUTE form) takes a duration via `retention_threshold`, NOT a snapshot-count keep-N parameter. The responder's SQL was correct, but the commentary suggested a count semantic that does not exist in the Trino form. This is a Spark-API-leak ("keep last N snapshots" is a Spark Iceberg `expireSnapshots().retainLast(N)` Java-API concept) bleeding into the Trino answer commentary.

**Suggested teacher action for iter716:**
- In resources/17 (or wherever the expire_snapshots Trino-EXECUTE canonical lives), add an INLINE DEFANG line right next to the canonical: "Trino's `expire_snapshots` is DURATION-DRIVEN (`retention_threshold => '7d'`), NOT count-driven. There is NO `keep_last_N` / `retain_last` parameter in the Trino ALTER TABLE EXECUTE form — that is a Spark Iceberg Java-API concept (`.retainLast(N)`) and does NOT cross over."
- Add a small DO-NOT-WRITE row: `-- keep last 10 snapshots` ❌ vs `retention_threshold => '7d'` ✅.
- Add keyword anchors near the canonical: "keep last N snapshots Trino", "retainLast Trino", "how many snapshots to keep Trino expire_snapshots", "expire_snapshots count parameter", "Spark retainLast in Trino".
- Re-probe in iter716 with a question phrased as "I want to keep the last 10 snapshots and expire everything older — how?" — the canonical answer should redirect the engineer to the duration form (or to manual snapshot-id rollback if a count-based strategy is genuinely required).

No other gaps surfaced this iteration. Q1/Q2/Q4 were essentially flawless.

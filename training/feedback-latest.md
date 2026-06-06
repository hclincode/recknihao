# Iter521 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall: 4.328 PASS (margin +0.828 above 3.5 floor)

**Iter520 Q3 double-fabrication FIX CONFIRMED LANDED ON FIRST RE-PROBE — BOTH FIXES** — 32nd consecutive leading-canonical bulletproofing landing instance (rare double-land in a single iteration).

**One new content gap surfaced** — Q4 Trino `uuid()` function (NOT in resources/). Responder PUNTED HONESTLY with no fabrication. Recoverable.

**Federation NOT probed this iter** — row stays 4.49944/310 per locked guardrails.

---

## Per-Question Scores

### Q1 — MAP(VARCHAR,VARCHAR) -> JSON STRING for webhook — 4.875 STRONG PASS

| Dim | Score |
|---|---|
| Accuracy | 5.0 |
| Clarity | 4.75 |
| Applicability | 5.0 |
| Completeness | 4.75 |

**ITER520 Q3 FAB #1 FIX CONFIRMED LANDED.** Responder emits clean canonical:
- `json_format(CAST(attributes AS JSON))` for VARCHAR JSON string output
- Explicit contrast that `CAST(map AS VARCHAR)` returns debug `{plan=pro, seats=50}` form (NOT JSON) — THE TRAP rule landed
- Warning against hand-rolling JSON via concat (escaping risk)
- Cites r09 CAST-to-JSON LEADING CANONICAL

**Verification quote (trino.io/docs/current/functions/json.html):**
> "MAP types can be cast when the key type of the map is VARCHAR and the value type of the map is a supported type."
>
> `SELECT CAST(MAP(ARRAY['k1','k2','k3'], ARRAY[1, 23, 456]) AS JSON); -- JSON '{"k1":1,"k2":23,"k3":456}'`
>
> `json_format(json) -> varchar` — "Serializes the input JSON value to JSON text conforming to RFC 7159."

Iter521 teacher's r09 LEADING CANONICAL inserted at ~line 595 between `Mnemonic:` and `### Working PySpark migration` heading CONFIRMED LANDED on first re-probe. Iter520 Q3 fabricated-absence "Trino has no direct MAP-to-JSON cast" GONE.

-0.25 Completeness: no explicit mention of `CAST(CAST(map AS JSON) AS VARCHAR)` alternative form (json_format covered, equivalent path not surfaced — non-load-bearing).

---

### Q2 — string aggregation Trino vs Postgres `string_agg` — 4.875 STRONG PASS

| Dim | Score |
|---|---|
| Accuracy | 5.0 |
| Clarity | 4.75 |
| Applicability | 5.0 |
| Completeness | 4.75 |

**ITER520 Q3 FAB #2 FIX CONFIRMED LANDED.** Responder emits clean rule:
- "Trino has NO `string_agg` (that's PostgreSQL)"
- Aggregate-only canonical `listagg(plan_tier, ',') WITHIN GROUP (ORDER BY plan_tier)`
- Window-form fallback `array_join(array_agg(plan_tier ORDER BY ...), ',')`
- Correctly flags listagg as aggregate-only (cannot be OVER window)
- Cites r27 §7A.2B + r09 string-aggregation note

**Verification quotes:**
- trino.io/docs/current/functions/aggregate.html — `string_agg` and `group_concat` ABSENT from aggregate function list. `LISTAGG(expression [, separator] [ON OVERFLOW overflow_behaviour]) WITHIN GROUP (ORDER BY sort_item, [...])` PRESENT verbatim. `array_agg(x) -> array<[same as input]>` PRESENT.
- trino.io/docs/current/functions/array.html — `array_join(x, delimiter) -> varchar` PRESENT ("Concatenates the elements of the given array using the delimiter and an optional string to replace nulls.").

Iter521 teacher's r27 §7A.2B inserted between §7A.2A and §7A.3 CONFIRMED LANDED on first re-probe. Iter520 Q3 fabricated `string_agg` PostgreSQL function name GONE.

**32nd consecutive leading-canonical bulletproofing landing instance** (Q1+Q2 both same iter — double-fix double-land, rare).

-0.25 Completeness: no `ON OVERFLOW` clause callout (listagg defaults to ERROR on overflow; engineers may want TRUNCATE — non-load-bearing).

---

### Q3 — dbt incremental insert_overwrite vs merge for Iceberg partitioned — 4.5 PASS

| Dim | Score |
|---|---|
| Accuracy | 5.0 |
| Clarity | 4.5 |
| Applicability | 4.5 |
| Completeness | 4.0 |

**Responder is CORRECT.** `insert_overwrite` is NOT a dbt-trino incremental strategy. That's Spark/Databricks/BigQuery terminology — dbt-trino supports `append`, `merge`, `delete+insert` ONLY.

**Verification quote (docs.getdbt.com/reference/resource-configs/trino-configs):**
> Supported incremental strategies: **append** (default), **delete+insert**, **merge**.
>
> "With the `merge` incremental strategy, dbt-trino constructs a Trino MERGE statement to insert new records and update existing records, based on the unique_key property."
>
> "With the `delete+insert` incremental strategy, you can instruct dbt to use a two-step incremental approach."

`insert_overwrite` is NOT listed. The only related construct is a Hive-connector-side simulation via `insert-existing-partitions-behavior` setting (connector config, NOT a dbt-trino strategy keyword). The responder correctly directs the engineer to `delete+insert` as the partition-replace pattern.

Merge-vs-delete+insert tradeoff guidance is sound:
- merge: overlapping/unique_key + idempotent dedup (constructs Trino MERGE)
- delete+insert: when unique_key isn't truly unique OR merge unsupported by connector OR partition-atomic replay needed

Responder's example `incremental_strategy='delete+insert', unique_key='event_date'` is valid.

-0.5 Clarity: doesn't pre-empt the Spark/Databricks user expectation that insert_overwrite exists (would help engineers porting from those stacks).
-0.5 Applicability / -1.0 Completeness: no explicit Hive-connector `insert-existing-partitions-behavior` simulation callout (non-load-bearing but engineers cross-searching from Spark may look for it).

---

### Q4 — Trino equivalent of `gen_random_uuid()`, safe as Iceberg PK? — 3.125 PASS (CONTENT GAP, HONEST PUNT, NO FABRICATION)

| Dim | Score |
|---|---|
| Accuracy | 4.0 |
| Clarity | 3.5 |
| Applicability | 2.5 |
| Completeness | 2.5 |

**Honest punt — no fabrication.** Responder said "I don't have enough information... resources do not document a Trino equivalent to gen_random_uuid() or Iceberg PK safety" and pointed to Trino function docs. DID NOT invent a function name (correct failure-mode under uncertainty — far better than fabricating `random_uuid()` or `gen_uuid()`).

**However, content gap is real.** Trino HAS a `uuid()` function:

**Verification quote (trino.io/docs/current/functions/uuid.html):**
> `uuid()` — "Returns a pseudo randomly generated UUID (type 4)."

Available since **Trino Release 312 (May 2019)**. Cast to VARCHAR via `CAST(uuid() AS VARCHAR)`.

**CRITICAL NUANCE for iter522 canonical:**
- `uuid()` is **RANDOM / NON-deterministic** — re-running a dbt model regenerates DIFFERENT UUIDs for the same logical row. NOT idempotent. NOT a good incremental-model surrogate key.
- For a **STABLE** dbt key use `dbt_utils.generate_surrogate_key([col_a, col_b, ...])` — deterministic MD5 hash, idempotent across runs, safe as a primary/unique key (see r27 §4.5A).
- `uuid()` is only appropriate for a genuinely-new-each-insert random ID (e.g., event tracking row that should get a new ID on every run).
- Iceberg has **NO enforced PRIMARY KEY** constraint (informational only per iter402 PK-not-enforced rule).

**Honest-punt Accuracy 4.0** (not 1-2 for fab) — responder did not make a false claim. Completeness/Applicability legitimately low because engineer cannot act without the function name. Same failure-mode as iter500/iter516 (gap-without-fab) — fully recoverable with one resource addition.

---

## Confirmation summary

| Item | Status |
|---|---|
| Iter520 Q3 fab #1 (`CAST(map AS JSON)` absence fab) | **FIXED** — r09 LEADING CANONICAL landed on first re-probe (Q1) |
| Iter520 Q3 fab #2 (`string_agg` fab) | **FIXED** — r27 §7A.2B canonical landed on first re-probe (Q2) |
| Q3 dbt-trino strategies (verification) | **Responder claim CORRECT** — dbt-trino has NO `insert_overwrite`; only `append`/`merge`/`delete+insert` per docs.getdbt.com verbatim |
| Q4 `uuid()` content gap | **NEW** — honest punt, no fab. Recoverable. |
| New fabrications | **NONE** |
| Federation row | **UNCHANGED** — 4.49944/310 stays per locked guardrails |

---

## Next-Teacher Actions (iter522)

### PRIMARY FIX — Trino `uuid()` canonical NEW LEADING CANONICAL

**Home:** r27 §4.5A (adjacent to existing `dbt_utils.generate_surrogate_key` content — cross-ref-net principle) OR r07 string/identity-functions block.

**Contents:**
- ONE-LINE RULE: "Trino has `uuid() -> uuid` returning a random RFC-4122 v4 UUID. Cast to VARCHAR via `CAST(uuid() AS VARCHAR)` for a string column."
- Signature row: `uuid() -> uuid` since Trino 312.
- **CRITICAL random-vs-deterministic dichotomy table:**
  | Need | Function | Idempotent? | Use case |
  |---|---|---|---|
  | Random per-insert ID | `uuid()` | NO | Event tracking, session ID |
  | Stable hash-based surrogate key | `dbt_utils.generate_surrogate_key([col_a, col_b, ...])` | YES (deterministic MD5) | dbt incremental upsert key |
- When-to-use-which guidance.
- Iceberg PK framing: no enforced PRIMARY KEY (iter402 informational-only rule); uniqueness via upstream or dbt test `unique`.
- DO-NOT-WRITE bans:
  - "Trino has no UUID function"
  - "use `random()` to build UUID"
  - "`uuid()` is deterministic"
  - "`uuid()` is safe as dbt incremental surrogate key"
  - "Iceberg enforces PRIMARY KEY"
- Verified source: trino.io/docs/current/functions/uuid.html.
- Cross-ref: r27 §4.5A (generate_surrogate_key) + iter402 PK-not-enforced rule.
- Keyword anchors: "Trino uuid function / gen_random_uuid Trino equivalent / Trino random UUID / dbt surrogate key Trino / Iceberg primary key / uuid() RFC 4122 / Trino UUID type / dbt unique_key generation / random vs deterministic key dbt".

### Iter522 Judge Probe Targets

**HIGH priority:**
1. **uuid() RE-PROBE** — "Trino equivalent of Postgres `gen_random_uuid()`? safe as dbt incremental surrogate key?" verifies FIX A `uuid()` canonical lands + random-vs-deterministic dichotomy + `generate_surrogate_key` cross-ref.
2. **dbt surrogate key 2nd angle** — "stable hash-based ID across dbt re-runs — what's idiomatic?" verifies FIX A surfaces `dbt_utils.generate_surrogate_key([...])` for deterministic-key need.

**MEDIUM priority:**
3. **MAP->JSON 2nd angle** — "ROW(name, email) as JSON object for API — same `CAST(... AS JSON)`?" verifies r09 canonical extends to ROW.
4. **ARRAY->JSON 2nd angle** — "Trino array of strings to JSON array string?" verifies r09 canonical extends to ARRAY.
5. **string_agg DESC-ORDER 2nd angle** — "listagg with DESC ordering — syntax?" verifies §7A.2B handles `WITHIN GROUP (ORDER BY x DESC)`.
6. **group_concat 2nd angle** — "MySQL `group_concat(x)` — Trino equivalent?" verifies §7A.2B bans group_concat too.
7. **dbt-trino incremental partition-replace 2nd angle** — "delete+insert on event_date — does it scan-and-delete or partition-drop?" verifies delete+insert pattern detail.

**LOW priority:**
8. **Iceberg PK-not-enforced 3rd angle** — "can I declare PRIMARY KEY on Iceberg in Trino DDL?" verifies iter402 informational-only rule.
9. **Federation stays UNPROBED** — row stays 4.49944/310 per locked guardrails.

---

## Topic Avg Updates

- **Lakehouse schema design** (Q1 r09 home): 4.5586/14 -> **4.5797/15** (+0.0211)
- **SQL query best practices for OLAP** (Q2 string aggregation, reversing iter520 drag): 4.5045/76 -> **4.5093/77** (+0.0048)
- **Oracle PL/SQL -> dbt + Trino SQL migration** (Q3 dbt-trino incremental + Q4 dbt uuid): 4.5178/90 -> **4.5025/92** (-0.0153 — Q4 honest-punt drags)
- **Trino federation**: **UNCHANGED 4.49944/310**

---

## Status

- 119th consecutive overall PASS in extended phase.
- Margin +0.828 above floor (recovered from iter520's tight +0.625).
- 32nd consecutive leading-canonical bulletproofing landing instance (rare double-land Q1+Q2).
- state.json: leave at iteration 521, passed: true (teacher set; do NOT bump per directive).
- Federation guardrails (r22 §13.x) and federation rubric row UNTOUCHED.

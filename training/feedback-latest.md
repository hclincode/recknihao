# Iter1185 Judge Feedback

**Overall verdict: PASS** (avg **4.28 / 5**, above 3.5 threshold).

- **Q1 watch CLOSES** — `r17 object_store_layout_enabled semantics-card FIX-A iter1184` reached cleanly; pin-perfect re-probe under different framing.
- **Q2 soft watch CLOSES** — iter1184 `EXTRACT(EPOCH FROM ts-ts)` fabrication did NOT recur; LAG + date_diff canonical surfaced as the lead.
- **Q4 = DUAL responder slip** (mis-recommendation + broken CONCAT). Resources at r27 §7A.3 + §7A.3.1 are pin-perfect on this exact ask with the exact fiscal_quarter_label worked example and the exact CONCAT-bigint defang. **NO resource fix**; classify per `feedback_responder_broken_secondary_alternative.md` family but more serious because the bug is in the recommended LEAD, not a "for completeness" alternative.

Total iter1185 score: (5.0 + 4.5 + 5.0 + 2.625) / 4 = **4.28 / 5**.

| Q | Topic | Score | Note |
|---|---|---|---|
| 1 | Iceberg partition design — `object_store_layout_enabled` write-side hash-prefix | 5.0 | Watch CLOSES. Write-side only, deterministic hash, MinIO per-prefix request-rate throttling solved, reads unaffected (manifest absolute paths), high-write tables only, CREATE/ALTER forms, future-writes-only. All verified at [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html). |
| 2 | Analytical query patterns — LAG-window for events close in time | 4.5 | Soft watch CLOSES. LAG(event_time) OVER (PARTITION BY user_id ORDER BY event_time) + date_diff('second', prev, curr) < 10, single-pass no-self-join. "Trino doesn't subtract timestamps — use date_diff" correct (no EXTRACT(EPOCH) recurrence). Minor style nit: LAG(...) OVER (...) expression repeated 3x instead of CTE (verbose but valid). |
| 3 | SQL best practices — split_to_map for URL-query parsing | 5.0 | Pin-perfect. `split_to_map(properties, '&', '=') → map(varchar,varchar)` + `element_at(map,'country')` lookups + `split_to_multimap` for repeated keys. All verified at [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html). |
| 4 | Oracle PL/SQL → dbt migration — fiscal_quarter reusable utility | 2.625 | **DUAL SLIP**: (a) mis-recommendation — Pattern A (intermediate model + join) recommended as canonical when the engineer's "shared utility function" ask directly maps to a Jinja macro per r27 §7A.3 verbatim; (b) BROKEN CONCAT in BOTH Pattern A's model AND Pattern B's macro — `CONCAT('FY', YEAR(date_col)+1, '-Q', ((MONTH(date_col)-2)/3)+1)` raises *"Unexpected parameters (varchar(N), bigint) for function concat"* per [trino.io/docs/current/functions/conversion.html](https://trino.io/docs/current/functions/conversion.html). r27 §7A.3.1 explicitly defangs this exact shape with this exact worked example (fiscal_quarter_label) — responder ignored the defang. **Responder slip, NOT resource gap.** |

---

## Per-question detail

### Q1 — `object_store_layout_enabled` semantics (WATCH RE-PROBE)

**Score 5.0** — **WATCH CLOSES**. The iter1184 LIGHT FIX-A to r17 (object_store_layout_enabled semantics card) reaches under a different question framing.

Responder's load-bearing facts:
- **Write-side property** that inserts a deterministic hash component into each data file's path → spreads files across many object-store prefixes
- **MinIO per-prefix request-rate throttling** is the bottleneck removed
- **Reads UNAFFECTED** because Iceberg manifests carry absolute file paths; planner never lists prefixes
- **Enable only on high-write-throughput tables** — NOT a blanket setting
- `CREATE TABLE WITH (object_store_layout_enabled = true)` for new tables
- `ALTER TABLE ... SET PROPERTIES object_store_layout_enabled = true` for existing tables (future writes only — pre-existing files keep their old paths)

Verifications (trino.io):
- Verified at [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html): *"Set to `true` to enable Iceberg's object store file layout. Enabling the object store file layout appends a deterministic hash directly after the data write path."* Default `false`.
- Catalog-default knob is `iceberg.object-store-layout-enabled`; the per-table property `object_store_layout_enabled` overrides at table grain.
- Write-side only / reads-unaffected confirmed by Iceberg manifest design (absolute file paths in metadata; planner does NOT do prefix listing on S3-compat stores).
- MinIO does implement per-prefix S3 request-rate limiting at scale — the colleague's bottleneck is real for high-throughput on-prem ingest.

Routes cleanly to r17 (the iter1184 FIX-A landed in r17 with the semantics card). **Watch CLOSES.** No further FIX-A on this property; re-probe was successful first try with structurally different framing.

No resource fix.

---

### Q2 — LAG-window for events close in time per user (SOFT WATCH RE-PROBE)

**Score 4.5** — **SOFT WATCH CLOSES**. Iter1184's `EXTRACT(EPOCH FROM ts-ts)` Postgres-muscle-memory fabrication did NOT recur. LAG canonical surfaced as the lead.

Responder's load-bearing facts:
- "**In Trino you don't subtract timestamps directly. Use `date_diff('second', earlier_ts, later_ts)`**" — explicit and correct dialect guidance
- `LAG(event_time) OVER (PARTITION BY user_id ORDER BY event_time)` — the iter671 PIN canonical from r07 §3185 reaches under bot-detection framing
- `date_diff('second', LAG(event_time) OVER (...), event_time) < 10` for the threshold predicate
- CASE flag: `WHEN date_diff(...) < 10 THEN 'potential_bot' ELSE 'normal'`
- Single sort O(N log N), no self-join — correctly addresses the engineer's stated 500M-row self-join blow-up

Verifications (trino.io):
- `date_diff(unit, ts1, ts2) → bigint` verified at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html): *"Returns timestamp2 - timestamp1 expressed in terms of unit."*
- `EXTRACT(EPOCH FROM ts)` is NOT a valid Trino EXTRACT field (Postgres-only) per the same page — responder correctly avoided it this time
- `ts - ts → interval` operator NOT supported in Trino 467 (responder correctly states this)

**Style nit (does NOT change the close-decision)**: the responder repeated the full `LAG(event_time) OVER (PARTITION BY user_id ORDER BY event_time)` expression 3x across the SELECT (the prev column, the date_diff arg, the CASE predicate) instead of moving it into a CTE / subquery. Valid Trino SQL — the optimizer will recognize and consolidate the identical window expression — but verbose for human readability. Per `feedback_responder_broken_secondary_alternative.md`-family policy this is a one-off verbosity nit, no resource fix.

**Soft watch CLOSES.** The iter1184 fabrication was a one-off; the canonical LAG+date_diff pattern reached under the structurally-similar bot-detection re-probe framing. No additional defang or cross-ref needed.

Scoring breakdown:
- Tech: 4.5/5 — load-bearing SQL valid; dialect guidance correct
- Clar: 4.5/5 — explanation prose readable; verbose LAG repetition slightly hurts
- Practical: 4.5/5 — engineer can copy-paste and run
- Complete: 4.5/5 — addresses both the SQL pattern and the timestamp-subtraction sub-question

---

### Q3 — split_to_map for URL-query parsing

**Score 5.0** — pin-perfect.

Responder's load-bearing facts:
- `split_to_map(properties, '&', '=') → map(varchar, varchar)` is the direct Trino function for parsing delimited key=value strings
- `element_at(map, 'country')` for key lookup (returns NULL on missing key, doesn't throw)
- `split_to_multimap(...)` for the duplicate-key case (returns `map<varchar, array<varchar>>`)
- Mentions GROUP BY on `element_at(parsed_map, 'country')` for the aggregation use case

Verifications (trino.io):
- `split_to_map(string, entryDelimiter, keyValueDelimiter) → map<varchar, varchar>` verified at [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html): *"Splits string by entryDelimiter and keyValueDelimiter and returns a map."*
- `split_to_multimap(string, entryDelimiter, keyValueDelimiter)` verified same page: *"Splits string by entryDelimiter and keyValueDelimiter and returns a map containing an array of values for each unique key. The values for each key will be in the same order as they appeared in string."*
- `element_at(map, key)` verified at trino.io map functions page
- Note: `split_to_map` errors on duplicate keys at runtime — responder correctly directs to `split_to_multimap` for the duplicate-key case

Cites r23. No resource fix.

---

### Q4 — Oracle PL/SQL fiscal_quarter function → dbt reusable utility

**Score 2.625** — **DUAL RESPONDER SLIP** (mis-recommendation + broken CONCAT in BOTH patterns).

#### Slip (a) — RECOMMENDATION INVERTED

Engineer's framing: *"Oracle PL/SQL function converts timestamps to a fiscal quarter; 15 reports call it. Rebuilding as dbt models without pasting the SQL everywhere. dbt mechanism for reusable SQL logic like a **shared utility function**?"*

The direct dbt analog of an Oracle stored **function** (per-row scalar conversion applied to whatever timestamp column each report has) is a **Jinja macro** — `{{ fiscal_quarter('date_col') }}` inlines the expression at each call site, works on any column, no join, no extra model. r27 §7A.3 is titled verbatim **"Oracle PL/SQL packages and stored functions → dbt macros + Jinja"** and leads with this exact pattern.

The responder recommended **Pattern A (intermediate dbt model + JOIN on date key)** as canonical. Pattern A is the analog of a shared computed-once **dimension/table**, not a function. It requires:
- Choosing a granularity for the int_fiscal_quarter model (daily? monthly?)
- Every report to JOIN on the date key
- A materialization decision (table vs view)
- A run-order dependency between int_fiscal_quarter and downstream reports

Pattern A is a valid alternative and reasonable when fiscal_quarter is one of many calendar attributes (then it's a dim_calendar columnetc), but the engineer's ask is the function shape, not the dimension shape. Pattern B (macro) is the direct, lightweight, function-like analog.

dbt's own docs at [docs.getdbt.com/docs/build/jinja-macros](https://docs.getdbt.com/docs/build/jinja-macros) describe macros as *"reusable piece of Jinja code that functions analogously to a function in programming languages"* and gives `cents_to_dollars` as the canonical example — same shape as fiscal_quarter.

**Verdict**: recommending Pattern A as canonical is a mis-recommendation for the "shared utility function" ask. Pattern B (macro) should have been led with.

#### Slip (b) — BROKEN CONCAT in BOTH PATTERNS

The fiscal_quarter SQL the responder wrote (identical in both Pattern A's model and Pattern B's macro):

```sql
CASE
  WHEN MONTH(date_col) >= 2 THEN CONCAT('FY', YEAR(date_col)+1, '-Q', ((MONTH(date_col)-2)/3)+1)
  ELSE                          CONCAT('FY', YEAR(date_col),   '-Q', ((MONTH(date_col)+10)/3)+1)
END
```

**Both CONCAT calls are TYPE ERRORS in Trino 467.** Verified:
- `concat(string1, ..., stringN) → varchar` — all arguments must be character types (verified at [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html))
- Trino does NOT implicitly cast numerics to varchar — verbatim from [trino.io/docs/current/functions/conversion.html](https://trino.io/docs/current/functions/conversion.html): *"Trino will not convert between character and numeric types. For example, a query that expects a varchar will not automatically convert a bigint value to an equivalent varchar."*
- `YEAR(date_col)+1` evaluates to BIGINT (YEAR returns BIGINT, BIGINT+INT widens to BIGINT)
- `((MONTH(date_col)-2)/3)+1` evaluates to BIGINT
- `CONCAT('FY', <BIGINT>, '-Q', <BIGINT>)` raises **"Unexpected parameters (varchar(N), bigint, varchar(N), bigint) for function concat. Expected: concat(varchar, varchar) ..."**

**Correct forms (either works)**:
```sql
-- Form A: CAST each numeric to VARCHAR
CONCAT('FY', CAST(YEAR(date_col)+1 AS VARCHAR), '-Q', CAST(((MONTH(date_col)-2)/3)+1 AS VARCHAR))

-- Form B: format() with %d (cleaner; handles BIGINT directly)
format('FY%d-Q%d', YEAR(date_col)+1, ((MONTH(date_col)-2)/3)+1)
```

#### Source classification — RESPONDER SLIP, NOT resource gap

r27 §7A.3.1 (lines ~4458–4520) is titled verbatim **"Trino dialect landmine in macro examples — CONCAT and `||` require all-VARCHAR args (NO implicit numeric/date coercion)"** and uses **fiscal_quarter_label** as the **WORKED EXAMPLE** of this exact bug:

```
WRONG (Oracle-style, errors at runtime in strict Trino with
"Unexpected parameters (varchar(N), bigint) for function concat"):

{% macro fiscal_quarter_label(date_col) %}
    CASE
        WHEN EXTRACT(MONTH FROM {{ date_col }}) IN (1,2,3) THEN CONCAT('FQ1-', EXTRACT(YEAR FROM {{ date_col }}))
        ...
    END
{% endmacro %}
```

…followed by the explicit CAST and format() corrections. This is the most precisely-targeted defang in the entire resource set for this exact ask. The responder either:
1. Did NOT reach r27 §7A.3.1, OR
2. Reached it and ignored the defang.

Either way, this is a **responder slip, NOT a resource content gap**. **No resource fix.** The fiscal_quarter_label name in §7A.3.1 even matches the question's "fiscal_quarter" framing — keyword anchors are correct.

Per `feedback_responder_broken_secondary_alternative.md` family — but more serious than the usual "broken for-completeness alternative" because here the bug is in BOTH the recommended canonical (Pattern A) AND the secondary (Pattern B); the engineer has nowhere to fall back on a working form. Worth a one-off note in next iteration's preamble; do NOT churn the resources (the existing §7A.3 + §7A.3.1 worked example IS the correct content).

#### Scoring breakdown
- Tech: 2.0/5 — broken CONCAT in BOTH patterns (parse-time type error); mis-recommendation inverts the function-vs-dimension shape
- Clar: 3.5/5 — two-pattern presentation is readable; explanation prose clear
- Practical: 2.0/5 — engineer copy-pastes either pattern, gets type error on first run; mis-recommendation steers them away from the lightweight function analog
- Complete: 3.0/5 — both patterns mentioned; recommendation reversed; SQL broken

---

## Rubric updates

| Topic | Before | After | Question |
|---|---|---|---|
| Iceberg partition design for SaaS | 4.4358 / 52 | (230.6616+5.0)/53 = **4.4465 / 53** | Q1 |
| Analytical query patterns on Iceberg+Trino | 4.5153 / 135 | (609.5655+4.5)/136 = **4.5152 / 136** | Q2 |
| SQL query best practices for OLAP | 4.5754 / 263 | (1203.3302+5.0)/264 = **4.5770 / 264** | Q3 |
| Oracle PL/SQL → dbt+Trino migration | 4.4680 / 146 | (652.328+2.625)/147 = **4.4555 / 147** | Q4 |

All required topics remain PASSED. Q4 drags Oracle migration topic slightly (4.4680 → 4.4555, still +0.9555 over threshold).

---

## Patterns / themes this iter

1. **Q1 watch CLOSES — r17 object_store_layout_enabled FIX-A successful.** The iter1184 LIGHT FIX-A added the semantics card to r17 explaining write-side hash-prefix file-spreading, MinIO per-prefix throttling, reads-unaffected, high-write tables only. Today's re-probe (different question framing: "MinIO rate-limiting errors during heavy writes; table property that spreads files across storage") reaches the card cleanly first try. Pin-perfect answer.

2. **Q2 soft watch CLOSES — `EXTRACT(EPOCH FROM ts-ts)` fabrication did NOT recur.** Iter1184 Q2 had the responder fabricating Postgres-style timestamp arithmetic despite five separate defangs in resources. Today's Q2 (structurally similar: bot-detection, events <10s apart, "Postgres lets you subtract timestamps — correct way?") gets the correct dialect answer: "Trino doesn't subtract timestamps — use date_diff." LAG canonical surfaced as the lead. Confirms the iter1184 fabrication was a one-off, NOT a recurring resource defect. No FIX-A needed.

3. **Q4 dual-slip pattern — `feedback_responder_broken_secondary_alternative.md` adjacent but more serious.** The responder inverted the recommendation (Pattern A intermediate model over Pattern B macro, when the macro IS the function analog the engineer asked for) AND reproduced the explicitly-defanged CONCAT-bigint type error in BOTH patterns. Resources at r27 §7A.3 + §7A.3.1 are pin-perfect on this exact ask with the exact fiscal_quarter_label worked example. This is a findability/processing failure on the responder side, NOT a resource gap. Do NOT churn resources. Per-instance one-off; re-probe with a structurally similar "Oracle PL/SQL fiscal-period function → dbt" framing next sweep to see if §7A.3.1 routes.

4. **Q3 split_to_map clean.** URL-query string parsing routes to r23 cleanly. Pin-perfect first try.

5. **Cushion check.** Thinnest current topics remain Query performance basics (4.1869) and dbt snapshots SCD2 (4.1549); next breadth sweep should probe those. Oracle migration cushion still very healthy (+0.9555 over threshold) despite today's Q4 drag.

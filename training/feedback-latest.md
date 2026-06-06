# Iter 520 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall verdict: **4.125 PASS** (margin +0.625 above 3.5 floor)

- **118th consecutive overall PASS** in extended phase.
- **iter519 dbt-GRANTS gap CONFIRMED FILLED** on first re-probe at Q1 — r27 §6.7I LEADING CANONICAL landed cleanly (31st consecutive leading-canonical bulletproofing landing instance).
- **TWO NEW FABRICATIONS surfaced at Q3 (MAP -> JSON)** — fabricated-absence of `CAST(map AS JSON)` + fabricated `string_agg` function name (PostgreSQL function, not Trino). Q3 FAILED hard (1.875). Q1+Q2+Q4 absorbed.
- Federation NOT probed — row stays 4.49944 / 310 UNCHANGED per directive.

---

## Per-question scores

### Q1 — dbt auto-GRANT SELECT to a role on build — native config? works on Trino roles? gotchas?

**Score: 4.9375 STRONG PASS** (Accuracy 5.0, Clarity 4.75, Applicability 5.0, Completeness 5.0)

**ITER519 Q3 dbt-GRANTS CONTENT GAP FILLED** — responder emitted all four load-bearing pieces:
1. Native `grants:` config in both forms — in-model `{{ config(grants={'select': ['analyst_role']}) }}` and schema YAML `config: grants: select: [...]`.
2. Idempotency framing — `grants:` is re-applied on every build to fix drift (matches docs.getdbt.com verbatim "dbt ensures that the grants on its view or table match exactly the grants you have configured").
3. **#12862 LOAD-BEARING CAVEAT** — dbt-trino adapter emits `GRANT ... TO <name>` (bare name resolves to USER under Trino's principal resolution), NOT `TO ROLE <name>` that role-based authorization requires.
4. **Workaround** — `post_hook="GRANT SELECT ON {{ this }} TO ROLE analyst_role"` with explicit `ROLE` keyword; notes post_hook is NOT idempotent.

OPA caveat correctly surfaces — engine GRANT and OPA enforcement are separate authz layers.

**WebSearch verification:**
- [docs.getdbt.com/reference/resource-configs/grants](https://docs.getdbt.com/reference/resource-configs/grants) — "When your model, seed, or snapshot finishes building, dbt ensures that the grants on its view or table match exactly the grants you have configured." Default REPLACE-on-merge and `+select` MERGE-prefix CONFIRMED.
- [dbt-labs/dbt-core#12862](https://github.com/dbt-labs/dbt-core/issues/12862) — Title "[Bug] Trino/Starburst Cannot use grants with roles." Core problem: dbt generates `GRANT ... TO ""` (bare name) without distinguishing USER vs ROLE. Status: open. CONFIRMED.

**r27 §6.7I CANONICAL CONFIRMED LANDED on first re-probe** — iter519 Q3 punt "uses post_hook but missed dbt's native idempotent `grants:`" GONE. 31st consecutive leading-canonical bulletproofing landing.

Minor -0.25 Clarity for not explicitly explaining `+select` MERGE vs default REPLACE rule.

---

### Q2 — Iceberg metadata tables for auditing files/versions — $manifests, $refs (branches/tags), etc — what are they, when to use

**Score: 4.8125 STRONG PASS** (Accuracy 5.0, Clarity 4.75, Applicability 4.75, Completeness 4.75)

Clean tabular emission of all six metadata tables — `$files`, `$partitions`, `$snapshots`, `$history`, `$manifests`, `$refs` — with columns and when-to-use. Whole-token quoting rule correct (`"events$files"` NOT `events."$files"`). Worked `$refs JOIN $snapshots` example for branch-snapshot lineage audit.

**WebSearch verification ([trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html)):**
- All six metadata-table names CONFIRMED.
- `$refs` columns CONFIRMED: `name` (VARCHAR), `type` (VARCHAR — `BRANCH` or `TAG`), `snapshot_id` (BIGINT), `max_reference_age_in_ms`, `min_snapshots_to_keep`, `max_snapshot_age_in_ms` (branch-only).
- Whole-token quoting rule CONFIRMED verbatim: "The dollar sign (`$`) is a literal character in the metadata table name, not a separate prefix. The entire token... requires quotation." Responder's `"events$files"` form is correct.

Minor -0.25 Completeness for no callout that `rewrite_manifests` is a Spark CALL procedure (Trino does not expose a `system.rewrite_manifests` procedure — only Spark via `CALL iceberg.system.rewrite_manifests(...)`). Non-load-bearing for this question scope.

---

### Q3 — Convert a MAP column to a JSON STRING in Trino (third-party API needs JSON); `CAST(map AS VARCHAR)` gives a non-JSON debug string

**Score: 1.875 FAIL** (Accuracy 1.5, Clarity 2.5, Applicability 1.5, Completeness 2.0)

**TWO LOAD-BEARING FABRICATIONS — both confirmed against official docs:**

#### Fabrication 1 — "Trino does NOT have a direct MAP-to-JSON cast function"

This is **WRONG**. Trino has supported `CAST(map AS JSON)` since well before 467.

**[trino.io/docs/current/functions/json.html](https://trino.io/docs/current/functions/json.html) verbatim:**
> "`ARRAY`, `MAP`, and `ROW` types can be cast to JSON when the following requirements are met: `ARRAY` types can be cast when the element type of the array is one of the supported types. `MAP` types can be cast when the key type of the map is `VARCHAR` and the value type of the map is a supported type. `ROW` types can be cast when every field type of the row is a supported type."

**Worked example from Trino docs:**
> "`SELECT CAST(MAP(ARRAY['k1', 'k2', 'k3'], ARRAY[1, 23, 456]) AS JSON); -- JSON '{\"k1\":1,\"k2\":23,\"k3\":456}'`"

The clean canonical for the engineer's third-party-API-needs-JSON case is:
```sql
-- Returns JSON value (proper RFC-7159 JSON, types preserved)
CAST(my_map_col AS JSON)

-- Returns VARCHAR JSON text (what the third-party API actually needs)
CAST(CAST(my_map_col AS JSON) AS VARCHAR)
-- equivalent:
json_format(CAST(my_map_col AS JSON))
```

`json_format` CONFIRMED at [trino.io/docs/current/functions/json.html](https://trino.io/docs/current/functions/json.html) verbatim: "`json_format()` serializes the input JSON value to JSON text conforming to RFC 7159."

This is the entire question. Responder missed the one-line answer and over-engineered a manual workaround.

#### Fabrication 2 — `string_agg(...)` is NOT a Trino function

Responder's workaround uses `string_agg('"'||key||'":"'||value||'"', ',' ORDER BY key)`. **`string_agg` does NOT exist in Trino** — it's a PostgreSQL function name.

**[trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html) CONFIRMED** — `string_agg` is NOT listed. Trino's string-aggregation primitives are:
- `listagg(x, separator) WITHIN GROUP (ORDER BY ...)` — verified verbatim: "LISTAGG( expression [, separator] [ON OVERFLOW overflow_behaviour]) WITHIN GROUP (ORDER BY sort_item, [...]) [FILTER (WHERE condition)]"
- `array_join(array_agg(x), ',')` — `array_agg(x) → array<...>` + `array_join(array, delimiter, null_replacement)`

Engineer copy-pasting the responder's `string_agg(...)` SQL into Trino 467 gets a parse-time error `Function 'string_agg' not registered`. The fabricated workaround does not run.

#### Additional issues with the workaround (even if string_agg worked)

- Values always quoted as strings — produces `{"k":"1"}` for INT/BIGINT values, NOT the type-preserving `{"k":1}` you get from `CAST(map AS JSON)`. Third-party API may type-check and reject.
- No JSON escaping — embedded `"` or `\` in keys/values produces invalid JSON.
- ROW/struct same-pattern claim is also wrong — `CAST(row AS JSON)` works directly for ROW types.

**Verdict:** Q3 fails on both Accuracy (two simultaneous fabrications) and Applicability (manual workaround doesn't even parse). 1.875 is consistent with FAIL-class scoring from iter505 fabricated-absence of `split_to_map` and iter517 fabricated `spark.sql.iceberg.write.*` config.

---

### Q4 — Oracle TO_NUMBER(col) -> Trino; a safe version that doesn't error on bad data

**Score: 4.875 STRONG PASS** (Accuracy 5.0, Clarity 5.0, Applicability 5.0, Completeness 4.5)

Clean canonical:
- Trino has no `TO_NUMBER` — verified at [trino.io/docs/current/functions/conversion.html](https://trino.io/docs/current/functions/conversion.html), only `cast()`, `try_cast()`, `format()`, `format_number()`.
- `CAST(col AS BIGINT)` — strict, fails on bad data.
- `TRY_CAST(col AS BIGINT)` — safe, returns NULL on bad data. Verified verbatim: "`try_cast(value AS type) → type` — Like `cast()`, but returns null if the cast fails."
- DECIMAL recommendation for money/precision values (not DOUBLE) is sound production guidance.

Minor -0.5 Completeness for no Oracle-specific NLS_NUMERIC_CHARACTERS / format-mask framing (`TO_NUMBER('1,234.56', '999G999D99')` — if source has formatted-currency strings, both `CAST` and `TRY_CAST` NULL/fail without `regexp_replace` pre-cleaning). Non-load-bearing for the safe-version core ask.

---

## Topic-avg updates

**Q1 dbt-GRANTS** -> maps to **Oracle PL/SQL → dbt + Trino SQL migration** topic (per r27 dbt-CLI/dbt-config cluster precedent — §6.7I sits next to §6.7F/§6.7G/§6.7H).

**Q4 TO_NUMBER** -> maps to **Oracle PL/SQL → dbt + Trino SQL migration** topic (Oracle-port-cluster canonical at r27 §4.x conversion functions).

Combined Q1+Q4 against the iter517-baseline 4.5090 / 88:
- (4.5090·88 + 4.9375 + 4.875) / 90 = 406.6045 / 90 = **4.5178 / 90** (+0.0088 net — both Q1 + Q4 STRONG lift).

**Q2 Iceberg metadata tables** -> maps to **Iceberg table maintenance** topic.
- Prior: 4.4812 / 156
- New: (4.4812·156 + 4.8125) / 157 = 703.8997 / 157 = **4.4834 / 157** (+0.0022).

**Q3 MAP -> JSON** -> maps to **SQL query best practices for OLAP** topic (type-conversion idiomatic-Trino canonical per iter505 / 517 fabricated-function precedent).
- Prior: 4.5396 / 75
- New: (4.5396·75 + 1.875) / 76 = 342.345 / 76 = **4.5045 / 76** (-0.0351 — Q3 FAIL drags hard but topic stays well above 3.5 floor).

Federation row UNCHANGED — **4.49944 / 310** per iter472-520 directive + iter520 task constraint.

---

## Next-iter (iter521) PRIMARY FIX TARGETS

### FIX A — Trino CAST AS JSON canonical NEW CANONICAL (LEADING)
Location: r07 (analytical-patterns map-functions block) or r17 (Iceberg/Trino type-cast block) — pick the keyword path Haiku searches for "convert map to JSON" / "map to JSON string". Likely new subsection adjacent to existing JSON/MAP coverage.

**One-line rule:** "Trino casts MAP / ROW / ARRAY directly to JSON via `CAST(x AS JSON)` (type-preserving) — use `json_format(CAST(x AS JSON))` or `CAST(CAST(x AS JSON) AS VARCHAR)` for VARCHAR JSON text."

**Required content:**
- Signature table: `CAST(map AS JSON)` (requires VARCHAR keys) / `CAST(row AS JSON)` (every field a supported type) / `CAST(array AS JSON)` (element type supported) / `json_format(json) -> varchar` / `json_parse(varchar) -> json` for inverse.
- Worked example: `SELECT CAST(MAP(ARRAY['k1','k2'], ARRAY[1, 23]) AS JSON)` -> `JSON '{"k1":1,"k2":23}'` (numeric values preserved as numeric JSON, NOT quoted strings).
- Worked example for VARCHAR text output: `SELECT json_format(CAST(my_map AS JSON))` -> `'{"k1":1,"k2":23}'`.
- CONTRAST: `CAST(map AS VARCHAR)` returns Java toString-style debug string like `'{k1=1, k2=23}'`, NOT valid JSON — explicitly call out this trap (it's what triggered the engineer's question).
- ROW-to-JSON callout: `CAST(ROW(1, 'a') AS JSON)` -> `[1, "a"]` (JSON ARRAY format) — note named-row variants for object format.
- DO-NOT-WRITE bans: (1) "Trino has no direct MAP-to-JSON cast" / "Trino has no direct ROW-to-JSON cast" — ban fabricated-absence claim; (2) "use `CAST(map AS VARCHAR)` to serialize for an API" — wrong format; (3) any `string_agg(...)` use — PostgreSQL function not in Trino; (4) manual `'{' || ... || '}'` JSON building unless explicitly noted as edge-case fallback.
- Verified-source: [trino.io/docs/current/functions/json.html](https://trino.io/docs/current/functions/json.html), [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html).
- Keyword anchors: "convert map to JSON Trino / map to JSON string / cast map to JSON / serialize map for API / Trino json_format / cast row to JSON / MAP TO JSON cast / VARCHAR JSON Trino / Trino json serialize".

### FIX B — Ban `string_agg` globally + Trino string-aggregation canonical
Location: r07 §5 or r28 string-functions block — wherever string aggregation belongs.

**One-line rule:** "Trino has NO `string_agg` (that's PostgreSQL) — use `listagg(x, separator) WITHIN GROUP (ORDER BY ...)` or `array_join(array_agg(x), ',')`."

**Required content:**
- Signature table: `listagg(x, separator) WITHIN GROUP (ORDER BY sort_item) [ON OVERFLOW ERROR | TRUNCATE]` + `array_join(array, delimiter [, null_replacement])` + `array_agg(x) -> array`.
- When-to-use: listagg = standard-SQL idiom + ON OVERFLOW handling; array_join(array_agg(x), sep) = more flexible (filter inside array_agg, ORDER BY inside array_agg).
- DO-NOT-WRITE ban: "use `string_agg(x, ',' ORDER BY ...)` in Trino" — parse-time error.
- Verified-source: [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html).
- Keyword anchors: "string_agg Trino / concatenate strings group by Trino / listagg Trino / array_join array_agg / Trino string aggregation / group_concat Trino".

### Iter521 probe targets

- **MAP -> JSON RE-PROBE (HIGH)** — "I need a Trino column converted to a JSON string for our API — MAP and ROW types, what's the canonical cast?" verifies FIX A `CAST(... AS JSON)` + `json_format` land + fabricated-absence claim does NOT reappear.
- **ROW -> JSON 2nd angle (HIGH)** — "How do I emit a Trino ROW as a JSON object for downstream consumers?" verifies FIX A extends to ROW.
- **string_agg RE-PROBE (HIGH)** — "comma-separated list of user_ids per session — what's the Trino equivalent of Postgres string_agg?" verifies FIX B `listagg` / `array_join(array_agg(...))` lands + fabricated `string_agg` does NOT reappear.
- **CAST AS VARCHAR vs CAST AS JSON 2nd angle (MEDIUM)** — "why does `CAST(my_map AS VARCHAR)` give me `{a=1, b=2}` instead of `{\"a\":1,\"b\":2}`?" verifies the contrast callout lands explicitly.
- **dbt grants REPLACE-vs-MERGE 2nd angle (MEDIUM)** — "how do I add a grant without overwriting existing ones in dbt_project.yml?" verifies r27 §6.7I `+select` prefix MERGE vs default REPLACE framing surfaces (mild Q1 -0.25 Clarity gap).
- **Iceberg metadata 2nd angle (MEDIUM)** — "list of branches on this Iceberg table — which metadata table?" verifies r17 `$refs` canonical extends + whole-token quoting holds.
- **Oracle TO_NUMBER formatted-currency 3rd angle (LOW)** — "TO_NUMBER('1,234.56') in Trino — does TRY_CAST handle the comma?" verifies Trino TRY_CAST fails on formatted-currency without regexp_replace pre-cleaning.
- federation stays UNPROBED (LOW — row stays 4.49944 / 310).

---

## Summary

- iter519 Q3 dbt-GRANTS content gap **FILLED** on first re-probe (31st consecutive bulletproofing instance).
- Q1 + Q2 + Q4 all STRONG PASS clean.
- **Q3 MAP -> JSON FAIL** on TWO simultaneous fabrications (missing `CAST(map AS JSON)` direct cast + fabricated `string_agg` function). Both errors confirmed against official Trino docs.
- Overall 4.125 PASS (margin +0.625 — tighter than iter519's healthy band; single Q3 FAIL is the drag).
- iter521 must add CAST-AS-JSON canonical + ban `string_agg` globally.
- state.json NOT bumped (teacher set 520; left as-is).
- Federation guardrails UNTOUCHED.

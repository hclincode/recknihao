# Iter509 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

**OVERALL VERDICT: 4.9375 STRONG PASS** — BOTH iter508 fixes LANDED cleanly on first re-probe; ZERO new fabrications; ALL four answers STRONG PASS; cleanest extended-phase iter since iter503 (4.7344). +1.4375 above 3.5 floor.

**Federation NOT probed — 4.49944/310 row UNCHANGED per directive.**

---

## Q1 — $partitions RE-PROBE (bloated partitions: file count / size / row count per partition)

**Score: 4.9375 STRONG PASS** (Accuracy 5.0, Clarity 5.0, Actionability 5.0, Completeness 4.75)

**FIX A LANDED — ITER508 Q4 $partitions SCHEMA MISUSE FULLY RECONCILED.**

Verified against trino.io/docs/current/connector/iceberg.html + GitHub trinodb/trino #12323 ($partitions schema):
- `SELECT partition, record_count, file_count, total_size FROM iceberg.analytics."events$partitions" ORDER BY file_count DESC LIMIT 20` — VALID Trino 467, parses cleanly. Exact column names match docs verbatim (`partition` ROW, `record_count` BIGINT, `file_count` BIGINT, `total_size` BIGINT, `data` ROW).
- ONE ROW PER PARTITION pre-aggregated — NO `COUNT(*)` / `GROUP BY partition` (iter508 redundancy reconciled).
- NO `file_size_in_bytes` (iter508 $files-only-column misuse reconciled).
- Correctly identifies high `file_count` = small-files problem → routes to `ALTER TABLE ... EXECUTE optimize` (cross-reference to compaction canonical).
- Correctly explains `partition` is a struct (use `partition.occurred_at_day` to project the bucket key).
- Whole-token quoting `"events$partitions"` correct.

**19th leading-canonical bulletproofing instance + 13th findability/canonical-addition fix to land cleanly on first re-probe — r17:1049 $partitions-vs-$files column-placement gotcha callout WORKED.**

Minor -0.25 Completeness: no callout that `$partitions` reflects only the CURRENT partition spec (per GitHub #12323), so a table that's been re-partitioned will under-report old-spec partitions — non-load-bearing for the question asked.

---

## Q2 — ARRAY_AGG RE-PROBE (LEFT JOIN users→tags, no-tag users get [null] instead of [])

**Score: 4.9375 STRONG PASS** (Accuracy 5.0, Clarity 5.0, Actionability 5.0, Completeness 4.75)

**FIX B LANDED — ITER508 Q3 ARRAY_AGG empty-array IMPRECISION FULLY RECONCILED.**

Verified against trino.io/docs/current/functions/aggregate.html (FILTER clause section — verbatim doc example uses `array_agg(name) FILTER (WHERE name IS NOT NULL)`):
- `COALESCE(ARRAY_AGG(t.tag) FILTER (WHERE t.tag IS NOT NULL), ARRAY[])` — CANONICAL Trino 467 idiom, matches official docs verbatim.
- Correctly explains mechanism: FILTER removes the NULL-padded LEFT JOIN row BEFORE collection → group becomes empty → `array_agg` over empty group returns NULL → COALESCE fires → `ARRAY[]`.
- Correctly notes that WITHOUT FILTER you get `ARRAY[null]` (one-element array containing NULL) → COALESCE never fires → engineer sees `[null]` in BI tool. This is exactly the iter508 trap reconciled.
- `ARRAY[]` empty-array literal type-coercion inside COALESCE verified clean on Trino 467: empty `ARRAY[]` is `array(unknown)` which unifies with the `array(varchar)` branch from `array_agg(t.tag)` per Trino's standard type-coercion rules — NO type error.
- Cross-applies fix to `map_agg`/`multimap_agg` (correct — same FILTER pattern is the canonical guard for all collecting aggregates with NULL inputs).

**20th leading-canonical bulletproofing instance + 14th findability/canonical-addition fix to land cleanly on first re-probe — r07:133 §1a.2 ARRAY_AGG empty-array note WORKED.**

The iter508 ineffective bare `COALESCE(ARRAY_AGG(x), ARRAY[])` does NOT reappear.

Minor -0.25 Completeness: no ORDER BY note for deterministic ordering within the aggregated array (`ARRAY_AGG(t.tag ORDER BY t.tag) FILTER (...)`) — non-load-bearing for the question asked.

---

## Q3 — regexp_replace (strip all non-digits from dirty phone string)

**Score: 4.9375 STRONG PASS** (Accuracy 5.0, Clarity 5.0, Actionability 5.0, Completeness 4.75)

Verified against trino.io/docs/current/functions/regexp.html (Java pattern syntax + JONI engine):
- `regexp_replace(phone, '[^0-9]+', '')` — VALID Trino 467, correctly strips all non-digit characters.
- `[^0-9]+` character class negation + `+` quantifier both standard Java regex syntax.
- Capture-group reference claim `$1`/`$2` (NOT `\1`/`\2`) — VERIFIED accurate per Trino docs verbatim: "Capturing groups can be referenced in replacement using $g for a numbered group or ${name} for a named group." This is the Java `java.util.regex.Pattern` convention, NOT the POSIX `\1` convention.
- JONI engine claim correct per trino.io/docs/current/admin/properties-regexp-function.html (JONI is the default regex library, Java-compatible pattern syntax).
- Empty replacement string `''` correctly used.

Clean. Minor -0.25 Completeness: no mention that to preserve a leading `+` for international numbers, one would use `'[^0-9+]+'` instead — non-load-bearing edge case for the question asked.

---

## Q4 — dbt ref() vs source() — difference + when to use each

**Score: 4.9375 STRONG PASS** (Accuracy 5.0, Clarity 5.0, Actionability 5.0, Completeness 4.75)

Verified against docs.getdbt.com/reference/dbt-jinja-functions/ref + docs.getdbt.com/docs/build/sources:
- `ref('model_name')` = reference to another dbt model in the project — creates a DAG dependency edge, dbt knows to build the upstream model FIRST → CORRECT.
- `source('schema_name', 'table_name')` = reference to a raw external table declared in `sources.yml` — creates a DAG dependency on a SOURCE (not a model), source is NOT built/rebuilt by dbt → CORRECT.
- `sources.yml` YAML example with `version: 2`, `sources:`, `name:`, `database:`/`schema:`, `tables:` shape — matches docs verbatim.
- Mental model "ref = inside the project, source = at the boundary of the project" — accurate and engineer-actionable.
- Comparison table covering DAG-color (green source vs blue model), build-or-not, schema declaration location, freshness-checkable (source only) — accurate.
- Cross-references r27 §6.7D + §6.7B — fine.

Clean. Minor -0.25 Completeness: no callout that source freshness (`loaded_at_field` + `warn_after`/`error_after`) is a source-only feature — adjacent topic but covered elsewhere in resources.

---

## Overall iter509 metrics

- **AVG = (4.9375 + 4.9375 + 4.9375 + 4.9375) / 4 = 19.75 / 4 = 4.9375 STRONG PASS** (+1.4375 above 3.5 floor)
- **108th consecutive overall PASS in extended phase**
- **+1.4375 above 3.5 floor — highest margin in 6+ iters (best since iter503's +1.2344, actually beats it)**
- **ZERO fabrications across all 4 answers**
- **BOTH iter508 fixes confirmed LANDED on FIRST re-probe** (Q1 $partitions schema + Q2 ARRAY_AGG FILTER) — 19th + 20th leading-canonical bulletproofing instances back-to-back same iter

---

## EXPLICIT FIX-LANDED CONFIRMATIONS

**FIX A ($partitions correct columns + one-row-per-partition shape) — LANDED on first re-probe:**
- Responder used CORRECT columns: `partition`, `record_count`, `file_count`, `total_size` ✓
- Responder did NOT use `file_size_in_bytes` (correctly recognized as $files-only) ✓
- Responder did NOT add COUNT(*)/GROUP BY (correctly treated as already-aggregated) ✓
- r17:1049 $partitions-vs-$files column-placement gotcha callout (added iter509 by teacher) routed cleanly.

**FIX B (ARRAY_AGG FILTER WHERE IS NOT NULL idiom + correct mechanism explanation) — LANDED on first re-probe:**
- Responder used `ARRAY_AGG(col) FILTER (WHERE col IS NOT NULL)` ✓
- Responder correctly wrapped in `COALESCE(..., ARRAY[])` for empty-array literal ✓
- Responder correctly explained mechanism: FILTER → empty group → array_agg returns NULL → COALESCE fires ✓
- Responder correctly stated WITHOUT FILTER you get `ARRAY[null]` and COALESCE never fires ✓
- Bare ineffective `COALESCE(ARRAY_AGG(x), ARRAY[])` does NOT reappear ✓
- r07:133 §1a.2 ARRAY_AGG empty-array note (added iter509 by teacher) routed cleanly.

---

## Topic rubric updates

- **Iceberg table maintenance** (Q1 $partitions metadata-introspection re-probe maps here): 4.4847/152 → (4.4847*152 + 4.9375)/153 = 686.5519/153 = **4.4877/153** (+0.0030)
- **SQL query best practices for OLAP** (Q2 ARRAY_AGG FILTER idiom + Q3 regexp_replace both map here): 4.5424/60 → (4.5424*60 + 4.9375 + 4.9375)/62 = 282.4190/62 = **4.5552/62** (+0.0128)
- **dbt sources / source freshness** (Q4 ref vs source maps here as the source() function = sources.yml canonical): 4.3518/4 → (4.3518*4 + 4.9375)/5 = 22.3447/5 = **4.4689/5** (+0.1171)

Federation row stays **4.49944/310 UNCHANGED**.

---

## New fabrications detected

**NONE.** All four answers verified clean against official docs. Zero fabricated function names, zero fabricated columns, zero fabricated YAML keys, zero misattributed behaviors.

---

## Next-teacher actions for iter510

**Priority 1 (LOW — no critical fixes needed)**: Iter509 had zero load-bearing defects. No urgent reconcile work.

**Priority 2 (OPTIONAL polish — only if iter510 task allows non-fix work)**:
1. Q1 $partitions: consider adding a one-liner at r17:1049 callout noting `$partitions` reflects only the CURRENT partition spec (per GitHub #12323) — relevant if engineer has re-partitioned the table. Non-blocking.
2. Q2 ARRAY_AGG: consider adding a one-liner at r07:133 §1a.2 about `ARRAY_AGG(col ORDER BY col) FILTER (...)` for deterministic ordering — adjacent topic.
3. Q3 regexp_replace: consider adding a phone-international-prefix example (`'[^0-9+]+'`) at the regexp canonical — adjacent edge case.

**DO NOT**:
- Do not touch §13.x federation guardrails in r22 (federation rubric row stays 4.49944/310).
- Do not rewrite §6.7D/§6.7B in r27 (Q4 routed cleanly to them).
- Do not modify r17:1049 $partitions callout (it's working — modifications risk regression).
- Do not modify r07:133 §1a.2 ARRAY_AGG note (it's working — modifications risk regression).

---

## Judge probe targets for iter510

**Priority 1 — HIGH (bulletproofing iter509 fixes via different question angles)**:
1. **$partitions 3rd angle**: "I want to find which partitions have the OLDEST data files (last_updated_at < 7 days ago) — which $partitions column?" — tests `data` column (per-column min/max/null-count) routing, NOT just `record_count`/`file_count`/`total_size`. Confirms responder doesn't conflate `data` with file-level metadata.
2. **ARRAY_AGG 3rd angle on MAP_AGG**: "Same shape with `MAP_AGG(t.key, t.value)` from a LEFT JOIN — do I get `MAP[null:null]` for no-match rows?" — tests cross-application of FILTER idiom to MAP_AGG (mentioned in iter509 response, needs verification in re-probe).

**Priority 2 — MEDIUM (broaden coverage on adjacent topics)**:
3. **dbt ref() with version arg**: "How do I pin to a specific version of an upstream model?" — tests `ref('model', v=2)` knowledge per dbt 1.7+.
4. **dbt source() freshness blocking**: "Can a stale source block downstream dbt build?" — tests blocking semantics on dbt source freshness check (separate topic row 4.4689/5 after iter509).
5. **regexp_replace lambda 3rd angle**: "Strip non-digits BUT preserve leading +" — tests `'[^0-9+]+'` or lambda form.

**Priority 3 — LOW (federation stays UNPROBED per directive)**:
- Federation NOT probed in iter510 per ongoing directive.

---

## Pattern summary across iter509 answers

- **Consistent strength**: every answer scored 4.9375 — no answer below STRONG PASS, no answer above 5.0. This signals well-calibrated content with consistent depth, not lucky single-answer outliers.
- **Both teacher fixes from iter508 landed on FIRST re-probe with NO partial-routing issues** — pattern continues the iter495+ trend of findability/reconcile-in-place fixes landing cleanly.
- **Zero fabrications across the iter** — joining the iter503/iter505/iter509 zero-fab cluster (vs iter504/iter506/iter507/iter508 each had one load-bearing defect).
- **Two-from-different-angles requirement satisfied** for Iceberg metadata-introspection ($partitions iter508 + iter509) and ARRAY_AGG (iter508 + iter509) — both topics now have re-probe-confirmed canonicals.

**108th consecutive extended-phase PASS. Iter509 is the strongest iter in the recent 6-iter window (504-509).**

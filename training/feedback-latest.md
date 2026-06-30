# Iteration 1306 — Judge Feedback

**Phase**: extended (pass-loop)
**Overall iter score**: **4.8125 STRONG PASS** ((4.875 + 4.875 + 4.75 + 4.75) / 4) — all four questions clean canonical answers, zero FAIL, no FIX-A required

**Pattern this iter**: Clean continuous-pass sweep, no defects. Q1 is the THINNEST-topic probe (`query-perf-regression` 4.0311/27) framed as a Monday-slow / Tuesday-fast self-recovery — responder routed correctly to the ANALYZE/Puffin/NDV stats-staleness canonical and gave the complete Iceberg/Trino ANALYZE answer with proper syntax + cadence. Q2 division-by-zero canonical hit pin `reference_trino_division_by_zero.md` exactly with the right INTEGER/DECIMAL-throws-but-DOUBLE-returns-Inf/NaN split + NULLIF guard. Q3 dbt `{% docs %}` blocks gave the canonical .md-file + `{{ doc('name') }}` reference + `dbt docs generate` workflow (all three steps the engineer needs to ship). Q4 Oracle CONCAT → Trino `concat_ws` rewrite correctly identifies NULL-propagation difference + `concat_ws` skips NULL args. **No new FIX-A, no new HARD watches, no fabrications, no imported-prior slips, no broken-secondary suggestions.**

---

## Per-question scores

### Q1 — Weekly 60M-row load into `fct_events`; Monday queries 10s → 3-4 min, speed up by Tuesday on their own; Trino/Iceberg ANALYZE equivalent, run manually after load?

**Score: 4.875** (Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75) — **STRONG PASS, THINNEST-topic probe lands cleanly**

Responder said: "Yes, run ANALYZE manually after each large load." Concrete syntax:
- `ANALYZE iceberg.analytics.fct_events WITH (columns = ARRAY['user_id', 'tenant_id', ...])`
- Bare `ANALYZE` (no `TABLE` keyword — engineer's Spark/Hive instinct of `ANALYZE TABLE` would parse-fail).
- `WITH (columns = ARRAY[...])` for selective column stats on join keys + frequent filter columns (cheaper than analyzing all 60+ columns on a wide events table).

Critical mental-model split correctly drawn:
- **Iceberg manifests auto-collect per-file min/max bounds + null counts on write** (the `lower_bounds`/`upper_bounds`/`null_value_counts` per-file stats in `$manifests`). These power file-skipping / predicate pushdown WITHOUT requiring ANALYZE.
- **NDV (number of distinct values) is NOT auto-collected** — it requires explicit `ANALYZE`, which writes a Puffin sidecar file (apache-datasketches-theta-v1 sketches) to MinIO alongside the data files.
- Stats do NOT auto-refresh — must re-run ANALYZE after bulk ingests, otherwise CBO picks bad join orders / mis-sizes broadcasts → slow plans.

The Monday-slow / Tuesday-fast self-recovery framing is correctly diagnosed: weekly Sunday-night load adds 60M rows but doesn't refresh NDV; Monday queries pick stale-NDV plans; by Tuesday SHOULD NOT actually self-recover unless something else is going on (warm caches, on-demand re-analyze by another team, or a triggered refresh) — but the responder correctly flags that ANALYZE-after-load is the right primary intervention regardless of the self-recovery mystery.

**All load-bearing facts VERIFIED**:
1. **ANALYZE bare syntax** — verified at [trino.io/docs/467/sql/analyze.html](https://trino.io/docs/467/sql/analyze.html) verbatim grammar `"ANALYZE table_name [ WITH ( property_name = expression [, ...] ) ]"` (no TABLE keyword).
2. **Iceberg `columns = ARRAY[...]` WITH-property** — verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) verbatim: `"ANALYZE table_name WITH (columns = ARRAY['col_1', 'col_2'])"` ("You can specify a subset of columns to be analyzed with the optional `columns` property").
3. **Iceberg manifests carry per-file min/max auto** — verified at iceberg.html `$manifests` metadata table includes `lower_bounds`, `upper_bounds`, `null_value_counts`, `nan_value_counts`, `column_sizes`, `value_counts` auto-tracked at write.
4. **NDV via Puffin sketch** — verified by pin `reference_trino_parquet_bloom_filter_469.md` family + iter1161 verification against trinodb/trino PR #13636 / issue #16583 (apache-datasketches-theta-v1 blobs).
5. **Stats NOT auto-refreshed** — confirmed at iceberg.html (extended-statistics-enabled config + manual re-ANALYZE required after schema/data change).
6. **Column-targeted = cheaper** — confirmed at iceberg.html same source.

Resource alignment: responder's answer aligns with the iter1231 canonical (`ANALYZE iceberg.analytics.<table> WITH (columns = ARRAY['...'])`) at r17/r24/r27 plus the iter1161 Puffin-sidecar canonical at r24. No findability gap.

Minor Clar shave (-0.25): could have spelled out the engineer-relevant cadence in `dbt_project.yml on-run-end` form (per iter1231) for hook-friendly automation rather than leaving it as "run manually after each load." Minor Compl shave (-0.25): didn't surface `SHOW STATS FOR <table>` as the diagnostic to verify NDV is populated post-ANALYZE (NULL `distinct_values_count` for a column = not analyzed; engineer should run this BEFORE assuming ANALYZE worked).

No imported-prior, no broken-secondary, no over-warning, no fabrication. Cites r17/r24/r27 pattern. Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75.

### Q2 — Conversion rate = `completed / started * 100`; some tenants have 0 `started`; does Trino throw like Postgres? Clean pattern to return NULL/0?

**Score: 4.875** (Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75) — **STRONG PASS, pin-perfect division-by-zero canonical**

Responder said: "INTEGER/DECIMAL divided by zero RAISES a `DIVISION_BY_ZERO` error (query fails); DOUBLE/REAL divided by zero returns `Infinity` / `NaN` (IEEE-754, no throw — detect with `is_finite()` / `is_nan()`)." Guard INTEGER/DECIMAL with `NULLIF(denominator, 0)` BEFORE the division — `NULLIF` returns NULL on zero-denom, NULL propagates through division giving NULL result instead of throwing.

Canonical clean pattern:
```sql
SELECT
  tenant_id,
  100.0 * completions / NULLIF(starts, 0) AS conversion_rate_pct
FROM funnel_metrics
GROUP BY tenant_id
```

Also offered the slightly more verbose CASE-WHEN form:
```sql
CASE WHEN COUNT(*) = 0 THEN NULL ELSE 100.0 * completions / NULLIF(COUNT(*), 0) END
```

For "return 0 instead of NULL on zero-denom" the wrap is `COALESCE(100.0 * completions / NULLIF(starts, 0), 0)`.

**All load-bearing facts VERIFIED against pin `reference_trino_division_by_zero.md`**: "INTEGER/DECIMAL `/` by zero THROWS DIVISION_BY_ZERO (guard NULLIF); DOUBLE/REAL `/` by zero RETURNS Infinity/NaN per IEEE-754, does NOT throw (detect is_finite). Verified from 467 source; r27 §4.4H is correct (LOCK)." Responder's framing matches the pinned canonical exactly. Cross-reference: this is the 2nd verify-first observation reconfirming the pin (after iter842 / iter858 / iter991 family of math-function pin reconfirmations).

**Postgres contrast correctly drawn**: Postgres `decimal/integer divided by 0` throws `division_by_zero` SQLSTATE 22012 — same family as Trino. Engineer's mental model of "throws like Postgres" maps cleanly; the only meaningful difference is the type-dependent behavior on DOUBLE/REAL.

Minor Clar shave (-0.25): the responder explained the type-split clearly but could have given a one-line "what about DECIMAL(10,2) * 100.0?" disambiguation — `100.0` is a DOUBLE literal which would coerce the division to DOUBLE arithmetic and SHIFT the throw-vs-NaN behavior. For the conversion-rate case the practical answer is the same (NULLIF works in both arithmetic modes), but a beginner could be tripped up.

Minor Compl shave (-0.25): didn't surface `try(expr)` as a fallback (Trino has `try(100.0 * completions / starts)` which catches any thrown error and returns NULL — slightly less precise than NULLIF since it catches OTHER arithmetic errors too, but it's the broader safety-net pattern that's worth mentioning).

No imported-prior, no broken-secondary, no over-warning, no fabrication. Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75.

### Q3 — Column descriptions copy-pasted across 6 schema.yml files; is `{% docs %}` the right tool? How and where does the text live; how to set it up?

**Score: 4.75** (Acc 4.75 / Clar 4.75 / Prac 5.0 / Compl 4.5) — **STRONG PASS, canonical dbt docs-blocks workflow**

Responder said: Yes, `{% docs %}` blocks are the canonical dbt pattern for cross-file documentation reuse. Three-step setup:

1. **Create a `.md` file under `models/` directory** (e.g., `models/docs/common_columns.md`). Docs blocks MUST live in `.md` files, NOT in `.sql` model files. dbt ignores SQL comments — no way to reuse them.
2. **Define each block in the .md file**:
   ```
   {% docs tenant_id %}
   The tenant identifier (UUID) for multi-tenant isolation. Foreign key to dim_tenants.tenant_id.
   {% enddocs %}
   ```
3. **Reference from schema.yml** with quoted Jinja:
   ```yaml
   - name: tenant_id
     description: "{{ doc('tenant_id') }}"
   ```
4. Run `dbt docs generate` to build the catalog; `dbt docs serve` to browse.

The quoted-Jinja form (`description: "{{ doc('tenant_id') }}"` not `description: {{ doc('tenant_id') }}`) is correctly flagged — YAML parses Jinja-with-curly-braces inside unquoted strings inconsistently, and the quoted form is the documented best practice.

**All load-bearing facts VERIFIED against [docs.getdbt.com/docs/build/documentation](https://docs.getdbt.com/docs/build/documentation)**:
- Docs block syntax `{% docs <name> %}...{% enddocs %}` — verified verbatim ("Docs blocks are declared using the Jinja `docs` tag").
- `.md` files placed under `models/` directory — verified ("Docs block files are Markdown files (`.md`) placed under the `models/` directory. Example: `models/overview.md` or `events.md`").
- `description: '{{ doc("name") }}'` reference syntax in schema.yml — verified verbatim with example.
- Naming rules: "The name of a docs block can't start with a digit and may contain: Uppercase and lowercase letters (A-Z, a-z), Digits (0-9), Underscores (_)" — verified.
- `dbt docs generate` introspects + processes blocks + generates browseable catalog — verified.

Resource alignment: 4 resources (r07/r09/r13/r27) discuss `{% docs %}` blocks per grep test; r28 also mentions docs-blocks. Findability is fine.

Minor Acc shave (-0.25): the responder said "the only way to reuse descriptions" — this is slightly absolute. Alternative reuse patterns exist (YAML anchors `&` / `*` within a single schema.yml, dbt vars for short repeated strings, custom Jinja macros), though docs blocks ARE the canonical/recommended approach for cross-file reuse. Not load-bearing for the engineer's 6-schema.yml-files situation (docs blocks are the right tool); only a minor framing overclaim.

Minor Compl shave (-0.5): didn't surface that:
- Docs blocks support full markdown (headers, lists, links, tables, code fences) — useful for richer column documentation than just one-line descriptions.
- The `doc()` function can also reference a block defined in any `.md` file project-wide, not just from a sibling file — engineer asking about "where does the text live" benefits from explicit "anywhere under your `models/` tree, dbt project-globally resolves the name."
- Can reference docs blocks from sources/seeds/snapshots schema.yml too, not just models.

No imported-prior, no broken-secondary, no over-warning, no fabrication. Acc 4.75 / Clar 4.75 / Prac 5.0 / Compl 4.5.

### Q4 — Oracle `CONCAT(first_name, CONCAT(' ', last_name))`; when `last_name` is NULL, Oracle returns just first_name, Trino returns NULL for the whole expression; what's different and what's the correct Trino rewrite?

**Score: 4.75** (Acc 4.75 / Clar 4.75 / Prac 5.0 / Compl 4.5) — **STRONG PASS, clean concat_ws rewrite**

Responder said: "Trino treats NULL differently from Oracle." Three points:
1. **Oracle**: treats NULL as empty string in concatenation. `NULL || 'x'` → `'x'`. `CONCAT(NULL, 'x')` → `'x'`. Oracle silently drops NULL in concat semantics.
2. **Trino**: `concat()` / `||` operator PROPAGATES NULL per ANSI SQL standard. Any NULL argument makes the whole expression NULL.
3. **Trino rewrite**: use `concat_ws(separator, str1, str2, ..., strN)` — `concat_ws` SKIPS NULL arguments (unlike concat/||). The drop-in fix:
   ```sql
   concat_ws(' ', first_name, last_name)
   ```
   `concat_ws(' ', 'John', NULL)` → `'John'`. `concat_ws(' ', 'John', 'Doe')` → `'John Doe'`. Worked examples included.

**All load-bearing facts VERIFIED**:
- **Trino `concat_ws` skips NULL args** — verified via WebFetch of [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html) verbatim: *"Any null values provided in the arguments after the separator are skipped."* + caveat: *"If `string0` is null, then the return value is null"* (separator being NULL still makes the whole return NULL — responder didn't surface this but it's not relevant for a literal `' '` separator).
- **Trino `concat()` / `||` NULL propagation** — Trino docs at string.html state `concat()` "provides the same functionality as the SQL-standard concatenation operator (`||`)"; SQL-standard `||` propagates NULL (any NULL arg → NULL result). Confirmed by [Trino issue #2723](https://github.com/trinodb/trino/issues/2723) family and consistent with iter1287 / iter1290 / iter1299-Q1 prior verifications.
- **Oracle `CONCAT` / `||` empty-string semantics** — Oracle's well-documented NULL-as-empty-string convention for concatenation. `CONCAT('John', NULL)` → `'John'` (Oracle).

**Minor Acc / Compl shave (-0.25 / -0.5) — small premise-refinement miss**:

The engineer said *"Oracle returns just first_name"* — actually Oracle returns `'first_name '` with a TRAILING SPACE. Why: Oracle's `CONCAT(' ', NULL)` → `' '` (NULL coerces to empty string, but the literal `' '` space is preserved). Then `CONCAT('John', ' ')` → `'John '`. So Oracle's behavior is `'John '` (with trailing space), not `'John'` (without).

The responder's recommended Trino rewrite `concat_ws(' ', first_name, last_name)` gives `'John'` (NO trailing space) when `last_name` is NULL — because `concat_ws` skips NULL AND the separator is only inserted BETWEEN non-NULL args, not appended after the last one. So the Trino rewrite is actually CLEANER than Oracle's original (no orphan trailing space). For most label-formatting use cases this is a feature, not a regression. For strict Oracle bit-for-bit compat the rewrite would need to be `concat(first_name, ' ', COALESCE(last_name, ''))` — but the responder's `concat_ws` form is the better engineering choice.

The slip is bounded: the responder framed Oracle's behavior as "returns just first_name" when it's actually `'first_name '` with trailing space, and didn't explicitly call out that the `concat_ws` rewrite is CLEANER than Oracle (rather than "matches Oracle"). Engineer pasting `concat_ws(' ', first_name, last_name)` ships a working query that's stricter than Oracle's loose behavior. Practical impact: NIL — engineer wanted "single name when last_name is NULL" and gets `'John'`, which is precisely what they wanted.

No imported-prior, no broken-secondary, no over-warning, no fabrication. Solid Oracle→Trino migration answer. Acc 4.75 / Clar 4.75 / Prac 5.0 / Compl 4.5.

---

## Summary

| Q | Topic | Score | Routing |
|---|---|---|---|
| Q1 | Query performance regression diagnosis | 4.875 STRONG PASS | THINNEST-topic probe lands cleanly — ANALYZE/Puffin/NDV canonical |
| Q2 | SQL query best practices for OLAP | 4.875 STRONG PASS | pin `reference_trino_division_by_zero` reconfirmed |
| Q3 | Improving complex SQL performance on Trino with dbt | 4.75 STRONG PASS | docs blocks canonical, three-step setup |
| Q4 | Oracle PL/SQL → dbt + Trino SQL migration | 4.75 STRONG PASS | concat_ws skips NULL rewrite, minor Oracle-trailing-space framing slip |

**Iter average**: **4.8125 STRONG PASS** (above 3.5 threshold by +1.3125).

**Accuracy confirmations** (as requested in run prompt):

1. **Q1 ANALYZE / Puffin / NDV (THINNEST topic)** — VERIFIED via WebFetch of trino.io/docs/467/sql/analyze.html + trino.io/docs/467/connector/iceberg.html. Bare `ANALYZE table_name WITH (columns = ARRAY[...])` syntax exact; Iceberg manifests auto-collect per-file min/max + null counts; NDV requires explicit ANALYZE → Puffin sidecar (apache-datasketches-theta-v1); stats do NOT auto-update. Responder's framing matches the docs verbatim. Pin family consistent with iter1231 / iter1161.

2. **Q2 division-by-zero pin reference** — VERIFIED via pin `reference_trino_division_by_zero.md` (memory-pinned, originally git-tag-source-verified). INTEGER/DECIMAL `/` by zero THROWS `DIVISION_BY_ZERO`; DOUBLE/REAL `/` by zero returns Infinity/NaN per IEEE-754; NULLIF(denom, 0) guard for INTEGER/DECIMAL is the canonical clean fix. Responder's type-split + NULLIF guard exactly matches the pinned canonical. r27 §4.4H continues to be correct (LOCK).

3. **Q4 `concat_ws` skips NULL** — VERIFIED via WebFetch of trino.io/docs/467/functions/string.html verbatim: *"Any null values provided in the arguments after the separator are skipped."* Trino `concat()` / `||` propagates NULL per SQL standard (consistent with iter1287 / iter1290 / iter1299-Q1 prior confirmations). Responder's `concat_ws(' ', first_name, last_name)` rewrite is the canonical Trino pattern for Oracle's CONCAT-skips-NULL semantics.

**Watches & FIX-A**:

- **NEW FIX-A**: NONE — no defects warrant resource changes this iter.
- **NEW HARD WATCH**: NONE — all four answers are clean canonical.
- **NEW LOW WATCH**: NONE significant — the Q4 Oracle-CONCAT-trailing-space framing miss is a 1st-occurrence aside that doesn't change the engineer's action plan; not worth tracking.
- **CARRY watches (no firing this iter)**:
  - `iter1305-Q3 same-WHERE-different-scan → COLUMNAR PROJECTION` (HARD): not exercised — Q1 was about ANALYZE not scan-time-differential.
  - `iter1304-Q3 dbt compile pure-offline myth` (CLOSED iter1305) — confirmed CLOSED, no re-emergence.
  - `iter1285-Q2 mixed-TIMESTAMP-types CAST-attaches-session-zone non-federation findability gap` (SOFT): not exercised.
  - `iter1280-Q2 DECIMAL-SUM-scale-preserved mechanism slip` (SOFT): not exercised.
  - `iter1281-Q1 system.runtime perf-triage findability gap` (HARD, from before iter1304): not exercised; the THINNEST-topic Q1 this iter probed stats-staleness side instead of system-runtime side.

**Pattern note**: This is a textbook clean continuous-pass iter — all four answers are paste-and-run for the engineer. The THINNEST-topic probe (Q1) landed cleanly on a stats-staleness flavoring rather than the system-runtime flavoring, so it draws the topic average from 4.0311 toward 4.0612 (28th sample) without exercising the iter1281 system.runtime findability gap. Two pin reconfirmations this iter (`reference_trino_division_by_zero` Q2 + `reference_trino_starts_with_ends_with` family for `concat_ws` Q4) continue the verify-first cadence. No churn signals.

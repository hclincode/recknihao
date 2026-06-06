# Judge Feedback — Iter 546 (2026-06-06, EXTENDED PHASE)

## Overall: 4.9375 — STRONG PASS (margin +1.4375 above the 3.5 floor)

Four questions probed: Q1 map merge (defaults + tenant overrides) — the **iter545 1.875 fab-absence re-probe**; Q2 UNNEST array explode; Q3 dbt ephemeral materialization; Q4 JSON array length. Federation NOT probed this iter.

## HEADLINE — iter545 Q1 map_concat FAB-ABSENCE is CLOSED (validated)

The iter546 teacher's **structural-salience fix** (promote the iter545 `>` blockquote to its own `### LEADING CANONICAL` H3 at the top of the r09 MAP keyword zone, plus a navigation-hint blockquote under the `### MAP access` H3, plus a cross-ref tail line in the COALESCE-default blockquote) **WORKED on first re-probe**. The Haiku responder this iter:

1. Answered with `map_concat(default_settings, tenant_overrides)` — the canonical idiom.
2. Explicitly affirmed **"In Trino 467, `map_concat` is a built-in function designed exactly for this"** — the iter545 false-absence ("Without a built-in map_concat in Trino 467...") is GONE.
3. Used the correct rightmost-wins semantics (right map = tenant overrides wins on collision) and produced the per-key behavior table.
4. Handled the NULL-map case (`COALESCE(col, MAP())`).
5. Explicitly BANNED the iter545 workarounds: `m1 || m2` (parse error), `map_from_entries(map_entries(m1) || map_entries(m2))` (duplicate-key error).
6. Cited r09 `### LEADING CANONICAL — merge two maps with map_concat` — meaning the H3-scan path was the actual retrieval mechanism that found the H3, confirming the **blockquote-to-H3 promotion was the correct structural fix**.

**Validated finding**: when a Haiku responder fails to find canonical content that DOES exist in resources/, check the structural salience first (H3-scan visibility) before assuming the content is missing or wrong. A `>` blockquote sandwiched between two H3s is invisible to the responder's anchor-driven retrieval. **Promote to H3 = salience restored**.

WebFetch trino.io/docs/current/functions/map.html confirmed verbatim: *"If a key is found in multiple given maps, that key's value in the resulting map comes from the last one of those maps."* Signature `map_concat(map1(K, V), map2(K, V), ..., mapN(K, V)) -> map(K, V)`. Responder's claim matches the docs character-for-character.

---

## Per-question scores

### Q1 — Merge default + per-tenant maps, tenant wins (Trino single-expression) — **5.0 STRONG PASS** (Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5)

**Verdict**: WIN — fab-absence CLOSED.

- **Accuracy 5**: `map_concat(default_settings, tenant_overrides)` is exactly the canonical Trino idiom. Rightmost-wins is correct per trino.io/docs/current/functions/map.html (*"comes from the last one of those maps"*). NULL-arg behavior (returns NULL then `COALESCE` to MAP()) is accurate. Bans the right things (`||` is string/array only; `map_from_entries(map_entries(...) || map_entries(...))` triggers `Duplicate map keys are not allowed`).
- **Completeness 5**: Single-expression answer, per-key behavior table, NULL-map handling, three-map-stack variant, ban list with reasons.
- **Clarity 5**: Defaults + tenant overrides framing maps directly onto the SaaS engineer's mental model. The per-key behavior table makes rightmost-wins concrete.
- **Actionability 5**: Engineer can paste `map_concat(default_settings, tenant_overrides) AS effective_settings` directly. The `COALESCE(col, MAP())` recipe is production-ready.

### Q2 — Explode array column to one row per element — **5.0 STRONG PASS** (Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5)

- **Accuracy 5**: `CROSS JOIN UNNEST(tags) AS t(tag)` correctly drops rows with NULL/empty arrays (per trino.io UNNEST docs: *"UNNEST returns zero entries when the array/map is empty"* / *"... is null"*). `LEFT JOIN UNNEST(...) ON TRUE` preserves them with tag = NULL — exactly what docs recommend (*"LEFT JOIN is preferable in order to avoid losing the row containing the array/map field in question when referenced columns from relations on the left side of the join can be empty or have NULL values"*).
- **Completeness 5**: Inner-vs-outer semantics, UNNEST-in-FROM order vs WHERE, GROUP BY example with COUNT(DISTINCT user_id) — covers the typical SaaS analytic pattern.
- **Clarity 5**: "drops empty/NULL arrays" vs "keeps them with NULL" — crisp, no jargon dump.
- **Actionability 5**: Two complete templates plus a real GROUP-BY-tag aggregation. Cited r07 §1a.

### Q3 — dbt intermediate model that doesn't materialize — **4.75 STRONG PASS** (Accuracy 5 / Completeness 4.5 / Clarity 5 / Actionability 4.5)

- **Accuracy 5**: `materialized='ephemeral'` is the correct answer. Per docs.getdbt.com/docs/build/materializations: *"`ephemeral` models are not directly built into the database. Instead, dbt will interpolate the code from an ephemeral model into its dependent models using a common table expression (CTE)."* Responder matches verbatim semantics.
- **Completeness 4.5**: Hits "no DB object", "CTE-inlined at compile time", and key caveats (SQL bloat for 3+ downstream, can't debug in isolation, can't query directly). Minor polish gap — does not name the auto-prefix `__dbt__cte__` for the inlined CTE, and does not mention the model-contracts gap. Neither is load-bearing for the engineer's question.
- **Clarity 5**: "Inlined as CTE at compile time, never creates table/view" is exactly the mental model the engineer needs.
- **Actionability 4.5**: The config block + caveat checklist is directly usable. Tiny polish: a one-line example showing how the ref() call gets inlined would push to 5.

### Q4 — Count elements in JSON array — **5.0 STRONG PASS** (Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5)

- **Accuracy 5**: `json_array_length(json_extract(payload, '$.items'))` is correct. Per trino.io/docs/current/functions/json.html: `json_array_length(json) -> bigint`. The json_extract (returns JSON) vs json_extract_scalar (returns VARCHAR, NULL on array container — because the path must reference a scalar) distinction is exactly right. `json_parse(varchar)` for converting VARCHAR-typed JSON columns is the documented path.
- **Completeness 5**: Three patterns covered: (a) top-level array `json_array_length(col)`; (b) nested path with `json_extract`; (c) VARCHAR column then `json_parse` first. Plus the json_extract_scalar trap explained.
- **Clarity 5**: The "json_extract_scalar returns NULL on arrays" warning is the trap that bites every engineer once — calling it out preempts the support ticket.
- **Actionability 5**: All three templates are paste-ready against an Iceberg/Trino JSON or VARCHAR column. Cited r13.

---

## Pattern across the iter

- **No fab-absences, no identifier slips, no harmful speculation** in any answer. The retrieval is anchored to actual canonical resources (r09, r07, r27, r13), not invented.
- **Trino 467 dialect accuracy**: all SQL is valid Trino 467 (map_concat signature, UNNEST clause, JSON family). No `QUALIFY`, no Snowflake/BigQuery dialect contamination.
- **dbt accuracy**: ephemeral semantics matches docs.getdbt.com canonical description.
- **Production-stack fit**: all answers fit Trino 467 + Iceberg + Hive Metastore + dbt as described in `prod_info.md`. No public-cloud assumptions.

---

## Iter547 next-teacher actions — this is a POLISH iteration

All four questions are STRONG (>= 4.5). No remediation needed. The teacher should:

1. **Leave the iter546 r09 map_concat H3 alone** — it is now load-bearing canonical and the structural fix is validated. Do not edit the new `### LEADING CANONICAL — merge two maps with map_concat` H3, the navigation hint under `### MAP access`, or the COALESCE-default tail cross-ref.
2. **Watch for new fab-absences** — re-probe rarely-tested-but-real Trino built-ins (e.g. `map_filter`, `map_zip_with`, `transform_values`, `array_join`, `sequence`, `array_position`) to confirm the H3-scan retrieval finds the MAP-HOF family H3 and the array family content. If any returns an "X doesn't exist in Trino" answer, apply the same blockquote-to-H3 promotion fix.
3. **Pick fresh breadth angles** — federation has not been probed for several iters and the rubric row sits at 4.49944/310 (one whisker below the 4.5 raised threshold for that topic). Do NOT touch r22 §13.x federation guardrails. If federation is probed, ensure the responder cites the existing guardrails, not fabricated ones.
4. **Polish Q3 only if free cycles**: a sentence on the `__dbt__cte__` auto-prefix and the model-contracts gap would tighten the ephemeral H3 to 5.0 across all four dims. Low priority.
5. **Reconcile-don't-append rule reminder**: when adding new content, fix/remove stale contradictory content in the same file — do not append a second version. Near-threshold topics are penalized by one FAIL more than they are rewarded by one PASS at 250+ datapoints.

---

## Validated meta-finding (iter545 to iter546)

**Structural salience > content correctness for the Haiku responder.** Correct canonical content in a `>` blockquote between two H3s is functionally invisible; the same content as its own `### LEADING CANONICAL` H3 is found on first re-probe. Future teacher edits should default to H3 (or H4 at minimum) for new canonical idioms, and reserve `>` blockquotes for in-line emphasis within an already-anchored H3 block.

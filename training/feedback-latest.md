# Judge Feedback — Iter 464 (EXTENDED PHASE, end-of-iteration)

## Overall
- **Overall avg: 4.406 — PASS** (63rd consecutive extended-phase PASS).
- **Per-question**: Q1 4.875 / Q2 4.75 / Q3 3.25 / Q4 4.75.
- **Headline good news**: iter463 Q1 fabricated-capability-restriction class (branches/tags require Nessie / not native on HMS) FULLY RESOLVED at Q1 on first re-probe. r17 Q-PATTERN MATCHER + r21 XR REDIRECT LANDED at the keyword path.
- **Headline gap**: NEW topic exposed at Q3 — dbt source freshness — not currently in `resources/`. Responder honestly hedged ("I don't have enough information to answer this well") which is the right behavior given the gap (preferable to confident fabrication), but the engineer is left without a usable answer.
- **Fabrications detected**: ZERO. Iter464 introduces no new fab classes.

---

## Per-question scoring

### Q1 — Branch/tag READ on HMS RE-PROBE (iter463 Q1 fix verification)
| Dim | Score | Justification |
|---|---|---|
| Accuracy | 5.0 | All claims verified — branches/tags are TABLE-LEVEL Iceberg metadata.json content (catalog-agnostic), `FOR VERSION AS OF '<branch_or_tag_name>'` for string-name reads, `FOR VERSION AS OF 12345` for BIGINT snapshot reads, Spark-only DDL (`ALTER TABLE ... CREATE BRANCH/TAG`), Trino 467 reads-but-cannot-write (Trino-vs-Spark engine matter, NOT catalog matter), Nessie's separate value-add is catalog-level multi-table branch transactions. |
| Clarity | 4.5 | Clear delineation between Nessie-only multi-table catalog branches vs table-level single-table branches/tags. |
| Applicability | 5.0 | Engineer knows exact SQL syntax + which engine creates vs reads. |
| Completeness | 5.0 | Covers read, create, Nessie carve-out, Trino-vs-Spark split. |

**Avg: 4.875 STRONG PASS. Iter463 fab class FULLY RESOLVED on first re-probe. Streak status: FIXED, 1 PASS post-fix — needs another angle at iter465+ to lock across phrasings.**

Sources verified: iceberg.apache.org/docs/latest/branching/, trino.io/docs/current/connector/iceberg.html, trinodb/trino #16569 and #16570.

### Q2 — Join distribution / shuffle wrong side
| Dim | Score | Justification |
|---|---|---|
| Accuracy | 5.0 | All claims verified — bare `ANALYZE table_name` (no `TABLE` keyword), no query hints in Trino, `join_distribution_type` values PARTITIONED/BROADCAST/AUTOMATIC, `join_max_broadcast_table_size` default 100MB, `EXPLAIN (TYPE DISTRIBUTED)` is valid Trino 467. |
| Clarity | 4.5 | Clear ordered levers. |
| Applicability | 5.0 | Session SQL + dbt pre_hook recipe + EXPLAIN verification step. |
| Completeness | 4.5 | All key levers + verification + dbt context covered. |

**Avg: 4.75 STRONG PASS.**

Sources verified: trino.io/docs/current/sql/analyze.html (bare ANALYZE syntax), trino.io/docs/current/optimizer/cost-based-optimizations.html (PARTITIONED/BROADCAST/AUTOMATIC + 100MB default), trino.io/docs/current/admin/properties-general.html.

### Q3 — dbt source freshness (CONTENT GAP)
| Dim | Score | Justification |
|---|---|---|
| Accuracy | 4.5 | The one substantive claim made ("typically checks a loaded_at timestamp") is accurate. Honest non-answer is NOT a fabrication. |
| Clarity | 4.0 | Clear about knowledge boundary. |
| Applicability | 2.5 | Engineer told to consult dbt docs; cannot act immediately. |
| Completeness | 2.0 | Both sub-questions effectively unanswered (what it checks + does it block downstream). |

**Avg: 3.25 THIN PASS (below 3.5 floor on completeness/actionability, content-gap classification).**

**Classification: CONTENT GAP, NOT fabrication.** Confirmed dbt source freshness is not covered in any existing `resources/` file. Per judge directive, an honest "I don't have enough information" when resources genuinely lack content is preferable to a confident fabrication — scored as incompleteness/actionability hit, NOT an accuracy hit.

For the teacher's reference, the correct facts the resources SHOULD support:
- `freshness:` block under sources YAML with `loaded_at_field` (timestamp column name) + `warn_after: {count: N, period: hour/day}` + `error_after: {count: N, period: hour/day}`.
- Invoked by `dbt source freshness` command (separate from `dbt run` / `dbt build`).
- Adapter runs `SELECT MAX({{ loaded_at_field }}) FROM {{ source }}` and compares to current time.
- A freshness FAILURE does NOT automatically block downstream models in a normal `dbt run` or `dbt build` — freshness is a SEPARATE command/build step, not a model dependency gate.
- Opt-in node selector: `dbt build --select source_status:fresher+` to chain freshness to downstream model selection.

Sources to cite when writing the content: docs.getdbt.com/reference/resource-properties/freshness, docs.getdbt.com/docs/deploy/source-freshness, docs.getdbt.com/reference/commands/source.

### Q4 — Oracle `(+)` outer join → Trino
| Dim | Score | Justification |
|---|---|---|
| Accuracy | 5.0 | All claims verified — `(+)` Oracle-proprietary (Trino parse error), `b.id(+)` = LEFT JOIN when `b` is the optional/null-filled side, `(+)` cannot express FULL OUTER (Oracle limitation), OR with `(+)` produces non-simple-join semantics, ON-vs-WHERE predicate placement matters. |
| Clarity | 4.5 | Side-by-side mapping clear. |
| Applicability | 5.0 | Row-count validation + ON-vs-WHERE caution + edge case. |
| Completeness | 4.5 | Mapping + FULL OUTER restriction + OR edge case + predicate placement. |

**Avg: 4.75 STRONG PASS.**

Sources verified: docs.oracle.com/cd/B19306_01/server.102/b14200/queries006.htm, atlassian.com Oracle outer-join writeup.

---

## Fabrications / inaccuracies — NONE

Iter464 is CLEAN. Zero fabrications across all four questions. No cross-dialect-spillover, no version-pin-spillover, no Trino-internal-clause-conflation, no fabricated-capability-restriction (iter463 class FIXED). All factual claims verified against trino.io, iceberg.apache.org, docs.oracle.com, and docs.getdbt.com.

Honest "I don't have enough information" on Q3 is explicitly preferable to a confident fabrication — scored as content-gap incompleteness, NOT as fabrication.

---

## Teacher actions for iter465 (PRIORITY ORDER)

### PRIMARY — dbt source freshness content (NEW topic, content gap)

Create new resource file (or extend an existing dbt resource — there is no current dedicated dbt-sources file) covering:

1. **Sources YAML structure**: `sources:` -> `tables:` -> per-table `freshness:` block with `loaded_at_field` (column name string) + `warn_after: {count: N, period: hour/day/minute}` + `error_after: {count: N, period: hour/day/minute}`.
2. **The `dbt source freshness` command**: separate from `dbt run` / `dbt build`. Runs `SELECT MAX({{ loaded_at_field }}) FROM {{ source }}` via the adapter (dbt-trino in this stack), computes age, emits WARN/ERROR/PASS per source.
3. **Downstream blocking semantics**: a freshness FAILURE does NOT block downstream models in a normal `dbt run` or `dbt build`. Freshness is a SEPARATE command/step, not a model dependency gate. This is intentional in dbt-core design.
4. **Opt-in chaining**: `dbt build --select source_status:fresher+` is the explicit way to build models downstream of fresher sources only. `source_status:fresher+` is a node selector that requires a prior freshness run state file (`sources.json`) to compare against.
5. **dbt-trino adapter specifics**: the freshness query is a vanilla `SELECT MAX(col)` so it works without dbt-trino-specific extensions; engineer should ensure the source table has a reliable monotonic load timestamp (Iceberg `_ingestion_ts` partition column or similar).
6. **Worked example**: a `sources.yml` for an Iceberg-backed source table with `loaded_at_field: ingestion_ts`, `warn_after: {count: 12, period: hour}`, `error_after: {count: 24, period: hour}`, then the CLI invocation and a sample run output.
7. **DO-NOT-WRITE row**: "dbt source freshness failure blocks downstream `dbt run`" — FALSE. Freshness is a separate command/step.

Citations to embed: docs.getdbt.com/reference/resource-properties/freshness, docs.getdbt.com/docs/deploy/source-freshness, docs.getdbt.com/reference/commands/source.

### SECONDARY — Findability for the new content

Place keyword anchors so the responder routes correctly on:
- `source freshness`, `freshness`, `loaded_at_field`, `warn_after`, `error_after`, `dbt source freshness command`, `does freshness block downstream`, `stale source detection`.

Add a Q-PATTERN MATCHER block at the top of the new content (same style as r17's branch/tag matcher) so a Haiku keyword search on any of these terms lands directly on the canonical answer.

### TERTIARY — Breadth design for iter465

- Re-probe dbt source freshness immediately at iter465 to lock the new content at the 2nd-angle bar.
- Consider one additional non-overlapping angle to verify the iter464 fixes don't crowd out other content. Candidates: Iceberg WAP workflow, Postgres-to-Iceberg JSONB handling, query-perf-regression triage on partition skew, dbt incremental materialization choice.
- **NO dedicated federation probe** — the 4.49944/310 row sits 0.001 below the 4.5 raised threshold; a thin probe in either direction locks or breaks the row.

### Q1 streak continuation

iter463 fabricated-capability-restriction class is FIXED on first re-probe (streak 1 PASS post-fix). To lock the fix across phrasings, iter466+ could probe a different branch/tag angle — e.g., reading from `<table>$refs` metadata table, branch+time-travel interaction, WAP branch read pattern. Not urgent for iter465; the PRIMARY action is the new dbt source freshness content.

---

## Verification log (WebSearch / WebFetch this iter)

- trino.io/docs/current/connector/iceberg.html — `FOR VERSION AS OF '<branch-name>'` and `FOR VERSION AS OF '<tag-name>'` string-literal form documented; BIGINT snapshot_id form also documented.
- iceberg.apache.org/docs/latest/branching/ — "Branching and Tagging" listed under Tables section, catalog-agnostic.
- trinodb/trino #16569 — branch/tag READ via FOR VERSION AS OF '<name>' (Trino 423+).
- trinodb/trino #16570 — branch/tag WRITE closed as NOT PLANNED.
- trino.io/docs/current/sql/analyze.html — bare `ANALYZE table_name` syntax confirmed (no `TABLE` keyword).
- trino.io/docs/current/optimizer/cost-based-optimizations.html — `join_distribution_type` values PARTITIONED/BROADCAST/AUTOMATIC + `join_max_broadcast_table_size` default 100MB.
- docs.getdbt.com/reference/resource-properties/freshness — `loaded_at_field`, `warn_after`, `error_after` schema.
- docs.getdbt.com/docs/deploy/source-freshness — freshness is a separate command, downstream blocking is opt-in via `source_status:fresher+`.
- docs.getdbt.com/reference/commands/source — `dbt source freshness` CLI.
- docs.oracle.com/cd/B19306_01/server.102/b14200/queries006.htm — `(+)` operator semantics, the optional side gets NULLs, restrictions.

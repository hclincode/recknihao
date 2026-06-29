# Judge Feedback — iter1278

**Overall**: 4 answers, average **4.4187 PASS** (Q1 4.4375 / Q2 4.875 / Q3 3.4375 / Q4 4.9375).

Drop from iter1277's 4.844 STRONG PASS is concentrated entirely in **Q3** (dbt_project.yml folder-level materialization). Q1/Q2/Q4 all STRONG PASS individually; Q3 has a real accuracy ding (bare `materialized:` vs required `+materialized:` prefix) and an honest findability hedge that reveals a genuine content gap. NEW SOFT WATCH on Q3 (FIX-A LIGHT warranted, scoped below). One imprecision SOFT WATCH on Q1 (Scheduled-vs-CPU framing as I/O-wait, recurring -0.5 Acc shave across iter1258/iter1273/iter1278 — pattern not regression).

---

## Q1 — Scheduled vs CPU gap on 12-min JOIN (query-perf-basics, thinnest topic): **4.4375 STRONG PASS, thin-topic LIFT (+0.006)**

**What landed correct.** Responder correctly frames the 600s Scheduled vs 20s CPU gap as "the 580s is WAITING not compute" + routes to the right diagnostic levers: (a) `physicalInputDataSize` per-operator metric for actual MinIO bytes; (b) Filter-above-TableScan + missing `constraint=` annotation = partition pruning broke; (c) `SHOW CREATE TABLE` to confirm `partitioning=ARRAY[...]`; (d) `ANALYZE iceberg.analytics.fct_events WITH (columns = ARRAY['event_date','account_id'])` to refresh CBO stats; (e) splitsCreated 10,000+ = small-files → `ALTER TABLE EXECUTE optimize(file_size_threshold => '256MB')`.

**Verified facts**:
- `physicalInputDataSize` per-operator metric — VALID per [trino.io/docs/467/sql/explain-analyze.html](https://trino.io/docs/467/sql/explain-analyze.html) (fragment shows `Physical Input: 4.51MB` verbatim; PR #23874).
- `ANALYZE table WITH (columns = ARRAY[...])` syntax — VALID via WebFetch of [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html): "You can specify a subset of columns to analyzed with the optional `columns` property" + example `ANALYZE table_name WITH (columns = ARRAY['col_1','col_2'])`.
- `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '256MB')` — VALID; documented form is `optimize(file_size_threshold => '128MB')` with default 100MB; raising to 256MB is a legitimate config (PR #24086 + iter1194 pin).
- Filter-above-TableScan + missing-constraint diagnostic — matches iter1258-Q2 textbook signal for pruning-broke.

**PRECISION DING — Scheduled-vs-CPU = I/O-wait interpretation is IMPRECISE (-0.5 Acc)**. Per [Medium "Query Plans — Trino"](https://medium.com/@simon.thelin90/query-plans-analyse-sql-performance-in-trino-97ac1e8f8044) + WebSearch results: the **precise I/O-wait metric is `Blocked` time**, specifically the `Blocked: Input` split (documented at the per-fragment line `Blocked 46.21s (Input: 23.06s, Output: 0.00ns)`). Scheduled time = on-thread time (CPU + scheduled-but-not-blocked waits); CPU time = pure compute. The Scheduled-CPU gap CAN signal blocked time but ALSO captures CPU-queue waits / lock contention / GC pauses — so it's a "warning indicator," not the canonical I/O-wait signal. The cleaner diagnostic route is: **"compute `Blocked: Input` on the stage's TableScan — that's the I/O-wait signal; the Scheduled-CPU delta is a coarser proxy."**

iter1273 + iter1258 both framed Scheduled-vs-CPU as the primary signal and got identical -0.5 Acc shaves (scored 4.625 / 4.6875). Pattern is **established, not a regression** — Haiku consistently routes via Scheduled-CPU rather than Blocked-Input on this thinnest topic. NOT urgent enough to FIX-A on its own, but a LIGHT FIX-A candidate if it recurs once more under "is it I/O bottleneck?" framing.

**Minor Clarity shave (-0.25)**: `splitsCreated` is informal naming — Trino EXPLAIN ANALYZE VERBOSE exposes split-related stats but `splitsCreated` is not the verbatim documented field name (see [trino discussions #17942](https://github.com/trinodb/trino/discussions/17942) on EXPLAIN ANALYZE VERBOSE doc gap). Concept (high split count → small-files → optimize) is correct, name is loose.

**Scores**: Acc 4.5 / Clar 4.25 / Prac 4.75 / Compl 4.25.

**Topic delta**: query-perf-basics 4.1639/43 → 4.1701/44 PASSED (+0.0062, margin +0.6701, REMAINS THINNEST REQUIRED TOPIC, lifts steadily across iter1258/iter1273/iter1276/iter1278).

**NEW SOFT WATCH `iter1278-Q1 Scheduled-vs-CPU-as-I/O-wait imprecision: route to Blocked time explicitly`**: re-probe in 4-8 iters under varied "is it I/O bottleneck" framings; if recurs with same Scheduled-CPU-only routing and no mention of Blocked time, escalate to LIGHT FIX-A canonical at r28 (or r18 EXPLAIN ANALYZE diagnostic section) adding "the `Blocked: Input` metric is the canonical I/O-wait signal; Scheduled-CPU delta is a coarser proxy" + worked disambiguation.

---

## Q2 — JSON per-day grouping in Trino: **4.875 STRONG PASS — all facts verified**

Responder's canonical:
```sql
SELECT json_extract_scalar(properties, '$.plan') AS plan,
       DATE(occurred_at) AS event_date,
       COUNT(*) AS event_count
FROM user_events
GROUP BY 1, 2
```

Plus the key disambiguation: `json_extract_scalar` returns VARCHAR (groupable directly, no CTE needed); `json_extract` returns Trino's `json` type (would type-error in GROUP BY); `CAST(json_extract_scalar AS INTEGER)` / `TRY_CAST` for numeric extraction. Correctly maps Postgres `->`/`->>` to Trino's json_extract / json_extract_scalar split (engineer asked for the Postgres parallel).

**VERIFIED** via WebFetch of [trino.io/docs/467/functions/json.html](https://trino.io/docs/467/functions/json.html): json_extract_scalar verbatim "Like `json_extract()`, but returns the result value as a string (as opposed to being encoded as JSON)" → VARCHAR; json_extract "returns the result as a JSON string" → json type. Consistent with iter1277-Q3 verified canonical.

**Minor Clarity shave (-0.25)**: didn't surface that `DATE(occurred_at)` is partition-pruning-friendly when occurred_at is day-partitioned (via Trino's UnwrapCastInComparison rule per `reference_trino_unwrap_temporal_predicates` pin). **Minor Compl shave (-0.25)**: no NULL-on-missing-path note for events with no 'plan' key; no `json_value` SQL/JSON standard alternative.

**Scores**: Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75.

---

## Q3 — dbt_project.yml folder-level materialization + override precedence: **3.4375 PASS-but-WEAK, ACCURACY DING + CONTENT GAP**

Engineer asked: (a) how to set default materialization for a whole FOLDER in dbt_project.yml + (b) does in-file `{{ config(materialized=...) }}` override folder-level or vice versa?

Responder hedged: "this specific configuration pattern is NOT covered in the resources provided" + gave (from general dbt knowledge) a dbt_project.yml `models:` tree with **BARE `materialized: 'view'` / `materialized: 'table'` / `materialized: 'incremental'`** keys nested by folder; precedence "specific model config > folder config > parent folder config > project default"; in-file `{{ config(materialized='table') }}` OVERRIDES folder-level. Closed with "verify with official docs."

### ACCURACY VERDICT — the `+` prefix IS REQUIRED

**VERIFIED** via WebFetch of [docs.getdbt.com/reference/model-configs](https://docs.getdbt.com/reference/model-configs): canonical example shows `+materialized: view` (WITH `+` prefix) under nested folder keys:

```yaml
models:
  dbt_labs:
    events:
      +enabled: true
      +materialized: view
      base:
        +materialized: ephemeral
```

The `+` prefix indicates these are model-specific configurations being applied at the directory level. **Bare `materialized: table` (without `+`) would not work in this context** — it gets mis-parsed as a folder named 'materialized' under nested-path semantics.

Responder's bare-key YAML is the older / non-recommended form that risks breaking under nested-path semantics. **This is a real accuracy ding.** Engineer who copy-pastes the bare-key form may hit "config not applying / silent ignore" surprise.

### PRECEDENCE VERDICT — responder CORRECT

VERIFIED at same URL: "Model configurations are applied hierarchically... 1. Using `config()` Jinja macro within a model. 2. Using `config` resource property in a `.yml` file. 3. From the project YAML file (`dbt_project.yml`)... the most specific configuration always takes precedence."

Responder's hierarchy is right: in-file `{{ config() }}` OVERRIDES folder-level dbt_project.yml. Minor Compl shave (-0.5): missed the **schema.yml `config:` intermediate layer** (full ladder is in-file config() > schema.yml config: > dbt_project.yml folder > project default).

### CONTENT-GAP / FINDABILITY VERDICT — FIX-A LIGHT WARRANTED, location specified below

**Grep evidence**:
- `+materialized` literal in resources/ → **ZERO matches**.
- `+`-prefix convention IS established in r27 for **adjacent configs**: `+tags` (§3861), `+pre_hook` (§2588), `+grants` (§4115), `+persist_docs` (§4163), `+schema` (§2955 + §4256).
- But the `+`-prefix pattern is NEVER specifically anchored for **materialization** — the existing `materialized: table` references in r27 (§3431, §4330) are all in `models.<name>.config:` schema.yml-style contexts, NOT in dbt_project.yml folder-tree contexts.

The responder's "not covered" hedge is **GENUINE** — this is a real findability + partial-content gap. The responder behaved correctly (hedged-not-fabricated, recommended docs verification) per the established responder-hedge-correct pattern.

### Recommended FIX-A (LIGHT, 15-25 lines)

**Location**: r27 §6.7 (alongside `+persist_docs` at §4148 or `+grants` at §4096) — the dbt configs / hierarchy zone where the `+`-prefix family already lives.

**Title**: "dbt_project.yml folder-level default materialization + config precedence"

**Contents**:
1. Copy-pasteable dbt_project.yml `models:` tree using `+materialized: view` for staging, `+materialized: table` for marts, `+materialized: incremental` for facts (with explicit project-name root):
   ```yaml
   models:
     my_project:
       staging:
         +materialized: view
       marts:
         +materialized: table
       marts:
         facts:
           +materialized: incremental
   ```
2. Explicit "**the `+` prefix is REQUIRED**" callout + WHY (disambiguation from subdirectory names; bare `materialized:` mis-parses as a folder).
3. 4-level precedence ladder: in-file `{{ config() }}` > schema.yml `config:` > dbt_project.yml nested-deepest > project default. Verified vs [docs.getdbt.com/reference/model-configs](https://docs.getdbt.com/reference/model-configs).
4. Worked example: folder default `+materialized: incremental` overridden by `{{ config(materialized='table') }}` for `dim_customers.sql` — engineer's exact case from the question.
5. DO-NOT-WRITE: bare `materialized: table` under nested folder keys (silent-ignore surprise).

**Scores**: Acc 3.0 / Clar 4.5 / Prac 3.5 / Compl 2.75.

**Topic delta**: Oracle PL/SQL → dbt+Trino migration 4.5123/246 → 4.5079/247 PASSED (-0.0044, margin +1.0079).

**NEW SOFT WATCH `iter1278-Q3 dbt_project.yml +materialized folder-level canonical + precedence ladder FIX-A reach-test`**: re-probe in 2-4 iters under varied folder-level-default framings to confirm FIX-A landed and `+`-prefix form lands without bare-key regression.

---

## Q4 — Oracle SUBSTR(s,-5) negative index → Trino: **4.9375 STRONG PASS — assumed-absence CORRECT this time**

Responder: "Trino SUBSTR supports negative indices EXACTLY like Oracle — no rewrite. SUBSTR(s,-5)=last 5 chars; SUBSTR('HelloWorld',-5)='World'; SUBSTR(s,1,5)=first 5"; both 1-indexed (pos 1 = first char); negative start counts from end; "**NO RIGHT()/LEFT() in Trino** — use SUBSTR(s,-n) / SUBSTR(s,1,n)"; optional length param.

**VERIFIED** via WebFetch of [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html):
- (a) Negative start position: "A negative starting position is interpreted as being relative to the end of the string" verbatim — applies to both `substr` and `substring`, both 1-arg and 2-arg variants. Oracle parity confirmed.
- (b) **LEFT() / RIGHT() — NEITHER listed in Trino 467 string-functions list**. The assumed-absence claim holds. This is the **rare correct assumed-absence call** — historical responder pattern has been to FALSELY claim absence for funcs that ARE in Trino (starts_with, to_char, listagg, array_sum, format_number, migrate, LATERAL — 8th+ instances per memory pins); here the absence is genuine. Engineer can confidently ship `SUBSTR(s, -n)` as the canonical "last N chars" Trino form.
- (c) 1-based indexing standard Trino behavior — confirmed.

**Minor Compl shave (-0.25)**: didn't mention `SUBSTR(s, -n, len)` negative-start + length combo also works (e.g., `SUBSTR(s, -5, 3)` = 3 chars starting 5 from end). Engineer's Oracle migration corner cases not all covered.

**Scores**: Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 4.75.

---

## Answers to the explicit verification asks

**(1) Q1 — Scheduled-vs-CPU = I/O-wait interpretation accuracy?** **IMPRECISE, not factually wrong.** The precise Trino I/O-wait metric is **`Blocked` time** (specifically the `Blocked: Input` per-fragment split, e.g., `Blocked 46.21s (Input: 23.06s, Output: 0.00ns)`). The Scheduled-CPU gap is a coarser proxy that ALSO captures CPU-queue waits / lock contention / GC pauses, not exclusively I/O wait. Responder's framing is directionally right (gap = waiting, not compute) but skips the canonical Blocked-Input route. -0.5 Acc shave applied; pattern recurring across iter1258/iter1273/iter1278 (3 instances) — NEW SOFT WATCH set, NOT urgent enough to FIX-A on its own yet.

**(2) Q3 — is `+materialized` prefix REQUIRED (and is there a genuine CONTENT GAP)?**

(a) **YES, `+` prefix is REQUIRED** per WebFetch of [docs.getdbt.com/reference/model-configs](https://docs.getdbt.com/reference/model-configs): canonical shows `+materialized: view` (not bare). Bare-key at folder-tree level is mis-parsed as a folder name. Responder's bare-key YAML is an ACCURACY DING.

(b) **PRECEDENCE — responder CORRECT**: in-file `{{ config() }}` OVERRIDES folder-level dbt_project.yml ("most specific configuration always takes precedence" verbatim from docs). Minor compl ding: missed the schema.yml `config:` intermediate layer in the full 4-level ladder.

(c) **CONTENT GAP — GENUINE, FIX-A LIGHT WARRANTED**: grep of resources/ shows ZERO `+materialized` literals; the `+`-prefix convention is established in r27 for `+tags`/`+pre_hook`/`+grants`/`+persist_docs`/`+schema` but NEVER for materialization specifically. Recommended location: r27 §6.7 (alongside §6.7J `+persist_docs` at §4148), 15-25 line canonical with `+materialized` folder-tree example + "the `+` prefix is REQUIRED" callout + 4-level precedence ladder + worked override example. See Q3 section above for full FIX-A scope.

**(3) Q4 — Trino SUBSTR negative + LEFT/RIGHT?** **BOTH responder claims CORRECT.**
(a) Trino 467 SUBSTR supports negative start position (counts from end of string) per [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html): "A negative starting position is interpreted as being relative to the end of the string" verbatim. Oracle migration zero-rewrite confirmed.
(b) NO LEFT() / RIGHT() in Trino 467 (assumed-absence holds this time — rare correct call in a historically-wrong-direction family).
(c) 1-based indexing confirmed.

**(4) New watches / recommended FIX-A**:
- **NEW SOFT WATCH `iter1278-Q1 Scheduled-vs-CPU-as-I/O-wait imprecision`** (re-probe 4-8 iters; LIGHT FIX-A if recurs to add Blocked-Input canonical at r28).
- **NEW SOFT WATCH `iter1278-Q3 dbt_project.yml +materialized folder-level canonical + precedence ladder FIX-A reach-test`** (re-probe 2-4 iters after FIX-A lands).
- **RECOMMENDED FIX-A LIGHT (this iter)**: r27 §6.7, 15-25 line canonical for dbt_project.yml folder-level `+materialized` + 4-level precedence ladder (scope detailed in Q3 section).

---

## Topic deltas this iteration

| Topic | Before | After | Delta |
|---|---|---|---|
| Query performance basics (Q1) | 4.1639/43 | 4.1701/44 | +0.0062 (REMAINS THINNEST) |
| SQL best practices OLAP (Q2 + Q4) | 4.5885/298 | 4.5906/300 | +0.0021 net |
| Oracle PL/SQL → dbt+Trino (Q3) | 4.5123/246 | 4.5079/247 | -0.0044 |

Continuous PASS streak intact (margins +0.67 / +1.09 / +1.01 well above 3.5 threshold). No critical regressions. Q3 -0.0044 drag is the first sub-4.0 single-Q score in many iterations; FIX-A LIGHT recommended to restore on next sweep.

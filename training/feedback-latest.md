# Judge Feedback — Iteration 1281

**Overall**: 4 questions, average **3.22 FAIL** (Q1 3.125 / Q2 3.125 / Q3 2.875 / Q4 3.75). **Biggest single-iteration drop in many sweeps.** Three of four questions below the 3.5 pass threshold. Two HEDGES (Q1, Q3) are NOT pure-recall ceilings — both confirm as **findability/framing gaps** where canonical content EXISTS but the keyword routing doesn't reach it. One broken example (Q2), one backwards rule (Q4).

**Headline results**:
1. **Q1 — FINDABILITY GAP confirmed.** Responder HEDGED on `system.runtime.queries`/`tasks` when r16 §295 AND r18 §404 both have full top-N-expensive-queries recipes — both framed as "expensive query / cost" not "cluster sluggish / hammering / longest-running / triage". FIX-A required.
2. **Q2 — Per-instance responder slip.** UNNEST mechanism correct, JSON-string variant correct, but the worked example `SELECT e.event_id, t.tag ... GROUP BY t.tag` violates Trino GROUP BY (e.event_id neither grouped nor aggregated → analysis error). r07 §1a's source example is correct (no GROUP BY there) and r07 §4's split-and-count example is correct (proper `SELECT t.tag, COUNT(*) ... GROUP BY t.tag`). Responder mashed two patterns. NO FIX-A — broken-secondary-alternative family, per-instance.
3. **Q3 — FINDABILITY GAP confirmed (partial-content variant).** r27 §6.7M generate_schema_name canonical exists with dev/staging/prod mention + `dbt run --target` reference, but framed as ADVANCED schema-name-macro override ("targets clobber each other"). r27 §2519 profiles.yml canonical only shows ONE output (prod). The BASIC "two outputs: dev + prod with different schemas + default `target:` + `dbt run --target dev`" question doesn't route to either section's keyword zone. FIX-A required.
4. **Q4 — Backwards rule, SQL conversions correct.** Responder stated rule: "(+) appears on the table that should be the OUTER table (the one that keeps all its rows)" — Oracle (+) actually marks the OPTIONAL / null-supplying side; the table WITHOUT (+) is preserved. Yet the worked SQL conversions land correctly (`a.id=b.id(+)` → `accounts LEFT JOIN orders`; `a.id(+)=b.id` → `accounts RIGHT JOIN orders`). r27 L1755 has ONE example, no prose rule — backwards rule is a responder paraphrase slip, not resource-sourced. LIGHT FIX-A recommended (add one-line correct rule statement + second-variation example).

---

## Q1 — Find top resource-consuming queries (cluster sluggish, longest-running, most data read)

**Score: Acc 3.5 / Clar 4.0 / Prac 2.5 / Compl 2.5 = 3.125 FAIL**

**Topic scored under**: "Query performance regression diagnosis: oncall workflow for slow queries" (4.3436/21 → 4.2882/22).

### Verification — system.runtime.queries+tasks recipe is VALID Trino 467

WebFetch of [trino.io/docs/467/connector/system.html](https://trino.io/docs/467/connector/system.html) describes the tables but does not enumerate columns. **Authoritative column reference** is in iter1141-pinned `system.runtime.queries`/`tasks` content (r18 §410-454 + r16 §270-282 DO-NOT-WRITE matrix), which has been validated against `QuerySystemTable.java` source on multiple prior iterations:

- `system.runtime.queries` (15-min ephemeral, ~100 query ring buffer): `query_id`, `state`, `"user"` (double-quoted; bare `user` returns current_user), `source`, `query`, `resource_group_id`, `created`, `started`, `last_heartbeat`, `end`, `error_type`, `error_code`. NO `catalog`, NO `schema`, NO `peak_memory_bytes`, NO `cost_usd`.
- `system.runtime.tasks`: `query_id`, `task_id`, `stage_id`, `state`, `split_cpu_time_ms` (NOT `cpu_time_ms`), `physical_input_bytes` (added Trino release 330, per iter1141 pin), `processed_input_bytes`, `output_bytes`, `output_rows`, `splits`, `created`, `start`, `end`.

Canonical Q1 answer (already in r16 §301-323 + r18 §456-498):
```sql
SELECT q.query_id, q.state, q."user", q.source,
       substr(q.query, 1, 200) AS sql_preview,
       SUM(t.split_cpu_time_ms) / 1000.0  AS total_cpu_sec,
       SUM(t.physical_input_bytes) / 1e9   AS gb_scanned,
       COUNT(t.task_id) AS task_count
FROM system.runtime.queries q
LEFT JOIN system.runtime.tasks t ON t.query_id = q.query_id
WHERE q.created > current_timestamp - INTERVAL '15' MINUTE
GROUP BY q.query_id, q.state, q."user", q.source, q.query
ORDER BY total_cpu_sec DESC
LIMIT 20;
```

### Findability gap CONFIRMED via Grep

Grep `system.runtime.queries|find.*heavy queries|top.*resource-consuming|cluster slow|hammering|sluggish` across resources → **only `system.runtime.queries` matches** (in r16, r18). No hits on "cluster sluggish", "queries hammering", "longest-running", "top resource-consuming", "before adding hardware" — the exact phrases the engineer used.

- **r16 §295** canonical heading: *"How do I find the most expensive single Trino queries (by CPU and bytes scanned) in the last 15 minutes?"* — keyword anchors all cost/expensive-framed.
- **r18 §404** section heading: *"Finding expensive queries on Trino 467 (verified SQL recipes)"* — Recipe 1 = "Top 50 most expensive queries by bytes scanned". Keyword anchor again "expensive query / cost".

Responder pattern-matched the perf-triage framing ("cluster sluggish during business hours / hammering / before adding hardware") and didn't route to either section. HEDGED + pivoted to `EXPLAIN ANALYZE` (which only diagnoses ONE already-running query at the operator level, NOT "which queries are heavy right now" — engineer needs to identify the heavy queries first BEFORE running EXPLAIN ANALYZE on them). The answer fails the practical test: the engineer cannot identify what to investigate next.

### FIX-A — perf-triage routing anchors at r18 §404 and r16 §295 (mirrored)

**Primary location: r18 §404** (the perf-regression file is the more natural keyword landing for "cluster slow / heavy queries" phrasings):

Add a `> **READ THIS FIRST** if your question contains any of these phrases` anchor block at the top of §404, immediately before "Finding expensive queries on Trino 467", listing:
- "cluster sluggish", "cluster slow during business hours", "Trino is slow"
- "queries hammering the cluster", "what's hammering my cluster"
- "find the heavy queries", "find the heaviest queries", "top resource-consuming queries"
- "longest-running queries", "queries reading the most data", "most data scanned"
- "find slow queries on a live cluster", "find the bad query right now"
- "before adding hardware", "before scaling the cluster", "before throwing hardware at it"
- "queries to kill", "queries to optimize first", "Trino system tables for slow queries"
- "which Trino system tables", "system.runtime tables", "system.runtime.queries", "system.runtime.tasks"

**Secondary mirror: r16 §295** — append the same perf-triage anchors to the existing keyword block (the recipe is already there; only the routing is broken).

This is a **routing-only FIX-A** (no recipe rewrite). The system.runtime.queries+tasks recipe in both files is already correct, exhaustively defanged, and column-verified.

---

## Q2 — UNNEST array column to count events per tag

**Score: Acc 2.5 / Clar 4.0 / Prac 2.5 / Compl 3.5 = 3.125 FAIL**

**Topic scored under**: "Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL" (4.4836/204 → 4.4770/205).

### What the responder said vs. what the resource teaches

**Responder's worked example (broken)**:
```sql
SELECT e.event_id, t.tag
FROM events e
CROSS JOIN UNNEST(e.tags) AS t(tag)
GROUP BY t.tag
ORDER BY COUNT(*) DESC;
```
This is **not valid Trino SQL** — `e.event_id` appears in the SELECT list but is neither in `GROUP BY` nor inside an aggregate. Trino 467 analysis error: `Column 'event_id' must appear in the GROUP BY clause or be used in an aggregation function`. Engineer copying this hits a hard analysis-time failure.

**The correct query for "count events per tag"**:
```sql
SELECT t.tag, COUNT(*) AS n
FROM events e
CROSS JOIN UNNEST(e.tags) AS t(tag)
GROUP BY t.tag
ORDER BY n DESC;
```

### r07 source check — resource is NOT broken; responder slip

**Grep r07 §1a (L84-108)** — the cited section — shows the EXPLODE form ONLY, no GROUP BY:
```sql
SELECT u.user_id, t.tag
FROM iceberg.analytics.users u
CROSS JOIN UNNEST(u.tags) AS t(tag);
```
This is one-row-per-(parent, element) explode — correct shape, no aggregation.

**Grep r07 §4 (L405, L420, L437)** — split-then-count examples are correct: `SELECT TRIM(tag) AS tag, COUNT(*) AS n ... GROUP BY TRIM(tag)`.

The responder kept the §1a `SELECT e.event_id, t.tag` head and welded on a §4-style `GROUP BY t.tag ORDER BY COUNT(*) DESC` tail. **Both source forms are individually correct**; the mash-up is a responder-side synthesis slip.

**Classification**: Per pinned `feedback_responder_broken_secondary_alternative.md` — Haiku often appends a broken "for completeness" alternative form. Here it's the MAIN example, not a secondary, which makes the slip more harmful, but the recall ceiling is the same. No single resource fix would prevent this.

**NO FIX-A.** Per-instance responder synthesis slip. Carry as soft watch `iter1281-Q2 UNNEST-GROUP-BY-column-not-in-list`: re-probe in 4-8 iters under different "UNNEST + GROUP BY + count per element" phrasings; if 2+ recurrences, consider a worked "count per tag" canonical example with explicit "SELECT tag, COUNT(*) — do NOT include event_id in SELECT" defang at r07 §1a.

### Mechanism portion was correct

- `CROSS JOIN UNNEST(arr) AS t(elem)` = INNER semantics, drops NULL/empty-array parents — verified at [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html).
- `LEFT JOIN UNNEST(arr) AS t(elem) ON TRUE` = preserves NULL/empty-array parents — also verified.
- JSON-string variant `CROSS JOIN UNNEST(CAST(json_parse(col) AS ARRAY(VARCHAR)))` for varchar-holding-JSON columns — correct (r07 §1a L118).

The mechanism explanation would earn 4.5+ if standalone. The broken main example drops it to 3.125.

---

## Q3 — dbt dev vs prod: separate schema so a laptop run doesn't overwrite prod

**Score: Acc 3.5 / Clar 4.0 / Prac 2.0 / Compl 2.0 = 2.875 FAIL**

**Topic scored under**: "Oracle PL/SQL procedure → dbt + Trino SQL migration" (4.5070/249 → 4.5005/250 after this question; canonical r27 dbt-OPS content lives there).

### What the responder did

HEDGED — *"I don't have enough info; the resources don't document dev/prod environments via profiles.yml / target schemas."* Deferred to dbt docs.

### Verification — content EXISTS but framing doesn't route from "dev vs prod" question shape

**Grep `generate_schema_name|dev vs prod|separate schema|dbt target|outputs:` on r27 confirms**:

- **r27 §2519-2542** has a profiles.yml canonical with `env_var()` + `DBT_ENV_SECRET_` secrets handling. **Shows only ONE output (`prod`)**. L2565 mentions "env-specific connection params (host, catalog, schema per dev/staging/prod)" in passing. NO two-target example, NO `dbt run --target dev` walkthrough.

- **r27 §6.7M (L4315-4367)** is the `generate_schema_name` macro canonical:
  - L4317 keyword anchors: *"dbt dev/staging/prod all land in the same schema / overwrite each other; want dev → dev_analytics, staging → staging_analytics, prod → analytics; per-environment schema; per-developer schema so devs don't clobber each other; generate_schema_name macro... control target schema by environment on dbt-trino."*
  - L4352 mentions `dbt run --target dev|staging|prod` (one inline reference, not a worked walkthrough).
  - L4354 `generate_schema_name_for_env` shortcut.
  - L4365 DO-NOT-WRITE for the "every env writes to same schema" footgun.

**The framing problem.** §6.7M is correct but framed around the ADVANCED schema-name-macro override case ("you tried multi-env and they're all landing in the same Trino schema — write a macro to fix it"). The BEGINNER question ("how do I set up dev vs prod in the first place so a laptop run writes to a separate schema?") doesn't match those anchors. The responder pattern-matched "dbt dev vs prod / separate schema / scared of overwriting prod / where to configure" and found no direct keyword hit.

**Missing keyword anchors at §6.7M (and the absent §2519.X two-target intro canonical)**:
- "dev vs prod" (plain, not "dev/staging/prod")
- "don't overwrite production"
- "scared of overwriting prod"
- "safe local dbt run"
- "run dbt on my laptop safely"
- "dbt environments setup"
- "dbt profiles dev"
- "team running same prod catalog"
- "personal dev schema"
- "default target dev not prod"

**Verified via WebSearch** of [docs.getdbt.com](https://docs.getdbt.com) ("About profiles.yml", "Connection profiles"): the canonical dbt pattern is exactly what the engineer needs — multiple outputs in one profile, separate schemas, `--target` flag override, `dbt_<username>` dev-schema convention. The fact IS in r27 §6.7M but routed only from the "schemas-clobber-each-other" symptom shape, not the "set up dev vs prod from scratch" shape.

### FIX-A — add a leading "dbt dev vs prod target separation" canonical near r27 §2519

**Recommended location**: NEW section §2519.X (or §2518.5) placed BEFORE the existing §2519 secrets canonical. This is the first dbt-OPS question a beginner asks; secrets come second.

**Recommended content (sketch)**:

> ### LEADING CANONICAL — dbt dev vs prod target separation — two outputs in profiles.yml so a laptop run writes to a SEPARATE schema (the "team scared of overwriting prod" fix)
>
> **READ THIS FIRST if your question contains any of these phrases:** dbt dev vs prod, set up dbt environments, run dbt on my laptop safely, separate schema for local dev, don't overwrite production, scared of overwriting prod, dbt profiles dev, two targets in profiles.yml, team running against same prod catalog, personal dev schema, default target dev not prod, dbt run --target, dbt --target flag, dbt environment variable for target, where to configure dev vs prod, dbt local-vs-prod safety.
>
> **The one fact.** `profiles.yml` supports MULTIPLE `outputs:` under one profile; each output is a "target" with its own connection params + schema. `target:` declares the DEFAULT target for that profile (set it to `dev` so a bare `dbt run` on a laptop NEVER writes to prod). `dbt run --target prod` explicitly opts in to prod. Local devs get a personal schema like `dbt_<username>` per dbt-Labs convention.
>
> ```yaml
> my_project:
>   target: dev          # SAFE default: bare `dbt run` writes to dev, never prod
>   outputs:
>     dev:
>       type: trino
>       host: trino.internal
>       user: "{{ env_var('TRINO_USER') }}"
>       password: "{{ env_var('DBT_ENV_SECRET_TRINO_PASSWORD') }}"
>       catalog: iceberg
>       schema: dbt_alice            # personal/dev schema — never collides with prod or teammates
>       threads: 4
>     prod:
>       type: trino
>       host: trino.internal
>       user: "{{ env_var('TRINO_USER') }}"
>       password: "{{ env_var('DBT_ENV_SECRET_TRINO_PROD_PASSWORD') }}"
>       catalog: iceberg
>       schema: analytics            # production schema — only CI/runbook writes here via --target prod
>       threads: 8
> ```
>
> ```bash
> dbt run                       # uses target: dev → writes to iceberg.dbt_alice.<model>
> dbt run --target prod         # explicit opt-in → writes to iceberg.analytics.<model>
> ```
>
> **Verified at [docs.getdbt.com/docs/core/connection-profiles](https://docs.getdbt.com/docs/core/connection-profiles)**: "dbt supports multiple targets within one profile to encourage the use of separate development and production environments... In development, a pattern we've found to work well is to name the schema in your dev target `dbt_<username>`."
>
> **For 3+ environments with systematic naming (`dev_analytics` / `staging_analytics` / `analytics`):** see §6.7M `generate_schema_name` macro override — a more advanced solution that derives the prefix from `target.name` so each developer uses the same project but lands in a different schema.

**Anchors must be exhaustive** — phrase mining from this question alone:
- "dev vs prod", "set up dev and prod", "dev/prod environments"
- "scared of overwriting prod", "scared a local run will overwrite production"
- "separate schema for dev", "personal schema", "laptop schema"
- "dbt profiles dev prod", "two outputs in profiles.yml"
- "where do I configure dev vs prod"
- "team running dbt against prod catalog"

**Cross-ref**: §6.7M `generate_schema_name` macro (advanced multi-env case + per-developer auto-prefix); §2519 secrets canonical (the `env_var` and `DBT_ENV_SECRET_` mechanics, sibling concern).

**Why NOT just expand §6.7M anchors**: §6.7M's title and framing are inseparable from the "schemas-clobber-each-other" diagnostic shape (the macro IS the fix for that specific symptom). A beginner's "set up dev vs prod safely" question deserves its own LEADING CANONICAL with a clean two-target example BEFORE the macro override. Routing both shapes to §6.7M alone overloads it.

---

## Q4 — Oracle `(+)` outer join → Trino ANSI

**Score: Acc 3.0 / Clar 4.0 / Prac 4.0 / Compl 4.0 = 3.75 PASS**

**Topic scored under**: "Oracle PL/SQL procedure → dbt + Trino SQL migration" (4.5005/250 → 4.4975/251 after this question; same topic as Q3).

### Backwards rule — verified

**Responder's stated rule**: *"the `(+)` appears on the table that should be the OUTER table (the one that keeps all its rows)."*

**Oracle's actual rule** (verified via WebSearch of [Oracle Database 10g Joins docs](https://docs.oracle.com/cd/B19306_01/server.102/b14200/queries006.htm) + [Oracle Optimizer blog: Outerjoins in Oracle](https://blogs.oracle.com/optimizer/outerjoins-in-oracle)):

> *"The (+) marker is placed on the column(s) from the table that is OPTIONAL (the side that may fail to match)... If `table2.col(+)` appears, then `table2` is OPTIONAL and the query behaves like a LEFT OUTER JOIN from table1 to table2. If `table1.col(+)` appears, then `table1` is OPTIONAL and the query behaves like a RIGHT OUTER JOIN from table1 to table2."*

So **the (+) is on the NULL-supplying / optional / "may fail to match" side; the table WITHOUT the (+) is the one whose rows are all PRESERVED**. The responder's rule is exactly inverted.

### Yet the SQL conversions land correctly

- `WHERE a.id = b.account_id(+)` → `accounts a LEFT JOIN orders b ON a.id = b.account_id` ✓ (accounts is preserved, b is optional)
- `WHERE a.id(+) = b.account_id` → `orders b LEFT JOIN accounts a ON a.id = b.account_id` ≡ `accounts a RIGHT JOIN orders b ON a.id = b.account_id` ✓ (orders is preserved, a is optional)

The responder labeled "(+) on b, so orders is outer table" / "(+) on a, so a is outer / accounts is outer" — terminology backwards (the no-(+) side is the preserved/outer-input side). But the actual SQL the engineer would copy matches Oracle's behavior. **A reader who copies the SQL is fine; a reader who internalizes the rule and applies it to a novel 3-table case will invert the join direction.**

### r27 L1755 source check — backwards rule is NOT resource-sourced

```
| `SELECT ... FROM a, b WHERE a.id = b.id(+)` (Oracle outer-join) | `SELECT ... FROM a LEFT JOIN b ON a.id = b.id` | ANSI JOIN syntax; Oracle `(+)` is parse error in Trino. |
```

r27 §4.5 L1755 shows ONE example pair, no prose rule, no second variation (`a.id(+) = b.id` → `a RIGHT JOIN b`). The backwards rule the responder gave is a **paraphrase invented during answer assembly**, not lifted from the resource.

### LIGHT FIX-A — add explicit rule + second variation at r27 §4.5 L1755

Suggest a 2-3 line addition to the L1755 row's "Notes" column (or a follow-up bullet block beneath the table):

> **The rule (memorize this — engineers paraphrase it backwards constantly):** `(+)` marks the **OPTIONAL / null-supplying side** (the side that MAY fail to match). The table **WITHOUT** `(+)` is the one whose rows are **PRESERVED**.
>
> | Oracle form | Trino ANSI rewrite | Who is preserved |
> |---|---|---|
> | `WHERE a.id = b.id(+)` | `a LEFT JOIN b ON a.id = b.id` | `a` (no `(+)` on `a.id`) |
> | `WHERE a.id(+) = b.id` | `a RIGHT JOIN b ON a.id = b.id`  (or equivalently `b LEFT JOIN a`) | `b` (no `(+)` on `b.id`) |
> | `WHERE a.id(+) = b.id(+)` | `a FULL OUTER JOIN b ON a.id = b.id` | both (each side has its own `(+)`) |
>
> **DO-NOT-WRITE — backwards paraphrase that engineers reflexively give:** *"`(+)` appears on the OUTER table / the table that keeps all its rows."* That is **EXACTLY INVERTED**. The `(+)`-marked side is the one that may CONTRIBUTE NULL rows; the un-marked side is the preserved/outer-input side. Use the table above, not the paraphrase.
>
> **Multi-condition restriction (Oracle gotcha worth preserving):** If `a` and `b` are joined by multiple conditions, ALL of them must carry `(+)` on the same side, or Oracle silently degrades to an inner join. The ANSI rewrite makes this explicit in the `ON` clause.

**Anchors to add**: "(+) outer join", "Oracle plus sign outer join", "Oracle (+) syntax", "convert Oracle outer join", "which side is outer Oracle (+)", "Oracle proprietary outer join Trino", "FULL OUTER (+) both sides".

This is a small additive defang (the row already exists; the rule prose + second-variation row + DO-NOT-WRITE backwards-paraphrase callout are the additions). Verify via grep that the backwards paraphrase isn't already present elsewhere before adding the defang (likely a clean addition).

---

## Findability/content gap summary (RECOMMENDED FIX-A actions)

| # | Q | Type | Location | Estimated effort |
|---|---|---|---|---|
| 1 | Q1 | Routing-only (anchors) | **r18 §404 (primary)** + **r16 §295 (mirror)** — perf-triage keyword anchors above the existing recipes | LIGHT — 15-25 lines of anchor blocks |
| 2 | Q3 | New leading canonical | **r27 NEW §2519.X** (before existing §2519 secrets canonical) — two-output profiles.yml + `--target` flag + dev/prod schemas + cross-ref to §6.7M | MEDIUM — ~50-80 lines including anchors, code block, DO-NOT-WRITE, cross-refs |
| 3 | Q4 | Small additive defang | **r27 §4.5 L1755** — correct rule prose + second-variation row + backwards-paraphrase DO-NOT-WRITE | LIGHT — 10-15 lines additive to existing table row |

**Q2 — NO FIX-A** (per-instance responder synthesis slip; both r07 §1a explode form and §4 split-and-count form are individually correct).

---

## Watches

**NEW HARD WATCH `iter1281-Q1 system.runtime perf-triage findability gap`**: re-probe within 2-3 iters under "find heaviest queries / which queries are hammering the cluster / cluster slow how do I find the bad queries" framings. After FIX-A, responder should route directly to r18 §404 recipe (Recipe 1 by bytes scanned + Recipe 2 by frequency) and produce the `system.runtime.queries JOIN system.runtime.tasks ON query_id` recipe with `split_cpu_time_ms` + `physical_input_bytes` columns. If hedge recurs, escalate (add a top-of-file callout in r18, or duplicate the recipe into a separate "find the bad query" leading canonical).

**NEW HARD WATCH `iter1281-Q3 dbt dev-vs-prod target-separation findability gap`**: re-probe within 2-3 iters under "set up dev environment for dbt / how do I keep my laptop runs from overwriting prod / two targets in profiles.yml" framings. After FIX-A, responder should produce the two-output profiles.yml example + `target: dev` default + `dbt run --target prod` opt-in walkthrough. If hedge recurs, escalate (mirror the canonical into the §6.7M anchor block or hoist to r28 dbt-OPS section).

**NEW LIGHT WATCH `iter1281-Q4 Oracle (+) backwards-rule paraphrase`**: re-probe within 4-6 iters under "Oracle (+) outer join convert / which side is outer in a.id=b.id(+)" framings. After LIGHT FIX-A, responder should give the correct "(+) marks optional / no-(+) side is preserved" rule. If backwards rule recurs even with FIX-A in place, treat as recall-ceiling and add a more aggressive top-of-§4.5 callout.

**NEW SOFT WATCH `iter1281-Q2 UNNEST SELECT-col-not-in-GROUP-BY synthesis slip`** (broken-secondary-alternative family per pinned `feedback_responder_broken_secondary_alternative.md`): re-probe in 4-8 iters under "count events per tag / per-tag aggregate after UNNEST" framings. Per-instance, **NO RESOURCE FIX** unless 2+ recurrences with the same exact shape, at which point consider a worked "count per tag" canonical at r07 §1a with explicit "drop parent columns from SELECT" defang.

**Carry from iter1280**: `iter1280-Q1 MUST-use-Spark paraphrase-slip-vs-r10-§125-defang` (re-probe 3-7 more); `iter1280-Q2 DECIMAL-SUM-scale-preserved mechanism-conclusion slip` (re-probe 3-7 more).
**Carry from iter1278/1279**: `iter1278-Q1 Scheduled-vs-Blocked imprecision` (re-probe 2-6); `iter1279-Q4 now()-alias` (re-probe 3-7).

---

## Rubric score updates

| Topic | Before | This iter | After | Margin |
|---|---|---|---|---|
| Query performance regression diagnosis (Q1) | 4.3436 / 21 | +3.125 | **4.2882 / 22** | +0.7882 (-0.0554 this iter — biggest single-iter drop on this thin topic) |
| Analytical query patterns on Iceberg+Trino (Q2) | 4.4836 / 204 | +3.125 | **4.4770 / 205** | +0.9770 (-0.0066) |
| Oracle PL/SQL → dbt+Trino migration (Q3+Q4) | 4.5070 / 249 | +2.875, +3.75 | **4.4975 / 251** | +0.9975 (-0.0095) |

All topics remain PASSED (no topic fell below threshold), but **Query performance regression diagnosis** absorbed a meaningful drag (-0.0554) and now sits at 4.2882 — close to (but not crossing) the 4.0 informal "thin-topic re-watch" floor. The FIX-A for Q1 routing should lift this back on the next re-probe.

**Iteration overall: 3.22 FAIL** — three of four questions below threshold. Two findability/framing gaps + one broken example + one backwards rule prose. NOT a knowledge gap on the part of the resources (all four answers EXIST in `resources/` or are derivable from it); a routing + synthesis-precision gap.

---

## Sources

- [trino.io/docs/467/connector/system.html](https://trino.io/docs/467/connector/system.html) — system tables (Q1)
- [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) — UNNEST semantics (Q2)
- [docs.getdbt.com/docs/core/connection-profiles](https://docs.getdbt.com/docs/core/connection-profiles) — multiple targets, --target flag (Q3)
- [docs.getdbt.com/docs/build/custom-schemas](https://docs.getdbt.com/docs/build/custom-schemas) — generate_schema_name (Q3 cross-ref)
- [docs.oracle.com/cd/B19306_01/server.102/b14200/queries006.htm](https://docs.oracle.com/cd/B19306_01/server.102/b14200/queries006.htm) — Oracle (+) outer-join semantics (Q4)
- [blogs.oracle.com/optimizer/outerjoins-in-oracle](https://blogs.oracle.com/optimizer/outerjoins-in-oracle) — Oracle Optimizer team confirmation of "(+) on the optional side" (Q4)

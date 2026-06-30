# Judge Feedback — Iteration 1285

**Overall**: 4 questions, average **4.359 PASS** (Q1 4.875 STRONG / Q2 3.50 PASS-borderline / Q3 4.125 PASS / Q4 4.9375 STRONG).

**Headline**: Q1 + Q4 are clean strong passes. Q2 has a SUBTLE BUT REAL accuracy slip on TIMESTAMP→TZ tagging (the "CAST = UTC assumption" framing). Q3 reproduces the **iter1208 dbt-selector-direction WATCH** — and this time the wrong selector is sitting verbatim in r27 §6.7H2 L4135 of the resource itself, so it's now a RESOURCE DEFECT, not just a responder slip.

| Q | Topic | Score | Status | Verdict |
|---|---|---|---|---|
| Q1 Iceberg time-travel revenue-bug recovery | Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup | 4.875 | STRONG PASS | $snapshots / FOR TIMESTAMP AS OF / FOR VERSION AS OF / whole-token quoting all correct |
| Q2 mixed TIMESTAMP vs TIMESTAMP WITH TIME ZONE date_diff | SQL query best practices for OLAP | 3.50 | PASS-borderline | Implicit coercion claim correct; "CAST = UTC" is SUBTLY WRONG (CAST attaches SESSION zone, not UTC); session-zone caveat omitted; r22 §2A.3 canonical not reached |
| Q3 dbt exposures for 40-model project | Improving complex SQL perf on Trino with dbt | 4.125 | PASS | Exposures shape / types / lineage / selective build all correct; impact-analysis selector direction WRONG (leading + = ancestors; should be trailing + for descendants) — copied verbatim from r27 §6.7H2 L4135 RESOURCE DEFECT |
| Q4 Oracle TRUNC(date) → Trino | Oracle PL/SQL → dbt + Trino SQL migration | 4.9375 | STRONG PASS | date_trunc('day', ts), unit table, TS→TIMESTAMP return-type diff, AT TIME ZONE for local-date grouping all correct |

---

## Q1 — Iceberg time-travel on bad-deploy revenue rows (4.875 STRONG PASS)

**Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 4.5.**

Responder gave the canonical full workflow:
1. **`FOR TIMESTAMP AS OF TIMESTAMP '2026-06-20 10:00:00 UTC'`** — wall-clock entry point. Verified valid Trino 467 syntax against [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html).
2. **`SELECT snapshot_id, committed_at, operation, summary FROM "orders$snapshots" ORDER BY committed_at`** — discovery query with whole-token quoting `"orders$snapshots"` (single quote pair around the whole token, the split-pair form `"orders"$snapshots` is a parse error). $snapshots column list matches docs: `committed_at TIMESTAMP(3) WITH TIME ZONE`, `snapshot_id BIGINT`, `parent_id BIGINT`, `operation VARCHAR`, `manifest_list VARCHAR`, `summary map(VARCHAR,VARCHAR)`.
3. **`FOR VERSION AS OF <bigint snapshot_id>`** — exact-reproducibility form for the pre-bad-deploy snapshot once identified.

All three load-bearing facts source-verified. Minor Compl shave (-0.5): didn't mention the 7-day default `expire_snapshots` retention floor (`iceberg.expire-snapshots.min-retention`) — last Tuesday was 8 days ago given today's date, so if the table has had `expire_snapshots(retention_threshold => '7d')` run since then, the snapshot may be gone. A one-line "verify the snapshot still exists in `$snapshots` before assuming you can travel back" would close this. Not load-bearing — the responder's workflow is paste-and-run for any case where the snapshot still exists.

No imported-prior, no broken-secondary, no over-warning, no fabrication.

---

## Q2 — Mixed TIMESTAMP vs TIMESTAMP WITH TIME ZONE date_diff (3.50 PASS-borderline)

**Acc 3.0 / Clar 4.5 / Prac 3.0 / Compl 3.5.**

### (a) Implicit coercion claim — CORRECT

Responder said *"Trino AUTOMATICALLY coerces between TIMESTAMP and TIMESTAMP WITH TIME ZONE — join/comparison work WITHOUT conversion"*. This is **correct per pinned `reference_trino_timestamp_tz_coercion`**: Trino 467's TypeCoercion.java DOES implicitly coerce TIMESTAMP → TIMESTAMP WITH TIME ZONE in comparison/date_diff contexts. The query `date_diff('hour', e.created_at, s.session_start)` will RUN, not type-error. **This part of the answer is right.**

### (b) "CAST = UTC" — SUBTLE ACCURACY ERROR

Responder said *"to be explicit (recommended): CAST(e.created_at AS TIMESTAMP WITH TIME ZONE) -- explicit UTC assumption"*. This is **WRONG**. Per [trino issue #37](https://github.com/trinodb/trino/issues/37) ("TIMESTAMP behaviour does not match sql standard") + SQL spec: when you CAST a TIMESTAMP without time zone to TIMESTAMP WITH TIME ZONE, Trino uses the **SESSION time zone** (`current_timezone()`), not UTC.

- If the cluster JVM has `-Duser.timezone=UTC` AND no client has issued `SET TIME ZONE 'X'`, the session zone IS UTC and CAST works as the responder described.
- If the session zone is anything else (e.g., a JDBC client set `SET TIME ZONE 'America/New_York'`, or a node's `-Duser.timezone` is NY), the CAST tags the UTC-stored wall-clock as NY-time. `date_diff('hour', ...)` then under-reports by the offset and comparisons silently misalign.

**The implicit coercion in (a) ALSO uses the session zone.** So both code paths the responder offered have the same hidden assumption — neither is "explicit UTC."

### (c) The actually-correct UTC-tag

To unambiguously tag a TIMESTAMP whose wall-clock IS UTC:
- **`e.created_at AT TIME ZONE 'UTC'`** — interprets the wall-clock as UTC, returns TIMESTAMP WITH TIME ZONE with UTC attached; **session-zone independent**.
- **`with_timezone(e.created_at, 'UTC')`** — function form, same semantics, preferred in complex expressions to avoid `AT TIME ZONE` operator-precedence surprises.

**Both are already canonicalized at r22 §2A.3 L2179-2196 verbatim**: *"CRITICAL — CAST(naive_ts AS TIMESTAMP WITH TIME ZONE) attaches the SESSION timezone, NOT unconditionally UTC. This is the single most common factual slip when people describe how to 'convert' a MySQL DATETIME (naive) into a comparable timezone-aware value..."* with the full safer-alternative table.

### (d) Why the canonical wasn't reached — FINDABILITY GAP

The r22 §2A.3 canonical lives under "Trino federation / PostgreSQL+MySQL connector" — its anchors are framed around MySQL `DATETIME`-vs-Postgres `TIMESTAMPTZ` federation joins. **Q2's framing has NO federation keyword** — both `events` and `sessions` are presumably plain Iceberg tables on the same Trino. So the responder didn't route to r22.

### (e) Severity

**Subtle but real.** On a production cluster where session zone is reliably UTC (typical `-Duser.timezone=UTC` setup per r22 §2A.4: *"If Trino's JVM is set to UTC (the typical production setup — see `-Duser.timezone=UTC` in `jvm.config`)..."*), the responder's answer works exactly as described and no engineer hits a bug. On a cluster with mixed session-zone settings (any client that issued `SET TIME ZONE 'X'`, any per-node `-Duser.timezone` drift), the responder's `CAST` advice silently misinterprets the UTC-stored wall-clock by the local offset and `date_diff('hour', ...)` is wrong by hours. The engineer asked specifically because they're worried about the mismatch — and the responder told them "CAST to make it explicit UTC" without flagging that CAST is exactly the wrong tool for "make it UTC."

### (f) Is this a resource gap — FIX-A or per-instance?

**Marginal FIX-A candidate.** The CORRECT canonical exists at r22 §2A.3. The gap is that no non-federation framing (just "events table has TIMESTAMP, sessions table has TIMESTAMP WITH TIME ZONE on the same Iceberg catalog") routes there. r23 (SQL best practices) is the natural home for a Trino-side reach card.

**My recommendation: LIGHT additive card** at r23 (SQL best practices) OR r07 (analytical query patterns) keyed on the keywords this question used:
- "events table TIMESTAMP, sessions table TIMESTAMP WITH TIME ZONE / date_diff between mixed timestamp types / one column has time zone the other doesn't / join across naive and tz-aware timestamps"
- 4-line canonical: (1) implicit coercion exists, comparison/date_diff RUN, (2) but coercion uses SESSION zone, (3) to tag a UTC-wall-clock as UTC explicitly use `expr AT TIME ZONE 'UTC'` or `with_timezone(expr, 'UTC')`, (4) **NEVER** `CAST(naive_ts AS TIMESTAMP WITH TIME ZONE)` for UTC-tagging (uses session zone)
- Cross-ref to r22 §2A.3 for the full federation-context version.

This is materially the same defect family as the resource-source check for Q3 below (correct content lives at a sibling framing, doesn't get reached from new framing). Pattern matches `feedback_responder_findability.md` ("place content where keywords lead, not just where it's topically correct").

**NEW WATCH** `iter1285-Q2 mixed-TIMESTAMP-types CAST-attaches-session-zone non-federation framing findability gap`: re-probe within 4-8 iters under any "Iceberg table A is TIMESTAMP, Iceberg table B is TIMESTAMP WITH TIME ZONE, join/compare/date_diff between them" framing that doesn't mention federation/MySQL/Postgres. If recurs with same "CAST = UTC" slip, escalate to mandatory LIGHT FIX-A at r23.

---

## Q3 — dbt exposures for 40-model project (4.125 PASS)

**Acc 3.5 / Clar 5.0 / Prac 3.5 / Compl 4.5.**

### (a) Exposures shape — CORRECT

- `exposures:` at top of `exposures.yml` (`version: 2`) — CORRECT.
- Per-exposure: `name`, `label`, `type` (one of `dashboard`/`notebook`/`analysis`/`ml`/`application`), `maturity` (`high`/`medium`/`low`), `url`, `description`, `owner` (`name`+`email`), `depends_on: [ref('model_name'), source('schema','table')]` — ALL VERIFIED against [docs.getdbt.com/reference/exposure-properties](https://docs.getdbt.com/reference/exposure-properties).
- Lineage rendering via `dbt docs generate && dbt docs serve` — CORRECT (exposure appears as downstream-leaf node on the DAG site).
- `manifest.json` exposure node ID — CORRECT.
- Selective-build `dbt build --select +exposure:revenue_dashboard` (leading + = ancestors of the exposure = the upstream models the dashboard depends on, which IS what you want to build for that dashboard) — CORRECT direction.
- File placement under `models/` or dedicated subdirectory — CORRECT.

### (b) Impact-analysis selector direction — WRONG (RESOURCE DEFECT, iter1208 WATCH RECURRENCE)

Responder wrote: `dbt ls --select +model:fct_orders --resource-type exposure`

Per [dbt graph operators docs](https://docs.getdbt.com/reference/node-selection/graph-operators), verified via WebFetch this iter:
- **Leading `+`** (e.g. `+my_model`) = "the resource and all its **ancestors** (upstream dependencies)."
- **Trailing `+`** (e.g. `my_model+`) = "the resource and all its **descendants** (downstream dependencies)."

Exposures DEPEND ON models — they live DOWNSTREAM of models. To list "every exposure that consumes fct_orders" you need `model:fct_orders+ --resource-type exposure` (trailing +, descendants). The responder's `+model:fct_orders --resource-type exposure` returns ANCESTORS of fct_orders intersected with exposures = always empty (exposures are leaf-only, never ancestors of a model).

**Engineer impact**: paste the command, see empty output, conclude "no dashboards depend on this model" — proceed with the breaking change. This is exactly the situation exposures are meant to prevent.

### (c) Source check — RESOURCE DEFECT confirmed

Grep `resources/27-oracle-plsql-to-dbt-trino.md` L4135:

> `dbt ls --select +model:fct_orders --resource-type exposure` lists every exposure (dashboard/ML pipeline) downstream of `fct_orders`...

**The responder's wrong direction is a verbatim copy of this line.** This was almost certainly introduced as a late FIX-A after the iter1208 directional WATCH was opened — but the fix encoded the WRONG direction. The responder is faithfully following the resource; the resource is wrong.

The adjacent line at L4134 — `dbt build --select +exposure:revenue_dashboard` (ancestors of the exposure = the upstream models to build for the dashboard) — is CORRECT direction. So the file has BOTH a correct directional example AND an incorrect one, adjacent to each other.

### (d) iter1208 WATCH status

iter1208 (line 740 of rubric.md) opened a soft WATCH `iter1208 Q3 dbt selector direction +model vs model+ for impact analysis` with re-probe in 4-8 iters. **iter1285 is iter77 after iter1208** — well past the re-probe window, but iter1285's recurrence is meaningful because it now manifests as a RESOURCE DEFECT not a responder slip. **WATCH ESCALATES from soft → mandatory FIX-A.**

### (e) Recommended FIX-A

**SURGICAL EDIT at r27 §6.7H2 L4135.** Change:

```
- **Impact analysis** — `dbt ls --select +model:fct_orders --resource-type exposure` lists every exposure (dashboard/ML pipeline) downstream of `fct_orders`...
```

to:

```
- **Impact analysis** — `dbt ls --select model:fct_orders+ --resource-type exposure` lists every exposure (dashboard/ML pipeline) downstream of `fct_orders` (trailing `+` = descendants per dbt graph-operator docs)...
```

Plus a one-line directional-mnemonic add at the same paragraph:

> **Selector direction**: `+model` = ancestors (upstream); `model+` = descendants (downstream). Exposures depend on models, so they're DOWNSTREAM — use `model_name+ --resource-type exposure` to find exposures consuming a model.

Optional: add a DO-NOT-WRITE row to the §6.7H2 table:
- `dbt ls --select +model:X --resource-type exposure` | **WRONG direction.** Leading `+` selects ancestors of X; exposures are downstream leaves, never ancestors. Returns empty. Use trailing `+` (`model:X+`) for descendants.

---

## Q4 — Oracle TRUNC(date) → Trino (4.9375 STRONG PASS)

**Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 4.75.**

Responder gave:
- `date_trunc('day', order_date)` as the direct Oracle TRUNC(date) port — correct per [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html).
- Full unit table: `second / minute / hour / day / week (ISO-Monday) / month / quarter / year` — correct unit list, ISO-Monday week boundary correctly called out (Oracle TRUNC('iw') matches; Oracle TRUNC('w') Sunday-week does NOT, which is a real engineer trap but not load-bearing here).
- Return-type diff: Oracle TRUNC returns DATE; Trino `date_trunc` on a TIMESTAMP returns TIMESTAMP (a midnight TIMESTAMP, not a DATE). Engineers comparing the result to a `DATE` literal need a `CAST(... AS date)` or `DATE(...)` wrap if the comparison fails — correctly framed.
- TZ caveat: `date_trunc` on TIMESTAMP WITH TIME ZONE returns a value in the SESSION time zone, so for local-day grouping use `CAST(date_trunc('day', created_at AT TIME ZONE 'America/New_York') AS DATE)` — CORRECT pattern, matches r23 §canonical (and ironically the right pattern that Q2 should have produced too).

Minor Compl shave (-0.25): didn't mention that Iceberg `partitioning = ARRAY['day(occurred_at)']` is the partition-prune-friendly equivalent if the engineer is doing this group-by repeatedly on a partitioned fact table — would be a nice forward pointer. Non-load-bearing.

No imported-prior, no broken-secondary, no over-warning, no fabrication.

---

## Score updates (rubric.md)

| Topic | Pre | Post | Delta |
|---|---|---|---|
| Iceberg table maintenance (Q1) | 4.4521/243 | 4.4538/244 | +0.0017 |
| SQL query best practices for OLAP (Q2) | 4.5882/301 | 4.5846/302 | -0.0036 |
| Improving complex SQL perf on Trino with dbt (Q3) | 4.4866/86 | 4.4825/87 | -0.0041 |
| Oracle PL/SQL → dbt + Trino (Q4) | 4.4912/254 | 4.4929/255 | +0.0017 |

All four topics remain comfortably above their 3.5 pass thresholds.

---

## Actions for the teacher

### MANDATORY THIS ITER (FIX-A)

**Q3 — r27 §6.7H2 L4135 directional fix.** Reverse the impact-analysis selector from leading `+model:fct_orders` to trailing `model:fct_orders+`. Add a one-line directional mnemonic. Optionally add a DO-NOT-WRITE row defanging the leading-+ form. This is a **resource defect** — the wrong selector is now baked into the canonical text and the responder is faithfully copying it. Verified WRONG against [docs.getdbt.com/reference/node-selection/graph-operators](https://docs.getdbt.com/reference/node-selection/graph-operators) verbatim "(`+`) Placed before a model/resource — Includes the resource itself and all its ancestors (upstream dependencies). Placed after a model/resource — Includes the resource itself and all its descendants (downstream dependencies)." (iter1208 WATCH escalated soft → mandatory FIX-A by recurrence + resource-defect confirmation.)

### MARGINAL — DECIDE NEXT ITER

**Q2 — r23 (or r07) non-federation TIMESTAMP-vs-TIMESTAMP-WITH-TIME-ZONE findability card.** The correct canonical exists at r22 §2A.3 L2179-2196 (verified correct), but its anchors are federation-framed (MySQL DATETIME / Postgres TIMESTAMPTZ). A 4-line additive card at r23 keyed on non-federation framings ("two Iceberg tables, one TIMESTAMP one TIMESTAMP WITH TIME ZONE, date_diff/join/compare between them") with the AT TIME ZONE 'UTC' / with_timezone(ts,'UTC') canonical + the SESSION-zone-CAST defang + cross-ref to r22 §2A.3 would close the gap.

**Open as NEW SOFT WATCH** `iter1285-Q2 mixed-TIMESTAMP-types CAST-attaches-session-zone non-federation findability gap`: re-probe within 4-8 iters. If recurs under any non-federation "join two timestamp types" framing with the "CAST = UTC" slip, escalate to mandatory LIGHT FIX-A. If the next re-probe ALSO comes through the non-federation framing AND lands a good answer (by pulling r22 §2A.3 anyway, perhaps the responder is improving cross-file routing), CLOSE the watch.

### CARRY WATCHES

- iter1283-Q1 perf-triage HARD → DOWNGRADED to periodic SOFT (re-probe 8-12); per `feedback_synthesis_ceiling_stop_churning.md`
- iter1284-Q3 dbt delete+insert-not-built-in slip (soft, re-probe 6-10, no fix)
- iter1283-Q3 hard_deletes (soft, no fix)
- iter1283-Q4 strpos-3-arg (soft, no fix; recall ceiling per `feedback_synthesis_ceiling_stop_churning.md`)
- iter1281-Q2 UNNEST SELECT-col-not-in-GROUP-BY (soft, re-probe 4-8)
- iter1280-Q1 partition-Spark (soft)
- iter1280-Q2 DECIMAL-scale mechanism conclusion (soft)
- iter1278-Q1 Scheduled-vs-CPU (soft)
- iter1279-Q4 now() empty-parens (soft)
- iter1208-Q3 dbt selector direction — **CLOSED via mandatory FIX-A this iter** (escalated and resolved)

### DO NOT

- Do not churn r05/r18 perf-triage land-points further (iter1283 confirmed recall-ceiling, per pinned synthesis-ceiling memory)
- Do not add aggressive defangs for the Q4 TRUNC family — current r27 §4 + r23 datetime cards are doing fine
- Do not over-attract Q2 family by colliding with the r22 §2A.3 federation canonical (cross-ref, don't duplicate)

---

## Meta — patterns this iter

1. **Resource-defect-from-late-FIX-A**: iter1208 opened a directional WATCH for `+model vs model+`. Sometime between iter1208 and iter1285, a teacher pass added the wrong-direction selector to r27 §6.7H2 — exactly the form iter1208 had flagged as wrong. The watch was open but the resource defect went uncaught. Lesson: when a directional/syntactic watch is opened, the teacher must grep BOTH `+model:` AND `model:.*+` patterns in the resource at FIX-A time to confirm the canonical reflects the correct direction, not just add a "do not write" defang. Pattern aligns with `feedback_trace_recurring_folklore_to_resource_root_cause.md` (when a slip recurs, grep resources for the wrong claim before treating as pure responder slip — but the converse also holds, when a teacher adds a "directional mnemonic," verify it's the right direction).

2. **Findability gap on adjacent framings (Q2)**: r22 §2A.3 has the perfectly-correct canonical for the CAST=session-zone gotcha, but anchored on federation/MySQL framing. A SaaS engineer asking the same question about two plain Iceberg tables doesn't route there. Same pattern as iter1274-Q1 source-freshness (correct canonical in r27, but Fivetran/ingestion narrative routed to r13 where there was no anchor). Lesson: high-value technical canonicals deserve mirror-anchors at sibling framings, not just the framing they originally lived under.

3. **Q1 / Q4 continue the long-running breadth-clean trend** on Iceberg time-travel + Oracle migration topics. Both responder reaches were direct to canonical content, no synthesis slips, no broken-secondary alternatives. These topic rows have a healthy combined margin (Iceberg-maintenance +0.95, Oracle-migration +0.99) and recent runs consistently land 4.75-5.0.

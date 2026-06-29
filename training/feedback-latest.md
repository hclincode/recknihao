# Judge Feedback — Iteration 1282

**Overall**: 4 questions, average **4.20 PASS** (Q1 2.125 FAIL / Q2 4.875 STRONG PASS / Q3 4.875 STRONG PASS / Q4 4.94 STRONG PASS). Big rebound from iter1281 3.22, but **Q1 still fails** — the iter1281 perf-triage FIX-A did NOT fully reach, and the residual gap is now diagnosed as a r05 mis-attract + myth reproduction, NOT a r18/r16 content problem.

**Headline results**:

| Q | Topic | Score | Status | Reach-test verdict |
|---|---|---|---|---|
| Q1 | Perf-triage: find heavy queries | 2.125 | FAIL | iter1281 FIX-A **PARTIAL REACH** — responder reached `system.runtime.queries` but routed to r05 (multi-tenant, narrow), missed JOIN-to-tasks, reproduced the no-bytes-column myth, used wrong CPU proxy |
| Q2 | dbt dev vs prod target separation | 4.875 | STRONG PASS | iter1281 FIX-A **FULLY REACHED** — iter1281-Q3 watch **CLOSED** |
| Q3 | Oracle `(+)` outer-join — which side preserved | 4.875 | STRONG PASS | iter1281 FIX-A **FULLY REACHED** — iter1281-Q4 watch **CLOSED** (minor "put it on the LEFT" muddiness only) |
| Q4 | Per-account status pivot | 4.94 | STRONG PASS | clean conditional aggregation + FILTER alternative |

---

## Q1 — find heavy queries on the cluster (perf triage)

**Score: 2.125** (Acc 1.5 / Clar 3.0 / Prac 2.0 / Compl 2.0) — FAIL

### What the responder said
- Correctly reached `system.runtime.queries`.
- Gave "what's running now" query (`WHERE state IN ('QUEUED','RUNNING')`) — fine for the running-now half.
- Gave "last 2 hours" query (`WHERE "end" > current_timestamp - INTERVAL '2' HOUR ORDER BY analysis_time_ms DESC LIMIT 20`) — three sub-bugs here.
- Claimed **"This table does NOT have a bytes_scanned or data_scanned column. For data volume auditing, you'll need to check the Trino event listener audit logs... For now, focus on wall-clock time."**
- Sorted by `analysis_time_ms` for "most CPU".
- Cited r05.

### Three substantive errors

**(1) Reproduced the no-bytes-column myth — missed the queries↔tasks JOIN.**
Verified against trino.io and [Release 330 docs](https://trino.io/docs/current/release/release-330.html) + r18 §404 + r16 §295: **`system.runtime.tasks` HAS `physical_input_bytes` (added release 330) and `split_cpu_time_ms`**. JOIN `system.runtime.queries q` to `system.runtime.tasks t ON q.query_id = t.query_id` and `SUM(t.physical_input_bytes)` gives bytes scanned per query. The responder's "no bytes column → use event listener" is FALSE as a final answer — it's true *only* for `system.runtime.queries` alone, but the JOIN-to-tasks escape hatch exists and is the canonical answer on this stack. r18 §404 and r16 §295 BOTH have this recipe explicitly defanging the myth ("`bytes_scanned` does NOT exist on `system.runtime.queries`. The actual column is `t.physical_input_bytes` on `system.runtime.tasks`" — r16 L356).

**(2) Wrong CPU proxy.**
`analysis_time_ms` is the SQL analysis PHASE timing (parse + analyze) — typically tens of milliseconds, a tiny fraction of total query time. It is **NOT** total execution CPU. For "most CPU" the canonical metric is `SUM(t.split_cpu_time_ms)` aggregated from tasks per query_id. Sorting by `analysis_time_ms` for "which queries are burning the CPU" returns the queries with the longest parse phase, not the heaviest queries.

**(3) 2-hour window on a ~15-min ring buffer.**
`system.runtime.queries` evicts entries past `query.min-expire-age` (15 min default) or `query.max-history` (100 queries default), whichever first. `WHERE "end" > current_timestamp - INTERVAL '2' HOUR` is meaningless against the in-memory table — it will only ever return what's still in the ring buffer (~15 min worth). For windows >15 min, the event listener is the right path (the responder mentioned this for bytes scanned but didn't apply the same caveat to the time window).

### Why the iter1281 FIX-A did NOT fully reach

The FIX-A added perf-triage READ-THIS-FIRST anchors to r18 §404 and r16 §295 — both anchors are present and correct (verified via Grep: "cluster sluggish", "hammering", "what's running", "most-data-read" all hit r16 + r18). **The anchors themselves are fine** — the problem is the responder routed to r05 (multi-tenant analytics) FIRST, because:

- The question framing "**suspect ONE TENANT** / runaway query eating the cluster" includes the **tenant** keyword, which maps strongly to r05 (multi-tenant).
- r05 §3800-3833 has an "Ad-hoc admin-only query against `system.runtime.queries`" section that:
  - Uses ONLY `system.runtime.queries` (no JOIN to tasks).
  - States at L3833: **"this runtime table does not help — `system.runtime.queries` exposes no I/O-bytes column. Use the HTTP event listener path"**.
  - Does NOT cross-ref the r18 §404 / r16 §295 tasks-JOIN recipe.

The responder lifted this verbatim. The r05 statement is technically correct in its narrow scope (per-tenant cost dashboard for tenants must use event listener for security + completeness), but as a final answer to a perf-triage question it reproduces exactly the myth that r18/r16 defang.

### Recommended FIX-A — r05 mis-attract repair

**Location: r05 §3800-3815, around lines 3814-3833.**

Two concrete additions:

1. **Insert a routing pointer at L3815** (right before "Ad-hoc admin-only query against `system.runtime.queries`"):
   > **If your question is broader cluster perf-triage** ("which query is hammering the cluster / eating CPU / scanning the most bytes" / "what's running now") — **go to r18 §404 "Finding expensive queries on Trino 467" or r16 §295 "LEADING CANONICAL COST WORKED EXAMPLE"** for the `system.runtime.queries` JOIN `system.runtime.tasks` recipe. The section below is a NARROW per-user count/duration roll-up only; it does NOT cover bytes scanned or per-query CPU.

2. **Reframe L3833** ("For per-tenant bytes scanned, this runtime table does not help — `system.runtime.queries` exposes no I/O-bytes column..."):
   > For per-tenant **bytes scanned** specifically, the per-tenant chargeback path uses the event listener (see below for security reasons). For **ad-hoc admin perf-triage** ("which query is hammering us right NOW"), JOIN `system.runtime.queries` to `system.runtime.tasks` on `query_id` and aggregate `t.physical_input_bytes` + `t.split_cpu_time_ms` — see r18 §404 / r16 §295. The "no bytes column" rule applies to `system.runtime.queries` ALONE, NOT to the queries+tasks JOIN.

3. **Add a DO-NOT-WRITE entry** to whichever DO-NOT-WRITE block already exists in r05's system-tables section:
   > | "`system.runtime.queries` has no bytes-scanned column, so you can only check bytes via the event listener" | The bytes column doesn't exist on `queries`, but it DOES exist as `physical_input_bytes` on `system.runtime.tasks` (verified release 330+). JOIN `queries` to `tasks` on `query_id` to get bytes per query without needing the event listener. The event listener is for windows >15 min only. | r18 §404 / r16 §295 recipe. |

This is a **r05 mis-attract repair**, not a r18/r16 content gap. The right content lives in r18/r16 — but r05 currently silently captures and gives a half-answer.

### Secondary fix — analysis_time_ms warning

Optional: add a small note somewhere in r18 §404 explicitly defanging `analysis_time_ms` as a CPU proxy. The current recipe correctly aggregates `t.split_cpu_time_ms` but doesn't explicitly warn against the trap. A one-liner like:
> **Do NOT sort by `q.analysis_time_ms` for "most CPU"** — that's the SQL analysis phase only (typically tens of ms), not total execution CPU. Use `SUM(t.split_cpu_time_ms)` from `system.runtime.tasks`.

---

## Q2 — dbt dev vs prod target separation

**Score: 4.875** (Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 4.5) — STRONG PASS

The responder gave a verbatim match to the iter1281 NEW r27 §2533 canonical:
- Two-output `profiles.yml` (dev: `schema: dbt_{{ env_var('USER') }}`; prod: `schema: analytics`).
- `target: dev` as the DEFAULT.
- `dbt run` → dev (safe); `dbt run --target prod` → prod (explicit opt-in).
- "No way to accidentally overwrite prod with a bare `dbt run`" — exact framing from the canonical.
- `DBT_ENV_SECRET_TRINO_PASSWORD` for password (matches the secrets section cross-ref).

Verified against [docs.getdbt.com profiles.yml docs](https://docs.getdbt.com/docs/core/connect-data-platform/profiles.yml): multiple `outputs:`, `target:` selects default, `--target prod` overrides — all correct.

Small Compl shave: didn't mention the `generate_schema_name` macro nuance (target schema may be PREFIXED, not REPLACED, by per-model `+schema:` configs — this is a real gotcha on dbt-trino). The iter1281 canonical does note this at §6.7M cross-ref — responder skipped it. Non-blocking.

**Verdict: iter1281 FIX-A FULLY REACHED. iter1281-Q3 watch CLOSED.**

---

## Q3 — Oracle `(+)` outer-join — which side preserved

**Score: 4.875** (Acc 5.0 / Clar 4.5 / Prac 5.0 / Compl 5.0) — STRONG PASS

The responder applied the corrected rule exactly as the iter1281 r27 §4.5 FIX-A teaches:
- "The table with the `(+)` is the one whose rows are DROPPED on a non-match" → CORRECT (matches Oracle docs verified [here](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/Joins.html)).
- `(+)` on `e.dept_id` → employees is the optional/null-supplying side → all departments preserved.
- Final rewrite: `FROM departments d LEFT JOIN employees e ON d.dept_id = e.dept_id`. CORRECT.
- Mental model: "`(+)` on right side → that table's rows dropped on non-match → LEFT JOIN, put it on the LEFT" — slightly muddy phrasing here (the table with `(+)` goes on the RIGHT of the LEFT JOIN, NOT the left — but the actual rewrite is correct).

The muddiness is a minor Clar nit (4.5), NOT an error. The rule itself, the rewrite, and the "which table preserved" answer are all right.

**Verdict: iter1281 FIX-A FULLY REACHED. iter1281-Q4 backwards-rule defang watch CLOSED.**

(Optional polish: the mental-model line in r27 §4.5 could be tightened to "`(+)` on the column → that column's TABLE goes on the RIGHT of `LEFT JOIN`; the table WITHOUT `(+)` goes on the LEFT and is preserved." Not required — current canonical with the variation table works.)

---

## Q4 — per-account status pivot

**Score: 4.94** (Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 4.75) — STRONG PASS

Two valid Trino 467 forms given:
- `SUM(CASE WHEN status='open' THEN 1 ELSE 0 END) AS open_count` (×4 statuses) — standard conditional aggregation, dialect-agnostic.
- `COUNT(*) FILTER (WHERE status='open') AS open_count` (×4) — verified against [Trino aggregate functions docs](https://trino.io/docs/current/functions/aggregate.html): the `FILTER (WHERE ...)` clause is supported for all aggregate functions.

"Both run identically on Trino 467" — accurate (the planner rewrites SUM(CASE) to the same internal form).

`GROUP BY account_id` correct. Result-shape table helpful for clarity. Tiny Compl shave for not mentioning `pivot` (Trino has no native PIVOT operator — would be a nice defang anchor, but it's not strictly required).

---

## Watches status

| Watch | Verdict |
|---|---|
| **HARD iter1281-Q1 perf-triage findability reach-test** | **FAILED to fully reach** — anchors at r18 §404 / r16 §295 are correct, but r05 mis-attracts and reproduces the no-bytes-column myth. NEEDS r05 FIX-A (above). RE-OPEN as HARD iter1282-Q1 r05 perf-triage mis-attract; re-probe 2-3 iters after FIX-A. |
| **HARD iter1281-Q3 dbt dev-vs-prod target-separation** | **CLOSED** — Q2 cleanly reached the canonical. |
| **LIGHT iter1281-Q4 Oracle `(+)` backwards-rule defang** | **CLOSED** — Q3 applied the corrected rule cleanly. Optional polish on mental-model wording but not required. |
| **SOFT iter1281-Q2 UNNEST SELECT-col-not-in-GROUP-BY slip** | Not exercised this iter; carry forward (re-probe 4-8 iters). |
| **SOFT iter1278-Q1 Scheduled-vs-CPU-as-I/O-wait imprecision** | Not exercised this iter; carry. |
| **SOFT iter1279-Q4 now() / iter1280-Q1 partition-Spark-paraphrase / iter1280-Q2 DECIMAL-scale** | Not exercised this iter; carry. |

---

## Patterns and recommendations

1. **The iter1281 perf-triage FIX-A demonstrates a known failure mode**: a correct canonical at r18/r16 with strong anchors can still be silently bypassed by an adjacent narrower section in r05 that gives a half-answer. The r05 section is correct for its narrow scope (per-tenant cost dashboard for tenants) but lacks the routing pointer to the broader recipe. **Reconcile r05 with cross-refs to r18/r16, don't just add anchors to r18/r16**. This matches the prior memory pattern: "Reconcile Don't Append" — when adding a new canonical, also fix the contradictory adjacent content.

2. **Watch dimension**: the responder's "no bytes column → use event listener" is the EXACT myth that r16 L276/L356 defangs in its DO-NOT-WRITE blocks. The defang is at the RIGHT place (r16) but the responder never reached r16 — it routed to r05 which has the myth without the defang. **The defang must travel with the mis-attractor, not just live in the right place.**

3. **`analysis_time_ms` as a CPU proxy** is a new variant of the responder's pattern of grabbing the first plausible-looking timing column when the right one (`split_cpu_time_ms` on tasks) requires a JOIN. Soft watch: re-probe "most CPU" framings to confirm whether this is a one-off or a recurring sloppy-column-pick pattern.

4. **Q2/Q3/Q4 all strong** — three of four canonicals work as designed when the routing is clean. The Q1 routing miss is isolated to the r05 mis-attract and is a fixable, narrow defect.

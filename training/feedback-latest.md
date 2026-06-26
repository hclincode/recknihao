# Iter1115 — Judge Feedback

**Overall verdict: 4.9844 STRONG PASS** (margin +1.48). iter1113 r07 two-level-aggregation FIX-A **REACH CONFIRMED on 3rd consecutive domain** (workspaces/projects after iter1113 account/user + iter1114 region/rep). iter1114 Q2 both-bounds half-pull **DID NOT RECUR** — both lower AND upper bound present this iter on explicit "complete months" wording, confirming per-instance synthesis slip, NOT structural. NO STEP-0 FIX-A needed. Q3 date-parse family-trap + Q4 Iceberg optimize file_size_threshold default both source-verified clean.

---

## Source verifications (Trino 467 docs)

- **Q4 file_size_threshold default**: trino.io/docs/current/connector/iceberg.html — "All files with a size below the optional `file_size_threshold` parameter (default value for the threshold is `100MB`) are merged…" Verbatim confirms responder's "default threshold 100MB" claim.
- **Q3 date_parse vs parse_datetime**: trino.io/docs/current/functions/datetime.html — `date_parse(string, format) → timestamp(3)` uses MySQL `%`-specifiers (`%m`/`%d`/`%Y`/`%H`/`%i`/`%s`); `parse_datetime(string, format) → timestamp with time zone` uses Joda DateTimeFormat letters (`MM`/`dd`/`yyyy`/`HH`/`mm`/`ss`). Both families incompatible — responder's "never mix families" is correct.
- **Q4 snapshot isolation**: Iceberg's atomic-snapshot-commit semantic — optimize writes new data files and commits a new snapshot atomically; readers see the old snapshot until commit, then the new one, never a partial state. This is canonical Iceberg behavior on Trino 467 — responder's "table stays queryable via snapshot isolation" is accurate.
- **Q4 optimize_manifests**: 467 has `optimize` only (data-file compaction); the separate `optimize_manifests` table procedure for manifest compaction was added in later Trino versions (470+), so responder's "manifest compaction is a separate concern" framing is correct for the production 467 stack.
- **Q1 two-level form**: SELECT.html GROUP BY semantics — inner `GROUP BY workspace_id, project_id HAVING COUNT(*) >= 10` produces one row per qualifying project; outer `GROUP BY workspace_id COUNT(*)` then counts those projects. Responder's note about COUNT(*) being right (not COUNT(DISTINCT project_id)) because inner GROUP BY made projects unique is precisely correct.
- **Q2 both bounds**: SELECT.html WHERE evaluation — `order_date >= date_add('month', -3, date_trunc('month', current_date))` AND `order_date < date_trunc('month', current_date)` gives a clean half-open window covering exactly the 3 complete prior months and excluding the in-progress month. HAVING `COUNT(DISTINCT date_trunc('month', order_date)) = 3` then requires presence in all three.

---

## Per-question scoring

### Q1 — Workspaces with count of projects each crossing >= 10 completed tasks (two-level aggregation, 3rd domain)

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Inner CTE `GROUP BY workspace_id, project_id HAVING COUNT(*) >= 10` correctly identifies qualifying projects; outer `GROUP BY workspace_id COUNT(*)` correctly counts them. Spontaneous explanatory note that COUNT(*) is right (not COUNT(DISTINCT project_id)) because inner GROUP BY guarantees one row per project is exactly the load-bearing insight. |
| Beginner clarity | 5.0 | Clean two-step framing; explicit anti-pattern callout on COUNT(*) vs COUNT(DISTINCT) prevents a reader from "defensively" adding DISTINCT and over-thinking it. |
| Practical applicability | 5.0 | Copy-paste-ready Trino-valid SQL on a workspace_id/project_id/status/tasks schema the engineer named. No hedges. |
| Completeness | 5.0 | Both halves of the FIX-A canonical (the nested form + the trap defang on single-level collapse) present in one answer; the COUNT(*) vs COUNT(DISTINCT) clarification covers the natural next question. |

**Q1 average: 5.0** — Two-level FIX-A reach **CONFIRMED on 3rd consecutive domain** (iter1113 account/user, iter1114 region/rep, iter1115 workspace/project). The iter1113 r07 §3694-3725 sub-canonical with keyword anchors + worked example + single-level-collapse DO-NOT-WRITE remains durable across novel domain phrasings.

### Q2 — Customers ordering in every one of last 3 COMPLETE calendar months (excl. current partial month)

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | BOTH bounds present: lower `order_date >= date_add('month', -3, date_trunc('month', current_date))` (month-aligned anchor, NOT bare current_date), upper `order_date < date_trunc('month', current_date)` (excludes in-progress month). HAVING `COUNT(DISTINCT date_trunc('month', order_date)) = 3` correctly counts distinct complete months. All Trino 467 functions valid (date_add, date_trunc, current_date). |
| Beginner clarity | 5.0 | Half-open window with the in-progress-month exclusion explained; HAVING semantic for "in EVERY month" via DISTINCT count = N is the idiomatic shape. |
| Practical applicability | 5.0 | Engineer can paste directly; iter1114's silent over-count on partial-week trap closed by the explicit < upper bound. |
| Completeness | 5.0 | Period-coverage discipline (both-bounds for "complete months") observed on the explicit "complete" wording — exactly what was missed iter1114. |

**Q2 average: 5.0** — iter1114 both-bounds half-pull **DID NOT RECUR**. Explicit "complete months" wording correctly triggered both-bounds discipline. **Verdict: per-instance synthesis slip iter1114, NOT structural recurrence. NO STEP-0 FIX-A needed on r07 §3713-3721. Watch CLEARED for this defect class.**

### Q3 — MM/DD/YYYY string to date (MySQL STR_TO_DATE / Python strptime equivalent)

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | `CAST(date_parse(date_str, '%m/%d/%Y') AS DATE)` correct (date_parse uses MySQL %-specifiers per datetime.html, returns timestamp(3), CAST to DATE works). `CAST(parse_datetime(date_str, 'MM/dd/yyyy') AS DATE)` correct (parse_datetime uses Joda letters per datetime.html, returns timestamp with time zone, CAST to DATE works). "Never mix families" is the load-bearing trap warning — both families are incompatible (e.g. `date_parse(s, 'MM/dd/yyyy')` returns wrong values silently because `MM`→literal 'M' twice in MySQL). |
| Beginner clarity | 5.0 | Two parallel forms shown side-by-side, with explicit family attribution (MySQL %-specifiers vs Joda letters) and explicit mixing trap. The Python/MySQL equivalents the engineer asked about correctly mapped. |
| Practical applicability | 4.75 | Copy-paste-ready both forms. Minor shave: didn't explicitly call out parse_datetime returning `timestamp with time zone` (vs date_parse returning plain `timestamp(3)`) — immaterial for the DATE CAST but might surprise an engineer using the result without further casting. Not a defect, just a tiny completeness nit. |
| Completeness | 5.0 | Both canonical forms + mixing trap + MySQL/Python lineage all addressed in one answer. |

**Q3 average: 4.9375** — Date-parse family-trap canonical clean. The MM↔%m + MM↔MM-vs-mm family is one of the most-failed angles in SQL training corpora — both correctly attributed.

### Q4 — Iceberg optimize for small files; queryability during optimize

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | `ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '256MB')` syntax correct (named parameter, two-arrow-key arg form, table-qualified). Default 100MB **verbatim verified** against iceberg.html. Snapshot-isolation/atomic/stays-queryable claim correct per canonical Iceberg semantic. "Manifest compaction is a separate concern" correctly distinguishes data-file vs manifest compaction on 467 (optimize_manifests is 470+, not 467 — production-stack-accurate). |
| Beginner clarity | 5.0 | Three load-bearing pieces named cleanly: (1) the EXECUTE optimize syntax with named parameter, (2) snapshot-isolation atomicity (readers see old-or-new, never partial), (3) the data-vs-manifest scope boundary. |
| Practical applicability | 5.0 | Engineer can run the command immediately; the queryability concern (real for a dbt-run-impacted analytics dashboard) directly answered. |
| Completeness | 5.0 | Both halves of the asked question (command + queryability) answered with the bonus default-threshold + scope-boundary caveat. |

**Q4 average: 5.0** — Iceberg optimize canonical clean. The production-stack constraint (467, not 470+) correctly observed (no spurious `optimize_manifests` suggestion).

---

## Score table

| Q | Topic touched | Accuracy | Clarity | Applicability | Completeness | Avg |
|---|---|---|---|---|---|---|
| Q1 | Analytical query patterns Iceberg+Trino (two-level aggregation, 3rd domain) | 5.0 | 5.0 | 5.0 | 5.0 | **5.0** |
| Q2 | Analytical query patterns Iceberg+Trino (complete-period coverage, both-bounds discipline) | 5.0 | 5.0 | 5.0 | 5.0 | **5.0** |
| Q3 | SQL best practices OLAP (date_parse vs parse_datetime family-trap) | 5.0 | 5.0 | 4.75 | 5.0 | **4.9375** |
| Q4 | Iceberg table maintenance (optimize, file_size_threshold default, snapshot isolation) | 5.0 | 5.0 | 5.0 | 5.0 | **5.0** |

**Iter average: (5.0 + 5.0 + 4.9375 + 5.0) / 4 = 4.9844 STRONG PASS** (margin +1.48 above 3.5).

---

## Defect ledger

**Source-verified defects this iter: ZERO.**

- Q1: clean two-level form on 3rd domain — FIX-A REACH **CONFIRMED**.
- Q2: both bounds present + correct HAVING — iter1114 half-pull **DID NOT RECUR**.
- Q3: both families correctly attributed; one tiny nit on not mentioning `timestamp with time zone` for parse_datetime (immaterial for DATE CAST).
- Q4: syntax + default + snapshot isolation + scope boundary all source-verified clean.

No `::` shorthand cast, no QUALIFY (Trino 467 has none), no false semi-join, no fabricated function, no regex-backslash escape, no INTERVAL quarter/week, no OFFSET-before-LIMIT (Trino requires OFFSET BEFORE LIMIT), no CAST-truncate misread, no EXECUTE rollback-on-467 (CALL is correct), no Spark/Oracle spillover, no imported-prior self-error.

---

## Verdicts

- **Q1 FIX-A REACH VERDICT: CONFIRMED (3rd consecutive domain).** iter1113 r07 two-level nested aggregation sub-canonical between §3694 and §3725 with keyword anchors + worked example + single-level-collapse DO-NOT-WRITE durably reaches across novel domains (account/user → region/rep → workspace/project). Same first-re-probe-reach pattern as iter1099 dbt-snapshot signpost and iter1102 hard-deletes-affirmative-hoist. Defect class **CLOSED** with 3 datapoints.
- **Q2 BOTH-BOUNDS RECURRENCE VERDICT: DID NOT RECUR.** iter1114 silent-wrong half-pull on "complete weeks" wording was per-instance synthesis slip — when the wording explicitly emphasized "complete months, exclude the current in-progress month", responder produced both bounds correctly. **STEP-0 FIX-A NOT NEEDED**; r07 §3713-3721 card already documents both-bounds form sufficiently. **Watch CLEARED for this defect class.**

---

## Topic row updates

- Analytical query patterns on Iceberg+Trino: 4.4195/67 → (296.1065 + 5.0 + 5.0)/69 = **4.4363/69 PASSED** (+0.0168, both Q1 and Q2 5.0)
- SQL best practices OLAP: 4.4993/170 → (764.881 + 4.9375)/171 = **4.5021/171 PASSED** (+0.0028)
- Iceberg table maintenance: 4.4652/172 → (768.0144 + 5.0)/173 = **4.4683/173 PASSED** (+0.0031)

ALL required topics REMAIN PASSED. Federation untouched (4.50244/312 fragile-PASS preserved). CBO/ANALYZE untouched (4.5716/20, +0.072 margin to raised 4.5 preserved). Storage-tiering untouched (3.5625/6 thinnest passing margin).

---

## Recommendation

**NO-OP.** No resource edits. No state.json bump beyond iteration counter. Commit rubric+feedback only.

Both critical re-probe streams resolved this iter:
1. **Two-level-aggregation FIX-A**: confirmed durable across 3 domains; close this watch.
2. **Both-bounds period-coverage**: iter1114 half-pull was per-instance, did not recur on explicit "complete months" wording; close this watch.

### Optional next-sweep durability probes (no edit, just probe)

- Storage-tiering 7th datapoint (3.5625/6 still thinnest required-topic row).
- dbt-model-contracts 7th angle (4.391/6).
- dbt-snapshots SCD2 14+th angle (4.0315/14, 2nd-thinnest after storage-tiering).
- Cost-considerations 21st angle (4.2129/20).
- Federation 313th angle ONLY if a bulletproofed pushdown form available (4.50244/312 fragile-PASS).

### Pattern observations

- Two consecutive STRONG PASS iters (4.6719 → 4.9844) with two distinct watch-streams both resolving positively: the iter1113 additive sub-canonical card + DO-NOT-WRITE defang pattern is durable when the root cause is a missing-canonical findability gap (not a content conflict).
- The iter1114 Q2 half-pull was the residual `feedback_synthesis_ceiling_stop_churning` artifact — confirmed per-instance, not structural — consistent with the iter1107→1108 fresh-domain re-probe pattern where 2/4 per-instance synthesis slips DID NOT recur across different domains.
- Q3 (date_parse vs parse_datetime family trap) producing both families' canonicals + mixing trap + MySQL/Python lineage in one answer signals strong r23 datetime-parse durability — similar to iter1110 Q2 Joda-vs-MySQL format-specifier trap.
- Q4 (Iceberg optimize) correctly observing the 467 production stack constraint (no spurious optimize_manifests suggestion) signals strong r12/r10 production-version-discipline.

### Teacher guidance

- **NO content edits warranted.** Both watch streams from prior iters resolved positively this iter.
- Maintain existing canonical cards at r07 §3694-3725 (two-level FIX-A) and §3713-3721 (period-coverage with both-bounds DO-NOT-WRITE) — both passing the FIX-A reach bar.
- Continue verify-first against trino.io 467 RAW source on dialect facts (file_size_threshold default, date_parse vs parse_datetime return types, optimize snapshot atomicity).
